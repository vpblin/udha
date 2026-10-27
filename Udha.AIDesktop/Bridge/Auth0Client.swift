import Foundation
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Network)
import Network
#endif
#if canImport(os)
import os
#endif

enum Auth0Error: Error, LocalizedError {
    case noBrowser
    case invalidCallback(String)
    case stateMismatch
    case authError(String)
    case tokenExchangeFailed(String)
    case noRefreshToken
    case missingClaim(String)
    case timedOut
    case listenerFailed(String)
    /// A newer sign-in attempt took over; this one is no longer the user's.
    case superseded
    /// The user gave up on a round-trip that was never going to land.
    case cancelled
    /// No relay / Auth0 settings to sign in against.
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .noBrowser: return "Could not open browser for sign-in"
        case .invalidCallback(let s): return "Invalid OAuth callback: \(s)"
        case .stateMismatch: return "OAuth state mismatch (possible CSRF)"
        case .authError(let s): return "Auth0 returned: \(s)"
        case .tokenExchangeFailed(let s): return "Token exchange failed: \(s)"
        case .noRefreshToken: return "No refresh token available — sign in again"
        case .missingClaim(let s): return "Missing JWT claim: \(s)"
        case .timedOut: return "Sign-in timed out"
        case .listenerFailed(let s): return "Local sign-in listener failed: \(s)"
        case .superseded: return "Sign-in restarted"
        case .cancelled: return "Sign-in cancelled"
        case .notConfigured: return "Set the relay URL and Auth0 tenant first (Settings → Mobile)"
        }
    }
}

/// Holds tokens + refresh logic. Storage is in the keychain (one entry per
/// field) — no plaintext on disk. Mirrors the home-server flow that is already
/// expected by the relay: the callback `http://localhost:8789/callback` must be
/// allowed on the Auth0 application, and the audience is the relay API's
/// identifier. Both come from `MobileBridgeConfig`; nothing is hard-wired.
@MainActor
@Observable
final class Auth0Client {

    /// Hands a URL to the user's browser. On the Mac that is LaunchServices; the
    /// headless agent has no browser, so it prints the URL for the operator to
    /// open elsewhere (typically through `ssh -L 8789:localhost:8789`).
    static func openInBrowser(_ url: URL) -> Bool {
#if canImport(AppKit)
        return NSWorkspace.shared.open(url)
#else
        print("Open this URL in a browser to sign in:\n\(url.absoluteString)")
        return true
#endif
    }
    /// True from the moment the browser is opened until the callback lands,
    /// fails, or times out. Lives here rather than in a view: the sheet that
    /// starts a sign-in can be closed and reopened while the browser round-trip
    /// is still out, and a fresh `@State` flag would hand back an enabled
    /// button whose second click collides with the first attempt's listener.
    private(set) var isSigningIn = false
    /// The callback listener of the attempt currently holding the loopback
    /// port, so a new attempt can take it over instead of racing it.
    @ObservationIgnored private var inFlight: CallbackListener?
    /// The authorize URL of the attempt in flight, kept so the user can send it
    /// to the browser again or copy it out. `NSWorkspace.open` reports success
    /// the moment LaunchServices accepts the URL, so a browser that never
    /// actually surfaces the page still looks like a launched sign-in — and
    /// then nothing can produce the callback the flow is waiting for.
    private(set) var pendingAuthorizeURL: URL?

    private let keychain: KeychainStore
    private let domain: String
    private let clientID: String
    private let audience: String
    private let callbackPort: Int

    /// 5-minute refresh buffer matches home-server behaviour so the relay never
    /// disconnects us mid-call because of an expired bearer.
    private let refreshBufferSec: TimeInterval = 5 * 60

    init(keychain: KeychainStore,
         domain: String,
         clientID: String,
         audience: String,
         callbackPort: Int = 8789) {
        self.keychain = keychain
        self.domain = domain
        self.clientID = clientID
        self.audience = audience
        self.callbackPort = callbackPort
    }

    var hasCachedTokens: Bool {
        keychain.has(.mobileBridgeAccessToken)
    }

    var cachedUserID: String? {
        guard let token = keychain.get(.mobileBridgeAccessToken) else { return nil }
        return Self.decodeSubClaim(token)
    }

    /// Returns a valid bearer token. Uses the cached one if it has not expired,
    /// refreshes silently if a refresh token exists, otherwise throws — caller
    /// is expected to invoke `signIn()` instead.
    func getValidAccessToken() async throws -> String {
        if let cached = keychain.get(.mobileBridgeAccessToken),
           let expiresAtStr = keychain.get(.mobileBridgeExpiresAt),
           let expiresAt = TimeInterval(expiresAtStr) {
            if Date().timeIntervalSince1970 < (expiresAt - refreshBufferSec) {
                return cached
            }
        }
        if keychain.has(.mobileBridgeRefreshToken) {
            return try await refreshAccessToken()
        }
        throw Auth0Error.noRefreshToken
    }

    func signOut() {
        keychain.delete(.mobileBridgeAccessToken)
        keychain.delete(.mobileBridgeRefreshToken)
        keychain.delete(.mobileBridgeExpiresAt)
    }

    // MARK: - Sign in (PKCE)

    /// Opens the system browser and waits for an Auth0 callback to land on the
    /// local listener. Throws on user cancel or 5-minute timeout.
    func signIn() async throws -> String {
        guard !domain.isEmpty, !clientID.isEmpty else { throw Auth0Error.notConfigured }
        let codeVerifier = Self.generateCodeVerifier()
        let codeChallenge = Self.generateCodeChallenge(from: codeVerifier)
        let state = Self.randomHex(16)
        let redirectURI = "http://localhost:\(callbackPort)/callback"

        var comps = URLComponents(string: "https://\(domain)/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
            URLQueryItem(name: "audience", value: audience),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let authURL = comps.url else {
            throw Auth0Error.invalidCallback("Could not build authorize URL")
        }

        // Only one sign-in can be in flight, because the callback listener owns
        // a fixed loopback port. A second attempt used to collide with the
        // first one's own listener and die with EADDRINUSE — which is exactly
        // what clicking "Sign in" again gets you when the browser round-trip
        // hasn't landed yet, i.e. precisely when you'd click it. The attempt the
        // user is watching is the new one, so it wins and the old one unwinds.
        if let previous = inFlight {
            Log.bridge.info("Auth0 sign-in: superseding the in-flight attempt")
            previous.abandon(.superseded)
            inFlight = nil
        }

        // Spin up the listener BEFORE opening the browser so the redirect
        // doesn't race the listener-ready state.
        let listener = try CallbackListener(port: callbackPort)
        inFlight = listener
        isSigningIn = true
        pendingAuthorizeURL = authURL
        defer {
            // Only if we're still the current attempt — a successor owns the
            // flag once it has taken over.
            if inFlight === listener {
                inFlight = nil
                isSigningIn = false
                pendingAuthorizeURL = nil
            }
        }
        let queryFuture = listener.start()

        Log.bridge.info("Auth0 sign-in: opening browser to \(authURL.absoluteString)")
        guard Self.openInBrowser(authURL) else {
            listener.stop()
            throw Auth0Error.noBrowser
        }

        let query: [String: String]
        do {
            query = try await withTimeout(seconds: 300) {
                try await queryFuture.value
            }
        } catch {
            listener.stop()
            throw error is Auth0Error ? error : Auth0Error.timedOut
        }
        listener.stop()

        if let err = query["error"] {
            throw Auth0Error.authError(err + (query["error_description"].map { ": \($0)" } ?? ""))
        }
        guard query["state"] == state else {
            throw Auth0Error.stateMismatch
        }
        guard let code = query["code"], !code.isEmpty else {
            throw Auth0Error.invalidCallback("missing code in callback")
        }

        return try await exchangeCodeForTokens(
            code: code,
            codeVerifier: codeVerifier,
            redirectURI: redirectURI
        )
    }

    /// Hand the in-flight authorize URL to the browser again. Same attempt and
    /// same listener, so the PKCE verifier and state still match: finishing it
    /// signs you in exactly as the first open would have.
    @discardableResult
    func reopenBrowser() -> Bool {
        guard let url = pendingAuthorizeURL else { return false }
        Log.bridge.info("Auth0 sign-in: re-opening the browser")
        return Self.openInBrowser(url)
    }

    /// Give up on the attempt in flight and release the button.
    ///
    /// `isSigningIn` used to clear only when the callback landed or the
    /// five-minute timeout expired — and a browser that never opened produces
    /// neither, which left quitting the app as the only way back to a clickable
    /// Sign in.
    func cancelSignIn() {
        guard let listener = inFlight else { return }
        Log.bridge.info("Auth0 sign-in: cancelled")
        inFlight = nil
        isSigningIn = false
        pendingAuthorizeURL = nil
        listener.abandon(.cancelled)
    }

    // MARK: - Token exchange + refresh

    private func exchangeCodeForTokens(code: String,
                                       codeVerifier: String,
                                       redirectURI: String) async throws -> String {
        let tokenURL = URL(string: "https://\(domain)/oauth/token")!
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": codeVerifier,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        guard let http, (200..<300).contains(http.statusCode) else {
            throw Auth0Error.tokenExchangeFailed(
                String(data: data, encoding: .utf8) ?? "(no body)"
            )
        }

        let token = try Self.parseAndStoreTokens(data: data, keychain: keychain)
        Log.bridge.info("Auth0 sign-in success")
        return token
    }

    private func refreshAccessToken() async throws -> String {
        guard let refresh = keychain.get(.mobileBridgeRefreshToken) else {
            throw Auth0Error.noRefreshToken
        }
        let tokenURL = URL(string: "https://\(domain)/oauth/token")!
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refresh,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        guard let http, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            Log.bridge.error("Auth0 refresh failed (\(http?.statusCode ?? -1)): \(body)")
            // ONLY delete the refresh token if Auth0 explicitly says it's
            // invalid (`invalid_grant`). Transient errors (5xx, network
            // blips, rate limits) must leave the refresh token in place so
            // the next attempt can succeed. The previous behaviour deleted
            // on any non-2xx and stranded the bridge in "no refresh token
            // available" forever after a single transient failure.
            let isInvalidGrant = body.contains("\"error\":\"invalid_grant\"")
                || body.contains("invalid_grant")
            if isInvalidGrant {
                Log.bridge.error("clearing refresh_token (invalid_grant)")
                keychain.delete(.mobileBridgeRefreshToken)
            }
            throw Auth0Error.tokenExchangeFailed(body)
        }

        let token = try Self.parseAndStoreTokens(data: data, keychain: keychain, fallbackRefresh: refresh)
        Log.bridge.info("Auth0 token refreshed")
        return token
    }

    // MARK: - Helpers

    private static func parseAndStoreTokens(data: Data,
                                            keychain: KeychainStore,
                                            fallbackRefresh: String? = nil) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Auth0Error.tokenExchangeFailed("non-JSON response")
        }
        guard let access = json["access_token"] as? String else {
            throw Auth0Error.tokenExchangeFailed("no access_token in response")
        }
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        let expiresAt = Date().timeIntervalSince1970 + expiresIn
        let refresh = (json["refresh_token"] as? String) ?? fallbackRefresh

        // Auth0 drops `offline_access` from the granted scope — and omits
        // `refresh_token` entirely — when the API behind `audience` does not
        // have "Allow Offline Access" turned on. It is not an error response:
        // sign-in reports success, the access token works, and the bridge only
        // dies an hour later when the socket drops and there is nothing to
        // refresh with. Record what actually came back so that silent
        // downgrade is visible at sign-in instead of a reconnect storm later.
        let grantedScope = (json["scope"] as? String) ?? "(none)"
        if refresh == nil {
            Log.bridge.error(
                "Auth0 issued NO refresh token (granted scope: \(grantedScope)). "
                + "The bridge will work until this access token expires and then "
                + "require a manual sign-in. Enable \"Allow Offline Access\" on the "
                + "API for this audience in the Auth0 dashboard."
            )
        } else {
            Log.bridge.info("Auth0 refresh token present (granted scope: \(grantedScope))")
        }

        try keychain.set(access, for: .mobileBridgeAccessToken)
        try keychain.set(String(expiresAt), for: .mobileBridgeExpiresAt)
        if let refresh { try keychain.set(refresh, for: .mobileBridgeRefreshToken) }

        return access
    }

    static func decodeSubClaim(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        let payloadBase64 = String(parts[1])
        guard let data = Data(base64UrlEncoded: payloadBase64) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["sub"] as? String
    }

    private static func generateCodeVerifier() -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        return Data(bytes).base64UrlEncodedString()
    }

    private static func generateCodeChallenge(from verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64UrlEncodedString()
    }

    private static func randomHex(_ count: Int) -> String {
        let bytes = (0..<count).map { _ in UInt8.random(in: .min ... .max) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Local OAuth callback listener

#if canImport(Network)
/// Tiny HTTP listener that accepts exactly one GET /callback request, hands its
/// query parameters to its caller, and then closes. Uses Network.framework so
/// we don't pull in a full HTTP server stack for a one-shot handshake.
private final class CallbackListener: @unchecked Sendable {
    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private let promise: CheckedContinuationBox<[String: String]> = .init()
    private var bindDeadline: DispatchWorkItem?

    init(port: Int) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw Auth0Error.invalidCallback("bad port \(port)")
        }
        self.port = nwPort
        // Pinned to loopback rather than every interface. Auth0 redirects to
        // 127.0.0.1, so a wildcard bind only ever exposed the authorization
        // code to the LAN — and it is a wildcard bind that drags macOS 15's
        // Local Network privacy gate into an OAuth flow that has no business
        // touching it.
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        params.allowLocalEndpointReuse = true
        do {
            self.listener = try NWListener(using: params)
        } catch {
            throw Auth0Error.listenerFailed("could not create listener on port \(port): \(error.localizedDescription)")
        }
    }

    func start() -> Task<[String: String], Error> {
        let task = Task<[String: String], Error> {
            try await self.promise.value()
        }
        // Without this handler a listener that cannot bind is COMPLETELY
        // silent: NWListener parks in `.waiting` and retries forever, so the
        // browser opens onto an authorize page whose redirect lands on a
        // refused port, and the app just spins for its full five-minute
        // timeout with nothing in the log. Surface it instead.
        listener?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.bindDeadline?.cancel()
                self.bindDeadline = nil
                Log.bridge.info("Auth0 callback listener ready on 127.0.0.1:\(self.port.rawValue)")
            case .waiting(let error):
                Log.bridge.error("Auth0 callback listener waiting on 127.0.0.1:\(self.port.rawValue): \(error.localizedDescription)")
                self.armBindDeadline(reason: error.localizedDescription)
            case .failed(let error):
                Log.bridge.error("Auth0 callback listener failed: \(error.localizedDescription)")
                self.promise.resume(.failure(Auth0Error.listenerFailed(self.describe(error))))
            default:
                break
            }
        }
        listener?.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener?.start(queue: .global(qos: .userInitiated))
        return task
    }

    /// `.waiting` is recoverable in principle (the port frees up), so give it a
    /// few seconds — then fail loudly rather than leaving the user in front of
    /// a spinner that cannot succeed.
    private func armBindDeadline(reason: String) {
        guard bindDeadline == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.promise.resume(.failure(Auth0Error.listenerFailed(
                "could not bind 127.0.0.1:\(self.port.rawValue) — \(reason)")))
        }
        bindDeadline = item
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 5, execute: item)
    }

    /// Tear down and unblock whoever is awaiting the callback. Without the
    /// resume, a superseded attempt would sit on its five-minute timeout and
    /// then flash a stale failure over the successor's result.
    func abandon(_ error: Auth0Error) {
        promise.resume(.failure(error))
        stop()
    }

    func stop() {
        bindDeadline?.cancel()
        bindDeadline = nil
        listener?.cancel()
        listener = nil
    }

    /// EADDRINUSE is the one bind failure a user can act on, and raw
    /// "NWError error 48" tells them nothing about what to do.
    private func describe(_ error: NWError) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return "127.0.0.1:\(port.rawValue) is already in use by another process — quit whatever is holding it, then try again"
        }
        return error.localizedDescription
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { conn.cancel(); return }
            guard let data, let request = String(data: data, encoding: .utf8) else {
                conn.cancel()
                return
            }
            // First line is "GET /callback?code=… HTTP/1.1"
            let firstLine = request.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first.map(String.init) ?? ""
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else {
                self.respond(conn, body: "bad request")
                return
            }
            let path = String(parts[1])
            guard let comps = URLComponents(string: "http://localhost\(path)") else {
                self.respond(conn, body: "bad url")
                return
            }
            var query: [String: String] = [:]
            comps.queryItems?.forEach { item in
                if let value = item.value { query[item.name] = value }
            }
            if comps.path != "/callback" {
                self.respond(conn, body: "not found", status: 404)
                return
            }
            let html = """
            <html><body style="font-family: -apple-system; text-align: center; padding-top: 60px;">
            <h2>✓ Signed in to Udha Mobile Bridge</h2>
            <p>You can close this window and return to the app.</p>
            </body></html>
            """
            self.respond(conn, body: html, contentType: "text/html") {
                self.promise.resume(.success(query))
            }
        }
    }

    private func respond(_ conn: NWConnection,
                         body: String,
                         status: Int = 200,
                         contentType: String = "text/plain",
                         completion: (() -> Void)? = nil) {
        let bodyData = Data(body.utf8)
        let header = "HTTP/1.1 \(status) OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(bodyData)
        conn.send(content: response, completion: .contentProcessed { _ in
            conn.cancel()
            completion?()
        })
    }
}
#else
#if canImport(Glibc)
import Glibc
#endif
/// Loopback listener for the OAuth callback on platforms without Network.framework.
/// Same contract as the NW version: one HTTP request on 127.0.0.1:port, the
/// `/callback` query string comes back as a dictionary, everything else 404s.
private final class CallbackListener: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var abandonError: Auth0Error?

    init(port: Int) throws {
        let sock = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard sock >= 0 else { throw Auth0Error.listenerFailed("socket() failed (errno \(errno))") }
        var one: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { let e = errno; close(sock); throw Auth0Error.listenerFailed("port \(port) busy (errno \(e))") }
        guard listen(sock, 4) == 0 else { let e = errno; close(sock); throw Auth0Error.listenerFailed("listen() failed (errno \(e))") }
        fd = sock
    }

    func start() -> Task<[String: String], Error> {
        Task.detached { [self] in
            while true {
                lock.lock(); let sock = fd; lock.unlock()
                guard sock >= 0 else { throw currentAbandonError() }
                let conn = accept(sock, nil, nil)
                guard conn >= 0 else { throw currentAbandonError() }
                defer { close(conn) }
                var buf = [UInt8](repeating: 0, count: 8192)
                let n = read(conn, &buf, buf.count)
                guard n > 0, let request = String(bytes: buf[0..<Int(n)], encoding: .utf8) else { continue }
                let firstLine = request.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first.map(String.init) ?? ""
                let parts = firstLine.split(separator: " ")
                guard parts.count >= 2 else { continue }
                let path = String(parts[1])
                guard path.hasPrefix("/callback") else { respond(conn, status: 404, body: "not found"); continue }
                var query: [String: String] = [:]
                for item in URLComponents(string: "http://localhost\(path)")?.queryItems ?? [] { query[item.name] = item.value ?? "" }
                respond(conn, status: 200, contentType: "text/html",
                        body: "<html><body style=\"font-family:-apple-system,sans-serif;padding:2em\"><h2>Signed in to Udha.</h2><p>You can close this tab.</p></body></html>")
                return query
            }
        }
    }

    private func currentAbandonError() -> Auth0Error {
        lock.lock(); defer { lock.unlock() }
        return abandonError ?? .cancelled
    }

    func abandon(_ error: Auth0Error) {
        lock.lock(); abandonError = error; lock.unlock()
        stop()
    }

    func stop() {
        lock.lock(); let sock = fd; fd = -1; lock.unlock()
        guard sock >= 0 else { return }
        shutdown(sock, Int32(SHUT_RDWR))
        close(sock)
    }

    private func respond(_ conn: Int32, status: Int, contentType: String = "text/plain", body: String) {
        let data = Data(body.utf8)
        let header = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Not Found")\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        var out = Data(header.utf8); out.append(data)
        out.withUnsafeBytes { p in _ = write(conn, p.baseAddress, p.count) }
    }
}
#endif

// One-shot continuation that can be safely awaited from one place and resumed
// from another. Resume after first call is a no-op.
private final class CheckedContinuationBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var resolved: Result<T, Error>?

    func value() async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if let resolved {
                lock.unlock()
                cont.resume(with: resolved)
                return
            }
            continuation = cont
            lock.unlock()
        }
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        guard resolved == nil else { lock.unlock(); return }   // first result wins
        if let cont = continuation {
            continuation = nil
            resolved = result
            lock.unlock()
            cont.resume(with: result)
        } else {
            resolved = result
            lock.unlock()
        }
    }
}

// Cancel a long await after N seconds. Used for the 5-minute browser timeout.
private func withTimeout<T: Sendable>(seconds: TimeInterval,
                                       _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw Auth0Error.timedOut
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}

// MARK: - Base64URL helpers

extension Data {
    init?(base64UrlEncoded: String) {
        var s = base64UrlEncoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        self.init(base64Encoded: s)
    }

    func base64UrlEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
