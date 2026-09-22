import Foundation
import Observation

// MARK: - Meeting

enum MeetingMode: String, Codable, Hashable {
    case standard
    case processMapping
}

/// Where the recording happened. A phone recording is mic-only and has no
/// `Them` separation, and the clients say so rather than implying this Mac's
/// diarized two-stream capture.
enum MeetingOrigin: String, Codable, Hashable, Sendable {
    case host
    case local
}

/// The calendar event a recording was matched to. Foundation-only on purpose:
/// this file is shared with the Linux agent, so the EventKit reading happens
/// in `MeetingCalendar` (Mac) and only this plain value is stored.
struct CalendarEventRef: Codable, Hashable, Sendable {
    var eventIdentifier: String
    var title: String
    /// The calendar's own name — for a synced account that is the address
    /// ("you@example.com"), which is exactly what tells the orgs apart.
    var calendarTitle: String
    /// The account the calendar lives in ("Google", "iCloud", "Exchange").
    var account: String
    var organizer: String? = nil
    /// Everyone invited except the user, display name where the calendar has
    /// one, address otherwise.
    var attendees: [String] = []
    var start: Date
    var end: Date
    var conferenceURL: String? = nil
    var location: String? = nil

    /// "example.com" for an address-named calendar, else the calendar name.
    var org: String {
        if let at = calendarTitle.firstIndex(of: "@") {
            return String(calendarTitle[calendarTitle.index(after: at)...])
        }
        return calendarTitle
    }
}

struct ActionItem: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var text: String
    var owner: String? = nil
    var done: Bool = false
}

/// Metadata for one recorded meeting. Notes and the process model live in
/// sidecar files inside the meeting folder (loaded on demand by MeetingStore),
/// so the list stays cheap and everything is hand-editable in Finder.
struct Meeting: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var createdAt: Date = Date()
    var endedAt: Date? = nil
    var mode: MeetingMode = .standard
    /// Where the recording came from. See the tolerant `init(from:)` below —
    /// a property default is NOT enough to keep older files decoding.
    var origin: MeetingOrigin = .host
    var summary: String = ""
    var actionItems: [ActionItem] = []
    var hasAudio: Bool = false
    /// True once the end-of-meeting notes pass has completed. False + non-nil
    /// endedAt renders as "Needs summary" with a retry button.
    var finalized: Bool = false
    /// On-disk folder name (stable even when the title is edited later).
    var folderName: String
    /// The Apple Calendar event this recording lined up with, if any. Set at
    /// start (or by the launch backfill); the event's title becomes the
    /// meeting's unless the user has already renamed it.
    var calendarEvent: CalendarEventRef? = nil

    var durationSeconds: TimeInterval? {
        guard let endedAt else { return nil }
        return endedAt.timeIntervalSince(createdAt)
    }
}

extension Meeting {
    /// Decodes tolerantly, because meeting.json files on disk were written by
    /// older builds that had fewer fields.
    ///
    /// A property default does **not** cover this: Swift's synthesised
    /// `init(from:)` calls `decode(_:forKey:)` for every non-optional property
    /// and throws `keyNotFound` when the key is absent — the default is only
    /// ever used by the memberwise initialiser. Adding `origin` with a default
    /// therefore made every pre-existing meeting undecodable, and `reload()`
    /// skips what it cannot decode, so the entire library silently vanished
    /// from the app and from every paired client.
    ///
    /// Deliberately in an extension: declaring `init(from:)` in the struct body
    /// would suppress the memberwise initialiser that `MeetingStore.create`
    /// relies on.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Identity and creation time are the two things a meeting cannot be
        // reconstructed without; everything else falls back.
        id = try c.decode(UUID.self, forKey: .id)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        title = try c.decodeIfPresent(String.self, forKey: .title)
            ?? Meeting.defaultTitleFallback(for: createdAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        mode = try c.decodeIfPresent(MeetingMode.self, forKey: .mode) ?? .standard
        origin = try c.decodeIfPresent(MeetingOrigin.self, forKey: .origin) ?? .host
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        actionItems = try c.decodeIfPresent([ActionItem].self, forKey: .actionItems) ?? []
        hasAudio = try c.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? false
        finalized = try c.decodeIfPresent(Bool.self, forKey: .finalized) ?? false
        // Overwritten by the store from the folder on disk anyway.
        folderName = try c.decodeIfPresent(String.self, forKey: .folderName) ?? ""
        calendarEvent = try c.decodeIfPresent(CalendarEventRef.self, forKey: .calendarEvent)
    }

    /// True while the title is still the placeholder the store stamped at
    /// creation, or the junk a finalize pass over an empty transcript once
    /// produced (",", "%20", ") Ex" and a literal "placeholder" were all real)
    /// — i.e. anything a calendar name should replace without asking.
    var hasPlaceholderTitle: Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count < 3 { return true }
        if t.lowercased() == "placeholder" || t.lowercased() == "untitled" { return true }
        if let first = t.unicodeScalars.first, !CharacterSet.alphanumerics.contains(first) { return true }
        if t == Meeting.defaultTitleFallback(for: createdAt) { return true }
        return t.hasPrefix("Meeting ") && t.range(of: #"^Meeting [A-Z][a-z]{2} \d{1,2}, \d{2}:\d{2}$"#, options: .regularExpression) != nil
    }

    static func defaultTitleFallback(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return "Meeting \(f.string(from: date))"
    }
}

// MARK: - Transcript

enum TranscriptSource: String, Codable, Sendable {
    case mic
    case system
}

struct TranscriptSegment: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var source: TranscriptSource
    /// "Me" for the mic stream; "Them" / "Them 1" / "Them 2" for the system
    /// stream (diarized labels are only stable within one STT chunk).
    var speaker: String
    var text: String
    /// Seconds relative to meeting start, counting active recording time only
    /// (pauses are excised from the timeline).
    var startTime: TimeInterval
    var endTime: TimeInterval
}

/// One cut chunk of PCM16 mono 16k audio bound for STT.
struct AudioChunk: Sendable {
    var source: TranscriptSource
    /// Meeting-relative start, in active recording time.
    var startOffset: TimeInterval
    var duration: TimeInterval
    var pcm: Data
    /// Peak RMS over the chunk as % of Int16 full scale — the silence gate.
    var peakRMSPercent: Double
}

/// Live, chronologically-merged transcript of a recording in progress. STT
/// chunks from the two streams complete out of order, so appends are
/// insertion-sorted by startTime rather than appended blindly.
@MainActor @Observable
final class MeetingTranscript {
    private(set) var segments: [TranscriptSegment] = []
    /// Fired with each batch as it arrives (feeds the JSONL writer).
    var onAppend: (([TranscriptSegment]) -> Void)?
    /// A second fan-out, for the mobile bridge's `meeting_live` push.
    /// Separate from `onAppend` rather than replacing it, because that one is
    /// already spoken for by the JSONL writer and a single closure means
    /// whichever observer registers last silently wins.
    var onAppendRemote: (([TranscriptSegment]) -> Void)?

    func append(_ new: [TranscriptSegment]) {
        guard !new.isEmpty else { return }
        for seg in new {
            let idx = insertionIndex(for: seg.startTime)
            segments.insert(seg, at: idx)
        }
        onAppend?(new)
        onAppendRemote?(new)
    }

    func reset() {
        segments = []
    }

    /// "[mm:ss] Speaker: text" lines — the transcript as the LLM reads it.
    func renderText() -> String {
        segments.map { seg in
            let m = Int(seg.startTime) / 60
            let s = Int(seg.startTime) % 60
            return String(format: "[%02d:%02d] %@: %@", m, s, seg.speaker, seg.text)
        }.joined(separator: "\n")
    }

    private func insertionIndex(for time: TimeInterval) -> Int {
        var lo = 0, hi = segments.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if segments[mid].startTime <= time { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

// MARK: - JSONL persistence

/// Appends transcript segments to `<meetingFolder>/transcript.jsonl`, one JSON
/// object per line, on a private serial queue (same shape as FileLogger).
/// Lines are in arrival order; each carries startTime so readers sort.
final class TranscriptJSONLWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "udha.meeting.transcript")
    private let url: URL
    private let encoder = JSONEncoder()

    init(meetingFolder: URL) {
        self.url = meetingFolder.appendingPathComponent("transcript.jsonl")
    }

    func append(_ segments: [TranscriptSegment]) {
        guard !segments.isEmpty else { return }
        let lines: [Data] = segments.compactMap { try? encoder.encode($0) }
        queue.async { [url] in
            var blob = Data()
            for line in lines {
                blob.append(line)
                blob.append(0x0A)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(blob)
                try? handle.close()
            } else {
                try? blob.write(to: url)
            }
        }
    }

    /// Blocks until all queued writes have hit the file. Safe from the quit path.
    func flushSync() {
        queue.sync {}
    }

    /// Replaces the whole file — the split path, which rewrites a finished
    /// meeting's transcript. Never used on a recording in progress.
    static func rewrite(_ segments: [TranscriptSegment], meetingFolder: URL) {
        let url = meetingFolder.appendingPathComponent("transcript.jsonl")
        let encoder = JSONEncoder()
        var blob = Data()
        for seg in segments.sorted(by: { $0.startTime < $1.startTime }) {
            guard let line = try? encoder.encode(seg) else { continue }
            blob.append(line)
            blob.append(0x0A)
        }
        do {
            try blob.write(to: url, options: .atomic)
        } catch {
            Log.meeting.error("TranscriptJSONLWriter: rewrite failed: \(error.localizedDescription)")
        }
    }

    static func load(meetingFolder: URL) -> [TranscriptSegment] {
        let url = meetingFolder.appendingPathComponent("transcript.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        let segments = text.split(separator: "\n").compactMap {
            try? decoder.decode(TranscriptSegment.self, from: Data($0.utf8))
        }
        return segments.sorted { $0.startTime < $1.startTime }
    }
}
