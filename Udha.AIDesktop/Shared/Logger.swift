import Foundation
#if canImport(os)
import os
#endif

final class FileLogger: @unchecked Sendable {
    static let shared = FileLogger()
    private let queue = DispatchQueue(label: "udha.filelog")
    private let url: URL
    private let formatter: DateFormatter

    init() {
#if os(macOS)
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/Udha.AI", isDirectory: true)
#else
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/udha", isDirectory: true)
#endif
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("udha.log")
        self.formatter = DateFormatter()
        self.formatter.dateFormat = "HH:mm:ss.SSS"
    }

    var fileURL: URL { url }

    /// The last `lines` lines of the log, for the Machines pane's agent-log
    /// panel. Only the tail of the file is read — the log grows without bound
    /// and the panel shows eight lines.
    func tail(lines: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 64 * 1024
        try? handle.seek(toOffset: end > window ? end - window : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(lines).map(String.init)
    }

    func log(_ category: String, _ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) \(level) [\(category)] \(message)\n"
        queue.async { [url] in
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

struct LogCategory {
    let name: String
#if canImport(os)
    let os: Logger
#endif

    init(_ name: String) {
        self.name = name
#if canImport(os)
        self.os = Logger(subsystem: Bundle.main.bundleIdentifier ?? "udha", category: name)
#endif
    }

    func info(_ message: String) {
#if canImport(os)
        os.info("\(message, privacy: .public)")
#endif
        FileLogger.shared.log(name, "INFO", message)
    }

    func debug(_ message: String) {
#if canImport(os)
        os.debug("\(message, privacy: .public)")
#endif
        // The file log is what gets read after the fact, and the pane reader +
        // hook feed emit debug lines several times a second — unconditionally
        // writing them buries every INFO line. os_log still gets them.
        guard Log.verbose else { return }
        FileLogger.shared.log(name, "DEBUG", message)
    }

    func error(_ message: String) {
#if canImport(os)
        os.error("\(message, privacy: .public)")
#endif
        FileLogger.shared.log(name, "ERROR", message)
    }
}

enum Log {
    /// Mirrors `AppConfig.verboseLogging`; set once at launch and whenever the
    /// setting changes. `nonisolated(unsafe)` because logging happens from every
    /// queue in the app and a lock here would be worse than a torn Bool read.
    nonisolated(unsafe) static var verbose: Bool = false

    static let app = LogCategory("app")
    static let pty = LogCategory("pty")
    static let classify = LogCategory("classify")
    static let voice = LogCategory("voice")
    static let agent = LogCategory("agent")
    static let hotkey = LogCategory("hotkey")
    static let lock = LogCategory("lock")
    static let net = LogCategory("net")
    static let slack = LogCategory("slack")
    static let bridge = LogCategory("bridge")
    static let meeting = LogCategory("meeting")
    static let recording = LogCategory("recording")
}
