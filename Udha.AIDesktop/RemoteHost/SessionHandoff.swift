import Foundation

/// Moves a live session from this Mac to a remote host (the dev box), keeping the
/// Claude conversation: it copies the working tree's current state and the chat
/// transcript over SSH, then asks the host to spawn a `claude --resume` session
/// in the mirrored folder. The Mac session is closed once the copy is safely on
/// the box — and even if the spawn were to fail, the transcript and files are
/// already there, so the conversation is never lost.
///
/// Assumes the host is reachable as an SSH alias of the same name (a Tailscale
/// MagicDNS name resolves anywhere), and that the working tree's parent is
/// mirrored so a sync transfers only the diff.
@MainActor
enum SessionHandoff {

    struct Plan {
        let sessionID: UUID          // Udha's id for the Mac session
        let label: String
        let macCwd: String           // absolute Mac working directory
        let claudeSessionID: String  // Claude's own session id (for --resume)
        let transcriptPath: String   // the .jsonl on the Mac
    }

    enum Failure: LocalizedError {
        case notResumable
        case ssh(String)
        var errorDescription: String? {
            switch self {
            case .notResumable:
                return "This session has no Claude conversation to move yet (it may not be a Claude session, or it started before Udha's status feed)."
            case .ssh(let m): return m
            }
        }
    }

    /// Build a handoff plan from a session's live status feed, or nil if the
    /// session has no Claude transcript to carry (non-Claude, or too new).
    static func plan(for snap: SessionSnapshot) -> Plan? {
        guard let latest = ClaudeStatusSidecar.latestTranscript(for: snap.id) else { return nil }
        return Plan(sessionID: snap.id, label: snap.label,
                    macCwd: snap.directory, claudeSessionID: latest.sessionID, transcriptPath: latest.path)
    }

    /// Copy the working tree + transcript to `host`. Returns the host-side
    /// working directory to spawn the resumed session in.
    static func stage(_ plan: Plan, toHost host: String, accounts: [ClaudeAccount]) async throws -> String {
        let macHome = NSHomeDirectory()
        let pcHome = try await run("/usr/bin/ssh", [host, "printf", "%s", "$HOME"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pcHome.isEmpty else { throw Failure.ssh("Could not read \(host)'s home directory over SSH") }

        // Map the path onto the host. Only the home prefix differs on a mirror.
        let pcCwd = plan.macCwd.hasPrefix(macHome)
            ? pcHome + String(plan.macCwd.dropFirst(macHome.count))
            : plan.macCwd

        // 1. Sync the working tree (diff only; no --delete, so host-only files stay).
        let rsync = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/rsync") ? "/opt/homebrew/bin/rsync" : "/usr/bin/rsync"
        _ = try await run(rsync, [
            "-az", "-s", "-e", "ssh",     // -s: send the remote path literally, so spaces are fine
            "--exclude", "node_modules", "--exclude", ".venv", "--exclude", "venv",
            "--exclude", ".next", "--exclude", ".turbo", "--exclude", "__pycache__",
            "--exclude", ".DS_Store", "--exclude", "target/",
            plan.macCwd + "/", "\(host):\(pcCwd)/",
        ])

        // 2. Place the transcript where the host's Claude will look. A tree with
        //    its own Claude login (`ClaudeAccount`) keeps that config dir on both
        //    machines, so the transcript must land there too — resolve the dir
        //    against the Mac path, then move it under the host's home.
        let macConfig = ClaudeAccount.configDir(for: plan.macCwd, accounts: accounts) ?? macHome + "/.claude"
        let pcConfig = macConfig.hasPrefix(macHome)
            ? pcHome + String(macConfig.dropFirst(macHome.count))
            : macConfig
        let escaped = String(pcCwd.map { ($0 == "/" || $0 == ".") ? "-" : $0 })
        let destDir = "\(pcConfig)/projects/\(escaped)"
        _ = try await run("/usr/bin/ssh", [host, "mkdir", "-p", shellQuote(destDir)])
        _ = try await run(rsync, ["-a", "-s", "-e", "ssh",
                                  plan.transcriptPath,
                                  "\(host):\(destDir)/\(plan.claudeSessionID).jsonl"])

        return pcCwd
    }

    // MARK: - Process helper

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            let out = Pipe(); let err = Pipe()
            p.standardOutput = out; p.standardError = err
            p.terminationHandler = { proc in
                let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    cont.resume(returning: o)
                } else {
                    cont.resume(throwing: Failure.ssh("\((tool as NSString).lastPathComponent) failed: \(e.isEmpty ? o : e)"))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: Failure.ssh("could not run \(tool): \(error.localizedDescription)")) }
        }
    }

    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
