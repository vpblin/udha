import Foundation
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os)
import os
#endif

enum RelayConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// WebSocket client for the relay (`<relayURL>/home`).
///
/// Mirrors the home-server's connection lifecycle: 25s app-level ping, 1→30s
/// exponential reconnect, exit on close code 4002 (instance replaced). Hands
/// every inbound message to a single delegate closure on the main actor —
/// `MobileBridge` is the only consumer.
@MainActor
@Observable
final class RelayClient {
    private(set) var state: RelayConnectionState = .disconnected
    private(set) var lastError: String?

    // MARK: - Link telemetry (read by the Machines pane)

    /// When the current socket came up. Nil while disconnected.
    private(set) var connectedAt: Date?
    /// Last `pong` the relay answered, and the round trip that measured it.
    /// This is the latency to the *relay*, not to any peer machine.
    private(set) var lastPongAt: Date?
    private(set) var rttMilliseconds: Double?
    private var lastPingAt: Date?
    /// A short ring of why the socket last went away. The Machines pane shows
    /// it verbatim: "reconnected in 2s" is only trustworthy if the failure it
    /// recovered from is on the record next to it.
    private(set) var recentErrors: [MachineStats.ConnectionError] = []

    /// Which WebSocket implementation is in use. Linux Foundation's needs a
    /// libcurl built with WebSocket support and Ubuntu's is not, so the agent
    /// runs SwiftNIO instead.
    var transportName: String {
#if UDHA_AGENT
        "NIORelaySocket (SwiftNIO)"
#else
        "URLSessionWebSocketTask"
#endif
    }

    private func record(_ code: String, _ text: String) {
        recentErrors.insert(MachineStats.ConnectionError(at: Date(), code: code, text: text), at: 0)
        if recentErrors.count > 8 { recentErrors.removeLast(recentErrors.count - 8) }
    }

    /// Stable per-install identifier appended to the relay URL. Persisted in the
    /// keychain so disconnect/reconnect doesn't churn instance IDs (which would
    /// confuse paired iPhone clients).
    let instanceID: String
    let instanceName: String

    let relayURL: String
    private let auth0: Auth0Client
    private let keychain: KeychainStore

    private var socket: RelaySocket?
    private var pingTimer: Timer?
    private let pingInterval: TimeInterval = 25
    private var reconnectAttempts: Int = 0
    private var listenTaskID: UInt64 = 0
    private var manualDisconnect: Bool = false

    /// Serialises connection attempts. Opening a second socket for the same
    /// `instanceId` is actively harmful: the relay evicts the older one
    /// (server.js closes it with 4002), so two overlapping attempts kill the
    /// very connection they are trying to establish. Every attempt captures the
    /// generation it owns and gives up the moment a newer one supersedes it.
    private var connectGeneration: UInt64 = 0

    /// Single inbound delegate. Receives both relay-direct messages (e.g.
    /// `validate_pairing`, `paired_instances`) and unwrapped client payloads.
    var onMessage: ((RelayInbound) -> Void)?

    /// Builds the WebSocket for each connection attempt. Foundation's socket on
    /// the Mac; the headless agent installs a SwiftNIO one at startup, because
    /// Linux Foundation's WebSocket needs a libcurl built with WebSocket support
    /// and Ubuntu's isn't.
#if UDHA_AGENT
    nonisolated(unsafe) static var socketFactory: (@MainActor () -> RelaySocket)?
#else
    nonisolated(unsafe) static var socketFactory: (@MainActor () -> RelaySocket)? = { URLSessionRelaySocket() }
#endif

    init(keychain: KeychainStore,
         auth0: Auth0Client,
         relayURL: String,
         instanceName: String) {
        self.keychain = keychain
        self.auth0 = auth0
        self.relayURL = relayURL
        self.instanceName = instanceName
        // Stable instance ID — generated once, persisted forever.
        if let cached = keychain.get(.mobileBridgeInstanceID), !cached.isEmpty {
            self.instanceID = cached
        } else {
            let host = (Host.current().localizedName ?? "udha")
                .lowercased()
                .filter { $0.isLetter || $0.isNumber }
                .prefix(12)
            let suffix = (0..<3).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            let id = "\(host.isEmpty ? "udha" : host)-\(suffix)"
            self.instanceID = id
            try? keychain.set(id, for: .mobileBridgeInstanceID)
        }
    }

    // MARK: - Lifecycle

    func connect() {
        Log.bridge.info("RelayClient.connect() called; state=\(String(describing: state))")
        guard state == .disconnected || isFailed else {
            Log.bridge.info("RelayClient.connect() noop — state \(String(describing: state))")
            return
        }
        manualDisconnect = false
        state = .connecting
        lastError = nil
        reconnectAttempts = 0
        let generation = beginConnectAttempt()
        Task { await self.openSocket(generation: generation) }
    }

    /// Tears down any in-flight socket, orphans any pending reconnect, and
    /// returns the generation the caller now owns.
    private func beginConnectAttempt() -> UInt64 {
        connectGeneration &+= 1
        listenTaskID &+= 1
        stopPingTimer()
        if let existing = socket {
            existing.close()
            socket = nil
        }
        return connectGeneration
    }

    func disconnect() {
        manualDisconnect = true
        stopPingTimer()
        socket?.close()
        socket = nil
        listenTaskID &+= 1
        connectGeneration &+= 1
        state = .disconnected
    }

    // MARK: - Sending

    /// Wraps `payload` in the `{type: "relay", payload: ...}` envelope expected
    /// by the relay server when forwarding messages to clients.
    @discardableResult
    func sendRelay(_ payload: [String: Any]) -> Bool {
        send(["type": "relay", "payload": payload])
    }

    /// Sends a message at the relay protocol level (used for `home_info`,
    /// `pairing_valid`, `ping`, etc.). Most callers want `sendRelay` instead.
    @discardableResult
    func send(_ message: [String: Any]) -> Bool {
        guard let socket, state.isConnected else {
            return false
        }
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: []),
              let str = String(data: data, encoding: .utf8) else {
            return false
        }
        socket.send(text: str) { error in
            if let error {
                Log.bridge.error("relay send failed: \(error.localizedDescription)")
            }
        }
        return true
    }

    // MARK: - Internals

    private var isFailed: Bool {
        if case .failed = state { return true } else { return false }
    }

    private func openSocket(generation: UInt64) async {
        let token: String
        do {
            token = try await auth0.getValidAccessToken()
        } catch {
            guard generation == connectGeneration else { return }
            Log.bridge.error("relay open: no token (\(error.localizedDescription))")
            record("auth", "no access token — sign in again")
            state = .failed("Not signed in")
            scheduleReconnect(generation: generation)
            return
        }

        // Fetching the token suspends, so a newer attempt (or a disconnect) may
        // have taken over while this one was waiting. Bail rather than race it.
        guard generation == connectGeneration else { return }

        var comps = URLComponents(string: relayURL.hasSuffix("/") ? relayURL + "home" : relayURL + "/home")!
        comps.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "instanceId", value: instanceID),
        ]
        guard let url = comps.url else {
            state = .failed("Bad relay URL")
            return
        }

        Log.bridge.info("relay: connecting to \(self.relayURL) instance=\(self.instanceID)")
        guard let makeSocket = Self.socketFactory else {
            state = .failed("No WebSocket transport installed")
            return
        }
        let socket = makeSocket()
        self.socket = socket
        let messages = socket.open(url: url)

        // No formal "open" callback on URLSessionWebSocketTask — the first
        // successful receive (or send) confirms the handshake. We optimistically
        // mark connected, send home_info, and start the keepalive.
        state = .connected
        connectedAt = Date()
        reconnectAttempts = 0

        listenTaskID &+= 1
        let listenID = listenTaskID

        sendHomeInfo()
        startPingTimer(generation: generation)
        listen(taskID: listenID, socket: socket, messages: messages, generation: generation)
    }

    private func sendHomeInfo() {
        let info: [String: Any] = [
            "type": "relay",
            "payload": [
                "type": "home_info",
                "instanceId": instanceID,
                "name": instanceName,
                "workingDirectory": NSHomeDirectory(),
                "folderName": "Udha",
                "machineName": Host.current().localizedName ?? instanceID,
                "kind": UdhaBuild.instanceKind,
            ],
        ]
        send(info)
    }

    private func startPingTimer(generation: UInt64) {
        stopPingTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: pingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, generation == self.connectGeneration else { return }
                self.lastPingAt = Date()
                guard self.send(["type": "ping"]) else {
                    // The socket went away without the receive loop ever throwing,
                    // which used to strand the client in `.connected` with no
                    // socket and nothing scheduled — dead until an app restart.
                    Log.bridge.error("relay: ping unsendable — treating socket as dead")
                    self.stopPingTimer()
                    self.socket?.close()
                    self.socket = nil
                    self.state = .failed("Connection lost")
                    self.scheduleReconnect(generation: generation)
                    return
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    private func stopPingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    private func listen(taskID: UInt64, socket: RelaySocket,
                        messages: AsyncThrowingStream<String, Error>, generation: UInt64) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Drain the stream this loop was started for, never whatever
            // `self.socket` happens to be now — otherwise a superseded loop keeps
            // draining the live socket alongside its real listener.
            Log.bridge.debug("relay: listen loop started (task \(taskID))")
            do {
                for try await text in messages {
                    guard taskID == self.listenTaskID else { return }
                    self.handle(text: text)
                }
                // The peer closed cleanly; treat it like any other loss.
                self.handleSocketClose(error: RelaySocketError.closed, socket: socket, generation: generation)
            } catch {
                self.handleSocketClose(error: error, socket: socket, generation: generation)
            }
        }
    }

    private func handle(text: String) {
        guard let data = text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "pong":
            let now = Date()
            lastPongAt = now
            if let sent = lastPingAt { rttMilliseconds = now.timeIntervalSince(sent) * 1000 }
            return
        case "relay":
            // Wrapped client message; unwrap and pass payload up.
            if let payload = json["payload"] as? [String: Any] {
                onMessage?(.clientPayload(payload))
            }
        default:
            // Direct relay-server messages: validate_pairing, paired_instances,
            // home_connected, home_disconnected, instance_online, etc.
            onMessage?(.relayDirect(json))
        }
    }

    private func handleSocketClose(error: Error,
                                   socket: RelaySocket,
                                   generation: UInt64) {
        // Read the code off the socket that actually closed. Reading `self.socket`
        // reported whichever socket was current instead, which is how an eviction
        // surfaced in the log as `code=0` and slipped past the 4002 branch below.
        let code = socket.closeCode ?? 0

        // A superseded socket dying is expected and must not touch shared state
        // or schedule a reconnect — the newer attempt owns the connection.
        guard generation == connectGeneration else {
            Log.bridge.info("relay: superseded socket closed (code=\(code)) — ignored")
            return
        }

        Log.bridge.error("relay closed: \(error.localizedDescription) code=\(code)")
        stopPingTimer()
        self.socket = nil
        connectedAt = nil
        record(code == 0 ? "close" : "close \(code)", error.localizedDescription)

        if manualDisconnect {
            state = .disconnected
            return
        }

        // 4002 = the relay gave this instanceId to someone else. Now that our own
        // attempts are serialised, that can only be a genuinely different machine
        // reusing the id, so retrying would just start a takeover war.
        if code == 4002 {
            state = .failed("Replaced by another connection")
            return
        }

        state = .failed(error.localizedDescription)
        scheduleReconnect(generation: generation)
    }

    private func scheduleReconnect(generation: UInt64) {
        guard !manualDisconnect, generation == connectGeneration else { return }
        let delay = min(pow(2.0, Double(reconnectAttempts)), 30.0)
        reconnectAttempts += 1
        Log.bridge.info("relay: reconnecting in \(Int(delay))s (attempt \(self.reconnectAttempts))")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !self.manualDisconnect,
                  generation == self.connectGeneration else { return }
            let next = self.beginConnectAttempt()
            await self.openSocket(generation: next)
        }
    }
}

/// What the relay client hands up to MobileBridge.
enum RelayInbound: Sendable {
    /// A wrapped relay-protocol payload from a client (iPhone). Already unwrapped.
    case clientPayload([String: Any])
    /// A direct message from the relay server (pairing, instance status, etc.).
    case relayDirect([String: Any])
}

// MARK: - Transport

/// The WebSocket `RelayClient` talks over. `open` returns the inbound text
/// stream; it ends (normally or throwing) when the socket closes, after which
/// `closeCode` carries the peer's close code if there was one (4002 = replaced).
@MainActor
protocol RelaySocket: AnyObject {
    func open(url: URL) -> AsyncThrowingStream<String, Error>
    func send(text: String, completion: @escaping @Sendable (Error?) -> Void)
    func close()
    var closeCode: Int? { get }
}

enum RelaySocketError: Error, LocalizedError {
    case closed
    case notConnected
    var errorDescription: String? {
        switch self {
        case .closed: return "Connection closed"
        case .notConnected: return "Not connected"
        }
    }
}

#if !UDHA_AGENT
/// Foundation's WebSocket — what the Mac app has always used.
@MainActor
final class URLSessionRelaySocket: RelaySocket {
    private let session = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?

    var closeCode: Int? {
        guard let task, task.closeCode != .invalid else { return nil }
        return Int(task.closeCode.rawValue)
    }

    func open(url: URL) -> AsyncThrowingStream<String, Error> {
        let task = session.webSocketTask(with: url)
        // Default is 1 MiB, which a staged screenshot travelling as base64 can
        // exceed — and the failure mode is the socket erroring out mid-upload
        // rather than the message being refused.
        task.maximumMessageSize = 16 * 1024 * 1024
        self.task = task
        task.resume()
        return AsyncThrowingStream { continuation in
            let receiver = Task {
                while !Task.isCancelled {
                    do {
                        switch try await task.receive() {
                        case .string(let text):
                            continuation.yield(text)
                        case .data(let data):
                            if let text = String(data: data, encoding: .utf8) { continuation.yield(text) }
                        @unknown default:
                            break
                        }
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }
            }
            continuation.onTermination = { _ in receiver.cancel() }
        }
    }

    func send(text: String, completion: @escaping @Sendable (Error?) -> Void) {
        guard let task else { completion(RelaySocketError.notConnected); return }
        task.send(.string(text), completionHandler: completion)
    }

    func close() {
        task?.cancel(with: .goingAway, reason: nil)
    }
}
#endif
