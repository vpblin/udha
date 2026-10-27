import Foundation
import Observation

/// One turn in the "ask about this call" pane.
struct MeetingAskTurn: Identifiable, Hashable {
    enum Role: Hashable { case you, udha }
    let id = UUID()
    var role: Role
    var text: String
    /// "11:58 – 12:40" — the transcript window the answer came from. Empty when
    /// the answer isn't grounded in a specific stretch of the call.
    var cite: String = ""
    var failed: Bool = false
}

/// Answers questions about the call that is happening *right now*, from the
/// live transcript only.
///
/// Deliberately read-only and private: the answer is rendered in the pane (and,
/// — it never goes near the
/// recording or the outbound audio, so asking mid-call is invisible to the
/// other participants.
///
/// Uses the cheap live model, not the finalize model: this runs while the call
/// is in flight and latency is the whole point.
@MainActor
@Observable
final class MeetingAsk {
    private(set) var turns: [MeetingAskTurn] = []
    private(set) var isAnswering = false

    /// The canned starters shown as chips above the input.
    static let suggestions = [
        "Catch me up",
        "What have they committed to?",
        "Any numbers said out loud?",
        "What should I ask next?",
        "Open questions",
    ]

    private let claude: ClaudeClient
    private let config: ConfigStore
    private let keychain: KeychainStore
    private weak var recorder: MeetingRecorder?

    /// Called with the answer text when it lands, so the caller can speak it.
    var onAnswer: ((String) -> Void)?
    /// Called for every answer, successful or not, whoever asked. Distinct from
    /// `onAnswer`, which only fires for voice asks — the mobile bridge needs
    /// the reply regardless of whether it was meant to be spoken.
    var onAnswerLanded: ((MeetingAskTurn) -> Void)?

    var hasKey: Bool { ClaudeClient.hasNotesModel(keychain: keychain, config: config) }

    init(claude: ClaudeClient, config: ConfigStore, keychain: KeychainStore, recorder: MeetingRecorder) {
        self.claude = claude
        self.config = config
        self.keychain = keychain
        self.recorder = recorder
    }

    func ask(_ question: String, speakAnswer: Bool = false) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isAnswering else { return }
        turns.append(MeetingAskTurn(role: .you, text: q))

        guard hasKey else {
            fail("No Anthropic key — add one in Settings › Keys and I can answer from the live transcript.")
            return
        }

        let segments = recorder?.transcript.segments ?? []
        guard segments.count >= 2 else {
            fail("Nothing transcribed yet — give it a few seconds of speech.")
            return
        }

        isAnswering = true
        let transcript = Self.render(segments)
        let model = config.config.meetings.liveModel

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isAnswering = false }
            do {
                let (payload, _) = try await claude.structured(
                    AskPayload.self,
                    model: model,
                    maxTokens: 1200,
                    system: [PromptBlock(text: Self.system, cached: true)],
                    user: [
                        PromptBlock(text: "<transcript>\n\(transcript)\n</transcript>", cached: false),
                        PromptBlock(text: "<question>\(q)</question>"),
                    ],
                    schema: Self.schema
                )
                let turn = MeetingAskTurn(role: .udha, text: payload.answer, cite: payload.cite ?? "")
                self.turns.append(turn)
                self.onAnswerLanded?(turn)
                if speakAnswer { self.onAnswer?(payload.answer) }
            } catch {
                Log.meeting.error("MeetingAsk failed: \(error.localizedDescription)")
                self.fail("Couldn't answer that — \(error.localizedDescription)")
            }
        }
    }

    /// Records a failed answer once, so every path that gives up still reaches
    /// whoever asked — including a remote client that would otherwise wait
    /// forever for a reply that was never going to come.
    private func fail(_ text: String) {
        let turn = MeetingAskTurn(role: .udha, text: text, failed: true)
        turns.append(turn)
        onAnswerLanded?(turn)
    }

    func clear() { turns = [] }

    // MARK: - Prompt

    private struct AskPayload: Decodable {
        var answer: String
        var cite: String?
    }

    private static let system = """
    You are listening in on a live call alongside the user. You answer their \
    questions about what has been said, from the transcript alone.

    Rules:
    - Answer only from the transcript. If it isn't in there, say so plainly.
    - Two or three sentences. The user is on a call and reading this out of the \
      corner of their eye.
    - "Me" is the user. "Them" is the other side.
    - Never invent commitments, numbers or names.
    - `cite` is the timestamp range your answer draws on, formatted "MM:SS – MM:SS". \
      Leave it empty if the answer isn't tied to a specific stretch.
    """

    private static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "answer": .object([
                "type": .string("string"),
                "description": .string("Two or three sentences, from the transcript only."),
            ]),
            "cite": .object([
                "type": .string("string"),
                "description": .string("Transcript range as \"MM:SS – MM:SS\", or empty."),
            ]),
        ]),
        "required": .array([.string("answer"), .string("cite")]),
        "additionalProperties": .bool(false),
    ])

    private static func render(_ segments: [TranscriptSegment]) -> String {
        // Tail-cap: an ask mid-marathon-call shouldn't push the cheap model out
        // of its context window.
        let text = segments.map { seg in
            let m = Int(seg.startTime) / 60, s = Int(seg.startTime) % 60
            return String(format: "[%02d:%02d] %@: %@", m, s, seg.speaker, seg.text)
        }.joined(separator: "\n")
        let cap = 120_000
        guard text.count > cap else { return text }
        return String(text.suffix(cap))
    }
}
