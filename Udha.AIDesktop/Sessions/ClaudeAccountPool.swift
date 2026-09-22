import Foundation
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One Claude login's remaining headroom, as last observed.
///
/// Two windows matter on a claude.ai subscription: the rolling five-hour
/// session cap and the weekly cap. Each reading carries the moment its window
/// resets, because a number past its reset is no longer a number — it is
/// whatever the last session happened to see before the counter rolled over.
struct ClaudeAccountUsage: Hashable, Sendable {
    var fiveHourPercent: Int?
    var fiveHourResetsAt: Date?
    var sevenDayPercent: Int?
    var sevenDayResetsAt: Date?
    /// The weekly cap that applies to one model only — "Fable" today — as the
    /// usage endpoint's `limits[]` reports it (`kind: weekly_scoped`). The
    /// statusLine never carries it, so it is only ever known from the probe.
    var scopedPercent: Int?
    var scopedResetsAt: Date?
    var scopedLabel: String?
    var observedAt: Date = Date()
    /// Where the reading came from: `statusline` (Claude's own status feed for a
    /// running session — documented) or `api` (the usage probe — not).
    var source: String = "statusline"

    /// How full this login is *right now*: the fuller of the two windows,
    /// ignoring one whose reset has already passed. nil when nothing current is
    /// known.
    func usedPercent(at now: Date = Date()) -> Int? {
        var values: [Int] = []
        if let p = fiveHourPercent, fiveHourResetsAt.map({ $0 > now }) ?? true { values.append(p) }
        if let p = sevenDayPercent, sevenDayResetsAt.map({ $0 > now }) ?? true { values.append(p) }
        if let p = scopedPercent, scopedResetsAt.map({ $0 > now }) ?? true { values.append(p) }
        return values.max()
    }

    /// The scoped window's name for a meter: "Fable".
    var scopedName: String { scopedLabel ?? "model" }

    /// A statusLine reading knows nothing of the scoped window; carry the
    /// probe's last word on it forward rather than forgetting it every tick.
    func keepingScoped(from previous: ClaudeAccountUsage?) -> ClaudeAccountUsage {
        guard scopedPercent == nil, let previous, previous.scopedPercent != nil else { return self }
        var out = self
        out.scopedPercent = previous.scopedPercent
        out.scopedResetsAt = previous.scopedResetsAt
        out.scopedLabel = previous.scopedLabel
        return out
    }

    /// One line for a log: "5h 18% · 7d 83%".
    var summary: String {
        var parts: [String] = []
        if let p = fiveHourPercent { parts.append("5h \(p)%") }
        if let p = sevenDayPercent { parts.append("7d \(p)%") }
        if let p = scopedPercent { parts.append("\(scopedName) \(p)%") }
        return parts.isEmpty ? "no reading" : parts.joined(separator: " · ")
    }

    /// Parse the `rate_limits` block of Claude Code's statusLine payload:
    /// `{"five_hour": {"used_percentage": 2, "resets_at": 1789379400}, "seven_day": {…}}`
    /// (`resets_at` is Unix seconds). Either window may be absent — a session
    /// that has not been told about the five-hour window yet only carries
    /// `seven_day`.
    static func fromStatusLine(_ rateLimits: [String: Any], observedAt: Date = Date()) -> ClaudeAccountUsage? {
        func window(_ key: String) -> (Int, Date?)? {
            guard let w = rateLimits[key] as? [String: Any] else { return nil }
            guard let pct = (w["used_percentage"] as? Double) ?? (w["used_percentage"] as? Int).map(Double.init) else { return nil }
            let reset = ((w["resets_at"] as? Double) ?? (w["resets_at"] as? Int).map(Double.init)).map { Date(timeIntervalSince1970: $0) }
            return (Int(pct.rounded()), reset)
        }
        let five = window("five_hour"), seven = window("seven_day")
        guard five != nil || seven != nil else { return nil }
        return ClaudeAccountUsage(fiveHourPercent: five?.0, fiveHourResetsAt: five?.1,
                                  sevenDayPercent: seven?.0, sevenDayResetsAt: seven?.1,
                                  observedAt: observedAt, source: "statusline")
    }
}

/// One login as the UI shows it: its name, what is known of its headroom, and
/// whether it is currently spent. Built on the machine that owns the pool and
/// carried over the bridge as the `accounts` reply, so the Mac can show a
/// box's logins exactly as the box sees them.
struct ClaudeLoginOverview: Hashable, Sendable, Identifiable {
    /// The normalized config dir; the pool's key and what a switch names.
    var dir: String
    /// `work-2` — what the row's `account` carries.
    var name: String
    /// Who the dir is signed in as, from its `.claude.json` — the thing you
    /// actually recognise. Nil until read, or for a dir never signed in.
    var email: String?
    var usage: ClaudeAccountUsage?
    /// Set while a hit limit is being waited out.
    var limitedUntil: Date?
    /// The dir's refresh token is dead: nothing can be read until someone
    /// signs it in again. Set by the probe, cleared by the next good reading.
    var needsSignIn: Bool = false

    var id: String { dir }

    /// The email when known, else the dir's short name.
    var displayName: String { email ?? name }

    /// The signed-in email in `<configDir>/.claude.json` (`oauthAccount.emailAddress`).
    /// A file read, not a `claude auth status` subprocess — but the file can
    /// be megabytes on a box that pre-trusts every project, so callers cache.
    nonisolated static func readEmail(configDir: String) -> String? {
        guard let path = claudeJSONPath(configDir: configDir),
              let data = FileManager.default.contents(atPath: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let account = obj["oauthAccount"] as? [String: Any],
              let email = account["emailAddress"] as? String, !email.isEmpty else { return nil }
        return email
    }

    /// Where a login keeps its `.claude.json`: inside the dir for one set by
    /// `CLAUDE_CONFIG_DIR`, but the default login writes `~/.claude.json` at
    /// the home root and keeps `~/.claude/` for everything else.
    nonisolated static func claudeJSONPath(configDir: String) -> String? {
        let dir = ClaudeAccountPool.normalized(configDir)
        let inside = (dir as NSString).appendingPathComponent(".claude.json")
        if FileManager.default.fileExists(atPath: inside) { return inside }
        if dir == ClaudeAccountPool.normalized("~/.claude") {
            let root = ClaudeAccountPool.normalized("~/.claude.json")
            if FileManager.default.fileExists(atPath: root) { return root }
        }
        return nil
    }

    func isLimited(at now: Date = Date()) -> Bool { limitedUntil.map { $0 > now } ?? false }

    /// "5h 26% · 7d 7%", "limited until 4:30pm", or "no reading".
    func headroom(at now: Date = Date()) -> String {
        if let until = limitedUntil, until > now { return "limited until \(ClaudeAccountPool.clock.string(from: until))" }
        if needsSignIn { return "sign in again" }
        return usage?.summary ?? "no reading"
    }

    var wire: [String: Any] {
        var out: [String: Any] = ["dir": dir, "name": name]
        if let email { out["email"] = email }
        if let usage {
            if let p = usage.fiveHourPercent { out["fiveHour"] = p }
            if let d = usage.fiveHourResetsAt { out["fiveHourResetsAt"] = d.timeIntervalSince1970 }
            if let p = usage.sevenDayPercent { out["sevenDay"] = p }
            if let d = usage.sevenDayResetsAt { out["sevenDayResetsAt"] = d.timeIntervalSince1970 }
            if let p = usage.scopedPercent { out["scoped"] = p }
            if let d = usage.scopedResetsAt { out["scopedResetsAt"] = d.timeIntervalSince1970 }
            if let l = usage.scopedLabel { out["scopedLabel"] = l }
            out["observedAt"] = usage.observedAt.timeIntervalSince1970
            out["source"] = usage.source
        }
        if let limitedUntil { out["limitedUntil"] = limitedUntil.timeIntervalSince1970 }
        if needsSignIn { out["needsSignIn"] = true }
        return out
    }

    init(dir: String, name: String, email: String? = nil, usage: ClaudeAccountUsage? = nil, limitedUntil: Date? = nil, needsSignIn: Bool = false) {
        self.dir = dir
        self.name = name
        self.email = email
        self.usage = usage
        self.limitedUntil = limitedUntil
        self.needsSignIn = needsSignIn
    }

    init?(wire r: [String: Any]) {
        guard let dir = r["dir"] as? String, let name = r["name"] as? String else { return nil }
        func seconds(_ key: String) -> Date? {
            ((r[key] as? Double) ?? (r[key] as? Int).map(Double.init)).map { Date(timeIntervalSince1970: $0) }
        }
        func percent(_ key: String) -> Int? { (r[key] as? Int) ?? (r[key] as? Double).map { Int($0.rounded()) } }
        var usage: ClaudeAccountUsage?
        if percent("fiveHour") != nil || percent("sevenDay") != nil || percent("scoped") != nil {
            usage = ClaudeAccountUsage(fiveHourPercent: percent("fiveHour"), fiveHourResetsAt: seconds("fiveHourResetsAt"),
                                       sevenDayPercent: percent("sevenDay"), sevenDayResetsAt: seconds("sevenDayResetsAt"),
                                       scopedPercent: percent("scoped"), scopedResetsAt: seconds("scopedResetsAt"),
                                       scopedLabel: r["scopedLabel"] as? String,
                                       observedAt: seconds("observedAt") ?? Date(),
                                       source: (r["source"] as? String) ?? "statusline")
        }
        self.init(dir: dir, name: name, email: r["email"] as? String, usage: usage, limitedUntil: seconds("limitedUntil"),
                  needsSignIn: (r["needsSignIn"] as? Bool) ?? false)
    }
}

/// One tree's logins, primary first — what `fetch_accounts` answers with.
struct ClaudeLoginPoolOverview: Hashable, Sendable, Identifiable {
    /// The tree, tilde-expanded, so a session's directory can be matched by prefix.
    var pathPrefix: String
    var members: [ClaudeLoginOverview]

    var id: String { pathPrefix }

    /// Whether `directory` (as the owning machine spells it) is in this tree.
    func covers(_ directory: String) -> Bool {
        directory == pathPrefix || directory.hasPrefix(pathPrefix + "/")
    }

    var wire: [String: Any] { ["pathPrefix": pathPrefix, "members": members.map(\.wire)] }

    init(pathPrefix: String, members: [ClaudeLoginOverview]) {
        self.pathPrefix = pathPrefix
        self.members = members
    }

    init?(wire r: [String: Any]) {
        guard let prefix = r["pathPrefix"] as? String else { return nil }
        let members = ((r["members"] as? [[String: Any]]) ?? []).compactMap(ClaudeLoginOverview.init(wire:))
        self.init(pathPrefix: prefix, members: members)
    }
}

/// Which login each Claude session should run under, and which ones are spent.
///
/// A `ClaudeAccount` names a directory tree and the config dir that logs it in;
/// with `alternates` it names several logins for the same tree. This pool holds
/// what is known about each of them — the last usage reading, and when a login
/// that hit its limit becomes usable again — and picks the one with the most
/// headroom when a session starts or has to move. It never touches credentials:
/// each config dir is signed in once by hand and Claude keeps its own tokens
/// fresh from then on.
///
/// Observable so the pane's login strip redraws as readings land.
@MainActor
@Observable
final class ClaudeAccountPool {
    private(set) var usage: [String: ClaudeAccountUsage] = [:]
    private(set) var limitedUntil: [String: Date] = [:]
    /// Who each dir is signed in as, read off the main actor by the manager.
    private(set) var emails: [String: String] = [:]
    /// Dirs whose refresh token the token endpoint refused.
    private(set) var signInNeeded: Set<String> = []

    func setEmail(_ email: String?, for configDir: String) {
        let key = Self.normalized(configDir)
        if emails[key] != email { emails[key] = email }
    }

    func setNeedsSignIn(_ needed: Bool, for configDir: String) {
        let key = Self.normalized(configDir)
        if needed { signInNeeded.insert(key) } else { signInNeeded.remove(key) }
    }

    /// The pool as the UI shows it, in pool order.
    func overview(of pool: [String], now: Date = Date()) -> [ClaudeLoginOverview] {
        pool.map(Self.normalized).map { dir in
            ClaudeLoginOverview(dir: dir, name: Self.shortName(dir), email: emails[dir], usage: usage[dir],
                                limitedUntil: limitedUntil[dir].flatMap { $0 > now ? $0 : nil },
                                needsSignIn: signInNeeded.contains(dir))
        }
    }

    /// A login with no reading is ranked as if this full. Below a login that is
    /// known to be nearly empty, above one that is known to be nearly spent —
    /// an idle login is *probably* fresh, but a measured one is certain.
    nonisolated static let unknownUsagePercent = 25

    func record(_ reading: ClaudeAccountUsage, for configDir: String) {
        let key = Self.normalized(configDir)
        // A statusLine reading is authoritative for its own session; the probe
        // is a fallback for logins nothing is running under. Never let an older
        // reading overwrite a newer one.
        if let existing = usage[key], existing.observedAt > reading.observedAt { return }
        usage[key] = reading.keepingScoped(from: usage[key])
        signInNeeded.remove(key)
        // A fresh reading under the cap means the window rolled over.
        if let used = reading.usedPercent(), used < 100 { limitedUntil[key] = nil }
    }

    func markLimited(_ configDir: String, until: Date) {
        limitedUntil[Self.normalized(configDir)] = until
    }

    func clearLimited(_ configDir: String) {
        limitedUntil[Self.normalized(configDir)] = nil
    }

    func isLimited(_ configDir: String, at now: Date = Date()) -> Bool {
        guard let until = limitedUntil[Self.normalized(configDir)] else { return false }
        return until > now
    }

    func usage(for configDir: String) -> ClaudeAccountUsage? { usage[Self.normalized(configDir)] }

    /// The login in `pool` with the most headroom, or nil when every one of
    /// them is spent. `avoiding` is the login being left; it is only ever
    /// returned when nothing else can take the work (it is never returned at
    /// all when it is known to be limited).
    func choose(from pool: [String], avoiding current: String? = nil, now: Date = Date()) -> String? {
        let candidates = pool.map(Self.normalized)
        let currentKey = current.map(Self.normalized)
        func rank(_ dir: String) -> Int {
            usage[dir]?.usedPercent(at: now) ?? Self.unknownUsagePercent
        }
        let open = candidates.enumerated()
            .filter { !isLimited($0.element, at: now) }
            .filter { $0.element != currentKey }
            .min { a, b in
                let ra = rank(a.element), rb = rank(b.element)
                return ra != rb ? ra < rb : a.offset < b.offset
            }
        if let open { return open.element }
        // Nothing else is open. Staying put is right only if the current one
        // is not itself spent; a limited login is never an answer.
        if let currentKey, candidates.contains(currentKey), !isLimited(currentKey, at: now) { return currentKey }
        return nil
    }

    /// "work-2 (5h 18% · 7d 83%)" for a log line.
    func describe(_ configDir: String) -> String {
        let key = Self.normalized(configDir)
        var text = Self.shortName(key)
        if let u = usage[key] { text += " (\(u.summary))" }
        if let until = limitedUntil[key], until > Date() {
            text += " limited until \(Self.clock.string(from: until))"
        }
        return text
    }

    /// `~/.claude-work-2` → `work-2`; `~/.claude` → `default`.
    nonisolated static func shortName(_ configDir: String) -> String {
        let leaf = (normalized(configDir) as NSString).lastPathComponent
        if leaf == ".claude" { return "default" }
        if leaf.hasPrefix(".claude-") { return String(leaf.dropFirst(".claude-".count)) }
        return leaf.hasPrefix(".") ? String(leaf.dropFirst()) : leaf
    }

    /// Tilde expanded, trailing slash dropped — so two spellings of one dir
    /// are one key.
    nonisolated static func normalized(_ path: String) -> String {
        var expanded = (path as NSString).expandingTildeInPath
        while expanded.count > 1, expanded.hasSuffix("/") { expanded.removeLast() }
        return expanded
    }

    /// `--resume <id>` finds the transcript under the login's own `projects/`.
    /// A handoff stages it under the *primary* login's; when a session starts
    /// on another member of the pool, point `--resume` at the file itself,
    /// which Claude accepts from any config dir.
    nonisolated static func resolvingResume(_ args: [String], directory: String, primaryDir: String, chosenDir: String,
                                            exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String] {
        guard normalized(chosenDir) != normalized(primaryDir),
              let i = args.firstIndex(of: "--resume"), i + 1 < args.count,
              UUID(uuidString: args[i + 1]) != nil else { return args }
        let path = "\(normalized(primaryDir))/projects/\(escapedProjectDir(directory))/\(args[i + 1]).jsonl"
        guard exists(path) else { return args }
        var out = args
        out[i + 1] = path
        return out
    }

    /// How Claude names a working directory under `projects/`: `/` and `.`
    /// both become `-`.
    nonisolated static func escapedProjectDir(_ directory: String) -> String {
        String(normalized(directory).map { ($0 == "/" || $0 == ".") ? "-" : $0 })
    }

    /// `<config dir>/projects/<escaped cwd>/<id>.jsonl` → `<config dir>`.
    nonisolated static func configDir(fromTranscriptPath path: String) -> String? {
        guard let range = path.range(of: "/projects/") else { return nil }
        let dir = String(path[..<range.lowerBound])
        return dir.isEmpty ? nil : dir
    }

    /// The clock Claude prints in "continuing automatically at 1:40am", as a
    /// date: the next time that clock reads so. Claude prints the *local* time
    /// of the machine it runs on, which is the machine this runs on too.
    nonisolated static func parseResumeClock(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard let m = clockPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let hourRange = Range(m.range(at: 1), in: text),
              var hour = Int(text[hourRange]) else { return nil }
        let minute = Range(m.range(at: 2), in: text).flatMap { Int(text[$0]) } ?? 0
        let meridiem = Range(m.range(at: 3), in: text).map { text[$0].lowercased() }
        if meridiem == "pm", hour < 12 { hour += 12 }
        if meridiem == "am", hour == 12 { hour = 0 }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour; comps.minute = minute; comps.second = 0
        guard let today = calendar.date(from: comps) else { return nil }
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }

    nonisolated private static let clockPattern = try! NSRegularExpression(pattern: #"(\d{1,2})(?::(\d{2}))?\s*(am|pm|AM|PM)?\b"#)
    nonisolated static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
}

/// Asks claude.ai how full a login is, for logins nothing is running under.
///
/// This is the call Claude Code's own `/usage` makes, not a documented API:
/// it may change shape or go away, so every failure here is silent and the
/// pool simply keeps ranking that login as unknown. It reads the access token
/// Claude left in `<config dir>/.credentials.json` and never writes there —
/// refreshing a token behind a running Claude would sign that session out.
enum ClaudeUsageProbe {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Claude Code's own token endpoint and public client id (both read out
    /// of its 2.1.278 binary on 2026-09-21).
    static let tokenEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// Renew an **idle** login's expired token so its headroom can still be
    /// read. Claude renews its own while it runs; a dir nothing is running
    /// under just goes dark two hours after its last session, which is
    /// exactly the login the pool most wants to know about. The caller
    /// promises no session is on this dir — a refresh rotates the refresh
    /// token, and a running Claude holding the old one would be signed out.
    /// File-backed dirs only; the write is atomic and keeps the file's other
    /// fields (`scopes`, `subscriptionType`, …). Returns what happened, for
    /// the log; nil when nothing needed doing.
    static func refreshExpiredToken(configDir: String, now: Date = Date()) async -> String? {
        let dir = ClaudeAccountPool.normalized(configDir)
        let file = (dir as NSString).appendingPathComponent(".credentials.json")
        guard let data = FileManager.default.contents(atPath: file),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var oauth = obj["claudeAiOauth"] as? [String: Any],
              let refresh = oauth["refreshToken"] as? String, !refresh.isEmpty else { return nil }
        let expiresMs = (oauth["expiresAt"] as? Double) ?? (oauth["expiresAt"] as? Int).map(Double.init) ?? 0
        guard Date(timeIntervalSince1970: expiresMs / 1000) < now.addingTimeInterval(5 * 60) else { return nil }
        if let refreshExpiresMs = (oauth["refreshTokenExpiresAt"] as? Double) ?? (oauth["refreshTokenExpiresAt"] as? Int).map(Double.init),
           Date(timeIntervalSince1970: refreshExpiresMs / 1000) < now {
            return "refresh token expired too — sign \(ClaudeAccountPool.shortName(dir)) in again"
        }
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("udha-account-pool", forHTTPHeaderField: "User-Agent")
        var body: [String: Any] = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID]
        if let scopes = oauth["scopes"] as? [String], !scopes.isEmpty { body["scope"] = scopes.joined(separator: " ") }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (reply, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return "refresh of \(ClaudeAccountPool.shortName(dir)) got no answer" }
        guard (200..<300).contains(http.statusCode),
              let got = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
              let access = got["access_token"] as? String, !access.isEmpty else {
            return "refresh of \(ClaudeAccountPool.shortName(dir)) refused (HTTP \(http.statusCode))"
        }
        oauth["accessToken"] = access
        if let rotated = got["refresh_token"] as? String, !rotated.isEmpty { oauth["refreshToken"] = rotated }
        let ttl = (got["expires_in"] as? Double) ?? (got["expires_in"] as? Int).map(Double.init) ?? 3600
        oauth["expiresAt"] = Int((now.timeIntervalSince1970 + ttl) * 1000)
        if let scope = got["scope"] as? String, !scope.isEmpty { oauth["scopes"] = scope.split(separator: " ").map(String.init) }
        obj["claudeAiOauth"] = oauth
        guard let out = try? JSONSerialization.data(withJSONObject: obj) else { return "refresh of \(ClaudeAccountPool.shortName(dir)) could not be encoded" }
        // The new refresh token is the only valid one now: land it or lose
        // the login. Temp file beside it, then a POSIX rename(2) — atomic on
        // both platforms. `FileManager.replaceItemAt` is NOT that on Linux:
        // on 2026-09-21 it moved the original onto the temp path, failed, and
        // left the new tokens nowhere — two logins had to be signed in again.
        // If even the rename fails, overwrite in place: a torn file is
        // recoverable by a sign-in, a lost refresh token is the same cost, and
        // a whole file usually lands.
        let tmp = file + ".new"
        do {
            try out.write(to: URL(fileURLWithPath: tmp), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp)
        } catch {
            try? out.write(to: URL(fileURLWithPath: file))
            return "renewed \(ClaudeAccountPool.shortName(dir))'s token, written in place (temp file failed: \(error.localizedDescription))"
        }
        if rename(tmp, file) != 0 {
            let why = String(cString: strerror(errno))
            try? FileManager.default.removeItem(atPath: tmp)
            do {
                try out.write(to: URL(fileURLWithPath: file))
            } catch {
                return "refresh of \(ClaudeAccountPool.shortName(dir)) succeeded but the write failed (\(why); \(error.localizedDescription)) — sign it in again"
            }
            return "renewed \(ClaudeAccountPool.shortName(dir))'s token, written in place (rename failed: \(why))"
        }
        return "renewed \(ClaudeAccountPool.shortName(dir))'s token (idle, was expired)"
    }

#if os(macOS)
    /// The default login's credentials JSON out of the login Keychain, via
    /// the `security` tool — the writer of the item, so no access prompt.
    static func keychainCredentials() -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()
        guard p.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }
#endif

    /// The bearer token for a config dir, or nil when it is missing or about to
    /// expire (a call with a stale token only ever answers 401).
    static func accessToken(configDir: String, now: Date = Date()) -> String? {
        let dir = ClaudeAccountPool.normalized(configDir)
        let file = (dir as NSString).appendingPathComponent(".credentials.json")
        var data = FileManager.default.contents(atPath: file)
#if os(macOS)
        // On a Mac the default login keeps the same JSON in the login
        // Keychain (service "Claude Code-credentials"), written by the
        // `security` tool — which is therefore on the item's ACL and reads it
        // back without a prompt. Only the default dir: a `CLAUDE_CONFIG_DIR`
        // login on a Mac writes the file.
        if data == nil, dir == ClaudeAccountPool.normalized("~/.claude") {
            data = keychainCredentials()
        }
#endif
        guard let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        if let expiresMs = (oauth["expiresAt"] as? Double) ?? (oauth["expiresAt"] as? Int).map(Double.init),
           Date(timeIntervalSince1970: expiresMs / 1000) < now.addingTimeInterval(60) {
            return nil
        }
        return token
    }

    static func fetch(configDir: String) async -> ClaudeAccountUsage? {
        guard let token = accessToken(configDir: configDir) else { return nil }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("udha-account-pool", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(obj)
    }

    /// `{"five_hour": {"utilization": 18.0, "resets_at": "2026-09-18T10:30:00.672633+00:00"}, "seven_day": {…}}`
    static func parse(_ obj: [String: Any], observedAt: Date = Date()) -> ClaudeAccountUsage? {
        func window(_ key: String) -> (Int, Date?)? {
            guard let w = obj[key] as? [String: Any],
                  let pct = (w["utilization"] as? Double) ?? (w["utilization"] as? Int).map(Double.init) else { return nil }
            return (Int(pct.rounded()), (w["resets_at"] as? String).flatMap(parseISO))
        }
        let five = window("five_hour"), seven = window("seven_day")
        // `limits[]` is the structured list; the one with `kind: weekly_scoped`
        // is the per-model cap and names the model it scopes ("Fable").
        var scoped: (Int, Date?, String?)?
        for entry in (obj["limits"] as? [[String: Any]]) ?? [] where (entry["kind"] as? String) == "weekly_scoped" {
            guard let pct = (entry["percent"] as? Double) ?? (entry["percent"] as? Int).map(Double.init) else { continue }
            let model = ((entry["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
            scoped = (Int(pct.rounded()), (entry["resets_at"] as? String).flatMap(parseISO), model)
            break
        }
        guard five != nil || seven != nil || scoped != nil else { return nil }
        return ClaudeAccountUsage(fiveHourPercent: five?.0, fiveHourResetsAt: five?.1,
                                  sevenDayPercent: seven?.0, sevenDayResetsAt: seven?.1,
                                  scopedPercent: scoped?.0, scopedResetsAt: scoped?.1, scopedLabel: scoped?.2,
                                  observedAt: observedAt, source: "api")
    }

    /// The endpoint writes six fractional digits, which `ISO8601DateFormatter`
    /// refuses; drop the fraction before parsing.
    static func parseISO(_ s: String) -> Date? {
        let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return isoFormatter.date(from: trimmed)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
}
