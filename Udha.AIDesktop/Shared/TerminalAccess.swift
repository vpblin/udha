import Foundation
import AppKit
import Observation

/// Detects and recovers the macOS Automation (Apple Events) grant that lets Udha
/// drive Terminal.app. A denied grant surfaces as osascript error **-1743**
/// ("Not authorized to send Apple events") and is the mechanism behind
/// "click-to-focus / new-session silently stopped working" — tmux still runs, but
/// every Terminal command is refused with no visible error.
///
/// macOS deliberately forbids an app from granting itself this permission (a
/// security boundary — there will always be one "Allow" click). What we CAN do is
/// reset our own *stale* grant and re-issue an Apple Event, which makes macOS show
/// the Allow prompt again. That turns "broken forever, looks like a bug" into
/// "a dialog pops up, click Allow."
@MainActor
@Observable
final class TerminalAccess {
    enum Status: Equatable { case unknown, ok, denied, repairing }

    private(set) var status: Status = .unknown
    private(set) var lastCheckedAt: Date?

    private let bundleID: String
    private var didAutoRepairThisLaunch = false

    init() {
        self.bundleID = Bundle.main.bundleIdentifier ?? "udha"
    }

    /// Startup entry point: probe Terminal access and, if it's been revoked,
    /// attempt ONE automatic repair this launch (reset our grant + re-issue an
    /// Apple Event so macOS re-prompts). Never resets a working grant.
    func checkAndAutoRepair() {
        Task { await runCheck(autoRepair: true) }
    }

    /// User-triggered from Settings — always resets and re-prompts.
    func repairNow() {
        Task { await forceRepair() }
    }

    /// Opens System Settings → Privacy & Security → Automation as a manual
    /// fallback when an automatic re-prompt doesn't take (e.g. macOS suppresses
    /// the dialog and the grant must be toggled by hand).
    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private func runCheck(autoRepair: Bool) async {
        let result = await Self.probe()
        apply(result)
        if result == .ok {
            Log.pty.info("TerminalAccess: Terminal control OK at startup")
        }
        guard result == .denied, autoRepair, !didAutoRepairThisLaunch else { return }
        didAutoRepairThisLaunch = true
        Log.pty.error("TerminalAccess: Terminal control denied (-1743) at startup — auto-repairing")
        await forceRepair()
    }

    private func forceRepair() async {
        status = .repairing
        Log.pty.info("TerminalAccess: resetting AppleEvents grant for \(bundleID) and re-prompting")
        await Self.resetGrant(bundleID: bundleID)
        // The first Apple Event after a reset triggers the macOS Allow prompt and
        // blocks until the user responds — that's why probe() runs off-main.
        let after = await Self.probe()
        apply(after)
        if after == .ok {
            Log.pty.info("TerminalAccess: repair succeeded — Terminal control restored")
        } else {
            Log.pty.error("TerminalAccess: still denied after repair — relaunch Udha or grant access in System Settings → Privacy & Security → Automation")
        }
    }

    private func apply(_ s: Status) {
        lastCheckedAt = Date()
        // .unknown (e.g. Terminal transiently unavailable) shouldn't clobber a
        // known-good/known-bad status with a misleading value.
        guard s == .ok || s == .denied else { return }
        status = s
    }

    // MARK: - Background-safe primitives (no main-actor state)

    /// Issues a harmless Apple Event to Terminal and classifies the outcome.
    /// Runs off the main actor because a pending TCC prompt blocks the event
    /// until the user responds.
    nonisolated private static func probe() async -> Status {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", "tell application \"Terminal\" to count windows"]
                let err = Pipe(); let out = Pipe()
                p.standardError = err; p.standardOutput = out
                do { try p.run(); p.waitUntilExit() } catch {
                    cont.resume(returning: .unknown); return
                }
                let errText = String(
                    data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
                ) ?? ""
                if p.terminationStatus == 0 {
                    cont.resume(returning: .ok)
                } else if errText.contains("-1743")
                    || errText.localizedCaseInsensitiveContains("Not authorized to send Apple events") {
                    cont.resume(returning: .denied)
                } else {
                    // Other failures (Terminal not running, AppleScript syntax)
                    // aren't a permission problem — don't trip the repair path.
                    cont.resume(returning: .unknown)
                }
            }
        }
    }

    /// Clears our own Automation grant so the next Apple Event re-prompts.
    /// Resetting one's OWN bundle id needs no elevated privilege.
    nonisolated private static func resetGrant(bundleID: String) async {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                p.arguments = ["reset", "AppleEvents", bundleID]
                p.standardOutput = Pipe(); p.standardError = Pipe()
                try? p.run()
                p.waitUntilExit()
                cont.resume(returning: ())
            }
        }
    }
}
