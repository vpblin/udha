import Foundation
import IOKit.pwr_mgt

/// Wraps `IOPMAssertionCreateWithName` so toggling the "keep my Mac awake"
/// setting just creates / releases a real power assertion. Same mechanism
/// `caffeinate` uses; visible via `pmset -g assertions`. No fake input.
@MainActor
@Observable
final class AwakeManager {
    private(set) var isActive: Bool = false
    private(set) var includesDisplay: Bool = false
    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)

    func apply(_ cfg: AwakeConfig) {
        if cfg.keepSystemAwake {
            engage(includeDisplay: cfg.keepDisplayAwake)
        } else {
            release()
        }
    }

    /// Idempotent: if the requested mode matches the active assertion, no-op.
    /// Otherwise release the old one and create a fresh assertion of the new
    /// type — IOPM doesn't let you mutate an existing assertion's type.
    private func engage(includeDisplay: Bool) {
        if isActive && includesDisplay == includeDisplay { return }
        release()
        let type = includeDisplay
            ? kIOPMAssertionTypePreventUserIdleDisplaySleep
            : kIOPMAssertionTypePreventUserIdleSystemSleep
        let reason = "Udha is keeping your Mac awake" as CFString
        var newID: IOPMAssertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &newID
        )
        if result == kIOReturnSuccess {
            assertionID = newID
            isActive = true
            includesDisplay = includeDisplay
            Log.app.info("AwakeManager: assertion created (display=\(includeDisplay))")
        } else {
            isActive = false
            Log.app.error("AwakeManager: IOPMAssertionCreateWithName failed (\(result))")
        }
    }

    private func release() {
        guard assertionID != IOPMAssertionID(0) else {
            isActive = false
            return
        }
        let result = IOPMAssertionRelease(assertionID)
        if result != kIOReturnSuccess {
            Log.app.error("AwakeManager: IOPMAssertionRelease failed (\(result))")
        } else {
            Log.app.info("AwakeManager: assertion released")
        }
        assertionID = IOPMAssertionID(0)
        isActive = false
        includesDisplay = false
    }

    func shutdown() {
        release()
    }
}
