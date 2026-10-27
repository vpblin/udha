import Foundation
import AppKit
@preconcurrency import AVFoundation
import Observation

/// Owns everything that happens between "record" and "stop" for one meeting:
/// mic capture ("Me"), the system-audio tap ("Them"), per-stream chunkers,
/// STT dispatch, optional audio archiving, and the live transcript.
///
/// Failure posture: mic denied is fatal (a meeting recorder without the user's
/// own voice is useless); system audio denied degrades to mic-only,
/// Granola-style; STT trouble never stops capture — audio keeps flowing to
/// the chunkers and (optionally) the .m4a archive.
///
/// Timeline semantics: transcript times are *active recording time* — pauses
/// are excised, and both streams pause together so they stay aligned.
@MainActor
@Observable
final class MeetingRecorder {
    enum State: Equatable {
        case idle, starting, recording, paused, stopping, finished
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var startedAt: Date?
    private(set) var systemAudioUnavailable = false
    private(set) var micUnavailable = false
    private(set) var sttHealthy = true
    private(set) var micLevelPercent: Double = 0
    private(set) var systemLevelPercent: Double = 0
    let transcript = MeetingTranscript()

    private let meetingFolder: URL
    private let keychain: KeychainStore
    private let config: ConfigStore
    private let systemAudioAccess: SystemAudioAccess

    private var micCapture: AudioCapture?
    private var systemTap: SystemAudioTap?
    private var micChunker: AudioChunker?
    private var systemChunker: AudioChunker?
    private var engine: TranscriptionEngine?
    private var micWriter: MeetingAudioWriter?
    private var systemWriter: MeetingAudioWriter?
    private var jsonlWriter: TranscriptJSONLWriter?

    // Active-time bookkeeping (pauses excised).
    private var pausedTotal: TimeInterval = 0
    private var pausedAt: Date?
    private var micNeedsAnchor = true
    private var systemNeedsAnchor = true

    // Watchdog + meters.
    private var watchdog: Timer?
    private var lastMicBuffer: Date?
    private var lastSystemBuffer: Date?
    private var micRebuilds = 0
    private var systemRebuilds = 0
    private var lastMicRebuild = Date.distantPast
    private var lastSystemRebuild = Date.distantPast
    private let maxRebuildsPerStream = 5
    /// A tap pinned to the wrong device delivers zeros, which count as live
    /// buffers — so audibility gets its own watchdog. Rebuilding re-picks the
    /// output device that is actually playing.
    private var lastSystemAudible = Date.distantPast
    private var lastAudibleRebuild = Date.distantPast
    private var micPeakSinceMeter: Double = 0
    private var systemPeakSinceMeter: Double = 0
    private var lastMeterUpdate = Date.distantPast
    private var loggedFirstMicChunk = false
    private var loggedFirstSystemChunk = false
    private var wakeObserver: NSObjectProtocol?

    var activeDuration: TimeInterval {
        guard let startedAt else { return 0 }
        let end = pausedAt ?? Date()
        return max(0, end.timeIntervalSince(startedAt) - pausedTotal)
    }

    init(meetingFolder: URL, keychain: KeychainStore, config: ConfigStore, systemAudioAccess: SystemAudioAccess) {
        self.meetingFolder = meetingFolder
        self.keychain = keychain
        self.config = config
        self.systemAudioAccess = systemAudioAccess
    }

    // MARK: - Lifecycle

    func start() async {
        guard state == .idle || state == .finished || isFailed else { return }
        state = .starting

        let micGranted = await AudioCapture.requestPermission()
        guard micGranted else {
            state = .failed("Microphone access denied. Enable Udha in System Settings → Privacy & Security → Microphone.")
            return
        }
        systemAudioUnavailable = !(await systemAudioAccess.requestAccess())

        let cfg = config.config.meetings
        transcript.reset()
        pausedTotal = 0
        pausedAt = nil
        startedAt = Date()
        loggedFirstMicChunk = false
        loggedFirstSystemChunk = false

        let jsonl = TranscriptJSONLWriter(meetingFolder: meetingFolder)
        jsonlWriter = jsonl
        transcript.onAppend = { segments in
            jsonl.append(segments)
        }

        if cfg.keepAudioRecordings {
            let audioDir = meetingFolder.appendingPathComponent("audio", isDirectory: true)
            try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
            micWriter = MeetingAudioWriter(url: audioDir.appendingPathComponent("mic.m4a"))
            if !systemAudioUnavailable {
                systemWriter = MeetingAudioWriter(url: audioDir.appendingPathComponent("system.m4a"))
            }
        }

        let stt = ElevenLabsSTTClient(keychain: keychain, config: config)
        let engine = TranscriptionEngine(stt: stt, config: config)
        self.engine = engine
        await engine.setOnSegments { [weak self] segments in
            self?.transcript.append(segments)
        }
        await engine.setOnHealthChange { [weak self] healthy in
            self?.sttHealthy = healthy
        }

        let micChunker = AudioChunker(source: .mic, config: cfg)
        micChunker.onChunk = { chunk in
            Task { await engine.submit(chunk) }
        }
        self.micChunker = micChunker

        let systemChunker = AudioChunker(source: .system, config: cfg)
        systemChunker.onChunk = { chunk in
            Task { await engine.submit(chunk) }
        }
        self.systemChunker = systemChunker

        micNeedsAnchor = true
        systemNeedsAnchor = true

        do {
            try await startMicCapture()
        } catch {
            micUnavailable = true
            Log.meeting.error("MeetingRecorder: mic start failed: \(error.localizedDescription)")
        }
        if !systemAudioUnavailable {
            await startSystemTap()
        }

        guard !micUnavailable || !systemAudioUnavailable else {
            teardownCaptures()
            state = .failed("No audio stream could be started.")
            return
        }

        state = .recording
        installObservers()
        startWatchdog()
        Log.meeting.info("MeetingRecorder: recording into \(meetingFolder.lastPathComponent) (systemAudio=\(!systemAudioUnavailable))")
    }

    func pause() {
        guard state == .recording else { return }
        micChunker?.flush()
        systemChunker?.flush()
        micCapture?.stop()
        micCapture = nil
        systemTap?.stop()
        systemTap = nil
        pausedAt = Date()
        state = .paused
        Log.meeting.info("MeetingRecorder: paused")
    }

    func resume() async {
        guard state == .paused else { return }
        if let pausedAt {
            pausedTotal += Date().timeIntervalSince(pausedAt)
        }
        pausedAt = nil
        micNeedsAnchor = true
        systemNeedsAnchor = true
        do {
            try await startMicCapture()
        } catch {
            Log.meeting.error("MeetingRecorder: mic resume failed: \(error.localizedDescription)")
        }
        if !systemAudioUnavailable {
            await startSystemTap()
        }
        state = .recording
        Log.meeting.info("MeetingRecorder: resumed")
    }

    func stop() async {
        guard state == .recording || state == .paused else { return }
        state = .stopping
        stopWatchdog()
        removeObservers()
        teardownCaptures()
        micChunker?.flush()
        systemChunker?.flush()
        // Best effort: give queued chunks a chance to transcribe. Untranscribed
        // audio still survives in the .m4a archive.
        await engine?.drain(timeout: 45)
        await engine?.reset()
        closeWriters()
        state = .finished
        Log.meeting.info("MeetingRecorder: stopped after \(Int(activeDuration))s, \(transcript.segments.count) segments")
    }

    /// Synchronous best-effort teardown for the app-quit path. No STT drain —
    /// the transcript JSONL and audio archive are flushed and closed so
    /// nothing on disk is left corrupt.
    func abort() {
        stopWatchdog()
        removeObservers()
        teardownCaptures()
        closeWriters()
        if state == .recording || state == .paused || state == .stopping || state == .starting {
            state = .finished
        }
        Log.meeting.info("MeetingRecorder: aborted")
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private struct StartTimeout: Error {}

    /// CoreAudio calls (engine start, tap/aggregate creation) can block
    /// indefinitely while a Bluetooth headset transitions in/out of call mode
    /// — which is exactly when meetings get recorded. A hung stream start
    /// must degrade that stream, never wedge the recorder (or, transitively,
    /// the app). The losing task is abandoned, not awaited: leaking a hung
    /// engine is strictly better than joining its fate.
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

    // MARK: - Capture wiring

    private func startMicCapture() async throws {
        let cfg = config.config
        let uid = !cfg.meetings.inputDeviceUID.isEmpty ? cfg.meetings.inputDeviceUID
            : nil
        // The engine start intermittently throws -10868 (format not supported)
        // when the preferred USB/BT device hasn't settled — retry once after a
        // beat, then fall back to the system-default input rather than losing
        // the whole "Me" stream to a flaky device.
        var lastError: Error?
        let attempts: [(Int, String?)] = [(0, uid), (1, uid), (2, nil)]
        for (attempt, deviceUID) in attempts {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            let capture = AudioCapture(sampleRate: 16000, preferredDeviceUID: deviceUID)
            capture.onAudioChunk = { [weak self] data in
                self?.ingest(data, source: .mic)
            }
            do {
                try await withStartTimeout(seconds: 10) {
                    try await capture.start()
                }
                if attempt == 2 && uid != nil {
                    Log.meeting.info("MeetingRecorder: mic fell back to system-default input")
                }
                micCapture = capture
                micUnavailable = false
                return
            } catch is StartTimeout {
                lastError = StartTimeout()
                // Deliberately no capture.stop(): stopping a wedged engine can
                // block too. Detach the callback and abandon it.
                capture.onAudioChunk = nil
                Log.meeting.error("MeetingRecorder: mic start attempt \(attempt + 1) TIMED OUT (10s) — abandoning that engine")
            } catch {
                lastError = error
                capture.stop()
                Log.meeting.error("MeetingRecorder: mic start attempt \(attempt + 1) failed: \(error.localizedDescription)")
            }
        }
        throw lastError ?? NSError(domain: "MeetingRecorder", code: 1)
    }

    private func startSystemTap() async {
        let tap = SystemAudioTap()
        tap.onAudioChunk = { [weak self] data in
            self?.ingest(data, source: .system)
        }
        tap.onStreamInterrupted = { [weak self] in
            // Rebuilt mid-stream (device change): re-anchor so sample math
            // stays aligned with active time.
            self?.systemNeedsAnchor = true
        }
        do {
            try await withStartTimeout(seconds: 10) {
                try await tap.start()
            }
            systemTap = tap
            systemAudioUnavailable = false
        } catch is StartTimeout {
            systemAudioUnavailable = true
            tap.onAudioChunk = nil
            Log.meeting.error("MeetingRecorder: system tap start TIMED OUT (10s) — continuing without system audio")
        } catch {
            systemAudioUnavailable = true
            Log.meeting.error("MeetingRecorder: system tap start failed: \(error.localizedDescription)")
        }
    }

    private func ingest(_ data: Data, source: TranscriptSource) {
        guard state == .recording else { return }
        switch source {
        case .mic where !loggedFirstMicChunk:
            loggedFirstMicChunk = true
            Log.meeting.debug("MeetingRecorder: first mic chunk reached recorder (\(data.count) bytes)")
            fallthrough
        case .mic:
            if micNeedsAnchor {
                micChunker?.setBaseOffset(activeDuration)
                micNeedsAnchor = false
            }
            if micUnavailable { micUnavailable = false }
            lastMicBuffer = Date()
            micChunker?.append(data)
            micWriter?.append(data)
            micPeakSinceMeter = max(micPeakSinceMeter, AudioChunker.rmsPercent(data))
        case .system where !loggedFirstSystemChunk:
            loggedFirstSystemChunk = true
            Log.meeting.debug("MeetingRecorder: first system chunk reached recorder (\(data.count) bytes)")
            fallthrough
        case .system:
            if systemNeedsAnchor {
                systemChunker?.setBaseOffset(activeDuration)
                systemNeedsAnchor = false
            }
            if systemAudioUnavailable { systemAudioUnavailable = false }
            lastSystemBuffer = Date()
            systemChunker?.append(data)
            systemWriter?.append(data)
            let rms = AudioChunker.rmsPercent(data)
            if rms > config.config.meetings.sttSilenceRMSPercent {
                lastSystemAudible = Date()
            }
            systemPeakSinceMeter = max(systemPeakSinceMeter, rms)
        }
        if Date().timeIntervalSince(lastMeterUpdate) >= 2 {
            micLevelPercent = micPeakSinceMeter
            systemLevelPercent = systemPeakSinceMeter
            micPeakSinceMeter = 0
            systemPeakSinceMeter = 0
            lastMeterUpdate = Date()
        }
    }

    private func teardownCaptures() {
        micCapture?.stop()
        micCapture = nil
        systemTap?.stop()
        systemTap = nil
    }

    private func closeWriters() {
        micWriter?.close()
        micWriter = nil
        systemWriter?.close()
        systemWriter = nil
        jsonlWriter?.flushSync()
        jsonlWriter = nil
    }

    // MARK: - Resilience

    // Deliberately NO .AVAudioEngineConfigurationChange observer: it fires for
    // every engine in the process (object: nil), including the replacement
    // engine each rebuild creates and the ConvAI agent's mic engine — which
    // made restarts re-trigger themselves in a tight loop that also flapped
    // Bluetooth headsets' call-audio profile ("call ended" announcements).
    // Dead capture is covered by the 10s buffer watchdog instead.
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
        Log.meeting.info("MeetingRecorder: system woke — rebuilding captures")
        rebuildMic(reason: "wake")
        rebuildSystemTap(reason: "wake")
    }

    private func rebuildMic(reason: String) {
        guard state == .recording else { return }
        Log.meeting.info("MeetingRecorder: restarting mic capture (\(reason))")
        micCapture?.stop()
        micCapture = nil
        micNeedsAnchor = true
        Task { @MainActor in
            do {
                try await startMicCapture()
            } catch {
                micUnavailable = true
                Log.meeting.error("MeetingRecorder: mic rebuild failed: \(error.localizedDescription)")
            }
        }
    }

    private func rebuildSystemTap(reason: String) {
        guard state == .recording, !systemAudioUnavailable else { return }
        Log.meeting.info("MeetingRecorder: restarting system tap (\(reason))")
        systemTap?.stop()
        systemTap = nil
        systemNeedsAnchor = true
        Task { @MainActor in
            await startSystemTap()
        }
    }

    /// Covers everything silent: mid-call TCC revocation, dead taps, unplugged
    /// devices that emitted no notification. One rebuild attempt per stream;
    /// still silent after that → flag the stream and keep the other going.
    private func startWatchdog() {
        lastMicBuffer = Date()
        lastSystemBuffer = Date()
        micRebuilds = 0
        systemRebuilds = 0
        lastMicRebuild = .distantPast
        lastSystemRebuild = .distantPast
        lastSystemAudible = Date()
        lastAudibleRebuild = Date()
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

    /// Streams flap during real calls (Bluetooth profile switches, USB device
    /// resets), so rebuilds retry — spaced 20s apart, up to
    /// maxRebuildsPerStream per meeting — before a stream is flagged. A chunk
    /// arriving in ingest() un-flags the stream, so flags self-heal.
    private func watchdogTick() {
        guard state == .recording else { return }
        let now = Date()
        if !micUnavailable, let last = lastMicBuffer, now.timeIntervalSince(last) > 10 {
            if micRebuilds >= maxRebuildsPerStream {
                micUnavailable = true
                Log.meeting.error("MeetingRecorder: mic stream silent after \(micRebuilds) rebuilds — flagged unavailable")
            } else if now.timeIntervalSince(lastMicRebuild) > 20 {
                micRebuilds += 1
                lastMicRebuild = now
                lastMicBuffer = now
                rebuildMic(reason: "watchdog: no buffers for 10s (attempt \(micRebuilds))")
            }
        }
        if !systemAudioUnavailable, let last = lastSystemBuffer, now.timeIntervalSince(last) > 10 {
            if systemRebuilds >= maxRebuildsPerStream {
                systemAudioUnavailable = true
                Log.meeting.error("MeetingRecorder: system stream silent after \(systemRebuilds) rebuilds — flagged unavailable")
            } else if now.timeIntervalSince(lastSystemRebuild) > 20 {
                systemRebuilds += 1
                lastSystemRebuild = now
                lastSystemBuffer = now
                rebuildSystemTap(reason: "watchdog: no buffers for 10s (attempt \(systemRebuilds))")
            }
        }
        // Buffers flowing but nothing audible for 60s: the tap is probably
        // pinned to a device nothing plays to (call audio moved elsewhere).
        // Rebuilding is harmless during a genuinely quiet stretch and
        // re-targets the running device otherwise.
        if !systemAudioUnavailable,
           now.timeIntervalSince(lastSystemAudible) > 60,
           now.timeIntervalSince(lastAudibleRebuild) > 60 {
            lastAudibleRebuild = now
            rebuildSystemTap(reason: "watchdog: no audible system audio for 60s — re-targeting device")
        }
        // "Unavailable" is not forever: taps fail transiently at call start
        // (devices mid-transition, nothing playing yet). Keep retrying on a
        // slow cadence — success un-flags via startSystemTap/ingest.
        if systemAudioUnavailable,
           now.timeIntervalSince(lastSystemRebuild) > 60,
           systemRebuilds < maxRebuildsPerStream * 2 {
            systemRebuilds += 1
            lastSystemRebuild = now
            lastSystemBuffer = now
            Log.meeting.info("MeetingRecorder: retrying flagged system stream (attempt \(systemRebuilds))")
            Task { @MainActor in
                await startSystemTap()
                if !systemAudioUnavailable {
                    systemNeedsAnchor = true
                }
            }
        }
        // Same for the mic. A device that went silent mid-call (Bluetooth
        // profile switch, USB reset, another app resizing the HAL buffer)
        // normally comes back, and without a retry the flag cost the whole
        // "Me" stream for the rest of the meeting — the one thing a recorder
        // cannot silently lose.
        if micUnavailable,
           now.timeIntervalSince(lastMicRebuild) > 60,
           micRebuilds < maxRebuildsPerStream * 2 {
            micRebuilds += 1
            lastMicRebuild = now
            lastMicBuffer = now
            Log.meeting.info("MeetingRecorder: retrying flagged mic stream (attempt \(micRebuilds))")
            rebuildMic(reason: "retry flagged mic stream")
        }
    }
}
