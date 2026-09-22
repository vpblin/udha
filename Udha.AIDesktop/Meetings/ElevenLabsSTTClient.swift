import Foundation

/// Moved here when the voice feature was removed: this used to live beside the
/// TTS client, and STT is now the only thing that speaks to ElevenLabs.
enum ElevenLabsError: Error, LocalizedError {
    case noAPIKey
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "ElevenLabs API key not set"
        case .httpError(let code, let body): return "ElevenLabs HTTP \(code): \(body)"
        }
    }
}

struct STTWord: Codable, Sendable {
    var text: String
    var start: Double?
    var end: Double?
    /// "word" | "spacing" | "audio_event"
    var type: String?
    /// "speaker_0", "speaker_1", … when diarize=true.
    var speaker_id: String?
}

struct STTResult: Codable, Sendable {
    var language_code: String?
    var text: String
    var words: [STTWord]?
}

/// Batch speech-to-text against ElevenLabs Scribe. Deliberately dumb: one
/// request in, one result out, no retries — TranscriptionEngine owns queueing
/// and retry because it is the one holding the chunks.
actor ElevenLabsSTTClient {
    private let keychain: KeychainStore
    private let config: ConfigStore
    private let session: URLSession

    init(keychain: KeychainStore, config: ConfigStore) {
        self.keychain = keychain
        self.config = config
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120   // allow for a cold local model load
        cfg.timeoutIntervalForResource = 180
        self.session = URLSession(configuration: cfg)
    }

    /// `wav` must be a complete WAV container (see AudioPlayer.wrapAsWAV).
    func transcribe(wav: Data, diarize: Bool, languageCode: String?) async throws -> STTResult {
        let (modelID, baseURL) = await MainActor.run {
            (config.config.meetings.sttModelID, config.config.meetings.sttBaseURL)
        }
        // ElevenLabs needs the API key; a local Whisper server ignores it.
        let usesElevenLabs = baseURL.contains("elevenlabs.io")
        let key = keychain.get(.elevenLabsAPIKey)
        if usesElevenLabs, key == nil { throw ElevenLabsError.noAPIKey }

        var fields: [(String, String)] = [
            ("model_id", modelID),
            ("diarize", diarize ? "true" : "false"),
            ("timestamps_granularity", "word"),
            ("tag_audio_events", "false"),
        ]
        if let languageCode, !languageCode.isEmpty {
            fields.append(("language_code", languageCode))
        }

        let boundary = "udha-\(UUID().uuidString)"
        var body = Data()
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"chunk.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        var req = URLRequest(url: URL(string: base + "/v1/speech-to-text")!)
        req.httpMethod = "POST"
        if let key { req.setValue(key, forHTTPHeaderField: "xi-api-key") }
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw ElevenLabsError.httpError(status, bodyStr)
        }
        return try JSONDecoder().decode(STTResult.self, from: data)
    }
}
