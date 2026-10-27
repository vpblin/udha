import Foundation
import AppKit
import ApplicationServices
import IOKit.hid
import Observation

/// Detects and recovers the Accessibility (and Input Monitoring) grants the
/// input lock's CGEventTap needs. Sibling of `TerminalAccess`, with two
/// deliberate differences:
///
/// - `AXIsProcessTrusted()` is cheap and synchronous — no subprocess, no
///   off-main hop, so probing is direct.
/// - **No auto-repair at startup.** Resetting a merely-unused Accessibility
///   grant would nag on every launch. Repair runs only from Settings, or on
///   the stale-grant fingerprint: `AXIsProcessTrusted() == true` while
///   `CGEvent.tapCreate` returns nil. That combination is what a `/tmp`-swept
///   Debug bundle leaves behind (TCC keys the grant to the bundle path).
///
/// Relaunch caveat: unlike Apple Events, a fresh Accessibility grant often
/// doesn't take effect until the process restarts — `needsRelaunchAfterGrant`
/// lets Settings offer `AppRelaunch.restart()` with an explanation, otherwise
/// "granted but still broken" reads as an app bug.
@MainActor
@Observable
final class AccessibilityAccess {
    enum Status: Equatable { case unknown, ok, denied, repairing }

    private(set) var status: Status = .unknown
    private(set) var inputMonitoring: Status = .unknown
    private(set) var lastCheckedAt: Date?
    private(set) var needsRelaunchAfterGrant = false

    private let bundleID: String
    private var didAutoRepairThisLaunch = false
    private var wasDenied = false

    init() {
        self.bundleID = Bundle.main.bundleIdentifier ?? "udha"
    }

    var isTrusted: Bool { AXIsProcessTrusted() }

    /// Cheap synchronous probe; safe to call from anywhere on the main actor.
    func check() {
        lastCheckedAt = Date()
        let trusted = AXIsProcessTrusted()
        if trusted, wasDenied {
            // Grant appeared during this run — it may not bite until relaunch.
            needsRelaunchAfterGrant = true
        }
        wasDenied = !trusted
        status = trusted ? .ok : .denied

        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: inputMonitoring = .ok
        case kIOHIDAccessTypeDenied: inputMonitoring = .denied
        default: inputMonitoring = .unknown
        }
        Log.lock.info("AccessibilityAccess: ax=\(status) inputMonitoring=\(inputMonitoring)")
    }

    /// Raises the system Accessibility prompt (only shows once per TCC state).
    func promptForAccess() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        check()
    }

    /// Raises the Input Monitoring prompt if undecided.
    func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        check()
    }

    /// User-triggered from Settings, or invoked once per launch on the
    /// stale-grant fingerprint (trusted but tapCreate == nil).
    func repairNow() {
        Task { await forceRepair() }
    }

    /// Called by InputLockManager when `AXIsProcessTrusted()` is true but the
    /// tap refused to create — the stale-grant fingerprint. One shot per launch.
    func repairStaleGrantIfNeeded() {
        guard !didAutoRepairThisLaunch else { return }
        didAutoRepairThisLaunch = true
        Log.lock.error("AccessibilityAccess: trusted but tapCreate failed — stale TCC grant, auto-repairing")
        Task { await forceRepair() }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    private func forceRepair() async {
        status = .repairing
        Log.lock.info("AccessibilityAccess: resetting Accessibility grant for \(bundleID) and re-prompting")
        await Self.resetGrant(bundleID: bundleID)
        promptForAccess()
        if status != .ok {
            Log.lock.error("AccessibilityAccess: still denied after repair — grant in System Settings → Privacy & Security → Accessibility, then relaunch Udha")
        }
    }

    /// Clears our own Accessibility grant so the next check re-prompts.
    /// Resetting one's OWN bundle id needs no elevated privilege.
    nonisolated private static func resetGrant(bundleID: String) async {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                p.arguments = ["reset", "Accessibility", bundleID]
                p.standardOutput = Pipe(); p.standardError = Pipe()
                try? p.run()
                p.waitUntilExit()
                cont.resume(returning: ())
            }
        }
    }
}
