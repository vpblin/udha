import Foundation
@preconcurrency import AVFoundation
import CoreMedia

/// Camera video **and** microphone audio from one `AVCaptureSession`, written
/// into an `AssetWriterPair`.
///
/// The mic deliberately rides on this session rather than reusing
/// `Voice/AudioCapture`. That class is a hand-rolled AUHAL unit emitting raw
/// PCM16 `Data` with no presentation timestamps — perfect for the STT pipeline
/// it was built for, useless for muxing into a movie, where every sample needs
/// a PTS on the same clock as the video. Putting the mic on the capture session
/// gets properly stamped `CMSampleBuffer`s and natural camera/mic sync for
/// free, and leaves the meetings and voice paths completely untouched.
///
/// `@unchecked Sendable` with an internal lock: AVFoundation delivers on its
/// own queue while the engine drives start/stop from the main actor.
final class CameraCaptureSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                                 AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let sampleQueue = DispatchQueue(label: "udha.recording.camera", qos: .userInitiated)
    private let controlQueue = DispatchQueue(label: "udha.recording.camera.control")

    private var writer: AssetWriterPair?
    private var running = false
    private var sawFirstFrame = false
    private var lastFrameAtRaw: Date = .distantPast
    /// False for a mic-only session, which changes what counts as "producing".
    private var wantsVideo = true
    private var loggedAudioProbe = false
    private var audioProbeSumSquares = 0.0
    private var audioProbeSamples = 0

    /// Polled by the engine's watchdog — see the note on the screen source.
    var lastFrameAt: Date { lock.withLock { lastFrameAtRaw } }

    /// Fired on the first camera frame that lands.
    var onFirstFrame: (@Sendable () -> Void)?
    /// Fired when AVFoundation interrupts the session (device grabbed by
    /// another app, lid closed). The engine's watchdog rebuilds.
    var onInterrupted: (@Sendable () -> Void)?

    /// The live session, so a preview layer can be hung off it. Reading it
    /// costs nothing and takes no frames away from the writer.
    var captureSession: AVCaptureSession { session }

    /// Cameras worth offering in a picker.
    static func availableCameras() -> [(uid: String, name: String)] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.map { ($0.uniqueID, $0.localizedName) }
    }

    /// Microphones worth offering in a picker.
    ///
    /// Enumerated through AVFoundation rather than `AudioDeviceLister` because
    /// `resolveMic` looks devices up by `AVCaptureDevice.uniqueID`. The two
    /// happen to agree on macOS — an audio device's unique ID *is* its
    /// CoreAudio UID — so a mic chosen in Voice or Meetings still resolves
    /// here, but listing from the API that does the resolving is the version
    /// that cannot drift.
    static func availableMicrophones() -> [(uid: String, name: String)] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return discovery.devices.map { ($0.uniqueID, $0.localizedName) }
    }

    /// The name of whatever `resolveMic` would pick for a given stored UID —
    /// what the picker shows for "System default".
    static func microphoneName(forUID uid: String?) -> String? {
        resolveMic(uid: uid)?.localizedName
    }

    // MARK: - Lifecycle

    /// `includeCamera == false` (or no camera present) still produces a useful
    /// session: mic-only.
    ///
    /// That case is not an edge case, it is the common one. The camera grant is
    /// separate from the screen grant, so a user who allowed screen recording
    /// and skipped the camera prompt would otherwise lose their narration too —
    /// and for a demo the voice matters far more than the bubble. Coupling the
    /// two was the first thing the capture self-test caught.
    func start(writer: AssetWriterPair, cameraUID: String?, micUID: String?, includeCamera: Bool, includeMic: Bool) async throws {
        let camera = includeCamera ? Self.resolveCamera(uid: cameraUID) : nil
        guard camera != nil || includeMic else { throw RecordingSourceError.noCamera }
        lock.withLock { wantsVideo = camera != nil }

        session.beginConfiguration()
        // 720p is plenty for a bubble that renders at most ~1080 wide in the
        // portrait master, and it keeps the encoder well clear of the screen
        // stream's budget.
        session.sessionPreset = camera != nil ? .hd1280x720 : .high

        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }

        if let camera {
            do {
                let videoInput = try AVCaptureDeviceInput(device: camera)
                guard session.canAddInput(videoInput) else {
                    session.commitConfiguration()
                    throw RecordingSourceError.cannotAddInput("camera")
                }
                session.addInput(videoInput)
            } catch let error as RecordingSourceError {
                session.commitConfiguration()
                throw error
            } catch {
                session.commitConfiguration()
                throw error
            }
        }

        var micName = "none"
        if includeMic, let mic = Self.resolveMic(uid: micUID) {
            do {
                let micInput = try AVCaptureDeviceInput(device: mic)
                if session.canAddInput(micInput) {
                    session.addInput(micInput)
                    micName = mic.localizedName
                    // Named explicitly, because the fallback chain can land
                    // somewhere else entirely: a UID that no longer resolves
                    // (mic asleep, unplugged) drops through to the system
                    // default, and "why is my narration coming off the laptop
                    // lid" was not a question the log could answer before.
                    if let micUID, !micUID.isEmpty, mic.uniqueID != micUID {
                        Log.recording.info("CameraCaptureSource: requested mic is unavailable — using \(mic.localizedName)")
                    }
                } else {
                    Log.recording.error("CameraCaptureSource: session refused the mic input — continuing without narration")
                }
            } catch {
                Log.recording.error("CameraCaptureSource: mic input failed: \(error.localizedDescription)")
            }
        }

        if camera != nil {
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            // A late camera frame is worth less than a responsive session; the
            // compositor reads the file, not the live stream.
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)
            guard session.canAddOutput(videoOutput) else {
                session.commitConfiguration()
                throw RecordingSourceError.cannotAddInput("camera output")
            }
            session.addOutput(videoOutput)
        }

        // Pin the delivered audio format instead of taking whatever the device
        // hands over (the MV6 gives 48kHz mono *non-interleaved float32*, an
        // AirPods mic in call mode gives 16kHz).
        //
        // Two reasons. It removes the format chain as a variable in the one bug
        // that has actually bitten here — a take whose narration came out as
        // full-band noise at a constant level, which is what byte-level
        // misinterpretation sounds like, while the samples arriving at this
        // callback measured as a quiet room. And it hands the AAC input exactly
        // the shape it is configured for, so the only conversion left is the
        // encode itself.
        audioOutput.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        audioOutput.setSampleBufferDelegate(self, queue: sampleQueue)
        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
        }

        session.commitConfiguration()

        lock.withLock {
            self.writer = writer
            self.sawFirstFrame = false
            self.loggedAudioProbe = false
            self.audioProbeSumSquares = 0
            self.audioProbeSamples = 0
        }
        installObservers()
        let describedDevice = camera?.localizedName ?? "microphone only"

        // startRunning blocks while the device warms up — never on the main
        // actor, or the whole UI stalls behind a slow USB camera.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            controlQueue.async { [session] in
                session.startRunning()
                cont.resume()
            }
        }
        lock.withLock { running = true }
        Log.recording.info("CameraCaptureSource: capturing from \(describedDevice), mic=\(micName)")
    }

    func stop() async {
        removeObservers()
        let wasRunning: Bool = lock.withLock {
            let r = running
            running = false
            writer = nil
            return r
        }
        guard wasRunning else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            controlQueue.async { [session] in
                session.stopRunning()
                cont.resume()
            }
        }
    }

    /// Detaches without awaiting, for the quit path.
    func abort() {
        removeObservers()
        lock.withLock {
            running = false
            writer = nil
        }
        controlQueue.async { [session] in
            session.stopRunning()
        }
    }

    // MARK: - Sample delivery

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let isVideo = output === videoOutput

        let writer: AssetWriterPair? = lock.withLock { self.writer }
        guard let writer else { return }

        var shouldSignalFirstFrame = false
        lock.withLock {
            // In a mic-only session there is no video at all, so audio is what
            // proves the source is alive — both for opening the shared session
            // and for the engine's watchdog. Keying either off video frames
            // would leave a mic-only recording waiting forever for a frame that
            // is never coming.
            let counts = wantsVideo ? isVideo : !isVideo
            guard counts else { return }
            lastFrameAtRaw = Date()
            if !sawFirstFrame {
                sawFirstFrame = true
                shouldSignalFirstFrame = true
            }
        }
        if shouldSignalFirstFrame { onFirstFrame?() }
        if !isVideo { probeAudioLevel(sampleBuffer) }

        writer.append(sampleBuffer, isVideo: isVideo)
    }

    /// Logs the microphone's format and its level over the first second, once
    /// per take.
    ///
    /// This is the measurement that separates "the mic is delivering rubbish"
    /// from "we wrote it down wrong" — the two are indistinguishable in the
    /// finished file, and the difference is the entire diagnosis. A dead take
    /// (rms 0) and a take of pure noise (a flat rms around 0.3, unchanging
    /// whether anyone is speaking) are both visible here.
    private func probeAudioLevel(_ sample: CMSampleBuffer) {
        let alreadyLogged: Bool = lock.withLock { loggedAudioProbe }
        guard !alreadyLogged else { return }

        guard let format = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return }

        var blockBuffer: CMBlockBuffer?
        var list = AudioBufferList()
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample,
            bufferListSizeNeededOut: nil,
            bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        ) == noErr, let data = list.mBuffers.mData else { return }

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let byteCount = Int(list.mBuffers.mDataByteSize)
        var sumSquares = 0.0
        var count = 0
        if isFloat {
            let samples = data.bindMemory(to: Float.self, capacity: byteCount / 4)
            for i in 0..<(byteCount / 4) {
                let v = Double(samples[i])
                sumSquares += v * v
                count += 1
            }
        } else {
            let samples = data.bindMemory(to: Int16.self, capacity: byteCount / 2)
            for i in 0..<(byteCount / 2) {
                let v = Double(samples[i]) / 32768.0
                sumSquares += v * v
                count += 1
            }
        }
        guard count > 0 else { return }

        let ready: Bool = lock.withLock {
            audioProbeSumSquares += sumSquares
            audioProbeSamples += count
            guard audioProbeSamples >= Int(asbd.mSampleRate) else { return false }
            loggedAudioProbe = true
            return true
        }
        guard ready else { return }

        let rms = (audioProbeSumSquares / Double(audioProbeSamples)).squareRoot()
        let interleaving = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? "non-interleaved" : "interleaved"
        let shape = "\(Int(asbd.mSampleRate))Hz \(asbd.mChannelsPerFrame)ch \(asbd.mBitsPerChannel)bit \(isFloat ? "float" : "int") \(interleaving)"
        Log.recording.info("CameraCaptureSource: mic format \(shape) — first second rms=\(String(format: "%.4f", rms))")
    }

    // MARK: - Device resolution

    private static func resolveCamera(uid: String?) -> AVCaptureDevice? {
        if let uid, !uid.isEmpty, let device = AVCaptureDevice(uniqueID: uid) {
            return device
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.first ?? AVCaptureDevice.default(for: .video)
    }

    private static func resolveMic(uid: String?) -> AVCaptureDevice? {
        if let uid, !uid.isEmpty, let device = AVCaptureDevice(uniqueID: uid) {
            return device
        }
        return AVCaptureDevice.default(for: .audio)
    }

    // MARK: - Interruptions

    private var interruptionObserver: NSObjectProtocol?
    private var errorObserver: NSObjectProtocol?

    private func installObservers() {
        removeObservers()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil
        ) { [weak self] _ in
            Log.recording.error("CameraCaptureSource: session interrupted")
            self?.onInterrupted?()
        }
        errorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] note in
            let err = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            Log.recording.error("CameraCaptureSource: runtime error: \(err?.localizedDescription ?? "unknown")")
            self?.onInterrupted?()
        }
    }

    private func removeObservers() {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let errorObserver { NotificationCenter.default.removeObserver(errorObserver) }
        interruptionObserver = nil
        errorObserver = nil
    }
}
