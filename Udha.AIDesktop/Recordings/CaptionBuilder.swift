import Foundation

/// Turns Scribe's flat word stream into on-screen cues.
///
/// This is a *display* problem, not a transcription one. Scribe returns
/// sentence-shaped segments, and sentences are unreadable burned into a phone
/// screen — long lines are the single most recognisable giveaway of
/// auto-generated captions. So the segment boundaries are thrown away and the
/// words are re-cut against three signals: a pause long enough to read as a
/// beat, sentence-ending punctuation, and a hard word ceiling.
/// How much punctuation survives into a burned caption.
///

enum CaptionBuilder {
    struct Options {
        /// Ceiling per cue. Six words is about two comfortable lines at the
        /// sizes social video needs; more than that starts wrapping to three.
        var maxWords: Int = 6
        /// A gap this long reads as a natural break, so cut there even if the
        /// cue is short.
        var pauseBreakSeconds: TimeInterval = 0.6
        /// Never flash a cue faster than this — even three quick words need a
        /// beat to land.
        var minCueSeconds: TimeInterval = 0.8
        /// Never hold one past this, or it stops tracking the speech.
        var maxCueSeconds: TimeInterval = 5.0
        /// Applied *after* the cut decisions below, which read sentence-ending
        /// punctuation to find a natural break. Stripping first would throw
        /// away the signal that makes the cues land in the right places.
        var punctuation: CaptionPunctuation = .reduced

        init() {}
    }

    /// `words` must be in ascending time order.
    static func build(from words: [CaptionWord], options: Options = Options()) -> [CaptionCue] {
        guard !words.isEmpty else { return [] }

        var cues: [CaptionCue] = []
        var current: [CaptionWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            // Hold a very short cue open a little longer, but never past the
            // next word — overlapping cues would render two captions at once.
            let end = max(last.end, first.start + options.minCueSeconds)
            let cleaned = current.compactMap { word -> CaptionWord? in
                let text = options.punctuation.apply(to: word.text)
                guard !text.isEmpty else { return nil }
                var copy = word
                copy.text = text
                return copy
            }
            if !cleaned.isEmpty {
                cues.append(CaptionCue(start: first.start, end: end, words: cleaned))
            }
            current = []
        }

        for (index, word) in words.enumerated() {
            current.append(word)

            let isLast = index == words.count - 1
            if isLast { break }

            let next = words[index + 1]
            let gap = next.start - word.end
            let spanIfExtended = next.end - (current.first?.start ?? word.start)

            let hitCeiling = current.count >= options.maxWords
            let hitPause = gap >= options.pauseBreakSeconds
            let hitSentenceEnd = word.text.hasSuffixIn([".", "!", "?"])
            let wouldRunLong = spanIfExtended > options.maxCueSeconds

            if hitCeiling || hitPause || hitSentenceEnd || wouldRunLong {
                flush()
            }
        }
        flush()

        // Clamp each cue so it never overlaps the next. The min-duration bump
        // above can push an end past the following start when speech is dense.
        for i in cues.indices.dropLast() {
            let nextStart = cues[i + 1].start
            if cues[i].end > nextStart {
                cues[i].end = nextStart
            }
        }
        return cues.filter { $0.end > $0.start }
    }
}

private extension String {
    func hasSuffixIn(_ suffixes: [String]) -> Bool {
        suffixes.contains { hasSuffix($0) }
    }
}

// MARK: - WebVTT

/// Serialises a `CaptionTrack` to WebVTT.
///
/// Even though captions are burned into the frames, the VTT still ships: it is
/// what Cloudflare Stream is handed for accessibility, and it is the readable
/// transcript rendered beside the video on the share page. It is derived —
/// `captions.json` is the source of truth, since only that carries word-level
/// timings.
enum CaptionTrackVTT {
    static func serialize(_ track: CaptionTrack) -> String {
        var out = "WEBVTT\n\n"
        for (index, cue) in track.cues.enumerated() {
            out += "\(index + 1)\n"
            out += "\(timestamp(cue.start)) --> \(timestamp(cue.end))\n"
            out += "\(wrap(cue.text))\n\n"
        }
        return out
    }

    /// WebVTT wants HH:MM:SS.mmm.
    static func timestamp(_ t: TimeInterval) -> String {
        let clamped = max(0, t)
        let totalMillis = Int((clamped * 1000).rounded())
        let millis = totalMillis % 1000
        let totalSeconds = totalMillis / 1000
        let seconds = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3600
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, millis)
    }

    /// Two lines maximum, split near the middle on a word boundary — the same
    /// shape the burned-in renderer uses, so the two never disagree.
    static func wrap(_ text: String, maxCharsPerLine: Int = 32) -> String {
        guard text.count > maxCharsPerLine else { return text }
        let words = text.split(separator: " ").map(String.init)
        guard words.count > 1 else { return text }

        var best: (first: String, second: String)?
        var bestDelta = Int.max
        for split in 1..<words.count {
            let first = words[0..<split].joined(separator: " ")
            let second = words[split...].joined(separator: " ")
            let delta = abs(first.count - second.count)
            if delta < bestDelta {
                bestDelta = delta
                best = (first, second)
            }
        }
        guard let best else { return text }
        return "\(best.first)\n\(best.second)"
    }
}
