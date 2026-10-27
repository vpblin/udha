import Foundation

/// Stand-in for the app's `Log`, which reaches into the os.log configuration
/// graph. `ClaudePaneReader` touches it only on one path — a regex that failed
/// to compile, which is a programmer error the tests would catch anyway.
enum Log {
    struct Channel {
        func error(_ message: String) {}
        func info(_ message: String) {}
        func debug(_ message: String) {}
    }
    static let classify = Channel()
    static let pty = Channel()
    static let bridge = Channel()
}
