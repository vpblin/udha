import Foundation
@preconcurrency import AVFoundation
import CoreAudio

enum SystemAudioTapError: Error, LocalizedError {
    case permissionDenied
    case osError(OSStatus, String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "System-audio recording permission denied. Open System Settings → Privacy & Security → Screen & System Audio Recording."
        case .osError(let status, let stage):
            return "System audio tap failed at \(stage) (OSStatus \(status))"
        }
    }
}

/// Captures everything the Mac is playing ("Them" in a call) via a Core Audio
/// process tap + private aggregate device (macOS 14.4+ API; this app targets
/// 15+). Chosen over ScreenCaptureKit because it uses the milder "System Audio
/// Recording Only" TCC instead of Screen Recording.
///
/// Mirrors AudioCapture's shape: PCM16 mono 16k chunks delivered on the main
/// actor via a single closure. Udha's own process is excluded from the tap so
/// the app's TTS voice never lands in the meeting transcript.
@MainActor
final class SystemAudioTap {
    /// PCM16 LE mono @16k, delivered on the main actor.
    var onAudioChunk: ((Data) -> Void)?
    /// Fired after an automatic rebuild (output device changed).
    var onStreamInterrupted: (() -> Void)?
    private(set) var isRunning = false

    private var resources: TapResources?
    private var deviceListenerInstalled = false
    private var rebuildInFlight = false
    private var lastRebuild = Date.distantPast

    func start() async throws {
        guard !isRunning else { return }
        let resources = try await Task.detached(priority: .userInitiated) {
            try TapResources.create()
        }.value
        self.resources = resources
        resources.onConverted = { [weak self] data in
            Task { @MainActor in
                self?.onAudioChunk?(data)
            }
        }
        let status = resources.startIO()
        guard status == noErr else {
            resources.teardown()
            self.resources = nil
            throw SystemAudioTapError.osError(status, "AudioDeviceStart")
        }
        isRunning = true
        installDeviceListenerIfNeeded()
        Log.meeting.info("SystemAudioTap started (tap \(resources.tapID), aggregate \(resources.aggregateID))")
    }

    func stop() {
        guard let resources else { return }
        resources.teardown()
        self.resources = nil
        isRunning = false
        Log.meeting.info("SystemAudioTap stopped")
    }

    /// The tap's format follows the default output device; when the device
    /// changes (AirPods connect, headphones unplug) a full rebuild is the only
    /// safe path. Downstream sees a seamless PCM16@16k stream either way.
    private func installDeviceListenerIfNeeded() {
        guard !deviceListenerInstalled else { return }
        deviceListenerInstalled = true
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
        ) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.handleOutputDeviceChanged()
            }
        }
    }

    private func handleOutputDeviceChanged() {
        guard isRunning, !rebuildInFlight else { return }
        // Cooldown: our own aggregate teardown/creation can echo device-list
        // notifications; never let that self-trigger a rebuild storm.
        guard Date().timeIntervalSince(lastRebuild) > 3 else { return }
        lastRebuild = Date()
        rebuildInFlight = true
        Log.meeting.info("SystemAudioTap: default output device changed — rebuilding")
        stop()
        Task { @MainActor in
            defer { rebuildInFlight = false }
            do {
                try await start()
                onStreamInterrupted?()
            } catch {
                Log.meeting.error("SystemAudioTap: rebuild failed: \(error.localizedDescription)")
            }
        }
    }
}

/// The Core Audio object chain for one live tap. Built and torn down off the
/// main actor (creating the tap can block on the TCC prompt); the IOProc runs
/// on its own serial queue.
final class TapResources: @unchecked Sendable {
    let tapID: AudioObjectID
    let aggregateID: AudioObjectID
    private let procID: AudioDeviceIOProcID
    private let queue: DispatchQueue
    private let holder: IOProcHolder

    var onConverted: ((Data) -> Void)? {
        get { holder.onConverted }
        set { holder.onConverted = newValue }
    }

    private init(tapID: AudioObjectID, aggregateID: AudioObjectID, procID: AudioDeviceIOProcID, queue: DispatchQueue, holder: IOProcHolder) {
        self.tapID = tapID
        self.aggregateID = aggregateID
        self.procID = procID
        self.queue = queue
        self.holder = holder
    }

    static func create() throws -> TapResources {
        // 1. Exclude our own process so Udha's TTS voice never leaks into "Them".
        var ownProcessObject = AudioObjectID(0)
        do {
            var pid = pid_t(ProcessInfo.processInfo.processIdentifier)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            let status = withUnsafeMutablePointer(to: &pid) { pidPtr in
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject), &address,
                    UInt32(MemoryLayout<pid_t>.size), pidPtr,
                    &size, &ownProcessObject
                )
            }
            if status != noErr {
                Log.meeting.error("SystemAudioTap: pid translation failed (\(status)) — proceeding without self-exclusion")
                ownProcessObject = 0
            }
        }

        // 2. Mono global tap (the HAL does the stereo mixdown for us).
        let excluded: [AudioObjectID] = ownProcessObject != 0 ? [ownProcessObject] : []
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
        description.name = "Udha Meeting Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        // A global tap hears the mix "as heard on" ONE device — by default the
        // system default output. Call audio often plays to a device that is
        // NOT the default (Zoom pinned to a headset while macOS default points
        // at the display): pin the tap to the output device that is actually
        // running, or it captures pure silence.
        if let runningUID = activeOutputDeviceUID() {
            description.deviceUID = runningUID
            Log.meeting.info("SystemAudioTap: tapping running output device \(runningUID)")
        }

        // 3. Create the tap — this is the TCC trigger point. Any failure is
        //    treated as denied-or-unavailable.
        var tapID = AudioObjectID(0)
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        if (status != noErr || tapID == 0) && description.deviceUID != nil {
            // Pinning to some devices (Bluetooth headsets in call mode) makes
            // tap creation itself fail. An unpinned tap follows the default
            // output — usually that same device — and does create.
            Log.meeting.info("SystemAudioTap: pinned tap failed (status \(status)) — retrying unpinned")
            description.deviceUID = nil
            tapID = 0
            status = AudioHardwareCreateProcessTap(description, &tapID)
        }
        guard status == noErr, tapID != 0 else {
            // Not a permission signal: TCC is handled by SystemAudioAccess
            // (an unauthorized tap creates fine and captures silence). A
            // create failure here is a device/HAL problem.
            Log.meeting.error("SystemAudioTap: AudioHardwareCreateProcessTap failed (status \(status), tapID \(tapID))")
            throw SystemAudioTapError.osError(status, "AudioHardwareCreateProcessTap")
        }

        func failAndCleanup(_ status: OSStatus, _ stage: String, agg: AudioObjectID? = nil) -> SystemAudioTapError {
            if let agg { AudioHardwareDestroyAggregateDevice(agg) }
            AudioHardwareDestroyProcessTap(tapID)
            return SystemAudioTapError.osError(status, stage)
        }

        // 4. Read the tap's stream format (mono Float32 at the output device's rate).
        var asbd = AudioStreamBasicDescription()
        do {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
            guard status == noErr else { throw failAndCleanup(status, "kAudioTapPropertyFormat") }
        }

        // 5. Private aggregate device: the tap plus the default output device
        //    as main sub-device. The sub-device is load-bearing — a tap-only
        //    aggregate has no clock source, its IOProc never fires, and the
        //    stream reads as silent.
        var aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Udha Meeting Aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        // Clock preference: built-in speakers over the default output. A
        // Bluetooth headset in telephony (HFP) mode — i.e. exactly when the
        // user is on a call — stops providing a usable clock and the IOProc
        // never fires. The built-in device always ticks regardless of what
        // the audio is actually routed to (the tap is global; it captures
        // processes, not a device).
        if let clockUID = Self.clockDeviceUID() {
            aggregateDescription[kAudioAggregateDeviceMainSubDeviceKey] = clockUID
            aggregateDescription[kAudioAggregateDeviceSubDeviceListKey] = [
                [kAudioSubDeviceUIDKey: clockUID]
            ]
        } else {
            Log.meeting.error("SystemAudioTap: no clock device found — tap may stay silent")
        }
        var aggregateID = AudioObjectID(0)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != 0 else {
            throw failAndCleanup(status, "AudioHardwareCreateAggregateDevice")
        }

        // The IOProc delivers samples at the AGGREGATE's rate, not the rate
        // the tap advertises. When the default output is e.g. a Bluetooth
        // headset in 16kHz call mode while the clock runs at 48kHz, trusting
        // the tap's rate feeds 3x-slowed audio to STT — which then
        // hallucinates fluent nonsense. Trust the aggregate.
        do {
            var rateAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var aggregateRate: Double = 0
            var rateSize = UInt32(MemoryLayout<Double>.size)
            if AudioObjectGetPropertyData(aggregateID, &rateAddress, 0, nil, &rateSize, &aggregateRate) == noErr,
               aggregateRate > 0, abs(aggregateRate - asbd.mSampleRate) > 1 {
                Log.meeting.info("SystemAudioTap: overriding tap rate \(asbd.mSampleRate) → aggregate rate \(aggregateRate)")
                asbd.mSampleRate = aggregateRate
            }
        }
        guard let tapFormat = AVAudioFormat(streamDescription: &asbd) else {
            throw failAndCleanup(-1, "AVAudioFormat(streamDescription:)", agg: aggregateID)
        }

        // 6. IOProc converting each buffer to PCM16 mono 16k (same converter
        //    pattern as AudioCapture.encodeToPCM16).
        let holder = IOProcHolder(tapFormat: tapFormat)
        let queue = DispatchQueue(label: "udha.meeting.systemtap")
        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inInputData, _, _, _ in
            holder.handle(bufferList: inInputData)
        }
        guard status == noErr, let procID else {
            throw failAndCleanup(status, "AudioDeviceCreateIOProcIDWithBlock", agg: aggregateID)
        }

        return TapResources(tapID: tapID, aggregateID: aggregateID, procID: procID, queue: queue, holder: holder)
    }

    /// Clock provider for the aggregate: the built-in output when present,
    /// else the default output. Inline CoreAudio reads — this runs off the
    /// main actor, where the MainActor-isolated AudioDeviceLister isn't
    /// reachable.
    private static func clockDeviceUID() -> String? {
        if let builtIn = builtInOutputDeviceID(), let uid = deviceUID(builtIn) {
            return uid
        }
        var deviceID = AudioObjectID(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceUID(deviceID)
    }

    /// The output device that is currently rendering audio (IsRunningSomewhere),
    /// preferring the default output when it qualifies. nil → let the tap
    /// follow the system default.
    private static func activeOutputDeviceUID() -> String? {
        var defaultOut = AudioObjectID(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &defaultOut)

        func isRunning(_ device: AudioObjectID) -> Bool {
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var running = UInt32(0)
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(device, &runningAddress, 0, nil, &runningSize, &running) == noErr
                && running != 0
        }
        func streamCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
            var streamsAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamsSize = UInt32(0)
            guard AudioObjectGetPropertyDataSize(device, &streamsAddress, 0, nil, &streamsSize) == noErr else { return 0 }
            return Int(streamsSize) / MemoryLayout<AudioObjectID>.size
        }

        if defaultOut != 0 && isRunning(defaultOut) {
            return deviceUID(defaultOut)
        }
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var listSize = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &listSize) == noErr,
              listSize > 0 else { return nil }
        var devices = [AudioObjectID](repeating: 0, count: Int(listSize) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &listSize, &devices) == noErr else {
            return nil
        }
        // Non-default candidates must be pure outputs: a microphone whose
        // input is held by a conferencing app reads as "running", and some
        // mics (Shure MV6) expose a headphone-monitor output stream — pinning
        // the tap there captures nothing. Devices with any input streams only
        // qualify via the default-output branch above (a BT headset in a call
        // has input streams but IS the default output).
        for device in devices
        where device != defaultOut
            && streamCount(device, scope: kAudioObjectPropertyScopeOutput) > 0
            && streamCount(device, scope: kAudioObjectPropertyScopeInput) == 0
            && isRunning(device) {
            return deviceUID(device)
        }
        return nil
    }

    private static func builtInOutputDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return nil }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else {
            return nil
        }
        for device in devices {
            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var transport = UInt32(0)
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(device, &transportAddress, 0, nil, &transportSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { continue }
            var streamsAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamsSize = UInt32(0)
            guard AudioObjectGetPropertyDataSize(device, &streamsAddress, 0, nil, &streamsSize) == noErr,
                  streamsSize > 0 else { continue }
            return device
        }
        return nil
    }

    private static func deviceUID(_ deviceID: AudioObjectID) -> String? {
        var uid: CFString = "" as CFString
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        let result = uid as String
        return result.isEmpty ? nil : result
    }

    func startIO() -> OSStatus {
        AudioDeviceStart(aggregateID, procID)
    }

    func teardown() {
        AudioDeviceStop(aggregateID, procID)
        AudioDeviceDestroyIOProcID(aggregateID, procID)
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
        holder.onConverted = nil
    }
}

/// Owns the AVAudioConverter and runs on the IOProc's serial queue only.
private final class IOProcHolder: @unchecked Sendable {
    private let tapFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var callbacks = 0
    var onConverted: ((Data) -> Void)?

    init(tapFormat: AVAudioFormat) {
        self.tapFormat = tapFormat
        Log.meeting.debug("SystemAudioTap: tap format \(tapFormat.sampleRate)Hz ch=\(tapFormat.channelCount) \(tapFormat.commonFormat.rawValue)")
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true
        )!
        if tapFormat.commonFormat != .pcmFormatInt16 || tapFormat.sampleRate != 16000 || tapFormat.channelCount != 1 {
            self.converter = AVAudioConverter(from: tapFormat, to: targetFormat)
        }
    }

    func handle(bufferList: UnsafePointer<AudioBufferList>) {
        // The aggregate's input side is [sub-device input streams…, tap].
        // Output-only sub-devices contribute nothing, but when the default
        // output does expose inputs the tap is always the LAST buffer.
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferList)
        )
        callbacks += 1
        if callbacks == 1 {
            let sizes = buffers.map { "\($0.mDataByteSize)B/\($0.mNumberChannels)ch" }.joined(separator: ", ")
            Log.meeting.debug("SystemAudioTap: first IOProc callback — \(buffers.count) buffer(s): [\(sizes)]")
        }
        guard buffers.count > 0 else { return }
        let tapBuffer = buffers[buffers.count - 1]
        guard tapBuffer.mDataByteSize > 0, tapBuffer.mData != nil else {
            if callbacks == 1 {
                Log.meeting.error("SystemAudioTap: first IOProc callback had empty tap buffer")
            }
            return
        }

        var single = AudioBufferList(mNumberBuffers: 1, mBuffers: tapBuffer)
        // Converted (copied) synchronously below, so pointing at the HAL's
        // buffer for the duration of this call is safe.
        let data: Data = withUnsafeMutablePointer(to: &single) { ablPtr in
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: tapFormat,
                bufferListNoCopy: ablPtr,
                deallocator: nil
            ) else { return Data() }
            return encodeToPCM16(buffer: buffer)
        }
        if !data.isEmpty {
            if callbacks == 1 {
                Log.meeting.debug("SystemAudioTap: first converted chunk (\(data.count) bytes)")
            }
            onConverted?(data)
        } else if callbacks == 1 {
            Log.meeting.error("SystemAudioTap: first IOProc callback converted to EMPTY data — converter problem")
        }
    }

    private func encodeToPCM16(buffer: AVAudioPCMBuffer) -> Data {
        if buffer.format.commonFormat == .pcmFormatInt16
            && buffer.format.sampleRate == targetFormat.sampleRate
            && buffer.format.channelCount == 1 {
            let frames = Int(buffer.frameLength)
            guard frames > 0, let src = buffer.int16ChannelData?[0] else { return Data() }
            return Data(bytes: src, count: frames * MemoryLayout<Int16>.size)
        }
        guard let converter else { return Data() }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return Data() }
        var done = false
        var error: NSError?
        _ = converter.convert(to: outBuffer, error: &error) { _, status in
            if done {
                status.pointee = .noDataNow
                return nil
            }
            done = true
            status.pointee = .haveData
            return buffer
        }
        if error != nil { return Data() }
        let frames = Int(outBuffer.frameLength)
        guard frames > 0, let src = outBuffer.int16ChannelData?[0] else { return Data() }
        return Data(bytes: src, count: frames * MemoryLayout<Int16>.size)
    }
}
