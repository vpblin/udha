import Foundation

enum SlackAPIError: Error, LocalizedError {
    case http(Int, String)
    case slack(String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let body): return "Slack HTTP \(code): \(body)"
        case .slack(let err): return "Slack API error: \(err)"
        case .decode(let msg): return "Slack decode failed: \(msg)"
        }
    }
}

actor SlackAPIClient {
    private let token: String
    private let session: URLSession
    private let baseURL = URL(string: "https://slack.com/api")!
    private let decoder: JSONDecoder

    init(token: String) {
        self.token = token
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: cfg)
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = d
    }

    func authTest() async throws -> SlackAuthTestResponse {
        try await call("auth.test", query: [:])
    }

    func usersConversations(types: [String], cursor: String?) async throws -> SlackConversationsListResponse {
        var q: [String: String] = [
            "types": types.joined(separator: ","),
            "exclude_archived": "true",
            "limit": "200",
        ]
        if let cursor, !cursor.isEmpty { q["cursor"] = cursor }
        return try await call("users.conversations", query: q)
    }

    func conversationsHistory(channel: String, oldest: String?, limit: Int = 30) async throws -> SlackHistoryResponse {
        var q: [String: String] = [
            "channel": channel,
            "limit": String(limit),
            "inclusive": "false",
        ]
        if let oldest { q["oldest"] = oldest }
        return try await call("conversations.history", query: q)
    }

    func usersInfo(user: String) async throws -> SlackUserInfoResponse {
        try await call("users.info", query: ["user": user])
    }

    /// Returns the set of OAuth scopes the token actually has, via the
    /// `X-OAuth-Scopes` response header on an auth.test call.
    func fetchGrantedScopes() async throws -> Set<String> {
        var req = URLRequest(url: baseURL.appendingPathComponent("auth.test"))
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw SlackAPIError.http(-1, "no HTTP response")
        }
        let header = http.value(forHTTPHeaderField: "X-OAuth-Scopes") ?? ""
        return Set(
            header.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
    }

    func usersList(cursor: String?, limit: Int = 200) async throws -> SlackUsersListResponse {
        var q: [String: String] = ["limit": String(limit)]
        if let cursor, !cursor.isEmpty { q["cursor"] = cursor }
        return try await call("users.list", query: q)
    }

    func conversationsOpen(users: String) async throws -> SlackConversationsOpenResponse {
        try await postJSON("conversations.open", body: ["users": users])
    }

    func chatPostMessage(channel: String, text: String, asUser: Bool = true) async throws -> SlackPostMessageResponse {
        let body: [String: Any] = [
            "channel": channel,
            "text": text,
            "as_user": asUser,
        ]
        return try await postJSON("chat.postMessage", body: body)
    }

    // MARK: - Request plumbing

    private func call<T: Decodable>(_ method: String, query: [String: String]) async throws -> T {
        var comp = URLComponents(url: baseURL.appendingPathComponent(method), resolvingAgainstBaseURL: false)!
        comp.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: comp.url!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        return try await executeWithRetry(req)
    }

    private func postJSON<T: Decodable>(_ method: String, body: [String: Any]) async throws -> T {
        var req = URLRequest(url: baseURL.appendingPathComponent(method))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await executeWithRetry(req)
    }

    private func executeWithRetry<T: Decodable>(_ req: URLRequest) async throws -> T {
        for attempt in 0..<2 {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw SlackAPIError.http(-1, "no HTTP response")
            }
            if http.statusCode == 429 {
                let retry = Int(http.value(forHTTPHeaderField: "Retry-After") ?? "2") ?? 2
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: UInt64(retry) * 1_000_000_000)
                    continue
                }
                throw SlackAPIError.http(429, "rate limited")
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw SlackAPIError.http(http.statusCode, body)
            }
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                throw SlackAPIError.decode(error.localizedDescription)
            }
        }
        throw SlackAPIError.http(-2, "retry exhausted")
    }
}
