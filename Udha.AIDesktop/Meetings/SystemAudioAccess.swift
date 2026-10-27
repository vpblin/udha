import Foundation
import AppKit
import Darwin
import Observation

/// TerminalAccess analogue for the "System Audio Recording" TCC grant the
/// meeting recorder's process tap needs.
///
/// The hard-won facts this class encodes:
/// - Creating a process tap NEVER prompts and NEVER fails on denial — an
///   unauthorized tap just captures pure silence. So tap creation is useless
///   as a probe and worse than useless as a prompt trigger.
/// - There is no public request API for this permission (macOS 15). The
///   prompt is raised via the TCC framework's TCCAccessRequest for
///   kTCCServiceAudioCapture — the same approach AudioCap uses. Sandbox is
///   off and this is not an App Store build, so the private call is
///   acceptable here.
/// - Denial is sticky: once recorded, no prompt ever fires again until
///   `tccutil reset AudioCapture <bundleID>` — hence the TerminalAccess-style
///   auto-repair (once per launch, only on the meeting-start path).
@MainActor
@Observable
final class SystemAudioAccess {
    enum Status: Equatable { case unknown, ok, denied, repairing }

    private(set) var status: Status = .unknown
    private(set) var lastCheckedAt: Date?

    private let bundleID: String
    private var didAutoRepairThisLaunch = false

    init() {
        self.bundleID = Bundle.main.bundleIdentifier ?? "udha"
    }

    /// Passive status read (no prompt) — safe for Settings to call anytime.
    func check() {
        guard let tcc = Self.tcc else { return }
        apply(preflight: tcc.preflight(Self.service, nil))
    }

    /// Called at meeting start. Prompts when the user has never been asked;
    /// on a recorded denial, resets our own grant once per launch so the
    /// prompt can fire again (the TerminalAccess pattern).
    @discardableResult
    func requestAccess() async -> Bool {
        guard let tcc = Self.tcc else {
            // SPI unavailable (future macOS?): don't block recording on it.
            Log.meeting.error("SystemAudioAccess: TCC functions unavailable — assuming granted")
            status = .ok
            return true
        }
        switch tcc.preflight(Self.service, nil) {
        case 0:
            apply(preflight: 0)
            return true
        case 2:
            if !didAutoRepairThisLaunch {
                didAutoRepairThisLaunch = true
                Log.meeting.info("SystemAudioAccess: denied — resetting grant and re-prompting")
                status = .repairing
                await Self.resetGrant(bundleID: bundleID)
                return await promptNow(tcc)
            }
            apply(preflight: 2)
            return false
        default:
            return await promptNow(tcc)
        }
    }

    /// User-triggered from Settings: always reset + re-prompt.
    func repairNow() {
        guard let tcc = Self.tcc else { return }
        Task {
            status = .repairing
            await Self.resetGrant(bundleID: bundleID)
            _ = await promptNow(tcc)
        }
    }

    /// System Settings → Privacy & Security → Screen & System Audio Recording.
    func openSystemAudioSettings() {
        let anchors = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        ]
        for anchor in anchors {
            if let url = URL(string: anchor), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    // MARK: - Internals

    private func promptNow(_ tcc: TCCFunctions) async -> Bool {
        let granted = await withCheckedContinuation { cont in
            tcc.request(Self.service, nil) { granted in
                cont.resume(returning: granted)
            }
        }
        lastCheckedAt = Date()
        status = granted ? .ok : .denied
        Log.meeting.info("SystemAudioAccess: prompt result granted=\(granted)")
        return granted
    }

    private func apply(preflight: Int32) {
        lastCheckedAt = Date()
        switch preflight {
        case 0: status = .ok
        case 2: status = .denied
        default: status = .unknown
        }
    }

    private struct TCCFunctions {
        let preflight: @convention(c) (CFString, CFDictionary?) -> Int32
        let request: @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void
    }

    private static let service = "kTCCServiceAudioCapture" as CFString

    private static let tcc: TCCFunctions? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let preflightSym = dlsym(handle, "TCCAccessPreflight"),
              let requestSym = dlsym(handle, "TCCAccessRequest") else {
            return nil
        }
        return TCCFunctions(
            preflight: unsafeBitCast(preflightSym, to: (@convention(c) (CFString, CFDictionary?) -> Int32).self),
            request: unsafeBitCast(requestSym, to: (@convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void).self)
        )
    }()

    nonisolated private static func resetGrant(bundleID: String) async {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                p.arguments = ["reset", "AudioCapture", bundleID]
                p.standardOutput = Pipe(); p.standardError = Pipe()
                try? p.run()
                p.waitUntilExit()
                cont.resume(returning: ())
            }
        }
    }
}
