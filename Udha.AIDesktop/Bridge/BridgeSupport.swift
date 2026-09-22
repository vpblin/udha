import Foundation

// MARK: - tmux key validation

/// Validates `send_keys` elements before they become arguments to
/// `tmux send-keys`.
///
/// Allow-list, never a deny-list: everything here is a key name tmux
/// understands, so nothing that reaches the argument position can carry shell
/// metacharacters, spaces or substitutions.
enum TmuxKeyValidator {
    private static let named: Set<String> = [
        "Up", "Down", "Left", "Right", "Enter", "Escape", "Tab", "BTab", "Space",
        "PPage", "NPage", "Home", "End", "BSpace", "DC", "IC",
    ]

    static func isValid(_ key: String) -> Bool {
        if key.count == 1, let c = key.first, c.isLetter || c.isNumber { return true }
        if named.contains(key) { return true }
        if key.count >= 3 {
            let parts = key.split(separator: "-", maxSplits: 1)
            if parts.count == 2, ["C", "M", "S"].contains(String(parts[0])),
               parts[1].count == 1 || named.contains(String(parts[1])) {
                return true
            }
        }
        if key.hasPrefix("F"), key.count <= 3, let n = Int(key.dropFirst()), (1...12).contains(n) {
            return true
        }
        return false
    }

    static func validate(_ keys: [String]) -> Bool {
        !keys.isEmpty && keys.count <= 32 && keys.allSatisfy(isValid)
    }
}

// MARK: - Git diff

/// Runs `git diff` for the review screen. Nonisolated so it can be called off
/// the main actor — a large diff should not stall the UI.
enum GitDiff {
    struct File {
        var path: String
        var patch: String
        var additions: Int
        var deletions: Int
        var truncated: Bool
    }

    struct Result {
        var stat: String = ""
        var files: [File] = []
        var truncated: Bool = false
        var error: String?
    }

    /// Total payload ceiling. The relay carries this as one JSON message, so an
    /// unbounded diff would be a denial of service against the client.
    private static let budget = 500_000
    private static let perFile = 60_000

    static func run(directory: String, mode: String) -> Result {
        guard !directory.isEmpty else { return Result(error: "no directory") }
        guard git(["rev-parse", "--is-inside-work-tree"], in: directory)?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            return Result(error: "not a git repository")
        }

        var args: [String]
        switch mode {
        case "staged":
            args = ["diff", "--cached"]
        case "branch":
            let base = defaultBranch(in: directory)
            if let mergeBase = git(["merge-base", "HEAD", base], in: directory)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !mergeBase.isEmpty {
                args = ["diff", mergeBase]
            } else {
                args = ["diff", "HEAD"]
            }
        default:
            args = ["diff"]
        }

        guard let raw = git(args, in: directory) else { return Result(error: "git diff failed") }
        let stat = git(args + ["--stat"], in: directory)?
            .components(separatedBy: .newlines).last(where: { !$0.isEmpty })?
            .trimmingCharacters(in: .whitespaces) ?? ""

        var result = Result(stat: stat)
        var used = 0
        for chunk in raw.components(separatedBy: "\ndiff --git ") where !chunk.isEmpty {
            let body = chunk.hasPrefix("diff --git ") ? chunk : "diff --git " + chunk
            let path = parsePath(body) ?? "unknown"
            var patch = body
            var fileTruncated = false
            if patch.count > perFile {
                patch = String(patch.prefix(perFile)) + "\n… truncated"
                fileTruncated = true
            }
            if used + patch.count > budget {
                result.truncated = true
                break
            }
            used += patch.count
            let lines = body.components(separatedBy: .newlines)
            result.files.append(File(
                path: path,
                patch: patch,
                additions: lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count,
                deletions: lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count,
                truncated: fileTruncated
            ))
        }
        return result
    }

    private static func parsePath(_ chunk: String) -> String? {
        guard let first = chunk.components(separatedBy: .newlines).first else { return nil }
        // "diff --git a/path b/path"
        guard let range = first.range(of: " b/") else { return nil }
        return String(first[range.upperBound...])
    }

    private static func defaultBranch(in directory: String) -> String {
        if let head = git(["symbolic-ref", "refs/remotes/origin/HEAD"], in: directory)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let name = head.components(separatedBy: "/").last, !name.isEmpty {
            return "origin/" + name
        }
        for candidate in ["origin/main", "origin/master", "main", "master"] {
            if git(["rev-parse", "--verify", candidate], in: directory) != nil { return candidate }
        }
        return "HEAD"
    }

    /// Thin wrapper preserving this file's original signature: stdout on
    /// success, nil on any failure. Worktree creation needs the failure text,
    /// so it calls `Git.run` directly.
    private static func git(_ args: [String], in directory: String) -> String? {
        let result = Git.run(args, in: directory)
        return result.status == 0 ? result.stdout : nil
    }
}

// MARK: - Git process runner

/// One place that shells out to git. Nonisolated so callers can stay off the
/// main actor.
///
/// Returns stderr as well as stdout because `git worktree add` fails for a
/// dozen mundane reasons — the branch exists, the base ref doesn't, the tree is
/// mid-rebase — and git already writes a better message for each than anything
/// this app would invent. That text goes to the phone verbatim.
enum Git {
    /// Carries git's own message so it can be forwarded to the phone verbatim.
    struct Failure: Error {
        var message: String
    }

    struct Output {
        var stdout: String
        var stderr: String
        var status: Int32

        var trimmedOut: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
        /// Whichever stream carries the explanation, trimmed and never empty.
        var message: String {
            let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !err.isEmpty { return err }
            let out = trimmedOut
            return out.isEmpty ? "git exited \(status)" : out
        }
    }

    static func run(_ args: [String], in directory: String) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory] + args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return Output(stdout: "", stderr: error.localizedDescription, status: -1)
        }
        // Drain both before waiting: a big diff fills the pipe buffer and would
        // deadlock a wait-then-read.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            status: process.terminationStatus
        )
    }
}

// MARK: - Git worktrees

/// Creates the worktrees that back a "new session on its own branch".
///
/// The layout is the one `SessionWireRow` already reads —
/// `<parent>/<repo>-wt/<leaf>` — so a worktree made here is recognised by the
/// Mac's own UI with no further changes. The leaf is a *filesystem-safe*
/// rendering of the branch, not the branch itself: `udha/cov` cannot be a
/// directory name without creating a nested folder. The real branch is stored
/// on `SessionConfig.branch` rather than re-derived from the path, which is
/// what lets a branch keep its slash.
enum GitWorktree {
    /// The repo containing `directory`, so picking a subfolder in the phone's
    /// browser still resolves to the right root.
    static func repoRoot(for directory: String) -> String? {
        let result = Git.run(["rev-parse", "--show-toplevel"], in: directory)
        guard result.status == 0 else { return nil }
        let path = result.trimmedOut
        return path.isEmpty ? nil : path
    }

    /// Local branches first, then remotes, then the current branch — the order
    /// the picker shows them in.
    static func branches(in directory: String) -> (current: String?, all: [String]) {
        func lines(_ args: [String]) -> [String] {
            let result = Git.run(args, in: directory)
            guard result.status == 0 else { return [] }
            return result.stdout
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasSuffix("/HEAD") }
        }
        let local = lines(["for-each-ref", "--format=%(refname:short)", "refs/heads"])
        let remote = lines(["for-each-ref", "--format=%(refname:short)", "refs/remotes"])
        let head = Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: directory)
        let current = head.status == 0 ? head.trimmedOut : nil
        return (current?.isEmpty == false ? current : nil, local + remote)
    }

    /// `udha/cov-a3f2` -> `udha-cov-a3f2`. Anything that would confuse a path
    /// or the `-wt/` convention is folded to a dash.
    static func leaf(for branch: String) -> String {
        let mapped = branch.map { ch -> Character in
            (ch == "/" || ch == ":" || ch == " " || ch == "\\") ? "-" : ch
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "work" : collapsed
    }

    /// `/x/scholar-health` + `udha/cov` -> `/x/scholar-health-wt/udha-cov`
    static func worktreePath(repoRoot: String, branch: String) -> String {
        let root = repoRoot as NSString
        let parent = root.deletingLastPathComponent
        let container = "\(root.lastPathComponent)-wt"
        let base = (parent as NSString).appendingPathComponent(container)
        return (base as NSString).appendingPathComponent(leaf(for: branch))
    }

    /// Adds the worktree and returns its path, or git's own error text.
    ///
    /// Two modes, because attaching to a branch that already exists is at least
    /// as common as cutting a new one, and `worktree add -b` only does the latter.
    static func create(
        repoRoot: String,
        branch: String,
        base: String?,
        isNewBranch: Bool
    ) -> Result<String, Git.Failure> {
        let path = worktreePath(repoRoot: repoRoot, branch: branch)
        guard !FileManager.default.fileExists(atPath: path) else {
            return .failure(Git.Failure(message: "worktree path already exists: \(path)"))
        }

        var args = ["worktree", "add"]
        if isNewBranch {
            let base = (base?.isEmpty == false) ? base! : "HEAD"
            guard Git.run(["rev-parse", "--verify", base], in: repoRoot).status == 0 else {
                return .failure(Git.Failure(message: "unknown base ref: \(base)"))
            }
            args += ["-b", branch, path, base]
        } else {
            guard Git.run(["rev-parse", "--verify", branch], in: repoRoot).status == 0 else {
                return .failure(Git.Failure(message: "unknown branch: \(branch)"))
            }
            args += [path, branch]
        }

        let result = Git.run(args, in: repoRoot)
        guard result.status == 0 else { return .failure(Git.Failure(message: result.message)) }
        return .success(path)
    }

    /// Rollback only — used when the worktree was created but the session
    /// failed to spawn, so the tree is not left with an orphan.
    @discardableResult
    static func remove(path: String, repoRoot: String) -> Bool {
        Git.run(["worktree", "remove", "--force", path], in: repoRoot).status == 0
    }
}


#if !UDHA_AGENT
// MARK: - Meeting notes parsing

/// Pulls structure back out of the notes markdown the LLM pass writes.
///
/// Decisions are not stored separately on disk — they live as bullets under a
/// "Decisions" heading in the notes file, which stays hand-editable in Finder.
/// Parsing them here beats introducing a second source of truth.
enum MeetingNotes {
    /// Extracts the bullets under a "Decisions" heading in the notes markdown.
    static func decisions(from markdown: String) -> [String] {
        var out: [String] = []
        var inSection = false
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                inSection = line.lowercased().contains("decision")
                continue
            }
            guard inSection else { continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                out.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            }
        }
        return out
    }
}

// MARK: - Local meeting uploads

/// What a phone sends in `push_local_meeting`, parsed and validated.
///
/// Separate from the handler so the parsing is testable without the whole app
/// graph — and because the handler getting this wrong is expensive: it used to
/// discard the phone's `id` and mint a new one, which meant the phone could
/// never recognise its own meeting coming back. Its copy stayed "waiting for
/// Mac" forever and every retry created another duplicate on this side.
struct LocalMeetingUpload {
    var id: UUID
    var title: String
    var createdAt: Date?
    var endedAt: Date?
    var mode: String
    var hasAudio: Bool
    var userNotes: String?
    var actionItems: [(id: UUID, text: String, owner: String?, done: Bool)]
    var transcript: [(source: String, speaker: String, text: String, start: Double, end: Double)]

    enum Failure: Error, Equatable {
        case notAnObject
        case missingTitle
        case badID

        var message: String {
            switch self {
            case .notAnObject:  return "malformed meeting payload"
            case .missingTitle: return "meeting title missing"
            case .badID:        return "meeting id missing or not a UUID"
            }
        }
    }

    static func parse(_ payload: [String: Any]) -> Result<LocalMeetingUpload, Failure> {
        guard let raw = payload["meeting"] as? [String: Any] else { return .failure(.notAnObject) }
        guard let title = raw["title"] as? String, !title.isEmpty else { return .failure(.missingTitle) }
        guard let id = (raw["id"] as? String).flatMap(UUID.init(uuidString:)) else {
            return .failure(.badID)
        }

        let items = (raw["actionItems"] as? [[String: Any]] ?? []).compactMap {
            item -> (id: UUID, text: String, owner: String?, done: Bool)? in
            guard let text = item["text"] as? String, !text.isEmpty else { return nil }
            return (
                id: (item["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(),
                text: text,
                owner: item["owner"] as? String,
                done: (item["done"] as? Bool) ?? false
            )
        }

        let segments = (raw["transcript"] as? [[String: Any]] ?? []).compactMap {
            seg -> (source: String, speaker: String, text: String, start: Double, end: Double)? in
            guard let text = seg["text"] as? String else { return nil }
            return (
                source: (seg["source"] as? String) ?? "mic",
                speaker: (seg["speaker"] as? String) ?? "Me",
                text: text,
                start: (seg["startTime"] as? Double) ?? 0,
                end: (seg["endTime"] as? Double) ?? 0
            )
        }

        let notes = raw["userNotes"] as? String
        return .success(LocalMeetingUpload(
            id: id,
            title: title,
            createdAt: (raw["createdAt"] as? Double).map(Date.init(timeIntervalSince1970:)),
            endedAt: (raw["endedAt"] as? Double).map(Date.init(timeIntervalSince1970:)),
            mode: (raw["mode"] as? String) ?? "standard",
            hasAudio: (raw["hasAudio"] as? Bool) ?? false,
            userNotes: (notes?.isEmpty ?? true) ? nil : notes,
            actionItems: items,
            transcript: segments
        ))
    }
}
#endif

// MARK: - State

@MainActor
final class BridgeV2State {
    /// What this host can actually do. A client's `hello` is intersected with
    /// this, so asking for a capability that is not implemented yet (`pty`)
    /// never results in the host claiming to support it.
#if UDHA_AGENT
    static let serverCapabilities: Set<String> = ["delta", "actions", "terminal", "diff", "push",
                                                  "resize", "rename", "reorder", "stats", "attachments", "attention_events",
                                                  "folders", "accounts"]
#else
    static let serverCapabilities: Set<String> = ["delta", "actions", "terminal", "diff", "push",
                                                  "resize", "rename", "reorder", "videos", "stats", "attachments", "attention_events",
                                                  "folders", "accounts"]
#endif

    /// Reads this machine's vitals for the `stats` reply. Held here rather than
    /// built per request because CPU and network are rates: the collector needs
    /// the previous sample to have a delta to report.
    let statsCollector = SystemStatsCollector()

    /// Nil until a client completes the handshake. Nil means protocol 1:
    /// answer what is asked, push nothing.
    var capabilities: Set<String> = []
    var protocolVersion: Int = 1
    var isV2: Bool { protocolVersion >= 2 }

    /// Monotonic per connection epoch. Reset on every `hello` so a reconnecting
    /// client never sees a sequence that appears to skip.
    var seq: Int = 0

    /// Coalesced delta payload. A busy fleet repaints phases faster than a
    /// relay round-trip is worth, so changes accumulate for a window first.
    var pendingChanged: [UUID: SessionSnapshot] = [:]
    var pendingRemoved: Set<UUID> = []
    var flushTask: Task<Void, Never>?
    /// Debounces the full-snapshot push that a sidebar drag-reorder triggers.
    var reorderTask: Task<Void, Never>?

    /// The session whose pane is being forwarded as frames, if any.
    var attachedSessionID: UUID?
    /// Last frame sent, so an idle pane costs zero traffic.
    var lastFrame: String?
    var frameSeq: Int = 0
    var attachedAt: Date?
    /// The window grid as it was before the phone asked for its own size, and
    /// the session it belongs to. Restored on detach, on the streaming timeout
    /// and on disconnect — a Mac left pinned at phone width after one glance
    /// from the couch is the failure mode this exists to prevent.
    var sizeBeforeResize: (cols: Int, rows: Int)?
    var resizedSessionID: UUID?
    /// Last grid the client asked for, so a repeated request is a no-op rather
    /// than another SIGWINCH and full TUI repaint.
    var requestedSize: (cols: Int, rows: Int)?
    /// The grid frames are currently being drawn at, cached.
    ///
    /// Refreshed on attach and after each resize rather than per frame: asking
    /// tmux would mean spawning a subprocess on every capture poll, and while
    /// the phone has the window pinned to `manual` the value cannot change
    /// underneath us anyway.
    var actualSize: (cols: Int, rows: Int)?

    // MARK: - Delta coalescing

    struct Batch {
        var seq: Int
        var changed: [SessionSnapshot]
        var removed: [UUID]
    }

    /// Fold one mutation into the pending batch.
    ///
    /// Last-write-wins per id, and changed/removed are mutually exclusive for
    /// the same session: a row that was edited and then closed inside one
    /// window must arrive only as a removal, or the client would re-add a
    /// session that no longer exists.
    func enqueue(changed: SessionSnapshot?, removed: UUID?) {
        if let changed {
            pendingChanged[changed.id] = changed
            pendingRemoved.remove(changed.id)
        }
        if let removed {
            pendingRemoved.insert(removed)
            pendingChanged.removeValue(forKey: removed)
        }
    }

    /// Take the batch and advance the sequence. Nil when nothing is pending, so
    /// an idle fleet emits no traffic at all.
    func drain() -> Batch? {
        guard !pendingChanged.isEmpty || !pendingRemoved.isEmpty else { return nil }
        seq += 1
        let batch = Batch(seq: seq,
                          changed: Array(pendingChanged.values),
                          removed: Array(pendingRemoved))
        pendingChanged = [:]
        pendingRemoved = []
        return batch
    }

    /// Discard the queue without burning a sequence number — used when a full
    /// snapshot has just superseded everything pending.
    func drainWithoutSequencing() -> Bool {
        let had = !pendingChanged.isEmpty || !pendingRemoved.isEmpty
        pendingChanged = [:]
        pendingRemoved = []
        return had
    }

    /// Should this pane capture be sent? Byte-identical output means nothing
    /// changed, and an idle session must cost zero frame traffic.
    func shouldSendFrame(_ content: String) -> Bool { content != lastFrame }

    func reset() {
        capabilities = []
        protocolVersion = 1
        seq = 0
        pendingChanged = [:]
        pendingRemoved = []
        flushTask?.cancel()
        flushTask = nil
        reorderTask?.cancel()
        reorderTask = nil
        attachedSessionID = nil
        lastFrame = nil
        frameSeq = 0
        attachedAt = nil
        // Deliberately NOT cleared here: the caller restores the window first
        // and clears these itself. Wiping them in reset() would strand a
        // resized pane at phone width with nothing left recording its old size.
    }
}


// MARK: - Terminal frame text

enum TerminalFrameText {
    /// Drops trailing rows that hold nothing but blanks and escape sequences.
    ///
    /// `capture-pane` emits the full grid, so a session whose output does not
    /// reach the bottom of its pane is padded with empty rows. A row is only
    /// "blank" once its ANSI escapes are discounted — a line of pure colour
    /// codes still renders as nothing but is not an empty string.
    static func trimTrailingBlankLines(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while let last = lines.last, isBlank(last) {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    static func isBlank(_ line: String) -> Bool {
        var iterator = line.makeIterator()
        while let char = iterator.next() {
            if char == "\u{1B}" {
                guard iterator.next() == "[" else { continue }
                while let next = iterator.next() {
                    if !next.isNumber && next != ";" { break }
                }
                continue
            }
            if !char.isWhitespace { return false }
        }
        return true
    }
}
