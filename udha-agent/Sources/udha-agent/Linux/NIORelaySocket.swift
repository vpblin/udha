// SwiftNIO WebSocket for the relay. Linux Foundation's URLSessionWebSocketTask
// needs a libcurl built with WebSocket support, which Ubuntu's isn't, so the
// agent brings its own transport and installs it via `RelayClient.socketFactory`.
import Foundation
import NIOCore
import NIOPosix
import NIOWebSocket
import WebSocketKit

@MainActor
final class NIORelaySocket: RelaySocket {
    private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var ws: WebSocket?
    private(set) var closeCode: Int?
    /// Foundation's socket queues sends made before the upgrade completes;
    /// `RelayClient` relies on that for `home_info`. Match it.
    private var pending: [(String, @Sendable (Error?) -> Void)] = []
    private var failed: Error?

    func open(url: URL) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Log.bridge.debug("nio socket connecting to \(url.absoluteString)")
            let connected = WebSocket.connect(to: url.absoluteString, on: Self.group) { ws in
                ws.onText { _, text in continuation.yield(text) }
                ws.onClose.whenComplete { _ in
                    let code: Int? = ws.closeCode.map { code in
                        if case .unknown(let raw) = code { return Int(raw) }
                        return Int(UInt16(webSocketErrorCode: code))
                    }
                    Task { @MainActor in
                        self.closeCode = code
                        Log.bridge.debug("nio socket closed code=\(code.map(String.init) ?? "none")")
                        continuation.finish(throwing: RelaySocketError.closed)
                    }
                }
                Task { @MainActor in self.attach(ws) }
            }
            connected.whenFailure { error in
                Task { @MainActor in
                    Log.bridge.error("nio socket connect failed: \(error)")
                    self.failed = error
                    for (_, done) in self.pending { done(error) }
                    self.pending.removeAll()
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func attach(_ ws: WebSocket) {
        self.ws = ws
        Log.bridge.debug("nio socket upgraded; flushing \(pending.count) queued sends")
        let queued = pending; pending.removeAll()
        for (text, done) in queued { send(text: text, completion: done) }
    }

    func send(text: String, completion: @escaping @Sendable (Error?) -> Void) {
        if let failed { completion(failed); return }
        guard let ws else { pending.append((text, completion)); return }
        let promise = ws.eventLoop.makePromise(of: Void.self)
        ws.send(text, promise: promise)
        promise.futureResult.whenComplete { result in
            if case .failure(let error) = result { completion(error) } else { completion(nil) }
        }
    }

    func close() {
        _ = ws?.close(code: .goingAway)
        ws = nil
    }
}
