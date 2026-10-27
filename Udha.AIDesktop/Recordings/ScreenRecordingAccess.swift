import Foundation
import AppKit
import CoreGraphics
import Observation

/// SystemAudioAccess analogue for the Screen Recording TCC grant that
/// ScreenCaptureKit needs.
///
/// The differences from the system-audio gate, all of which matter:
/// - **No private SPI needed.** `CGPreflightScreenCaptureAccess` and
///   `CGRequestScreenCaptureAccess` are public, unlike kTCCServiceAudioCapture
///   which has no public request API. No dlopen here.
/// - **The prompt does not gate the call.** `CGRequestScreenCaptureAccess()`
///   returns the *current* answer immediately and raises the prompt as a side
///   effect — it does not wait for the user. So a `false` right after
///   prompting means "not yet", not "denied forever", and the status settles
///   on a later `check()`.
/// - **A fresh grant almost never bites until relaunch.** TCC hands screen
///   capture to a process at launch; an already-running app keeps getting
///   black frames after the user flips the switch. `needsRelaunchAfterGrant`
///   lets Settings offer `AppRelaunch.restart()` rather than letting
///   "granted but still black" read as an app bug.
/// - **Denial is sticky**, same as every other TCC service: once recorded, no
///   prompt fires again until `tccutil reset ScreenCapture <bundleID>`. Hence
///   the same once-per-launch auto-repair on the record path.
@MainActor
@Observable
final class ScreenRecordingAccess {
    enum Status: Equatable { case unknown, ok, denied, repairing }

    private(set) var status: Status = .unknown
    private(set) var lastCheckedAt: Date?
    private(set) var needsRelaunchAfterGrant = false
    /// A prompt has been raised (or a denial is on record) and this process
    /// cannot capture until it relaunches. Drives the Settings copy.
    private(set) var awaitingDecision = false

    private let bundleID: String
    private var didAutoRepairThisLaunch = false
    private var wasDenied = false

    init() {
        self.bundleID = Bundle.main.bundleIdentifier ?? "udha"
    }

    /// Passive status read (never prompts) — safe for Settings to call anytime.
    func check() {
        apply(granted: CGPreflightScreenCaptureAccess())
    }

    /// Called on the record path.
    ///
    /// Deliberately does **not** reset the grant on failure, which is where an
    /// earlier version of this went wrong. Resetting and immediately
    /// re-requesting in the same process raises no prompt at all: the reset
    /// clears tccd's record, but this process's screen-capture authorization
    /// was already bound at launch, so the follow-up request just reports the
    /// cached answer. The observable result was a silent no-op — no dialog, no
    /// access, and a log line claiming it had re-prompted.
    ///
    /// So the honest split is: `requestAccess` raises the *system* prompt and
    /// reports what it knows, and un-sticking a recorded denial is `repairNow`,
    /// which resets and then requires a relaunch.
    @discardableResult
    func requestAccess() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            apply(granted: true)
            return true
        }
        // Raises the prompt when TCC holds no record, and returns the answer as
        // it stands *right now* — which is false while the dialog is still on
        // screen, and also false on a recorded denial. From inside the process
        // those two are indistinguishable, so both land on `awaitingDecision`
        // and the UI offers the same two ways out: answer the prompt, or repair.
        let granted = CGRequestScreenCaptureAccess()
        apply(granted: granted)
        if !granted {
            awaitingDecision = true
            Log.recording.info("ScreenRecordingAccess: no access — prompt raised or denial on record; relaunch needed once granted")
        }
        return granted
    }

    /// User-triggered from Settings: clears a recorded denial so the next
    /// launch can prompt cleanly. Cannot itself re-prompt — see `requestAccess`
    /// — so it flags the relaunch the caller has to offer.
    func repairNow() {
        Task {
            status = .repairing
            await Self.resetGrant(bundleID: bundleID)
            didAutoRepairThisLaunch = true
            awaitingDecision = true
            needsRelaunchAfterGrant = true
            status = .denied
            Log.recording.info("ScreenRecordingAccess: grant reset — relaunch required before the prompt can fire")
        }
    }

    /// System Settings → Privacy & Security → Screen & System Audio Recording.
    func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Internals

    private func apply(granted: Bool) {
        lastCheckedAt = Date()
        if granted, wasDenied {
            // The grant appeared during this run, so this process is still
            // running under the old (denied) decision and will capture black.
            needsRelaunchAfterGrant = true
        }
        wasDenied = !granted
        status = granted ? .ok : .denied
    }

    nonisolated private static func resetGrant(bundleID: String) async {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                p.arguments = ["reset", "ScreenCapture", bundleID]
                p.standardOutput = Pipe(); p.standardError = Pipe()
                try? p.run()
                p.waitUntilExit()
                cont.resume(returning: ())
            }
        }
    }
}
