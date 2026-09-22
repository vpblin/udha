import Foundation
import AppKit
@preconcurrency import AVFoundation
import CoreMedia
import Observation

/// Owns everything that happens between "record" and "stop" for one video:
/// the screen stream (video + system audio), the camera session (camera +
/// mic), and the two output files they write into.
///
/// Failure posture is the inverse of `MeetingRecorder`'s. There, the mic was
/// fatal and system audio degraded. Here the **screen is fatal** — a screen
/// recorder with no screen is nothing — while camera and mic each degrade
/// independently, so a dead webcam costs you the bubble rather than the take.
///
/// Timeline semantics: both files share one session start on the host clock,
/// and pauses are excised from both together, so the two raw files can be laid
/// over each other later with no alignment pass. See `AssetWriterPair`.
@MainActor
@Observable
final class RecordingEngine {
    enum State: Equatable {
        case idle, starting, recording, paused, stopping, finished
        case failed(String)
    }

    /// What actually got captured, handed back to the store on stop.
    struct Result: Sendable {
        var duration: TimeInterval
        /// The one that actually matters. Everything else can be absent and
        /// still leave a usable recording; without this there is nothing to
        /// render, and the old code did not check it at all — which is how a
        /// screen-less take reached the compositor before anyone noticed.
        var hasScreenVideo: Bool
        var hasCamera: Bool
        var hasMic: Bool
        var hasSystemAudio: Bool
    }

    private(set) var state: State = .idle
    private(set) var startedAt: Date?
    private(set) var cameraUnavailable = false
    private(set) var micUnavailable = false
    private(set) var systemAudioUnavailable = false

    private let screenURL: URL
    private let cameraFileURL: URL
    private let config: ConfigStore
    private let screenAccess: ScreenRecordingAccess
    private let cameraAccess: CameraAccess

    private var screenSource: ScreenCaptureSource?
    private var cameraSource: CameraCaptureSource?
    private var screenWriter: AssetWriterPair?
    private var cameraWriter: AssetWriterPair?

    private var target: ScreenCaptureTarget?
    /// True for a camera-only take: no screen stream, and the camera writer
    /// takes over as the one that claims t=0.
    private var isCameraOnly = false
    private var wantsCamera = false
    private var wantsMic = false
    /// True whenever the second capture source is worth running at all — it
    /// carries the camera, the mic, or both.
    private var wantsLocalSource: Bool { wantsCamera || wantsMic }

    // t=0 is claimed by the screen's first frame, inside the capture callback.
    // See SharedSessionStart for why this is not decided up here.
    private var sessionStart = SharedSessionStart()
    private var screenProducing = false
    private var sessionFallback: Task<Void, Never>?

    // Active-time bookkeeping (pauses excised).
    private var pausedTotal: TimeInterval = 0
    private var pausedAt: Date?

    // Watchdog.
    private var watchdog: Timer?
    private var screenRebuilds = 0
    private var cameraRebuilds = 0
    private var lastScreenRebuild = Date.distantPast
    private var lastCameraRebuild = Date.distantPast
    private let maxRebuildsPerStream = 5
    private var wakeObserver: NSObjectProtocol?

    var activeDuration: TimeInterval {
        guard let startedAt else { return 0 }
        let end = pausedAt ?? Date()
        return max(0, end.timeIntervalSince(startedAt) - pausedTotal)
    }

    /// The camera session behind the live self-view, or nil when this take has
    /// no camera. Read through `cameraSource`, which observation tracks, so the
    /// preview re-attaches by itself whenever the watchdog rebuilds the source.
    var cameraPreviewSession: AVCaptureSession? {
        guard wantsCamera, let cameraSource else { return nil }
        return cameraSource.captureSession
    }

    init(screenURL: URL, cameraURL: URL, config: ConfigStore, screenAccess: ScreenRecordingAccess, cameraAccess: CameraAccess) {
        self.screenURL = screenURL
        self.cameraFileURL = cameraURL
        self.config = config
        self.screenAccess = screenAccess
        self.cameraAccess = cameraAccess
    }

    // MARK: - Lifecycle

    /// `target == nil` records the camera alone — no screen, and therefore no
    /// Screen Recording permission and no system audio (which arrives on the
    /// screen stream). The inverse of the usual posture: here the *camera* is
    /// fatal, because it is the entire picture.
    func start(target: ScreenCaptureTarget?) async {
        guard state == .idle || state == .finished || isFailed else { return }
        state = .starting
        self.target = target
        isCameraOnly = target == nil

        let cfg = config.config.recordings

        if !isCameraOnly {
            guard await screenAccess.requestAccess() else {
                state = .failed("Screen recording access is off. Enable Udha in System Settings → Privacy & Security → Screen & System Audio Recording, then restart Udha.")
                return
            }
            if screenAccess.needsRelaunchAfterGrant {
                // Capturing now would silently produce black frames for the
                // whole take — far worse than refusing and saying why.
                state = .failed("Screen recording was just enabled. Udha has to restart before macOS will let it capture.")
                return
            }
        }

        wantsCamera = cfg.includeCamera || isCameraOnly
        if wantsCamera {
            let granted = await cameraAccess.requestAccess()
            if !granted {
                if isCameraOnly {
                    state = .failed("Camera access is off. Enable Udha under Privacy & Security → Camera.")
                    return
                }
                wantsCamera = false
                cameraUnavailable = true
                // The mic is a separate grant and a separate device — losing
                // the bubble must not cost the narration.
                Log.recording.info("RecordingEngine: camera denied — recording screen\(cfg.includeMic ? " + mic" : " only")")
            }
        }
        wantsMic = cfg.includeMic

        pausedTotal = 0
        pausedAt = nil
        startedAt = nil
        sessionStart = SharedSessionStart()
        screenProducing = false
        micUnavailable = !cfg.includeMic
        // System audio rides on the screen stream, so a camera-only take has
        // none by construction.
        systemAudioUnavailable = isCameraOnly || !cfg.captureSystemAudio

        if let target {
            // Screen writer sizing has to match what SCK is configured to emit,
            // so resolve the target's dimensions before opening the file.
            guard let size = await resolveCaptureSize(for: target) else {
                state = .failed("That screen or window is no longer available.")
                return
            }
            guard let screenWriter = AssetWriterPair.make(
                url: screenURL, width: size.width, height: size.height,
                includeVideo: true, includeAudio: cfg.captureSystemAudio, label: "screen"
            ) else {
                state = .failed(RecordingSourceError.writerUnavailable.localizedDescription)
                return
            }
            screenWriter.useSessionStart(sessionStart, primary: true)
            self.screenWriter = screenWriter
        }

        if wantsLocalSource {
            cameraWriter = AssetWriterPair.make(
                url: cameraFileURL, width: 1280, height: 720,
                includeVideo: wantsCamera, includeAudio: wantsMic, label: "camera"
            )
            if cameraWriter == nil {
                if isCameraOnly {
                    state = .failed(RecordingSourceError.writerUnavailable.localizedDescription)
                    return
                }
                wantsCamera = false
                wantsMic = false
                cameraUnavailable = true
            } else {
                // With no screen there is nobody else to claim t=0, so the
                // camera opens the shared session itself.
                cameraWriter?.useSessionStart(sessionStart, primary: isCameraOnly)
            }
        }

        if target != nil {
            do {
                try await startScreenCapture()
            } catch {
                await teardownAfterFailedStart()
                state = .failed(error.localizedDescription)
                return
            }
        }

        if wantsLocalSource {
            await startCameraCapture()
        }

        // Whichever source is primary opens the session itself, so the only
        // thing left to catch is that source never producing a frame at all.
        sessionFallback = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, !Task.isCancelled, !self.sessionStart.isOpen else { return }
            let what = self.isCameraOnly ? "camera" : "screen"
            Log.recording.error("RecordingEngine: no \(what) frames after 6s — failing")
            self.state = .failed(self.isCameraOnly
                ? "The camera never produced a frame. Check that no other app is holding it."
                : "The screen never produced a frame. Check Screen Recording permission, then restart Udha.")
            await self.teardownAfterFailedStart()
        }

        state = .recording
        installObservers()
        startWatchdog()
        micUnavailable = !wantsMic
        Log.recording.info("RecordingEngine: recording (screen=\(!isCameraOnly) camera=\(wantsCamera) mic=\(wantsMic) systemAudio=\(!systemAudioUnavailable))")
    }

    func pause() {
        guard state == .recording else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        // The capture streams stay live. Stopping and restarting SCStream and
        // AVCaptureSession costs about a second each way, which would swallow
        // the first moment after every resume — the opposite of what pause is
        // for. Trade-off: the camera indicator light stays lit while paused, so
        // the UI has to say "paused", not imply the camera is off.
        screenWriter?.pause(at: now)
        cameraWriter?.pause(at: now)
        pausedAt = Date()
        state = .paused
        Log.recording.info("RecordingEngine: paused")
    }

    func resume() {
        guard state == .paused else { return }
        if let pausedAt {
            pausedTotal += Date().timeIntervalSince(pausedAt)
        }
        pausedAt = nil
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        screenWriter?.resume(at: now)
        cameraWriter?.resume(at: now)
        state = .recording
        Log.recording.info("RecordingEngine: resumed")
    }

    @discardableResult
    func stop() async -> Result {
        guard state == .recording || state == .paused else {
            return Result(duration: activeDuration, hasScreenVideo: false, hasCamera: false, hasMic: false, hasSystemAudio: false)
        }
        state = .stopping
        let duration = activeDuration
        stopWatchdog()
        removeObservers()
        sessionFallback?.cancel()
        sessionFallback = nil

        await screenSource?.stop()
        await cameraSource?.stop()
        screenSource = nil
        cameraSource = nil

        // Must be awaited: an unfinished writer leaves the tail fragment
        // unflushed, and the compositor is about to read these files.
        await screenWriter?.finish()
        await cameraWriter?.finish()

        let result = Result(
            duration: duration,
            hasScreenVideo: screenWriter?.hasVideo ?? false,
            hasCamera: cameraWriter?.hasVideo ?? false,
            hasMic: cameraWriter?.hasAudio ?? false,
            hasSystemAudio: screenWriter?.hasAudio ?? false
        )
        screenWriter = nil
        cameraWriter = nil
        state = .finished
        Log.recording.info("RecordingEngine: stopped after \(Int(duration))s (screenVideo=\(result.hasScreenVideo) camera=\(result.hasCamera) mic=\(result.hasMic) systemAudio=\(result.hasSystemAudio))")
        if !result.hasScreenVideo {
            Log.recording.error("RecordingEngine: NO screen video was written — the take has no picture")
        }
        return result
    }

    /// Synchronous best-effort teardown for the app-quit path. No await — the
    /// fragmented .mov stays playable without a final moov atom, which is the
    /// whole reason `movieFragmentInterval` is set.
    func abort() {
        stopWatchdog()
        removeObservers()
        sessionFallback?.cancel()
        sessionFallback = nil
        screenSource?.abort()
        cameraSource?.abort()
        screenWriter?.abort()
        cameraWriter?.abort()
        screenSource = nil
        cameraSource = nil
        screenWriter = nil
        cameraWriter = nil
        if state == .recording || state == .paused || state == .stopping || state == .starting {
            state = .finished
        }
        Log.recording.info("RecordingEngine: aborted")
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    // MARK: - Session opening

    /// Called once the screen's first frame has opened the shared session, just
    /// to stamp wall-clock start and stand the watchdog down. The writers have
    /// already begun by the time this runs.
    private func noteSessionOpened() {
        guard startedAt == nil else { return }
        startedAt = Date()
        sessionFallback?.cancel()
        sessionFallback = nil
        Log.recording.info("RecordingEngine: session opened by first screen frame")
    }

    // MARK: - Capture wiring

    private func resolveCaptureSize(for target: ScreenCaptureTarget) async -> (width: Int, height: Int)? {
        guard let candidates = try? await ScreenCaptureSource.availableTargets(),
              let match = candidates.first(where: { $0.target == target }) else { return nil }
        return ScreenCaptureSource.captureSize(width: match.width, height: match.height)
    }

    private func startScreenCapture() async throws {
        guard let target, let screenWriter else { throw RecordingSourceError.writerUnavailable }
        let cfg = config.config.recordings
        let source = ScreenCaptureSource()
        source.onFirstFrame = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.screenProducing = true
                self.noteSessionOpened()
            }
        }
        source.onStreamStopped = { [weak self] _ in
            Task { @MainActor in
                self?.rebuildScreen(reason: "stream stopped")
            }
        }
        // SCK's startCapture can hang while displays reconfigure — the same
        // class of problem the meeting recorder hit with CoreAudio and Bluetooth.
        // Read here rather than captured at start: the watchdog rebuilds this
        // stream, and by then the border may have been re-created with a new
        // window number.
        let borderWindows = CaptureBorderController.shared.windowIDs
        try await withStartTimeout(seconds: 10) {
            try await source.start(
                target: target, writer: screenWriter,
                frameRate: cfg.frameRate,
                capturesAudio: cfg.captureSystemAudio,
                showsCursor: cfg.showsCursor,
                excludingWindowIDs: borderWindows
            )
        }
        screenSource = source
    }

    private func startCameraCapture() async {
        guard let cameraWriter else { return }
        let cfg = config.config
        let micUID = cfg.effectiveRecordingMicUID

        let source = CameraCaptureSource()
        source.onFirstFrame = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.cameraUnavailable = false
                if self.isCameraOnly { self.noteSessionOpened() }
            }
        }
        source.onInterrupted = { [weak self] in
            Task { @MainActor in
                self?.rebuildCamera(reason: "session interrupted")
            }
        }
        do {
            try await withStartTimeout(seconds: 10) {
                try await source.start(
                    writer: cameraWriter,
                    cameraUID: cfg.recordings.cameraDeviceUID.isEmpty ? nil : cfg.recordings.cameraDeviceUID,
                    micUID: micUID,
                    includeCamera: self.wantsCamera,
                    includeMic: self.wantsMic
                )
            }
            cameraSource = source
        } catch {
            // Degrade, never fail: the screen is the recording.
            cameraUnavailable = true
            Log.recording.error("RecordingEngine: camera start failed: \(error.localizedDescription) — continuing screen-only")
        }
    }

    /// Swap the camera or the microphone mid-take, after the picker wrote a new
    /// UID into the config.
    ///
    /// Only a *swap* — turning the camera or the mic on partway through is not
    /// supported, because the output file's tracks were laid down at start and
    /// a track cannot be grown into a movie that is already being written. The
    /// on/off toggles therefore apply to the next recording, and the picker
    /// says so by only listing devices while a take is live.
    func reloadLocalDevices() {
        guard state == .recording || state == .paused, wantsLocalSource else { return }
        rebuildCamera(reason: "device changed")
    }

    private func teardownAfterFailedStart() async {
        await screenSource?.stop()
        await cameraSource?.stop()
        screenSource = nil
        cameraSource = nil
        screenWriter?.abort()
        cameraWriter?.abort()
        screenWriter = nil
        cameraWriter = nil
    }

    private struct StartTimeout: Error {}

    /// Lifted from `MeetingRecorder`. A hung stream start must degrade that
    /// stream, never wedge the recorder — and transitively the app. The losing
    /// task is abandoned rather than awaited: leaking a hung stream is strictly
    /// better than joining its fate.
    private func withStartTimeout<T: Sendable>(
        seconds: Double,
        _ operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { @MainActor in
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw StartTimeout()
            }
            guard let first = try await group.next() else { throw StartTimeout() }
            group.cancelAll()
            return first
        }
    }

    // MARK: - Resilience

    private func installObservers() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWake()
            }
        }
    }

    private func removeObservers() {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
    }

    private func handleWake() {
        guard state == .recording else { return }
        Log.recording.info("RecordingEngine: system woke — rebuilding captures")
        if !isCameraOnly { rebuildScreen(reason: "wake") }
        if wantsLocalSource { rebuildCamera(reason: "wake") }
    }

    private func rebuildScreen(reason: String) {
        guard state == .recording else { return }
        Log.recording.info("RecordingEngine: restarting screen capture (\(reason))")
        let old = screenSource
        screenSource = nil
        Task { @MainActor in
            await old?.stop()
            do {
                try await startScreenCapture()
            } catch {
                Log.recording.error("RecordingEngine: screen rebuild failed: \(error.localizedDescription)")
            }
        }
    }

    /// Also runs while paused — the capture sessions stay live through a pause
    /// (see `pause()`), and the writer drops what arrives, so swapping a device
    /// mid-pause is safe and lands before the take resumes.
    private func rebuildCamera(reason: String) {
        guard state == .recording || state == .paused, wantsLocalSource else { return }
        Log.recording.info("RecordingEngine: restarting camera capture (\(reason))")
        let old = cameraSource
        cameraSource = nil
        Task { @MainActor in
            await old?.stop()
            await startCameraCapture()
        }
    }

    /// Covers everything that goes quiet without an error: a display
    /// reconfiguration that killed the stream, a camera another app grabbed,
    /// TCC revoked mid-recording.
    ///
    /// Note the screen source stamps liveness on *every* sample including SCK's
    /// `.idle` ones, so a user reading a static page for a minute does not look
    /// like a dead stream here.
    private func startWatchdog() {
        screenRebuilds = 0
        cameraRebuilds = 0
        lastScreenRebuild = .distantPast
        lastCameraRebuild = .distantPast
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.watchdogTick()
            }
        }
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private func watchdogTick() {
        guard state == .recording, sessionStart.isOpen else { return }
        let now = Date()

        if !isCameraOnly, let source = screenSource, now.timeIntervalSince(source.lastFrameAt) > 10 {
            if screenRebuilds >= maxRebuildsPerStream {
                // The screen is the recording — there is nothing to degrade to.
                state = .failed("The screen capture stopped and could not be restarted after \(screenRebuilds) attempts.")
                Log.recording.error("RecordingEngine: screen stream dead after \(screenRebuilds) rebuilds — failing")
            } else if now.timeIntervalSince(lastScreenRebuild) > 20 {
                screenRebuilds += 1
                lastScreenRebuild = now
                rebuildScreen(reason: "watchdog: no frames for 10s (attempt \(screenRebuilds))")
            }
        }

        if wantsLocalSource, let source = cameraSource, now.timeIntervalSince(source.lastFrameAt) > 10 {
            if cameraRebuilds >= maxRebuildsPerStream {
                cameraUnavailable = true
                if isCameraOnly {
                    // Nothing to degrade to: the camera *is* the recording,
                    // exactly as the screen is in a normal take.
                    state = .failed("The camera stopped and could not be restarted after \(cameraRebuilds) attempts.")
                }
                Log.recording.error("RecordingEngine: camera dead after \(cameraRebuilds) rebuilds — flagged unavailable")
            } else if now.timeIntervalSince(lastCameraRebuild) > 20 {
                cameraRebuilds += 1
                lastCameraRebuild = now
                rebuildCamera(reason: "watchdog: no frames for 10s (attempt \(cameraRebuilds))")
            }
        }

        // "Unavailable" is not forever — a camera another app grabbed usually
        // comes back. Same self-healing cadence as the meeting recorder.
        if wantsLocalSource, cameraUnavailable,
           now.timeIntervalSince(lastCameraRebuild) > 60,
           cameraRebuilds < maxRebuildsPerStream * 2 {
            cameraRebuilds += 1
            lastCameraRebuild = now
            Log.recording.info("RecordingEngine: retrying flagged camera (attempt \(cameraRebuilds))")
            rebuildCamera(reason: "retry flagged camera")
        }
    }
}
