import Foundation

/// Captions in a language you did not speak.
///
/// The English track keeps the measured word timings; this builds a second
/// track from it. Translating the six-word cues one by one would give broken
/// Spanish — word order does not survive a cut that small — so the cues are
/// first gathered back into sentences (a gap under a third of a second means
/// the same breath; terminal punctuation or thirty words ends one), each
/// sentence is translated whole, and its words are spread across the
/// sentence's own span in proportion to their length, the same rule an edited
/// cue uses. `CaptionBuilder` then re-cuts the result exactly as it cut the
/// original: the pauses are still where the voice paused, so the cues land on
/// the same beats and the highlight tracks to within a word.
enum CaptionTranslator {
    static let maxSentenceWords = 30
    static let sameBreathGap: TimeInterval = 0.35
    static let batchSize = 40

    static func translate(
        _ source: CaptionTrack, to language: String,
        using translator: LocalTranslator, options: CaptionBuilder.Options
    ) async throws -> CaptionTrack {
        let sentences = gather(source.cues)
        guard !sentences.isEmpty else { return CaptionTrack(cues: [], languageCode: LocalTranslator.code(for: language)) }

        var translated: [String?] = Array(repeating: nil, count: sentences.count)
        var start = 0
        while start < sentences.count {
            let end = min(sentences.count, start + batchSize)
            let batch = Array(sentences[start..<end])
            let lines = try await translator.translate(
                batch.map(\.text), to: language,
                about: "the narration of a screen-recorded demo video, shown as burned-in social captions"
            )
            for (offset, line) in lines.enumerated() { translated[start + offset] = line }
            start = end
        }
        // One retry for anything the model skipped; after that the English
        // line stays, which is better than a hole in the captions.
        let missing = translated.indices.filter { translated[$0] == nil }
        if !missing.isEmpty {
            let lines = try await translator.translate(
                missing.map { sentences[$0].text }, to: language,
                about: "the narration of a screen-recorded demo video, shown as burned-in social captions"
            )
            for (offset, line) in lines.enumerated() { translated[missing[offset]] = line }
        }

        var words: [CaptionWord] = []
        for (sentence, line) in zip(sentences, translated) {
            words.append(contentsOf: spread(line ?? sentence.text, over: sentence))
        }
        var track = CaptionTrack(cues: CaptionBuilder.build(from: words, options: options))
        track.languageCode = LocalTranslator.code(for: language)
        return track
    }

    struct Sentence {
        var text: String
        var start: TimeInterval
        var end: TimeInterval
        var wordCount: Int
    }

    /// Cues back into sentences. The stored cues may have lost their full
    /// stops (`CaptionPunctuation.reduced`), so timing is the main signal.
    static func gather(_ cues: [CaptionCue]) -> [Sentence] {
        var out: [Sentence] = []
        var current: Sentence?
        for cue in cues where !cue.words.isEmpty {
            let text = cue.text
            if var open = current,
               cue.start - open.end < sameBreathGap,
               open.wordCount + cue.words.count <= maxSentenceWords,
               !endsSentence(open.text) {
                open.text += " " + text
                open.end = cue.end
                open.wordCount += cue.words.count
                current = open
            } else {
                if let open = current { out.append(open) }
                current = Sentence(text: text, start: cue.start, end: cue.end, wordCount: cue.words.count)
            }
        }
        if let open = current { out.append(open) }
        return out
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".?!…".contains(last)
    }

    /// Words of `line` across the sentence's span, weighted by length.
    static func spread(_ line: String, over sentence: Sentence) -> [CaptionWord] {
        let pieces = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !pieces.isEmpty else { return [] }
        let span = max(0.001, sentence.end - sentence.start)
        let weights = pieces.map { Double(max(1, $0.count)) }
        let total = weights.reduce(0, +)
        var cursor = sentence.start
        return zip(pieces, weights).map { piece, weight in
            let duration = span * (weight / total)
            let word = CaptionWord(text: piece, start: cursor, end: cursor + duration)
            cursor += duration
            return word
        }
    }
}
