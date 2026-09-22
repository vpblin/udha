import Foundation

/// Feeds AudioChunks to ElevenLabs STT and turns results into transcript
/// segments. One FIFO queue per stream, order preserved within a stream;
/// cross-stream ordering doesn't matter because segments carry absolute
/// meeting-relative times and MeetingTranscript insertion-sorts.
///
/// Failure posture: a failed chunk stays at its queue head and retries with
/// backoff indefinitely while recording — an ElevenLabs outage must never lose
/// queued audio. Auth failures park the queue on a slow tick (the user may
/// paste a key mid-call). STT trouble never stops the capture side.
actor TranscriptionEngine {
    private let stt: ElevenLabsSTTClient
    private let config: ConfigStore

    private var queues: [TranscriptSource: [AudioChunk]] = [.mic: [], .system: []]
    private var workers: [TranscriptSource: Task<Void, Never>] = [:]
    private(set) var isHealthy = true
    /// Mirrors isHealthy onto the main actor for UI.
    var onHealthChange: (@MainActor (Bool) -> Void)?
    var onSegments: (@MainActor ([TranscriptSegment]) -> Void)?

    private let maxQueuedChunks = 200

    init(stt: ElevenLabsSTTClient, config: ConfigStore) {
        self.stt = stt
        self.config = config
    }

    func setOnSegments(_ handler: @escaping @MainActor ([TranscriptSegment]) -> Void) {
        onSegments = handler
    }

    func setOnHealthChange(_ handler: @escaping @MainActor (Bool) -> Void) {
        onHealthChange = handler
    }

    func submit(_ chunk: AudioChunk) async {
        let cfg = await configSnapshot()
        guard chunk.peakRMSPercent >= cfg.sttSilenceRMSPercent else {
            Log.meeting.debug("STT: dropping silent \(chunk.source.rawValue) chunk (\(Int(chunk.duration))s, peak \(String(format: "%.2f", chunk.peakRMSPercent))%)")
            return
        }
        queues[chunk.source, default: []].append(chunk)
        if queues[chunk.source]!.count > maxQueuedChunks {
            queues[chunk.source]!.removeFirst()
            Log.meeting.error("STT: \(chunk.source.rawValue) queue over \(maxQueuedChunks) chunks — dropping oldest (audio survives in the .m4a)")
        }
        ensureWorker(for: chunk.source)
    }

    /// Best-effort wait for both queues to empty (the stop path).
    func drain(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let pending = queues.values.map(\.count).reduce(0, +)
            if pending == 0 && !hasActiveWorker() { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let left = queues.values.map(\.count).reduce(0, +)
        if left > 0 {
            Log.meeting.error("STT: drain timed out with \(left) chunks untranscribed")
        }
    }

    func reset() {
        for task in workers.values { task.cancel() }
        workers = [:]
        queues = [.mic: [], .system: []]
        isHealthy = true
    }

    // MARK: - Worker

    private func hasActiveWorker() -> Bool {
        workers.values.contains { !$0.isCancelled }
    }

    private func ensureWorker(for source: TranscriptSource) {
        if let existing = workers[source], !existing.isCancelled { return }
        workers[source] = Task { [weak self] in
            await self?.runWorker(source)
        }
    }

    private func workerFinished(_ source: TranscriptSource) {
        workers[source] = nil
    }

    private func runWorker(_ source: TranscriptSource) async {
        var attempt = 0
        while !Task.isCancelled {
            guard let chunk = queues[source]?.first else { break }
            let cfg = await configSnapshot()
            do {
                Log.meeting.debug("STT: uploading \(source.rawValue) chunk (\(Int(chunk.duration))s @ \(String(format: "%.1f", chunk.startOffset))s)")
                let wav = await MainActor.run { AudioPlayer.wrapAsWAV(chunk.pcm, sampleRate: 16000, channels: 1) }
                let diarize = source == .system && cfg.diarizeSystemAudio
                let result = try await stt.transcribe(
                    wav: wav,
                    diarize: diarize,
                    languageCode: cfg.languageCode.isEmpty ? nil : cfg.languageCode
                )
                queues[source]?.removeFirst()
                attempt = 0
                setHealthy(true)
                let segments = Self.buildSegments(from: result, chunk: chunk, diarized: diarize)
                if !segments.isEmpty, let deliver = onSegments {
                    await MainActor.run { deliver(segments) }
                }
            } catch {
                attempt += 1
                setHealthy(false)
                let delay = Self.backoffSeconds(for: error, attempt: attempt)
                Log.meeting.error("STT: \(source.rawValue) chunk failed (attempt \(attempt), retry in \(Int(delay))s): \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        workerFinished(source)
    }

    private func setHealthy(_ healthy: Bool) {
        guard healthy != isHealthy else { return }
        isHealthy = healthy
        if let onHealthChange {
            Task { @MainActor in onHealthChange(healthy) }
        }
    }

    private static func backoffSeconds(for error: Error, attempt: Int) -> TimeInterval {
        if case ElevenLabsError.noAPIKey = error { return 60 }
        if case ElevenLabsError.httpError(let code, _) = error, code == 401 { return 60 }
        switch attempt {
        case 1: return 2
        case 2: return 8
        default: return 30
        }
    }

    private func configSnapshot() async -> MeetingsConfig {
        await MainActor.run { config.config.meetings }
    }

    // MARK: - Segment building

    /// Turn one STT result into transcript segments with absolute times.
    /// Mic → single "Me" speaker, split on >1.5s word gaps. Diarized system
    /// audio → grouped by speaker_id ("Them 1", "Them 2"; a lone speaker
    /// collapses to "Them"). Diarized identities are only stable within one
    /// chunk — "Them 1" here is not guaranteed to be chunk N-1's "Them 1".
    static func buildSegments(from result: STTResult, chunk: AudioChunk, diarized: Bool) -> [TranscriptSegment] {
        let words = (result.words ?? []).filter { ($0.type ?? "word") == "word" && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }

        guard !words.isEmpty else {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return [TranscriptSegment(
                source: chunk.source,
                speaker: chunk.source == .mic ? "Me" : "Them",
                text: text,
                startTime: chunk.startOffset,
                endTime: chunk.startOffset + chunk.duration
            )]
        }

        let speakerIDs = Set(words.compactMap(\.speaker_id))
        func label(for word: STTWord) -> String {
            if chunk.source == .mic { return "Me" }
            guard diarized, speakerIDs.count > 1, let sid = word.speaker_id,
                  let n = Int(sid.split(separator: "_").last.map(String.init) ?? "") else { return "Them" }
            return "Them \(n + 1)"
        }

        var segments: [TranscriptSegment] = []
        var runWords: [String] = []
        var runSpeaker = label(for: words[0])
        var runStart = words[0].start ?? 0
        var runEnd = words[0].end ?? runStart
        let gapLimit: Double = 1.5

        func closeRun() {
            let text = runWords.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            segments.append(TranscriptSegment(
                source: chunk.source,
                speaker: runSpeaker,
                text: text,
                startTime: chunk.startOffset + runStart,
                endTime: chunk.startOffset + runEnd
            ))
        }

        for word in words {
            let speaker = label(for: word)
            let start = word.start ?? runEnd
            if speaker != runSpeaker || start - runEnd > gapLimit {
                closeRun()
                runWords = []
                runSpeaker = speaker
                runStart = start
            }
            runWords.append(word.text.trimmingCharacters(in: .whitespaces))
            runEnd = word.end ?? start
        }
        closeRun()
        return segments
    }
}
