import Foundation
import Observation

/// Shows each transcript line in another language, next to the original.
///
/// Local by design: the lines go to an Ollama server on your own machine
/// (`config.localModel`, default localhost — point it at whatever box
/// already transcribes meetings for free) and nowhere else. Nothing is billed,
/// and a transcript never leaves your network. This is the second deliberate LLM in
/// the meeting recorder, next to notes; it is not a general dependency.
///
/// Batches of up to 30 untranslated lines go out numbered; the model returns
/// the same numbers, so a dropped or reordered line is simply retried on the
/// next pass rather than landing under the wrong speaker. Results persist per
/// meeting in `translations.json` (language → segment id → line), so a
/// finished meeting is translated once.
@MainActor
@Observable
final class MeetingTranslator {
    static var languages: [String] { LocalTranslator.languages }
    static let batchSize = 30

    /// meeting id → language → segment id → line (the on-disk shape).
    private(set) var tables: [UUID: [String: [String: String]]] = [:]
    /// Meetings with a call in flight.
    private(set) var busy: Set<UUID> = []
    private(set) var lastError: String?

    private struct Request {
        var meeting: Meeting
        var segments: [TranscriptSegment]
        /// The live pane wants what was just said; a stored meeting is read
        /// from the top.
        var newestFirst: Bool
    }
    private var pending: [UUID: Request] = [:]
    private var loaded: Set<UUID> = []

    private let config: ConfigStore
    private weak var store: MeetingStore?

    init(config: ConfigStore, store: MeetingStore) {
        self.config = config
        self.store = store
    }

    var language: String { config.config.meetings.translateTo }
    var isOn: Bool { !language.isEmpty }

    func setLanguage(_ name: String) {
        config.mutate { $0.meetings.translateTo = name }
        lastError = nil
    }

    func text(for segment: TranscriptSegment, in meeting: Meeting) -> String? {
        tables[meeting.id]?[language]?[segment.id.uuidString]
    }

    func isBusy(_ meeting: Meeting) -> Bool { busy.contains(meeting.id) }

    /// Make sure every one of `segments` has a line in the current language,
    /// fetching what is missing. Cheap to call on every transcript change.
    func ensure(_ segments: [TranscriptSegment], for meeting: Meeting, newestFirst: Bool) {
        guard isOn else { return }
        loadIfNeeded(meeting)
        pending[meeting.id] = Request(meeting: meeting, segments: segments, newestFirst: newestFirst)
        guard !busy.contains(meeting.id) else { return }
        busy.insert(meeting.id)
        Task { await drain(meeting.id) }
    }

    private func loadIfNeeded(_ meeting: Meeting) {
        guard !loaded.contains(meeting.id), let store else { return }
        loaded.insert(meeting.id)
        let table = store.loadTranslations(for: meeting)
        if !table.isEmpty { tables[meeting.id] = table }
    }

    private func drain(_ id: UUID) async {
        defer { busy.remove(id) }
        while let request = pending.removeValue(forKey: id) {
            let lang = language
            guard !lang.isEmpty else { return }
            let done = tables[id]?[lang] ?? [:]
            let missing = request.segments
                .filter { done[$0.id.uuidString] == nil && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .sorted { $0.startTime < $1.startTime }
            guard !missing.isEmpty else { continue }
            let batch = request.newestFirst
                ? Array(missing.suffix(Self.batchSize))
                : Array(missing.prefix(Self.batchSize))
            do {
                let lines = try await LocalTranslator(config: config.config.localModel)
                    .translate(batch.map(\.text), to: lang, about: "a live meeting transcript")
                var table = tables[id] ?? [:]
                var forLang = table[lang] ?? [:]
                var landed = 0
                for (segment, line) in zip(batch, lines) {
                    guard let line, !line.isEmpty else { continue }
                    forLang[segment.id.uuidString] = line
                    landed += 1
                }
                table[lang] = forLang
                tables[id] = table
                lastError = nil
                store?.writeTranslations(table, for: request.meeting)
                Log.meeting.info("MeetingTranslator: \(landed)/\(batch.count) lines → \(lang) for \(request.meeting.folderName)")
                // More to do and nothing newer queued: go round again. A
                // batch that landed nothing would loop forever, so stop there.
                if landed > 0, missing.count > batch.count, pending[id] == nil {
                    pending[id] = request
                }
            } catch {
                lastError = error.localizedDescription
                Log.meeting.error("MeetingTranslator: batch failed: \(error.localizedDescription)")
                return
            }
        }
    }
}
