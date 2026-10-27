// Stand-ins for Apple frameworks the shared engine leans on. Only compiled where
// the real thing is missing, so building this package on a Mac still uses
// Keychain and Combine.
import Foundation

#if !canImport(Combine)
/// `SessionManager` declares this conformance for SwiftUI's sake; nothing on
/// Linux observes it.
protocol ObservableObject: AnyObject {}
#endif

#if !canImport(Security)
/// File-backed replacement for the macOS keychain: one JSON object at
/// `~/.config/udha/secrets.json`, mode 0600. Same API as `KeychainStore` in
/// Config/Keychain.swift so the shared code doesn't know the difference.
final class KeychainStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var values: [String: String]

    private var mtime: TimeInterval = 0

    init(service: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/udha", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("secrets.json")
        values = [:]
        reloadIfChanged()
    }

    /// Re-read the file when another process has written it since we last looked.
    /// `udha-agent login` runs as a separate process from the daemon, so the
    /// daemon must pick up the credentials it drops without a restart.
    private func reloadIfChanged() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let m = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { return }
        guard m > mtime else { return }
        if let loaded = try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url)) {
            values = loaded
        }
        mtime = m
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(values) else { return }
        try? data.write(to: url, options: .atomic)
        chmod(url.path, 0o600)
        if let m = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?
            .timeIntervalSince1970 { mtime = m }
    }

    func set(_ value: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        reloadIfChanged(); values[account] = value; persist()
    }
    func get(account: String) -> String? { lock.lock(); defer { lock.unlock() }; reloadIfChanged(); return values[account] }
    func delete(account: String) { lock.lock(); defer { lock.unlock() }; reloadIfChanged(); values[account] = nil; persist() }
    func has(account: String) -> Bool { get(account: account) != nil }

    func set(_ value: String, for key: KeychainKey) throws { try set(value, account: key.rawValue) }
    func get(_ key: KeychainKey) -> String? { get(account: key.rawValue) }
    func delete(_ key: KeychainKey) { delete(account: key.rawValue) }
    func has(_ key: KeychainKey) -> Bool { has(account: key.rawValue) }
    /// The Mac drains an older keychain here; nothing to migrate on Linux.
    func migrateLegacyItems() {}
}
#endif
