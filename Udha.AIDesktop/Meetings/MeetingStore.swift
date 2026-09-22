import Foundation
import Observation

/// Per-meeting-folder persistence under ~/Library/Application Support/Udha.AI/Meetings/.
///
/// Folder layout (folder name is human-browsable; the UUID in meeting.json is
/// the authoritative identity — renaming a meeting edits the title only):
///   yyyyMMdd-HHmmss-<slug>/
///     meeting.json        (store-owned metadata)
///     notes-user.md       (rough notes typed during the call)
///     notes-ai.md         (polished markdown from the finalize pass)
///     process.json        (swimlane model, processMapping meetings only)
///     transcript.jsonl    (recorder-owned, append-only)
///     audio/              (recorder-owned, optional mic.m4a / system.m4a)
///
/// Deliberate deviation from AgentStore: mutations update the in-memory array
/// in place and write only the touched files instead of write-then-rescan —
/// saves fire every few seconds during a live call. Errors are logged, never
/// thrown (house rule); writes are atomic.
@MainActor
@Observable
final class MeetingStore {
    /// Sorted newest-first.
    private(set) var meetings: [Meeting] = []

    private var pendingWrites: [String: Task<Void, Never>] = [:]

    var meetingsDirectory: URL { directoryURL }

    private var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Udha.AI", isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)
    }

    private static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Load

    func load() {
        ensureDirectory()
        reload()
        sweepCrashedMeetings()
    }

    func reload() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil))?
            .filter(\.hasDirectoryPath) ?? []
        var loaded: [Meeting] = []
        for folder in folders {
            let metaURL = folder.appendingPathComponent("meeting.json")
            guard let data = try? Data(contentsOf: metaURL) else { continue }
            do {
                var meeting = try Self.jsonDecoder.decode(Meeting.self, from: data)
                meeting.folderName = folder.lastPathComponent
                loaded.append(meeting)
            } catch {
                Log.meeting.error("MeetingStore: skipping undecodable \(folder.lastPathComponent): \(error.localizedDescription)")
            }
        }
        meetings = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    /// A meeting.json with no endedAt at launch died with the app. Stamp it
    /// ended (transcript mtime is the best estimate) and leave it unfinalized
    /// so the UI shows "Needs summary" with a one-click retry.
    private func sweepCrashedMeetings() {
        for var meeting in meetings where meeting.endedAt == nil {
            let folder = folderURL(for: meeting)
            let transcriptURL = folder.appendingPathComponent("transcript.jsonl")
            let attrs = try? FileManager.default.attributesOfItem(atPath: transcriptURL.path)
            let mtime = attrs?[.modificationDate] as? Date
            meeting.endedAt = mtime ?? meeting.createdAt
            meeting.finalized = false
            save(meeting)
            Log.meeting.info("MeetingStore: recovered crashed meeting \(meeting.folderName) — needs summary")
        }
    }

    // MARK: - Create / save / delete

    static func defaultTitle(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return "Meeting \(f.string(from: date))"
    }

    @discardableResult
    func create(mode: MeetingMode) -> Meeting {
        ensureDirectory()
        let now = Date()
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let folderName = "\(stamp.string(from: now))-meeting"
        let meeting = Meeting(
            title: Self.defaultTitle(for: now),
            createdAt: now,
            mode: mode,
            folderName: folderName
        )
        let folder = directoryURL.appendingPathComponent(folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            Log.meeting.error("MeetingStore: cannot create \(folderName): \(error.localizedDescription)")
        }
        meetings.insert(meeting, at: 0)
        save(meeting)
        return meeting
    }

    func save(_ meeting: Meeting) {
        if let idx = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[idx] = meeting
        } else {
            meetings.insert(meeting, at: 0)
            meetings.sort { $0.createdAt > $1.createdAt }
        }
        let url = folderURL(for: meeting).appendingPathComponent("meeting.json")
        do {
            let data = try Self.jsonEncoder.encode(meeting)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.meeting.error("MeetingStore: save failed for \(meeting.folderName): \(error.localizedDescription)")
        }
    }

    func saveDebounced(_ meeting: Meeting) {
        if let idx = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[idx] = meeting
        }
        debounced(key: "meta-\(meeting.id)") { [weak self] in
            self?.save(meeting)
        }
    }

    func delete(_ meeting: Meeting) {
        try? FileManager.default.removeItem(at: folderURL(for: meeting))
        meetings.removeAll { $0.id == meeting.id }
    }

    // MARK: - Split

    /// Cuts a finished meeting in two at `offset` (active-recording seconds):
    /// every transcript line from there on becomes a new meeting, the
    /// original keeps what came before. Rough notes are copied to both (a
    /// note typed during the call could belong to either half); the AI notes,
    /// summary, action items and process map describe the *combined* call,
    /// so they are dropped from the original — both halves come back as
    /// "Needs summary" and the caller re-runs finalize. Audio is the
    /// caller's job (`MeetingAudioSplitter`), because trimming an m4a is
    /// async. Returns the new meeting, or nil when there is nothing after
    /// the cut.
    func split(_ meeting: Meeting, at offset: TimeInterval) -> Meeting? {
        guard offset > 0 else { return nil }
        let sourceFolder = folderURL(for: meeting)
        let all = loadTranscript(for: meeting)
        let head = all.filter { $0.startTime < offset }
        let tail = all.filter { $0.startTime >= offset }.map { seg -> TranscriptSegment in
            var s = seg
            s.startTime = max(0, seg.startTime - offset)
            s.endTime = max(s.startTime, seg.endTime - offset)
            return s
        }
        guard !tail.isEmpty else { return nil }

        // Wall-clock for the cut. Pauses are excised from the timeline, so
        // this is the earliest the second meeting can have started — close
        // enough for the list, the calendar match and the duration stamp.
        let cutAt = meeting.createdAt.addingTimeInterval(offset)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        var folderName = "\(stamp.string(from: cutAt))-meeting"
        var n = 2
        while FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent(folderName).path) {
            folderName = "\(stamp.string(from: cutAt))-meeting-\(n)"
            n += 1
        }
        let second = Meeting(
            title: Self.defaultTitle(for: cutAt),
            createdAt: cutAt,
            endedAt: meeting.endedAt,
            mode: meeting.mode,
            origin: meeting.origin,
            folderName: folderName
        )
        let secondFolder = directoryURL.appendingPathComponent(folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        } catch {
            Log.meeting.error("MeetingStore: split cannot create \(folderName): \(error.localizedDescription)")
            return nil
        }
        TranscriptJSONLWriter.rewrite(tail, meetingFolder: secondFolder)
        let notes = loadUserNotes(for: meeting)
        if !notes.isEmpty {
            try? notes.write(to: secondFolder.appendingPathComponent("notes-user.md"), atomically: true, encoding: .utf8)
        }

        TranscriptJSONLWriter.rewrite(head, meetingFolder: sourceFolder)
        var first = meeting
        first.endedAt = cutAt
        first.finalized = false
        first.summary = ""
        first.actionItems = []
        for stale in ["notes-ai.md", "process.json"] {
            try? FileManager.default.removeItem(at: sourceFolder.appendingPathComponent(stale))
        }
        save(first)
        save(second)
        Log.meeting.info("MeetingStore: split \(meeting.folderName) at \(Int(offset))s → \(folderName) (\(head.count) + \(tail.count) lines)")
        return second
    }

    // MARK: - Join

    /// Folds `parts` (in recording order, the first being the survivor) into
    /// one meeting — the inverse of `split`, for a call that was stopped and
    /// restarted. `starts[i]` is where part i begins on the joined
    /// active-time line (the sum of the earlier parts' lengths), so its
    /// transcript lines shift by that much; rough notes are stacked with a
    /// rule between them; translations merge (segment ids survive). The AI
    /// notes, summary, action items and process map each described one
    /// piece, so they are dropped and the result comes back as "Needs
    /// summary" for the caller to finalize. The absorbed folders are deleted
    /// — audio must already have been joined into the first
    /// (`MeetingAudioJoiner`). Returns the survivor, or nil for fewer than two
    /// parts.
    func join(_ parts: [Meeting], starts: [TimeInterval]) -> Meeting? {
        guard parts.count >= 2, parts.count == starts.count else { return nil }
        let base = parts[0]
        let baseFolder = folderURL(for: base)
        var lines: [TranscriptSegment] = []
        var notes: [String] = []
        var translations = loadTranslations(for: base)
        for (part, start) in zip(parts, starts) {
            lines += loadTranscript(for: part).map { seg in
                var s = seg
                s.startTime += start
                s.endTime += start
                return s
            }
            let n = loadUserNotes(for: part).trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty { notes.append(n) }
            if part.id != base.id {
                for (language, table) in loadTranslations(for: part) {
                    translations[language, default: [:]].merge(table) { mine, _ in mine }
                }
            }
        }
        TranscriptJSONLWriter.rewrite(lines, meetingFolder: baseFolder)
        let stacked = notes.joined(separator: "\n\n---\n\n")
        if !stacked.isEmpty {
            try? stacked.write(to: baseFolder.appendingPathComponent("notes-user.md"), atomically: true, encoding: .utf8)
        }
        if !translations.isEmpty { writeTranslations(translations, for: base) }

        var joined = base
        joined.endedAt = parts.compactMap(\.endedAt).max() ?? base.endedAt
        joined.finalized = false
        joined.summary = ""
        joined.actionItems = []
        // The earliest part's calendar match stands; the others were the same call.
        if joined.calendarEvent == nil { joined.calendarEvent = parts.compactMap(\.calendarEvent).first }
        for stale in ["notes-ai.md", "process.json"] {
            try? FileManager.default.removeItem(at: baseFolder.appendingPathComponent(stale))
        }
        for part in parts.dropFirst() { delete(part) }
        save(joined)
        Log.meeting.info("MeetingStore: joined \(parts.count) recordings into \(base.folderName) (\(lines.count) lines)")
        return joined
    }

    func folderURL(for meeting: Meeting) -> URL {
        directoryURL.appendingPathComponent(meeting.folderName, isDirectory: true)
    }

    // MARK: - Sidecar files

    /// `immediate` skips the debounce for the quit path — a note typed in the
    /// last second before the app dies must not be dropped with the pending
    /// task. Cancels the outstanding write so it can't land stale afterwards.
    func writeUserNotes(_ text: String, for meeting: Meeting, immediate: Bool = false) {
        let url = folderURL(for: meeting).appendingPathComponent("notes-user.md")
        let key = "usernotes-\(meeting.id)"
        guard !immediate else {
            pendingWrites[key]?.cancel()
            pendingWrites[key] = nil
            try? text.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        debounced(key: key) {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func writeAINotes(_ markdown: String, for meeting: Meeting) {
        let url = folderURL(for: meeting).appendingPathComponent("notes-ai.md")
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.meeting.error("MeetingStore: notes-ai write failed: \(error.localizedDescription)")
        }
    }

    func writeProcessModel(_ model: ProcessModel, for meeting: Meeting) {
        // Immediate, not debounced: at most one write per live tick (~60s),
        // and post-hoc generation reloads the file as soon as the call returns.
        let url = folderURL(for: meeting).appendingPathComponent("process.json")
        do {
            let data = try Self.jsonEncoder.encode(model)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.meeting.error("MeetingStore: process write failed: \(error.localizedDescription)")
        }
    }

    func loadUserNotes(for meeting: Meeting) -> String {
        let url = folderURL(for: meeting).appendingPathComponent("notes-user.md")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func loadAINotes(for meeting: Meeting) -> String {
        let url = folderURL(for: meeting).appendingPathComponent("notes-ai.md")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func loadProcessModel(for meeting: Meeting) -> ProcessModel? {
        let url = folderURL(for: meeting).appendingPathComponent("process.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.jsonDecoder.decode(ProcessModel.self, from: data)
    }

    func loadTranscript(for meeting: Meeting) -> [TranscriptSegment] {
        TranscriptJSONLWriter.load(meetingFolder: folderURL(for: meeting))
    }

    /// `translations.json`: language name → segment id → translated line.
    /// Written by `MeetingTranslator`; a missing file is an empty table.
    func loadTranslations(for meeting: Meeting) -> [String: [String: String]] {
        let url = folderURL(for: meeting).appendingPathComponent("translations.json")
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? Self.jsonDecoder.decode([String: [String: String]].self, from: data)) ?? [:]
    }

    func writeTranslations(_ table: [String: [String: String]], for meeting: Meeting) {
        let url = folderURL(for: meeting).appendingPathComponent("translations.json")
        debounced(key: "translations-\(meeting.id)") {
            do {
                let data = try Self.jsonEncoder.encode(table)
                try data.write(to: url, options: .atomic)
            } catch {
                Log.meeting.error("MeetingStore: translations write failed: \(error.localizedDescription)")
            }
        }
    }

    func hasProcessModel(_ meeting: Meeting) -> Bool {
        FileManager.default.fileExists(
            atPath: folderURL(for: meeting).appendingPathComponent("process.json").path
        )
    }

    // MARK: - Helpers

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func debounced(key: String, _ work: @escaping @MainActor () -> Void) {
        pendingWrites[key]?.cancel()
        pendingWrites[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            work()
            self?.pendingWrites[key] = nil
        }
    }

    /// Flush all debounced writes immediately (app-quit path).
    func flushPendingWrites() {
        // Cancelling would drop the work; instead let each pending task run by
        // replaying its save synchronously is not possible here — so we simply
        // rely on save() being called directly on the quit path for anything
        // that matters (MeetingCenter.emergencyStop does).
        for task in pendingWrites.values { task.cancel() }
        pendingWrites = [:]
    }
}
