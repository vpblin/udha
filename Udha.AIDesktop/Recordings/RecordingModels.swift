import Foundation

// MARK: - Recording

/// Where a recording is in the capture → transcribe → compose → share pipeline.
///
/// Stored rather than derived, because the interesting question after a crash
/// is "what was in flight?", and a folder full of raw files can't answer that
/// on its own. `MeetingStore` learned the same lesson with `finalized`.
enum RecordingStage: String, Codable, Hashable, Sendable {
    /// Capture is live right now (or died mid-capture — see the crash sweep).
    case capturing
    /// Raw files are on disk and closed. Nothing has been rendered yet.
    case needsProcessing
    case transcribing
    case composing
    /// Both masters rendered. Uploading is a separate, resumable concern.
    case ready
    case failed
}

/// What the compositor should output. Both are produced by default; the enum
/// exists so a re-render can target one without redoing the other.
enum RecordingOrientation: String, Codable, Hashable, Sendable, CaseIterable {
    case landscape
    case portrait

    /// Output pixel dimensions. 1080p on both axes — high enough for a screen
    /// demo to stay readable, low enough that a Mac encodes it faster than
    /// real time.
    var renderSize: (width: Int, height: Int) {
        switch self {
        case .landscape: return (1920, 1080)
        case .portrait:  return (1080, 1920)
        }
    }

    var fileName: String { "\(rawValue).mp4" }
}

/// Metadata for one recorded video. Raw capture, rendered masters and captions
/// live as sidecar files in the recording folder, so the list stays cheap and
/// everything is inspectable in Finder.
struct Recording: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var createdAt: Date = Date()
    var endedAt: Date? = nil
    var stage: RecordingStage = .capturing
    /// Active capture seconds, pauses excised. Stored rather than derived from
    /// createdAt/endedAt because those include paused time.
    var durationSeconds: TimeInterval = 0

    // What actually got captured — each stream can degrade independently.
    var hasCamera: Bool = false
    var hasMic: Bool = false
    var hasSystemAudio: Bool = false

    /// Which masters exist on disk right now.
    var renderedOrientations: [RecordingOrientation] = []
    /// Set when the pipeline gave up, so the UI can offer a retry with a reason.
    var failureReason: String? = nil

    // Sharing. All nil until the recording is published.
    var slug: String? = nil
    var streamUIDLandscape: String? = nil
    var streamUIDPortrait: String? = nil
    var isPasswordProtected: Bool = false
    var publishedAt: Date? = nil

    /// Which part of the source the masters keep, as a normalised centre
    /// (0…1, y measured from the bottom so it agrees with both AppKit and Core
    /// Image). The screen is aspect-filled, so on a wide display most of it
    /// falls outside the frame; dragging the red guides before recording moves
    /// this, and storing it per recording is what lets a re-render reproduce
    /// the same crop months later.
    var screenCropX: Double = 0.5
    var screenCropY: Double = 0.5
    /// How much of the largest possible crop to keep, 0…1. 1 is the whole
    /// aspect-filled region; smaller zooms in, which is how you cut the menu
    /// bar and the Dock out of a full-screen recording. The aspect never
    /// changes — this is one scalar, so both masters stay exactly the shape
    /// they have to be.
    var screenCropScale: Double = 1
    /// No screen at all — just the camera, filling the frame. Recorded on the
    /// take rather than inferred from a missing file, so a re-render lays it
    /// out the same way even if the raw files are ever moved around.
    var isCameraOnly: Bool = false

    /// The recordings this one was concatenated from, in play order.
    ///
    /// Empty for an ordinary take. A joined recording has no `raw/` files of
    /// its own — its masters were built from the sources' masters — so this is
    /// also what tells the pipeline that "re-render" means "join again" rather
    /// than "compose from raw".
    var joinedFromIDs: [UUID] = []
    /// The sources' titles as they read at join time. Stored alongside the ids
    /// because a source can later be renamed or deleted, and the provenance
    /// strip should still say what this video was made of.
    var joinedFromTitles: [String] = []
    /// Language *name* of the captions burned into the masters ("" = as
    /// spoken). Stamped at render time so a share link serves the VTT that
    /// matches the picture, whatever the setting says today.
    var captionLanguage: String = ""
    /// The title the share service last confirmed. A published recording whose
    /// `title` differs has a rename the public page has not seen yet — the
    /// push failed (offline, signed out) or happened before this was tracked —
    /// and `RecordingCenter.syncPendingTitles` retries it at launch.
    var syncedTitle: String? = nil

    var titleSyncPending: Bool { isPublished && syncedTitle != title }

    /// On-disk folder name (stable even when the title is edited later).
    var folderName: String

    var isPublished: Bool { slug != nil && publishedAt != nil }

    var isJoined: Bool { !joinedFromIDs.isEmpty }
}

extension Recording {
    /// Decodes tolerantly. See the long note on `Meeting.init(from:)` — a
    /// property default does **not** keep older files decoding, because the
    /// synthesised `init(from:)` calls `decode(_:forKey:)` for every
    /// non-optional property and throws `keyNotFound` when the key is absent.
    /// Getting this wrong once made an entire library silently vanish.
    ///
    /// Deliberately in an extension so the memberwise initialiser survives for
    /// `RecordingStore.create`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Identity and creation time are the only two things a recording cannot
        // be reconstructed without.
        id = try c.decode(UUID.self, forKey: .id)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        title = try c.decodeIfPresent(String.self, forKey: .title)
            ?? Recording.defaultTitleFallback(for: createdAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        stage = try c.decodeIfPresent(RecordingStage.self, forKey: .stage) ?? .needsProcessing
        durationSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .durationSeconds) ?? 0
        hasCamera = try c.decodeIfPresent(Bool.self, forKey: .hasCamera) ?? false
        hasMic = try c.decodeIfPresent(Bool.self, forKey: .hasMic) ?? false
        hasSystemAudio = try c.decodeIfPresent(Bool.self, forKey: .hasSystemAudio) ?? false
        renderedOrientations = try c.decodeIfPresent([RecordingOrientation].self, forKey: .renderedOrientations) ?? []
        failureReason = try c.decodeIfPresent(String.self, forKey: .failureReason)
        slug = try c.decodeIfPresent(String.self, forKey: .slug)
        streamUIDLandscape = try c.decodeIfPresent(String.self, forKey: .streamUIDLandscape)
        streamUIDPortrait = try c.decodeIfPresent(String.self, forKey: .streamUIDPortrait)
        isPasswordProtected = try c.decodeIfPresent(Bool.self, forKey: .isPasswordProtected) ?? false
        publishedAt = try c.decodeIfPresent(Date.self, forKey: .publishedAt)
        screenCropX = try c.decodeIfPresent(Double.self, forKey: .screenCropX) ?? 0.5
        screenCropY = try c.decodeIfPresent(Double.self, forKey: .screenCropY) ?? 0.5
        screenCropScale = try c.decodeIfPresent(Double.self, forKey: .screenCropScale) ?? 1
        isCameraOnly = try c.decodeIfPresent(Bool.self, forKey: .isCameraOnly) ?? false
        joinedFromIDs = try c.decodeIfPresent([UUID].self, forKey: .joinedFromIDs) ?? []
        joinedFromTitles = try c.decodeIfPresent([String].self, forKey: .joinedFromTitles) ?? []
        captionLanguage = try c.decodeIfPresent(String.self, forKey: .captionLanguage) ?? ""
        syncedTitle = try c.decodeIfPresent(String.self, forKey: .syncedTitle)
        // Overwritten by the store from the folder on disk anyway.
        folderName = try c.decodeIfPresent(String.self, forKey: .folderName) ?? ""
    }

    static func defaultTitleFallback(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return "Recording \(f.string(from: date))"
    }
}

// MARK: - Captions

/// One word with its own timing. Kept because Scribe returns word-level
/// timestamps and burned-in social captions are expected to highlight the
/// word being spoken — segment-level timing cannot drive that.
struct CaptionWord: Codable, Hashable, Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

/// One on-screen caption: at most two short lines, which is a display
/// constraint rather than a transcription one. `CaptionBuilder` is what turns
/// Scribe's continuous word stream into cues this shape.
struct CaptionCue: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var words: [CaptionWord]

    var text: String { words.map(\.text).joined(separator: " ") }

    func contains(_ t: TimeInterval) -> Bool { t >= start && t < end }

    /// Replace what this cue says, keeping when it says it.
    ///
    /// The word timings cannot survive an edit — they came from Scribe and the
    /// new words never existed — so they are re-derived by spreading the cue's
    /// own span across the words in proportion to their length. That keeps the
    /// per-word highlight tracking roughly with the voice instead of freezing
    /// on the first word, and the cue's start and end are untouched, so an edit
    /// can never drift a caption out of sync with the picture.
    mutating func setText(_ newText: String) {
        let pieces = newText.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !pieces.isEmpty else {
            words = []
            return
        }
        let span = max(0.001, end - start)
        let weights = pieces.map { Double(max(1, $0.count)) }
        let total = weights.reduce(0, +)
        var cursor = start
        words = zip(pieces, weights).map { piece, weight in
            let duration = span * (weight / total)
            let word = CaptionWord(text: piece, start: cursor, end: cursor + duration)
            cursor += duration
            return word
        }
    }

    enum CodingKeys: String, CodingKey { case id, start, end, words }

    init(start: TimeInterval, end: TimeInterval, words: [CaptionWord]) {
        self.start = start
        self.end = end
        self.words = words
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try c.decode(TimeInterval.self, forKey: .start)
        end = try c.decode(TimeInterval.self, forKey: .end)
        words = try c.decodeIfPresent([CaptionWord].self, forKey: .words) ?? []
    }
}

/// The caption track for one recording, persisted as `captions.json` (the
/// editable source of truth) and exported to `captions.vtt` (what Cloudflare
/// Stream is handed). Keeping the JSON means a re-render never needs a second
/// STT call, and a typo in a product name can be fixed by hand once.
struct CaptionTrack: Codable, Hashable, Sendable {
    var cues: [CaptionCue] = []
    /// Language Scribe reported, for the VTT header and the Stream API.
    var languageCode: String = "en"

    var isEmpty: Bool { cues.isEmpty }

    /// The cue visible at `t`, if any. Linear scan is fine: cue counts are in
    /// the hundreds and the compositor walks time forward anyway.
    func cue(at t: TimeInterval) -> CaptionCue? {
        cues.first { $0.contains(t) }
    }
}
