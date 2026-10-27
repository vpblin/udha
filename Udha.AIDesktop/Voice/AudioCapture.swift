import Foundation
@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import os

/// Microphone capture, delivering PCM16 mono at `sampleRate`.
///
/// Deliberately NOT built on `AVAudioEngine`. Its `inputNode` binds to whatever
/// the *default* input device is at the moment the graph is instantiated, and
/// `kAudioOutputUnitProperty_CurrentDevice` can only be re-pointed afterwards.
/// That left two failures, both seen live on Aug 24: the engine started clean
/// and then never delivered a single buffer when the default input (a Bluetooth
/// headset at 16kHz) differed from the device we actually wanted (a 48kHz USB
/// mic); and the grab-then-release of the headset's mic on every start/stop
/// flipped it between A2DP and HFP, so the headphones announced "call ended"
/// once per rebuild — a 10s meeting watchdog turned that into a storm.
///
/// A HAL unit is pinned to its device *before* initialization and touches
/// nothing else: no default input, no output device, no Bluetooth profile.
@MainActor
final class AudioCapture {
    private let targetFormat: AVAudioFormat
    let preferredDeviceUID: String?

    nonisolated(unsafe) private var unit: AudioComponentInstance?
    nonisolated(unsafe) private var converter: AVAudioConverter?
    /// Rendered into by the HAL thread, then converted in place. Preallocated:
    /// the input proc is a real-time thread and must not allocate per callback.
    nonisolated(unsafe) private var scratch: AVAudioPCMBuffer?
    nonisolated(unsafe) private var converted: AVAudioPCMBuffer?
    nonisolated(unsafe) private var deliveredFirstChunk = false
    nonisolated(unsafe) private var rawTapCallbacks = 0
    nonisolated(unsafe) private var overflowLogged = false

    var onAudioChunk: ((Data) -> Void)?

    init(sampleRate: Double = 16000, preferredDeviceUID: String? = nil) {
        self.targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: sampleRate,
                                          channels: 1,
                                          interleaved: true)!
        self.preferredDeviceUID = preferredDeviceUID
    }

    deinit {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
    }

    static func requestPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    cont.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    func start() async throws {
        guard unit == nil else { return }

        let granted = await Self.requestPermission()
        guard granted else {
            Log.voice.error("AudioCapture: mic permission denied")
            throw NSError(domain: "AudioCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied. Open System Settings → Privacy & Security → Microphone and enable Udha.AIDesktop."])
        }

        // Resolve the device up front and pin it. Falling back to the *current*
        // default input still pins that specific device, so a later default
        // change can't silently move capture out from under us mid-meeting.
        var deviceID: AudioDeviceID
        if let uid = preferredDeviceUID, !uid.isEmpty,
           let resolved = AudioDeviceLister.deviceID(forUID: uid) {
            deviceID = resolved
            Log.voice.info("AudioCapture: using device \(uid)")
        } else if let fallback = Self.defaultInputDevice() {
            deviceID = fallback
            Log.voice.info("AudioCapture: using system default input (device \(fallback))")
        } else {
            throw NSError(domain: "AudioCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "No audio input device available."])
        }

        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0,
                                             componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw Self.err(-1, "No HAL audio component")
        }
        var instance: AudioComponentInstance?
        try Self.check(AudioComponentInstanceNew(component, &instance), "create HAL unit")
        guard let instance else { throw Self.err(-1, "HAL unit is nil") }

        do {
            var enable: UInt32 = 1
            try Self.check(AudioUnitSetProperty(instance, kAudioOutputUnitProperty_EnableIO,
                                                kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size)),
                           "enable input")
            var disable: UInt32 = 0
            try Self.check(AudioUnitSetProperty(instance, kAudioOutputUnitProperty_EnableIO,
                                                kAudioUnitScope_Output, 0, &disable, UInt32(MemoryLayout<UInt32>.size)),
                           "disable output")
            try Self.check(AudioUnitSetProperty(instance, kAudioOutputUnitProperty_CurrentDevice,
                                                kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)),
                           "set input device")

            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check(AudioUnitGetProperty(instance, kAudioUnitProperty_StreamFormat,
                                                kAudioUnitScope_Input, 1, &hardware, &size),
                           "read hardware format")

            // Ask the unit for deinterleaved Float32 at the hardware rate and
            // let AVAudioConverter do rate + downmix; AUHAL's own converter
            // does not reliably change channel count.
            let channels = max(1, min(2, hardware.mChannelsPerFrame))
            guard hardware.mSampleRate > 0,
                  let hwFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: hardware.mSampleRate,
                                               channels: AVAudioChannelCount(channels),
                                               interleaved: false) else {
                throw Self.err(-1, "Unsupported hardware format (\(hardware.mSampleRate)Hz, \(hardware.mChannelsPerFrame)ch)")
            }
            var client = hwFormat.streamDescription.pointee
            try Self.check(AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat,
                                                kAudioUnitScope_Output, 1, &client, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                           "set client format")

            let capacity = Self.bufferFrameSize(instance: instance)
            guard let scratchBuffer = AVAudioPCMBuffer(pcmFormat: hwFormat, frameCapacity: capacity) else {
                throw Self.err(-1, "Could not allocate capture buffer")
            }
            let outCapacity = AVAudioFrameCount(Double(capacity) * targetFormat.sampleRate / hwFormat.sampleRate) + 1024
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
                throw Self.err(-1, "Could not allocate conversion buffer")
            }
            scratch = scratchBuffer
            converted = outBuffer
            converter = AVAudioConverter(from: hwFormat, to: targetFormat)
            if converter == nil {
                throw Self.err(-1, "No converter from \(hwFormat) to \(targetFormat)")
            }

            var callback = AURenderCallbackStruct(
                inputProc: { refCon, flags, timestamp, bus, frames, _ in
                    Unmanaged<AudioCapture>.fromOpaque(refCon)
                        .takeUnretainedValue()
                        .render(flags: flags, timestamp: timestamp, bus: bus, frames: frames)
                },
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try Self.check(AudioUnitSetProperty(instance, kAudioOutputUnitProperty_SetInputCallback,
                                                kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                           "set input callback")

            deliveredFirstChunk = false
            rawTapCallbacks = 0
            overflowLogged = false
            unit = instance

            // Initialize + start can block for seconds while a device settles
            // (Bluetooth profile switches especially), so keep them off main.
            try await Task.detached {
                try Self.check(AudioUnitInitialize(instance), "initialize unit")
                try Self.check(AudioOutputUnitStart(instance), "start unit")
            }.value
            Log.voice.info("AudioCapture started")
        } catch {
            unit = nil
            AudioUnitUninitialize(instance)
            AudioComponentInstanceDispose(instance)
            throw error
        }
    }

    func stop() {
        guard let instance = unit else { return }
        // AudioOutputUnitStop does not return until the input proc has left,
        // so nothing can touch the buffers after this point.
        AudioOutputUnitStop(instance)
        AudioUnitUninitialize(instance)
        AudioComponentInstanceDispose(instance)
        unit = nil
        converter = nil
        scratch = nil
        converted = nil
    }

    // MARK: - Audio thread

    nonisolated private func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                    timestamp: UnsafePointer<AudioTimeStamp>,
                                    bus: UInt32,
                                    frames: UInt32) -> OSStatus {
        guard let unit, let scratch else { return noErr }
        guard frames <= scratch.frameCapacity else {
            if !overflowLogged {
                overflowLogged = true
                Log.voice.error("AudioCapture: HAL delivered \(frames) frames, buffer holds \(scratch.frameCapacity) — dropping")
            }
            return noErr
        }

        scratch.frameLength = frames
        let list = UnsafeMutableAudioBufferListPointer(scratch.mutableAudioBufferList)
        let bytesPerFrame = scratch.format.streamDescription.pointee.mBytesPerFrame
        for i in 0..<list.count {
            list[i].mDataByteSize = frames * bytesPerFrame
        }

        let status = AudioUnitRender(unit, flags, timestamp, bus, frames, scratch.mutableAudioBufferList)
        guard status == noErr else {
            if rawTapCallbacks == 0 {
                Log.voice.error("AudioCapture: AudioUnitRender failed (status \(status))")
            }
            return noErr
        }

        rawTapCallbacks += 1
        if rawTapCallbacks == 1 {
            Log.voice.debug("AudioCapture: first tap callback (\(frames) frames @ \(scratch.format.sampleRate)Hz)")
        }

        let data = encodeToPCM16(buffer: scratch)
        if !data.isEmpty {
            if !deliveredFirstChunk {
                deliveredFirstChunk = true
                Log.voice.debug("AudioCapture: first converted chunk (\(data.count) bytes)")
            }
            Task { @MainActor [weak self] in
                self?.onAudioChunk?(data)
            }
        } else if rawTapCallbacks == 1 {
            Log.voice.error("AudioCapture: first tap callback converted to EMPTY data — converter problem")
        }
        return noErr
    }

    nonisolated private func encodeToPCM16(buffer: AVAudioPCMBuffer) -> Data {
        guard let converter, let out = converted else { return Data() }
        out.frameLength = 0
        var supplied = false
        var error: NSError?
        let outcome = converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard outcome != .error, error == nil else { return Data() }
        let frames = Int(out.frameLength)
        guard frames > 0, let src = out.int16ChannelData?[0] else { return Data() }
        return Data(bytes: src, count: frames * MemoryLayout<Int16>.size)
    }

    // MARK: - Core Audio helpers

    private static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    /// The HAL never hands over more than the device's buffer frame size, but
    /// that can change under us (another client resizing it), so keep headroom.
    private static func bufferFrameSize(instance: AudioComponentInstance) -> AVAudioFrameCount {
        var frames: UInt32 = 512
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioUnitGetProperty(instance, kAudioDevicePropertyBufferFrameSize,
                                 kAudioUnitScope_Global, 0, &frames, &size)
        return AVAudioFrameCount(max(4096, frames * 4))
    }

    nonisolated private static func check(_ status: OSStatus, _ what: String) throws {
        guard status != noErr else { return }
        throw err(status, "AudioCapture could not \(what) (status \(status))")
    }

    nonisolated private static func err(_ code: OSStatus, _ message: String) -> NSError {
        NSError(domain: "AudioCapture", code: Int(code), userInfo: [NSLocalizedDescriptionKey: message])
    }
}
