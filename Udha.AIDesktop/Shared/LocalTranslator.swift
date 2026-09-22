import Foundation

/// Translation on your own hardware: numbered lines go to an Ollama server
/// (`config.localModel`, default localhost — point it at whatever box already
/// transcribes meetings for free) and come back with the same numbers. Nothing
/// is billed and the text never leaves your network.
///
/// Shared by the meeting transcript (`MeetingTranslator`) and the video
/// captions (`CaptionTranslator`); each owns its own batching and cache, this
/// is only the call. The numbering is the contract: a line the model skips
/// comes back nil and the caller retries it, so a dropped line can never
/// land under the wrong speaker or on the wrong frame.
struct LocalTranslator: Sendable {
    static let languages = [
        "Albanian", "English", "Spanish", "German", "French", "Italian", "Portuguese",
        "Dutch", "Greek", "Turkish", "Serbian", "Macedonian", "Russian", "Ukrainian",
        "Polish", "Arabic", "Hindi", "Chinese", "Japanese", "Korean",
    ]

    /// BCP-47 tag for a language name, for VTT headers and the Stream API.
    static func code(for language: String) -> String {
        switch language.lowercased() {
        case "albanian": return "sq"
        case "english": return "en"
        case "spanish": return "es"
        case "german": return "de"
        case "french": return "fr"
        case "italian": return "it"
        case "portuguese": return "pt"
        case "dutch": return "nl"
        case "greek": return "el"
        case "turkish": return "tr"
        case "serbian": return "sr"
        case "macedonian": return "mk"
        case "russian": return "ru"
        case "ukrainian": return "uk"
        case "polish": return "pl"
        case "arabic": return "ar"
        case "hindi": return "hi"
        case "chinese": return "zh"
        case "japanese": return "ja"
        case "korean": return "ko"
        default: return String(language.lowercased().prefix(2))
        }
    }

    let baseURL: String
    let model: String
    let contextTokens: Int
    private let session: URLSession

    init(baseURL: String, model: String, contextTokens: Int = 65536) {
        self.baseURL = baseURL
        self.model = model
        self.contextTokens = contextTokens
        let cfg = URLSessionConfiguration.ephemeral
        // A cold model load on the box is ~40s before the first token; a
        // 30-line batch after that is a few seconds.
        cfg.timeoutIntervalForRequest = 180
        cfg.timeoutIntervalForResource = 240
        self.session = URLSession(configuration: cfg)
    }

    init(config: LocalModelConfig) {
        self.init(baseURL: config.baseURL, model: config.model, contextTokens: config.contextTokens)
    }

    /// `about` finishes the sentence "You translate lines from …" — what the
    /// lines are, so the register fits (a call, a narrated demo).
    func translate(_ lines: [String], to language: String, about: String) async throws -> [String?] {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !lines.isEmpty else { return [] }
        guard let url = URL(string: base + "/api/chat") else {
            throw LocalTranslatorError.badEndpoint(baseURL)
        }
        let numbered = lines.enumerated()
            .map { "\($0.offset + 1). \($0.element.replacingOccurrences(of: "\n", with: " "))" }
            .joined(separator: "\n")
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "think": false,
            "keep_alive": "30m",
            // The same window as every other local call (see
            // `LocalModelConfig.contextTokens`) — a different one here would
            // make Ollama reload the model between a translation and a notes
            // tick, and that reload is the lag you see in a live transcript.
            "options": ["temperature": 0.1, "num_ctx": contextTokens],
            "format": [
                "type": "object",
                "properties": [
                    "items": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": ["n": ["type": "integer"], "text": ["type": "string"]],
                            "required": ["n", "text"],
                        ],
                    ],
                ],
                "required": ["items"],
            ],
            "messages": [
                ["role": "system", "content": Self.system(language: language, about: about)],
                ["role": "user", "content": numbered],
            ],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw LocalTranslatorError.server(http.statusCode, String(text.prefix(200)))
        }
        let reply = try JSONDecoder().decode(ChatReply.self, from: data)
        let payload = try JSONDecoder().decode(Payload.self, from: Data(reply.message.content.utf8))
        var out = [String?](repeating: nil, count: lines.count)
        for item in payload.items where item.n >= 1 && item.n <= lines.count {
            let text = Self.stripNumbering(item.text, n: item.n)
            if !text.isEmpty { out[item.n - 1] = text }
        }
        return out
    }

    /// The model sometimes copies the numbering into the text — "3. Hola"
    /// or, when the input had no full stops to anchor on, the *next* line's
    /// number at the end ("…WordPress 4"). Only the numbers that fit the
    /// pattern are removed, so a real number in the line survives.
    static func stripNumbering(_ raw: String, n: Int) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = try! NSRegularExpression(pattern: "^\\s*(\\d{1,3})\\s*[.):\\-]?\\s+")
        if let m = lead.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r = Range(m.range(at: 1), in: text), Int(text[r]) == n,
           let whole = Range(m.range, in: text) {
            text.removeSubrange(whole)
        }
        let trail = try! NSRegularExpression(pattern: "\\s+(\\d{1,3})\\s*[.):]?\\s*$")
        if let m = trail.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r = Range(m.range(at: 1), in: text), Int(text[r]) == n + 1,
           let whole = Range(m.range, in: text) {
            text.removeSubrange(whole)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct ChatReply: Decodable {
        struct Message: Decodable { var content: String }
        var message: Message
    }
    private struct Payload: Decodable {
        struct Item: Decodable { var n: Int; var text: String }
        var items: [Item]
    }

    private static func system(language: String, about: String) -> String {
        """
        You translate lines from \(about) into \(language). \
        Each input line is numbered. Translate every line faithfully and naturally, \
        keeping the same number in the n field; the text field holds only the \
        translation, never the number. Do not merge, split, skip or reorder lines. \
        Keep names, numbers, product names, code and URLs as they are. \
        The lines are speech-to-text output — a line that is garbled or a fragment \
        is translated as the fragment it is, never explained. Output only the translations.
        """
    }
}

enum LocalTranslatorError: LocalizedError {
    case badEndpoint(String)
    case server(Int, String)
    var errorDescription: String? {
        switch self {
        case .badEndpoint(let s): return "bad translate endpoint “\(s)”"
        case .server(let code, let body): return "translate server said \(code): \(body)"
        }
    }
}
