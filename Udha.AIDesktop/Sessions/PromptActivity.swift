import Foundation

/// One prompt a person typed into Claude Code, read back from the transcript
/// Claude writes for every session. The time tracker's main signal: a prompt
/// is proof someone was at a keyboard, and its folder says for whom.
///
/// Only what the tracker needs crosses the wire — when, which project folder,
/// which config dir (= which login tree), and a hash of the first words so a
/// loop that sends the same long prompt every few minutes can be told apart
/// from typing. Never the text itself.
struct PromptEvent: Sendable, Hashable {
    var at: Date
    /// Claude's escaped cwd: `-home-you-projects-work-app`.
    var project: String
    /// The config dir's own name: `.claude`, `.claude-work-2`.
    var configDir: String
    /// FNV-1a of the first 70 characters — stable across processes and
    /// machines, unlike `hashValue`. Zero for prompts under 40 characters.
    var key: UInt32
    /// Which machine it came from. Filled by the reader, not the wire.
    var host: String = ""

    var wire: [String: Any] {
        ["t": at.timeIntervalSince1970, "p": project, "c": configDir, "k": Int(key)]
    }

    init(at: Date, project: String, configDir: String, key: UInt32, host: String = "") {
        self.at = at; self.project = project; self.configDir = configDir; self.key = key; self.host = host
    }

    init?(wire w: [String: Any], host: String) {
        guard let t = w["t"] as? Double, let p = w["p"] as? String else { return nil }
        at = Date(timeIntervalSince1970: t)
        project = p
        configDir = w["c"] as? String ?? ".claude"
        key = UInt32(truncatingIfNeeded: (w["k"] as? Int) ?? 0)
        self.host = host
    }

    static func fnv(_ s: Substring) -> UInt32 {
        var h: UInt32 = 2_166_136_261
        for b in s.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return h
    }
}

/// Reads every `~/.claude*/projects/*/*.jsonl` on this machine and keeps the
/// human prompts in memory. Incremental: each file is read from where the
/// last scan stopped, so a refresh costs only what was written since.
///
/// What counts as typed by a person: a `user` line that is not meta, not a
/// sidechain, not a tool result, from the interactive CLI (`claude -p` bots and
/// the SDK are skipped), and not one of the notices Claude or Udha inject
/// (context continuations, login moves, interrupts, slash-command echoes).
final class PromptActivityScanner: @unchecked Sendable {
    private let lock = NSLock()
    private var offsets: [String: UInt64] = [:]
    private var events = Set<PromptEvent>()
    /// How far back the first scan reads. Claude keeps transcripts 30 days.
    let horizon: TimeInterval

    init(horizon: TimeInterval = 40 * 86_400) { self.horizon = horizon }

    private static let userMarker = Data("\"type\":\"user\"".utf8)
    private static let toolMarker = Data("\"tool_use_id\"".utf8)

    private static let injected = [
        "<local-command", "<command-name>", "<command-message>", "<task-notification", "Caveat:", "[SYSTEM",
        "<system-reminder", "This session is being continued", "This session moved to a different Claude login",
        "[Request interrupted", "<artifact-content", "<<autonomous",
    ]

    /// Every prompt seen at or after `since`. Blocking; call off the main actor.
    func events(since: Date) -> [PromptEvent] {
        scan()
        lock.lock(); defer { lock.unlock() }
        return events.filter { $0.at >= since }.sorted { $0.at < $1.at }
    }

    private func scan() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let cutoff = Date().addingTimeInterval(-horizon)
        guard let entries = try? fm.contentsOfDirectory(atPath: home.path) else { return }
        // A login pool's alternates symlink `projects/` to the base dir; read
        // each real directory once.
        var seenRoots = Set<String>()
        for name in entries.sorted() where name.hasPrefix(".claude") {
            let projects = home.appendingPathComponent(name).appendingPathComponent("projects")
            let real = projects.resolvingSymlinksInPath().path
            guard fm.fileExists(atPath: real), seenRoots.insert(real).inserted,
                  let folders = try? fm.contentsOfDirectory(atPath: real) else { continue }
            for folder in folders {
                let dir = URL(fileURLWithPath: real).appendingPathComponent(folder)
                guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
                for file in files where file.hasSuffix(".jsonl") {
                    let path = dir.appendingPathComponent(file).path
                    guard let attrs = try? fm.attributesOfItem(atPath: path),
                          let mtime = attrs[.modificationDate] as? Date, mtime >= cutoff,
                          let size = (attrs[.size] as? NSNumber)?.uint64Value else { continue }
                    read(path, size: size, project: folder, configDir: name, cutoff: cutoff)
                }
            }
        }
    }

    private func read(_ path: String, size: UInt64, project: String, configDir: String, cutoff: Date) {
        lock.lock()
        var start = offsets[path] ?? 0
        lock.unlock()
        if size < start { start = 0 }           // rewritten or truncated
        guard size > start, let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: start) } catch { return }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        // Only whole lines; a half-written last line is read next time.
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return }
        let chunk = data[data.startIndex...lastNewline]
        var found: [PromptEvent] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in chunk.split(separator: 0x0A) {
            // Cheap byte checks before any JSON: most lines are tool traffic,
            // some of it megabytes long. Claude writes `"type":"user"` within
            // the first few hundred bytes of the line.
            guard line.count < 400_000,
                  line.prefix(600).range(of: Self.userMarker) != nil,
                  line.range(of: Self.toolMarker) == nil else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if obj["isMeta"] as? Bool == true || obj["isSidechain"] as? Bool == true { continue }
            if let kind = obj["userType"] as? String, kind != "external" { continue }
            if let entry = obj["entrypoint"] as? String, entry != "cli" { continue }
            guard let stamp = obj["timestamp"] as? String, let at = iso.date(from: stamp), at >= cutoff,
                  let message = obj["message"] as? [String: Any] else { continue }
            var content = ""
            if let s = message["content"] as? String {
                content = s
            } else if let parts = message["content"] as? [[String: Any]] {
                content = parts.compactMap { $0["text"] as? String }.joined(separator: " ")
            }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !Self.injected.contains(where: { trimmed.hasPrefix($0) }) else { continue }
            found.append(PromptEvent(at: at, project: project, configDir: configDir,
                                     // Short replies ("yes", "do it") repeat by nature; only
                                     // long prompts get a key the loop check can use.
                                     key: trimmed.count < 40 ? 0 : PromptEvent.fnv(trimmed.prefix(70))))
        }
        lock.lock()
        offsets[path] = start + UInt64(chunk.count)
        events.formUnion(found)
        lock.unlock()
    }
}
