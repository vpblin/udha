import Foundation
import Observation

/// One live meeting: the metadata, its recorder, its intelligence loop, and
/// the rough notes the user types during the call.
@MainActor
@Observable
final class LiveMeeting {
    var meeting: Meeting
    let recorder: MeetingRecorder
    let intelligence: MeetingIntelligence
    /// Answers questions about the call while it's still happening, from the
    /// live transcript. Private to you — nothing it produces touches the
    /// recording or the outbound audio.
    let ask: MeetingAsk

    /// "The next meeting starts here" marks, in active-recording seconds —
    /// applied as splits when the recording stops. Marked live because
    /// that is when you notice you forgot to end the last call.
    var breakpoints: [TimeInterval] = []

    var roughNotes: String = "" {
        didSet {
            guard roughNotes != oldValue else { return }
            store?.writeUserNotes(roughNotes, for: meeting)
        }
    }

    private weak var store: MeetingStore?

    init(meeting: Meeting, recorder: MeetingRecorder, intelligence: MeetingIntelligence,
         ask: MeetingAsk, store: MeetingStore) {
        self.meeting = meeting
        self.recorder = recorder
        self.intelligence = intelligence
        self.ask = ask
        self.store = store
    }
}

/// Lifecycle owner tying store, recorder, and Claude together. Enforces one
/// live meeting at a time. Recording never blocks on the LLM: a missing
/// Anthropic key just idles the intelligence loop and the finalize pass.
@MainActor
@Observable
final class MeetingCenter {
    let store: MeetingStore
    private let claude: ClaudeClient
    private let config: ConfigStore
    private let keychain: KeychainStore
    private let activity: ActivityLog
    private let systemAudioAccess: SystemAudioAccess
    let calendar: MeetingCalendar
    /// Transcript lines in another language, translated on the box's GPU.
    let translator: MeetingTranslator

    private(set) var live: LiveMeeting?
    private(set) var finalizingIDs: Set<UUID> = []
    private(set) var generatingProcessIDs: Set<UUID> = []

    var hasAnthropicKey: Bool { keychain.has(.anthropicAPIKey) }
    /// Notes can be written: a key, or the local model (chosen or as fallback).
    var hasNotesModel: Bool { ClaudeClient.hasNotesModel(keychain: keychain, config: config) }

    init(store: MeetingStore, claude: ClaudeClient, config: ConfigStore,
         keychain: KeychainStore, activity: ActivityLog, systemAudioAccess: SystemAudioAccess,
         calendar: MeetingCalendar) {
        self.store = store
        self.claude = claude
        self.config = config
        self.keychain = keychain
        self.activity = activity
        self.systemAudioAccess = systemAudioAccess
        self.calendar = calendar
        self.translator = MeetingTranslator(config: config, store: store)
    }

    // MARK: - Start / stop

    func start(mode: MeetingMode) async {
        guard live == nil else { return }
        var meeting = store.create(mode: mode)
        if config.config.meetings.useCalendarTitles {
            // First recording ever: this is where the calendar prompt fires.
            if calendar.status == .unknown { calendar.check() }
            if calendar.status == .notDetermined { await calendar.requestAccess() }
            if let ref = await calendar.match(recordingStart: meeting.createdAt, recordingEnd: nil) {
                meeting.calendarEvent = ref
                meeting.title = ref.title
                store.save(meeting)
                Log.meeting.info("MeetingCenter: recording is “\(ref.title)” (\(ref.calendarTitle))")
            }
        }
        let folder = store.folderURL(for: meeting)
        let recorder = MeetingRecorder(
            meetingFolder: folder, keychain: keychain, config: config,
            systemAudioAccess: systemAudioAccess
        )
        let intelligence = MeetingIntelligence(
            claude: claude, config: config, keychain: keychain, mode: mode, recorder: recorder
        )
        let ask = MeetingAsk(claude: claude, config: config, keychain: keychain, recorder: recorder)
        let liveMeeting = LiveMeeting(
            meeting: meeting, recorder: recorder, intelligence: intelligence, ask: ask, store: store
        )
        live = liveMeeting

        intelligence.onStateChanged = { [weak self, weak liveMeeting] in
            guard let self, let liveMeeting else { return }
            var m = liveMeeting.meeting
            m.actionItems = liveMeeting.intelligence.actionItems
            liveMeeting.meeting = m
            self.store.saveDebounced(m)
            if m.mode == .processMapping {
                self.store.writeProcessModel(liveMeeting.intelligence.processModel, for: m)
            }
        }

        await recorder.start()
        if case .failed(let reason) = recorder.state {
            Log.meeting.error("MeetingCenter: recorder failed to start: \(reason)")
            // Keep `live` so the UI can show the failure; the user stops it.
        } else {
            intelligence.startLoop()
            startLiveTranslation()
            activity.record(.meetingStarted(meetingID: meeting.id, mode: mode.rawValue))
        }
    }

    /// Keeps the live transcript translated for as long as the meeting runs,
    /// whichever rail (or section) is on screen. This used to hang off the
    /// transcript rail's `onChange`, so nothing was translated while you were
    /// on Ask or Items, and coming back meant a backlog of minutes filling
    /// in — the "five minutes behind" that looked like a slow model.
    private var liveTranslationTask: Task<Void, Never>?
    private func startLiveTranslation() {
        liveTranslationTask?.cancel()
        liveTranslationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, let live = self.live, !Task.isCancelled else { return }
                guard self.translator.isOn else { continue }
                self.translator.ensure(live.recorder.transcript.segments, for: live.meeting, newestFirst: true)
            }
        }
    }

    func stop() async {
        guard let live else { return }
        liveTranslationTask?.cancel()
        liveTranslationTask = nil
        live.intelligence.stopLoop()
        await live.recorder.stop()

        var meeting = live.meeting
        meeting.endedAt = Date()
        meeting.actionItems = live.intelligence.actionItems
        meeting.hasAudio = config.config.meetings.keepAudioRecordings
        store.save(meeting)
        store.writeUserNotes(live.roughNotes, for: meeting)
        if meeting.mode == .processMapping {
            store.writeProcessModel(live.intelligence.processModel, for: meeting)
        }
        activity.record(.meetingEnded(meetingID: meeting.id, durationSec: Int(live.recorder.activeDuration)))

        let breaks = live.breakpoints
        self.live = nil

        // Largest offset first: each cut shortens the original, and an
        // earlier mark stays valid inside what is left.
        var pieces = [meeting]
        for offset in Set(breaks).sorted(by: >) {
            guard let current = store.meetings.first(where: { $0.id == meeting.id }),
                  let second = await split(current, at: offset, finalize: false) else { continue }
            pieces.append(second)
        }
        if let first = store.meetings.first(where: { $0.id == meeting.id }) { pieces[0] = first }
        for piece in pieces {
            Task { await self.finalize(piece) }
        }
    }

    // MARK: - Split

    /// Mark "the next meeting starts now" on the live recording.
    func markBreak() {
        guard let live else { return }
        let at = live.recorder.activeDuration
        live.breakpoints.append(at)
        Log.meeting.info("MeetingCenter: break marked at \(Int(at))s")
    }

    func clearBreaks() {
        live?.breakpoints = []
    }

    /// Cut a finished meeting in two at `offset` (active-recording seconds).
    /// Transcript and notes are split by the store, audio is trimmed here,
    /// and both halves are written up again. Returns the new second meeting.
    @discardableResult
    func split(_ meeting: Meeting, at offset: TimeInterval, finalize: Bool = true) async -> Meeting? {
        guard live?.meeting.id != meeting.id else {
            Log.meeting.info("MeetingCenter: split refused — meeting is live")
            return nil
        }
        guard !finalizingIDs.contains(meeting.id) else { return nil }
        guard var second = store.split(meeting, at: offset) else { return nil }
        if meeting.hasAudio {
            let ok = await MeetingAudioSplitter.split(
                from: store.folderURL(for: meeting), to: store.folderURL(for: second), at: offset
            )
            if ok {
                second.hasAudio = true
                store.save(second)
            }
        }
        activity.record(.meetingSplit(meetingID: meeting.id, newMeetingID: second.id, atSec: Int(offset)))
        if finalize, let first = store.meetings.first(where: { $0.id == meeting.id }) {
            let tail = second
            Task { await self.finalize(first) }
            Task { await self.finalize(tail) }
        }
        return second
    }

    /// Folds several finished recordings of one call into the earliest —
    /// the fix for a meeting stopped by mistake and started again. Audio is
    /// laid end to end first (nothing is touched if that fails), then the
    /// transcripts, notes and translations, and the result is written up
    /// once. Refused while any part is live or being finalized.
    func join(_ meetings: [Meeting], finalize: Bool = true) async -> Meeting? {
        let parts = meetings.sorted { $0.createdAt < $1.createdAt }
        guard parts.count >= 2 else { return nil }
        guard !parts.contains(where: { $0.id == live?.meeting.id }) else {
            Log.meeting.info("MeetingCenter: join refused — a part is live")
            return nil
        }
        guard !parts.contains(where: { finalizingIDs.contains($0.id) }) else { return nil }

        // Each part's length on the joined line: its audio when it has any
        // (the archives are active time, exactly what the transcript counts),
        // else its last transcript line, else the wall clock.
        var lengths: [TimeInterval] = []
        for part in parts {
            let folder = store.folderURL(for: part)
            let fromAudio = part.hasAudio ? await MeetingAudioJoiner.activeDuration(of: folder) : nil
            let fromLines = store.loadTranscript(for: part).map(\.endTime).max()
            lengths.append(fromAudio ?? fromLines ?? part.durationSeconds ?? 0)
        }
        var starts: [TimeInterval] = []
        var cursor: TimeInterval = 0
        for length in lengths { starts.append(cursor); cursor += length }

        var audioLanded = false
        if parts.contains(where: \.hasAudio) {
            audioLanded = await MeetingAudioJoiner.join(parts: parts.map { store.folderURL(for: $0) }, lengths: lengths)
            guard audioLanded else {
                Log.meeting.error("MeetingCenter: join aborted — audio could not be joined, nothing changed")
                return nil
            }
        }
        guard var joined = store.join(parts, starts: starts) else { return nil }
        if audioLanded, !joined.hasAudio {
            joined.hasAudio = true
            store.save(joined)
        }
        activity.record(.meetingJoined(meetingID: joined.id, absorbed: parts.count - 1))
        if finalize, let current = store.meetings.first(where: { $0.id == joined.id }) {
            Task { await self.finalize(current) }
        }
        return joined
    }

    /// Attaches calendar events to every recording that has none — the
    /// launch pass over the library, and the "Match now" button. Placeholder
    /// titles are replaced; a name you typed or the model wrote is kept.
    func backfillCalendar() async {
        guard config.config.meetings.useCalendarTitles else { return }
        var renamed = 0
        // Already matched but still junk-titled (an older finalize pass over an
        // empty transcript): the event name wins now.
        for var m in store.meetings where m.calendarEvent != nil && m.hasPlaceholderTitle {
            m.title = m.calendarEvent!.title
            store.save(m)
            renamed += 1
        }
        let candidates = store.meetings.filter { $0.calendarEvent == nil }
        guard !candidates.isEmpty else {
            if renamed > 0 { Log.meeting.info("MeetingCenter: calendar backfill renamed \(renamed)") }
            return
        }
        let found = await calendar.matches(for: candidates)
        for var m in candidates {
            guard let ref = found[m.id] else { continue }
            m.calendarEvent = ref
            if m.hasPlaceholderTitle { m.title = ref.title; renamed += 1 }
            store.save(m)
        }
        Log.meeting.info("MeetingCenter: calendar backfill matched \(found.count) of \(candidates.count) recordings, renamed \(renamed)")
    }

    /// Synchronous best-effort shutdown for applicationWillTerminate. No LLM
    /// call — the meeting is recovered as "Needs summary" next launch.
    func emergencyStop() {
        guard let live else { return }
        liveTranslationTask?.cancel()
        liveTranslationTask = nil
        live.intelligence.stopLoop()
        live.recorder.abort()
        var meeting = live.meeting
        meeting.endedAt = Date()
        meeting.actionItems = live.intelligence.actionItems
        meeting.finalized = false
        store.save(meeting)
        // Unbuffered: the notes are the one thing here a human wrote by hand,
        // and the debounced write would die with the process.
        store.writeUserNotes(live.roughNotes, for: meeting, immediate: true)
        self.live = nil
        Log.meeting.info("MeetingCenter: emergency stop for \(meeting.folderName)")
    }

    func isGeneratingProcess(_ meeting: Meeting) -> Bool {
        generatingProcessIDs.contains(meeting.id)
    }

    /// Retroactive process map for a finished meeting — nobody remembers to
    /// click a mode button mid-call. Extracts the swimlane model from the
    /// full transcript with the final-notes model.
    func generateProcessMap(for meeting: Meeting) async {
        guard !generatingProcessIDs.contains(meeting.id) else { return }
        guard hasNotesModel else { return }
        let segments = store.loadTranscript(for: meeting)
        guard segments.count >= 5 else {
            Log.meeting.info("MeetingCenter: process map skipped — transcript too short")
            return
        }
        generatingProcessIDs.insert(meeting.id)
        defer { generatingProcessIDs.remove(meeting.id) }

        let transcriptText = segments.map { seg in
            let m = Int(seg.startTime) / 60, s = Int(seg.startTime) % 60
            return String(format: "[%02d:%02d] %@: %@", m, s, seg.speaker, seg.text)
        }.joined(separator: "\n")

        do {
            let (payload, _) = try await claude.structured(
                ProcessOnlyPayload.self,
                model: config.config.meetings.finalModel,
                maxTokens: 8000,
                system: [PromptBlock(text: MeetingPrompts.processExtractionSystem, cached: true)],
                user: [
                    PromptBlock(text: "<transcript>\n\(transcriptText)\n</transcript>", cached: true),
                    PromptBlock(text: "Extract the process model."),
                ],
                schema: MeetingPrompts.processExtractionSchema
            )
            store.writeProcessModel(payload.process.toModel(), for: meeting)
            Log.meeting.info("MeetingCenter: process map generated for \(meeting.folderName)")
        } catch {
            activity.record(.meetingLLMError(description: error.localizedDescription))
            Log.meeting.error("MeetingCenter: process map generation failed: \(error.localizedDescription)")
        }
    }

    /// Flip the live meeting into process-mapping mid-call (auto-recorded
    /// meetings start standard; the diagram should not require a restart).
    func switchLiveToProcessMapping() {
        guard let live, live.meeting.mode == .standard else { return }
        var meeting = live.meeting
        meeting.mode = .processMapping
        live.meeting = meeting
        store.save(meeting)
        live.intelligence.setMode(.processMapping)
        Log.meeting.info("MeetingCenter: live meeting switched to process mapping")
    }

    // MARK: - Finalize

    func isFinalizing(_ meeting: Meeting) -> Bool {
        finalizingIDs.contains(meeting.id)
    }

    /// Re-runnable: first run after stop, crash recovery ("Generate notes"),
    /// or an explicit re-finalize over existing notes.
    func finalize(_ meeting: Meeting) async {
        guard !finalizingIDs.contains(meeting.id) else { return }
        guard var current = store.meetings.first(where: { $0.id == meeting.id }) else { return }

        let segments = store.loadTranscript(for: current)
        let duration = current.durationSeconds ?? 0
        if segments.count < 5 || duration < 60 {
            // Empty/short meeting: nothing to summarize; don't burn a call.
            current.finalized = true
            store.save(current)
            return
        }
        guard hasNotesModel else {
            Log.meeting.info("MeetingCenter: finalize skipped — no notes model (no Anthropic key, local model off)")
            return
        }

        finalizingIDs.insert(current.id)
        defer { finalizingIDs.remove(current.id) }

        let transcriptText = segments.map { seg in
            let m = Int(seg.startTime) / 60, s = Int(seg.startTime) % 60
            return String(format: "[%02d:%02d] %@: %@", m, s, seg.speaker, seg.text)
        }.joined(separator: "\n")
        let roughNotes = store.loadUserNotes(for: current)
        // A recording that began long before its event, or before calendar
        // access was granted, gets a second look now that its span is known.
        if current.calendarEvent == nil, config.config.meetings.useCalendarTitles,
           let ref = await calendar.match(recordingStart: current.createdAt, recordingEnd: current.endedAt) {
            current.calendarEvent = ref
            if current.hasPlaceholderTitle { current.title = ref.title }
            store.save(current)
        }
        let process = current.mode == .processMapping ? store.loadProcessModel(for: current) : nil
        let stateJSON = MeetingIntelligence.encodeState(actionItems: current.actionItems, process: process)
        let cfg = config.config.meetings

        do {
            let payload = try await runFinalize(
                mode: current.mode, model: cfg.finalModel,
                transcript: transcriptText, roughNotes: roughNotes, stateJSON: stateJSON,
                calendar: current.calendarEvent
            )
            store.writeAINotes(payload.notes_markdown, for: current)
            // The calendar names the meeting when it can; the model only
            // fills a placeholder (and never overwrites a name you typed).
            let aiTitle = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if current.calendarEvent == nil, current.hasPlaceholderTitle, aiTitle.count >= 3 {
                current.title = aiTitle
            }
            current.summary = payload.summary
            current.actionItems = ActionItemPayload.merge(payload.action_items)
            if current.mode == .processMapping, let processPayload = payload.process {
                store.writeProcessModel(processPayload.toModel(), for: current)
            }
            current.finalized = true
            store.save(current)
            activity.record(.meetingNotesGenerated(meetingID: current.id))
            Log.meeting.info("MeetingCenter: finalized \(current.folderName)")
        } catch {
            activity.record(.meetingLLMError(description: error.localizedDescription))
            Log.meeting.error("MeetingCenter: finalize failed: \(error.localizedDescription)")
            // finalized stays false → "Needs summary" + retry button.
        }
    }

    private func runFinalize(
        mode: MeetingMode, model: String,
        transcript: String, roughNotes: String, stateJSON: String,
        calendar: CalendarEventRef?
    ) async throws -> FinalizePayload {
        var user = [
            PromptBlock(text: "<transcript>\n\(transcript)\n</transcript>", cached: true),
        ]
        if let calendar {
            user.append(PromptBlock(text: "<calendar_event>\n\(MeetingPrompts.describe(calendar))\n</calendar_event>"))
        }
        user += [
            PromptBlock(text: "<user_rough_notes>\n\(roughNotes)\n</user_rough_notes>"),
            PromptBlock(text: "<current_state>\n\(stateJSON)\n</current_state>"),
            PromptBlock(text: "Produce the final record."),
        ]
        do {
            let (payload, _) = try await claude.structured(
                FinalizePayload.self, model: model, maxTokens: 16000,
                system: [PromptBlock(text: MeetingPrompts.finalizeSystem(mode: mode), cached: true)],
                user: user,
                schema: MeetingPrompts.finalizeSchema(mode: mode)
            )
            return payload
        } catch ClaudeError.truncated {
            // One retry with a brevity addendum (thinking + text share max_tokens).
            let (payload, _) = try await claude.structured(
                FinalizePayload.self, model: model, maxTokens: 16000,
                system: [PromptBlock(text: MeetingPrompts.finalizeSystem(mode: mode)
                    + "\n\nBe concise; hard limit ~3000 words of notes.", cached: false)],
                user: user,
                schema: MeetingPrompts.finalizeSchema(mode: mode)
            )
            return payload
        }
    }
}
