import Foundation

enum ClaudeError: Error, LocalizedError {
    case noAPIKey
    case http(status: Int, type: String?, message: String)
    case rateLimited(retryAfter: Int?)
    case overloaded
    case refused(category: String?)
    case truncated
    case badPayload(String)
    case local(String)

    /// Claude cannot be called at all right now — nothing to retry, nothing
    /// a different prompt fixes: no key, or the API account cannot be billed.
    /// The one case worth answering from the local model instead.
    var isUnavailable: Bool {
        switch self {
        case .noAPIKey: return true
        case .http(let status, _, let message):
            let m = message.lowercased()
            return status == 401 || status == 403
                || (status == 400 && (m.contains("credit") || m.contains("billing") || m.contains("balance")))
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "Anthropic API key not set"
        case .http(let status, let type, let message): return "Claude HTTP \(status) (\(type ?? "?")): \(message)"
        case .rateLimited(let after): return "Claude rate limited (retry after \(after.map(String.init) ?? "?")s)"
        case .overloaded: return "Claude API overloaded"
        case .refused(let category): return "Claude declined the request (\(category ?? "unspecified"))"
        case .truncated: return "Claude response hit the token limit"
        case .badPayload(let detail): return "Claude payload error: \(detail)"
        case .local(let detail): return "Local model: \(detail)"
        }
    }
}

struct ClaudeUsage: Decodable, Sendable {
    var input_tokens: Int?
    var output_tokens: Int?
    var cache_read_input_tokens: Int?
    var cache_creation_input_tokens: Int?
}

struct ClaudeMessageResponse: Decodable, Sendable {
    struct ContentBlock: Decodable, Sendable {
        var type: String
        var text: String?
    }
    struct StopDetails: Decodable, Sendable {
        var category: String?
    }
    var content: [ContentBlock]
    var stop_reason: String?
    var stop_details: StopDetails?
    var usage: ClaudeUsage?
}

/// One text block of a prompt; `cached` adds a prompt-cache breakpoint.
/// Ollama's `/api/chat` reply, the part of it the local notes path reads.
private struct OllamaChatReply: Decodable {
    struct Message: Decodable { var content: String }
    var message: Message
    var prompt_eval_count: Int?
    var eval_count: Int?
}

struct PromptBlock: Sendable {
    var text: String
    var cached: Bool = false
}

/// Anthropic Messages API client, raw HTTP (no official Swift SDK). Mirrors
/// the house pattern of ElevenLabsTTSClient. Structured JSON is requested via
/// `output_config.format` (json_schema) which guarantees the first text block
/// is schema-valid JSON — simpler and more reliable than forced tool-use
/// (which remains a documented fallback if a schema ever hits a
/// structured-outputs limitation).
///
/// Model-behavior notes baked in: never send temperature/top_p/top_k
/// (claude-sonnet-5 rejects non-defaults) and never send `thinking` — on
/// Sonnet 5 omission means adaptive thinking (wanted for the finalize pass),
/// on Haiku 4.5 omission means none (wanted for cheap live ticks). Because
/// Sonnet's max_tokens caps thinking + text together, callers pass a generous
/// maxTokens for the finalize pass.
actor ClaudeClient {
    private let keychain: KeychainStore
    private let config: ConfigStore
    private let session: URLSession

    init(keychain: KeychainStore, config: ConfigStore) {
        self.keychain = keychain
        self.config = config
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 180
        cfg.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: cfg)
    }

    /// True when *something* can write notes: an Anthropic key, or the local
    /// model chosen outright or as the fallback.
    @MainActor static func hasNotesModel(keychain: KeychainStore, config: ConfigStore) -> Bool {
        let m = config.config.meetings
        return keychain.has(.anthropicAPIKey) || m.notesProvider == .local || m.fallbackToLocal
    }

    /// Structured call: system + user text blocks in, schema-valid T out.
    ///
    /// Routed by `meetings.notesProvider`: Claude, or the local model on the
    /// box. With Claude chosen and `fallbackToLocal` on, a call Claude cannot
    /// take at all (no key, account out of credit) is answered locally
    /// instead — the meeting gets written up either way.
    func structured<T: Decodable>(
        _ type: T.Type,
        model: String,
        maxTokens: Int,
        system: [PromptBlock],
        user: [PromptBlock],
        schema: JSONValue
    ) async throws -> (T, ClaudeUsage?) {
        let meetings = await MainActor.run { config.config.meetings }
        if meetings.notesProvider == .local {
            return (try await localStructured(type, maxTokens: maxTokens, system: system, user: user, schema: schema), nil)
        }
        do {
            return try await claudeStructured(type, model: model, maxTokens: maxTokens, system: system, user: user, schema: schema)
        } catch let error as ClaudeError where error.isUnavailable && meetings.fallbackToLocal {
            Log.meeting.info("Claude unavailable (\(error.localizedDescription)) — writing this with the local model instead")
            return (try await localStructured(type, maxTokens: maxTokens, system: system, user: user, schema: schema), nil)
        }
    }

    /// The same call against Ollama's `/api/chat` with the schema as
    /// `format`. Thinking is off (a 27B model reasoning over a 40k-token
    /// transcript is minutes for little gain in notes); the context window is
    /// sized to the prompt each time, since Ollama's default is far too small
    /// for a transcript and a fixed 128k would pin the KV cache in VRAM for
    /// every one-line ask.
    private func localStructured<T: Decodable>(
        _ type: T.Type, maxTokens: Int, system: [PromptBlock], user: [PromptBlock], schema: JSONValue
    ) async throws -> T {
        let local = await MainActor.run { config.config.localModel }
        let base = local.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + "/api/chat") else { throw ClaudeError.local("bad endpoint “\(local.baseURL)”") }
        let systemText = system.map(\.text).joined(separator: "\n\n")
        let userText = user.map(\.text).joined(separator: "\n\n")
        // ~3 chars per token is pessimistic for English prose, which is the
        // safe side: a context that is too small silently truncates the head
        // of the transcript.
        let estimated = (systemText.count + userText.count) / 3 + maxTokens
        // The shared window unless this prompt needs more (then Ollama
        // reloads once for it); never smaller, so the model stays loaded as
        // the translator left it.
        let numCtx = estimated <= local.contextTokens
            ? local.contextTokens
            : min(131_072, ((estimated + 4095) / 4096) * 4096)
        guard estimated <= 131_072 else {
            throw ClaudeError.local("transcript too long for \(local.model) (~\(estimated) tokens)")
        }
        let body: JSONValue = .object([
            "model": .string(local.model),
            "stream": .bool(false),
            "think": .bool(false),
            "keep_alive": .string("30m"),
            "options": .object(["temperature": .double(0.2), "num_ctx": .int(numCtx), "num_predict": .int(maxTokens)]),
            "format": schema,
            "messages": .array([
                .object(["role": .string("system"), "content": .string(systemText)]),
                .object(["role": .string("user"), "content": .string(userText)]),
            ]),
        ])
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 1800
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONEncoder().encode(body)
        let started = Date()
        let (data, response) = try await localSession.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw ClaudeError.local("\(local.model) at \(base) said \(status): \(text.prefix(200))")
        }
        let reply: OllamaChatReply
        do { reply = try JSONDecoder().decode(OllamaChatReply.self, from: data) }
        catch { throw ClaudeError.local("reply decode failed: \(error.localizedDescription)") }
        Log.meeting.debug("local \(local.model): in=\(reply.prompt_eval_count ?? 0) out=\(reply.eval_count ?? 0) ctx=\(numCtx) \(Int(Date().timeIntervalSince(started)))s")
        do {
            return try JSONDecoder().decode(T.self, from: Data(reply.message.content.utf8))
        } catch {
            throw ClaudeError.local("schema decode failed: \(error.localizedDescription)")
        }
    }

    private lazy var localSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 1800
        cfg.timeoutIntervalForResource = 3600
        return URLSession(configuration: cfg)
    }()

    private func claudeStructured<T: Decodable>(
        _ type: T.Type,
        model: String,
        maxTokens: Int,
        system: [PromptBlock],
        user: [PromptBlock],
        schema: JSONValue
    ) async throws -> (T, ClaudeUsage?) {
        let body: JSONValue = .object([
            "model": .string(model),
            "max_tokens": .int(maxTokens),
            "system": .array(system.map(Self.textBlock)),
            "messages": .array([
                .object([
                    "role": .string("user"),
                    "content": .array(user.map(Self.textBlock)),
                ])
            ]),
            "output_config": .object([
                "format": .object([
                    "type": .string("json_schema"),
                    "schema": schema,
                ])
            ]),
        ])

        let response = try await complete(body)

        switch response.stop_reason {
        case "refusal":
            throw ClaudeError.refused(category: response.stop_details?.category)
        case "max_tokens":
            throw ClaudeError.truncated
        default:
            break
        }

        guard let text = response.content.first(where: { $0.type == "text" })?.text,
              let data = text.data(using: .utf8) else {
            throw ClaudeError.badPayload("no text block in response")
        }
        do {
            let decoded = try JSONDecoder().decode(T.self, from: data)
            if let usage = response.usage {
                Log.meeting.debug("Claude \(model): in=\(usage.input_tokens ?? 0) out=\(usage.output_tokens ?? 0) cacheRead=\(usage.cache_read_input_tokens ?? 0) cacheWrite=\(usage.cache_creation_input_tokens ?? 0)")
            }
            return (decoded, response.usage)
        } catch {
            throw ClaudeError.badPayload("schema decode failed: \(error.localizedDescription)")
        }
    }

    /// Cheapest possible round-trip for the Settings "Test key" button.
    func ping(model: String) async throws {
        _ = try await complete(.object([
            "model": .string(model),
            "max_tokens": .int(1),
            "messages": .array([
                .object(["role": .string("user"), "content": .string("ping")])
            ]),
        ]))
    }

    // MARK: - Low level

    /// POST /v1/messages with one backoff retry on 429/500/529.
    func complete(_ body: JSONValue) async throws -> ClaudeMessageResponse {
        guard let key = keychain.get(.anthropicAPIKey) else { throw ClaudeError.noAPIKey }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONEncoder().encode(body)

        var attempt = 0
        while true {
            attempt += 1
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1

            if (200..<300).contains(status) {
                do {
                    return try JSONDecoder().decode(ClaudeMessageResponse.self, from: data)
                } catch {
                    throw ClaudeError.badPayload("response decode failed: \(error.localizedDescription)")
                }
            }

            let envelope = try? JSONDecoder().decode(ClaudeErrorEnvelope.self, from: data)
            let errType = envelope?.error.type
            let errMessage = envelope?.error.message ?? String(data: data, encoding: .utf8) ?? ""

            let retryable = status == 429 || status == 500 || status == 529
            if retryable && attempt == 1 {
                let retryAfter = (response as? HTTPURLResponse)?
                    .value(forHTTPHeaderField: "retry-after").flatMap(Int.init)
                let delay = status == 429 ? Double(retryAfter ?? 5) : 2.0
                Log.meeting.debug("Claude HTTP \(status), retrying in \(Int(delay))s")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue
            }

            switch status {
            case 429: throw ClaudeError.rateLimited(retryAfter: nil)
            case 529: throw ClaudeError.overloaded
            default: throw ClaudeError.http(status: status, type: errType, message: errMessage)
            }
        }
    }

    private struct ClaudeErrorEnvelope: Decodable {
        struct Inner: Decodable {
            var type: String?
            var message: String?
        }
        var error: Inner
    }

    private static func textBlock(_ block: PromptBlock) -> JSONValue {
        var obj: [String: JSONValue] = [
            "type": .string("text"),
            "text": .string(block.text),
        ]
        if block.cached {
            obj["cache_control"] = .object(["type": .string("ephemeral")])
        }
        return .object(obj)
    }
}

// MARK: - JSONValue

/// Minimal recursive JSON model so request bodies and schemas can be written
/// as Swift literals while staying Codable (house style: no third-party deps).
indirect enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unknown JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(floatLiteral value: Double) { self = .double(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(nilLiteral: ()) { self = .null }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}
