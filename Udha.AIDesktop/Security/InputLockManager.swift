import Foundation
import AppKit
import CoreGraphics
import IOKit.pwr_mgt
import LocalAuthentication
import Observation

/// The input lock: keyboard + mouse dead (session event tap), screen kept on,
/// Touch ID / password to unlock. A hotel-room deterrent, not kiosk mode —
/// macOS reserves ⌃⌘Q, the power button, Touch ID and force-restart below the
/// event-tap layer, and a SIGKILLed Udha releases the tap (the kernel reclaims
/// the mach port on process death), so the lock can never outlive the process.
///
/// Design rule throughout: **refuse loudly, never pretend.** Every path that
/// can't guarantee a real lock lands in `.failed(reason)`, which is sticky and
/// visibly red — a chip that says "locked" over live input is the one
/// unacceptable failure mode.
@MainActor
@Observable
final class InputLockManager {

    enum LockState: Equatable {
        case unlocked
        case locking
        case locked(degraded: Degradation?)
        case authenticating(passthrough: Bool)
        case unlocking
        case failed(Failure)

        var isFailed: Bool { if case .failed = self { return true }; return false }
    }

    enum Degradation: Equatable {
        /// Another app holds Secure Keyboard Entry: taps can't see the keyboard,
        /// so only the mouse is actually dead.
        case secureInputKeyboardLive(app: String?)
    }

    enum Failure: Equatable {
        case accessibilityDenied
        case tapCreateFailed          // trusted but tapCreate == nil → stale TCC grant
        case secureInputActive(app: String?)
        case noDeviceOwnerAuth        // no account password / LA unavailable
        case tapLostWhileLocked       // the loud one — input is live again

        var message: String {
            switch self {
            case .accessibilityDenied: return "Accessibility permission missing"
            case .tapCreateFailed: return "macOS refused the event tap (stale permission — repair in Settings)"
            case .secureInputActive(let app): return "\(app ?? "An app") has Secure Keyboard Entry on"
            case .noDeviceOwnerAuth: return "No way to unlock (no account password?)"
            case .tapLostWhileLocked: return "Lock failed — input is live"
            }
        }
    }

    enum LockSource: String { case menu, hotkey, autoIdle, test }
    enum UnlockReason: String { case authenticated, testExpired, cannotAuthenticate, disabled, shutdown }

    // MARK: - Observable state

    private(set) var state: LockState = .unlocked
    /// Deadline of the password-fallback passthrough window (chip countdown).
    private(set) var passthroughDeadline: Date?
    /// Non-nil while a lock() attempt or the last one failed — menu bar shows it.
    var lastFailure: Failure? { if case .failed(let f) = state { return f }; return nil }
    var isEngaged: Bool {
        switch state {
        case .locking, .locked, .authenticating: return true
        default: return false
        }
    }
    var currentIdleSeconds: Double { SystemInputState.idleSeconds() }

    // MARK: - Wiring

    private let accessibility: AccessibilityAccess
    private let config: ConfigStore
    private var cfg: InputLockConfig { config.config.inputLock }

    @ObservationIgnored private lazy var tap = InputLockTap { [weak self] signal in
        Task { @MainActor in self?.handleTapSignal(signal) }
    }
    @ObservationIgnored private lazy var chip = LockChipController(manager: self, config: config)
    @ObservationIgnored private lazy var curtain = LockCurtainController(manager: self)

    private var lockHotkey: GlobalHotkey?
    private var appliedHotkeyBinding: HotkeyBinding?
    private(set) var hotkeyError: String?

    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var authContext: LAContext?
    private var authCooldownUntil: Date = .distantPast
    private var consecutiveFailures = 0

    private var heartbeat: Timer?
    private var idleTimer: Timer?
    private var autoUnlockTimer: Timer?
    private var fallbackGraceTimer: Timer?
    private var fallbackWatchdogTimer: Timer?
    private var lastWakeAt: Date = .distantPast
    private var wakeObservers: [NSObjectProtocol] = []

    init(accessibility: AccessibilityAccess, config: ConfigStore) {
        // Inert by design — no tap, no hotkey, no timer until apply()/lock().
        self.accessibility = accessibility
        self.config = config
    }

    // MARK: - Config

    /// Idempotent, mirrors AwakeManager.apply. Never engages or disengages the
    /// lock as a side effect of a config change.
    func apply(_ c: InputLockConfig) {
        // Hotkey: (re)register only when enablement or binding changed.
        let wantHotkey = c.enabled && c.lockHotkeyEnabled
        if !wantHotkey {
            lockHotkey?.unregister()
            lockHotkey = nil
            appliedHotkeyBinding = nil
        } else if lockHotkey == nil || appliedHotkeyBinding != c.lockHotkey {
            lockHotkey?.unregister()
            lockHotkey = nil
            do {
                lockHotkey = try GlobalHotkey(binding: c.lockHotkey) { [weak self] in
                    self?.lock(source: .hotkey)
                }
                appliedHotkeyBinding = c.lockHotkey
                hotkeyError = nil
            } catch GlobalHotkey.RegisterError.alreadyTaken {
                hotkeyError = "\(c.lockHotkey.displayString) is taken by another app"
                Log.lock.error("InputLockManager: hotkey \(c.lockHotkey.displayString) already taken")
            } catch {
                hotkeyError = "Hotkey registration failed"
                Log.lock.error("InputLockManager: hotkey registration failed: \(error)")
            }
        }

        restartIdleTimerIfNeeded()

        // Curtain / chip visibility change while locked. The curtain carries
        // the lock messaging, so the chip is redundant while it's up.
        if isEngaged {
            if c.hideScreen {
                curtain.present()
                chip.dismiss()
            } else {
                curtain.dismiss()
                c.showChip ? chip.present() : chip.dismiss()
            }
        }
    }

    func start() {
        installWakeObservers()
        restartIdleTimerIfNeeded()
    }

    func shutdown() {
        // Unlock unconditionally before anything else in AppCore.shutdown()
        // can fail — a live tap must never outlast a clean quit.
        if state != .unlocked { finishUnlock(reason: .shutdown) }
        lockHotkey?.unregister()
        lockHotkey = nil
        idleTimer?.invalidate(); idleTimer = nil
        for o in wakeObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        wakeObservers = []
    }

    // MARK: - Lock

    func lock(source: LockSource, autoUnlockAfter: TimeInterval? = nil) {
        guard cfg.enabled || source == .test else { return }
        switch state {
        case .unlocked, .failed: break
        default: return // already engaged or mid-transition
        }

        // Preflight 1: Accessibility — cheap and synchronous.
        accessibility.check()
        guard accessibility.isTrusted else { fail(.accessibilityDenied); return }

        // Preflight 2: a way back in. With no account password LocalAuthentication
        // can never succeed and locking would strand the Mac.
        var laErr: NSError?
        guard LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &laErr) else {
            Log.lock.error("InputLockManager: canEvaluatePolicy failed (\(laErr?.code ?? 0))")
            fail(.noDeviceOwnerAuth); return
        }

        // Preflight 3: Secure Keyboard Entry. While any process holds it,
        // keyboard events bypass every tap — we'd lock the mouse and leave the
        // keyboard wide open. Terminal's menu item is the usual culprit.
        if let holder = SystemInputState.secureInputHolder(), !cfg.allowLockWithSecureInput {
            fail(.secureInputActive(app: holder.appName)); return
        }

        state = .locking
        Log.lock.info("InputLockManager: locking (source=\(source.rawValue))")
        tap.arm { [weak self] armed in
            Task { @MainActor in
                guard let self, self.state == .locking else { return }
                if armed {
                    self.finishLock(autoUnlockAfter: autoUnlockAfter)
                } else {
                    // Trusted but refused = the stale-TCC fingerprint.
                    self.accessibility.repairStaleGrantIfNeeded()
                    self.fail(.tapCreateFailed)
                }
            }
        }
    }

    private func finishLock(autoUnlockAfter: TimeInterval?) {
        holdDisplayAssertion()
        if cfg.hideScreen {
            curtain.present()
        } else if cfg.showChip {
            chip.present()
        }
        idleTimer?.invalidate(); idleTimer = nil
        startHeartbeat()
        state = .locked(degraded: currentDegradation())
        Log.lock.info("InputLockManager: locked")

        if let after = autoUnlockAfter {
            // Test mode: auth-free timed release, immune to input state by
            // construction — the safety net that makes the lock testable.
            autoUnlockTimer?.invalidate()
            autoUnlockTimer = Timer.scheduledTimer(withTimeInterval: after, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.finishUnlock(reason: .testExpired) }
            }
        }
    }

    /// Settings' "Test lock (5 seconds)" — verify input is genuinely dead with
    /// zero lockout risk before trusting this in a hotel.
    func testLock(seconds: TimeInterval = 5) {
        lock(source: .test, autoUnlockAfter: seconds)
    }

    // MARK: - Unlock

    private func finishUnlock(reason: UnlockReason) {
        state = .unlocking
        cancelFallbackTimers()
        autoUnlockTimer?.invalidate(); autoUnlockTimer = nil
        heartbeat?.invalidate(); heartbeat = nil
        authContext?.invalidate(); authContext = nil
        tap.setMode(.swallow)
        tap.disarm()
        releaseDisplayAssertion()
        chip.dismiss()
        curtain.dismiss()
        passthroughDeadline = nil
        consecutiveFailures = 0
        authCooldownUntil = .distantPast
        state = .unlocked
        restartIdleTimerIfNeeded()
        Log.lock.info("InputLockManager: unlocked (\(reason.rawValue))")
    }

    // MARK: - Tap signals

    private func handleTapSignal(_ signal: InputLockTap.Signal) {
        switch signal {
        case .reEnabled(let timeout):
            Log.lock.info("InputLockManager: tap was disabled by \(timeout ? "timeout" : "user input") — re-enabled")
        case .userIntent:
            guard case .locked = state else { return }
            guard autoUnlockTimer == nil else { return } // test lock: no auth prompt
            beginAuthentication()
        }
    }

    // MARK: - Authentication

    private func beginAuthentication() {
        guard case .locked = state, Date() >= authCooldownUntil else { return }

        let context = LAContext()
        context.localizedCancelTitle = "Stay locked"
        var err: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            // Nothing can ever unlock this. Releasing beats trapping the Mac.
            Log.lock.error("InputLockManager: canEvaluatePolicy failed mid-lock (\(err?.code ?? 0)) — releasing")
            finishUnlock(reason: .cannotAuthenticate)
            return
        }

        authContext = context
        state = .authenticating(passthrough: false)
        // Drop the curtain below the system dialog's level so the Touch ID
        // prompt / password sheet is visible above the frost.
        curtain.setAuthPresentation(lowered: true)
        scheduleFallbackPassthrough()

        context.evaluatePolicy(.deviceOwnerAuthentication,
                               localizedReason: "unlock this Mac's keyboard and mouse") { [weak self] ok, error in
            // LocalAuthentication calls back on a private queue.
            Task { @MainActor in self?.handleAuthResult(success: ok, error: error) }
        }
    }

    /// Touch ID needs no input at all (out-of-band sensor — the tap stays fully
    /// armed and the hole is zero). The password sheet does need keyboard and
    /// mouse, so if auth hasn't resolved after a short grace the user is
    /// presumably reaching for "Enter Password": open a bounded passthrough
    /// window, visibly counted down on the chip, and slam it shut on a watchdog.
    private func scheduleFallbackPassthrough() {
        guard cfg.allowPasswordFallback else { return }
        let grace = TimeInterval(cfg.passwordFallbackGraceSeconds)
        let window = TimeInterval(cfg.passwordFallbackWindowSeconds)

        fallbackGraceTimer = Timer.scheduledTimer(withTimeInterval: grace, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, case .authenticating(false) = self.state else { return }
                self.tap.setMode(.passthrough)
                self.passthroughDeadline = Date().addingTimeInterval(window)
                self.state = .authenticating(passthrough: true)
                Log.lock.info("InputLockManager: passthrough open for password entry (\(Int(window))s)")
            }
        }
        fallbackWatchdogTimer = Timer.scheduledTimer(withTimeInterval: grace + window, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, case .authenticating = self.state else { return }
                // Order matters: re-swallow FIRST, then cancel the sheet —
                // invalidating first leaves a beat of live input with no dialog.
                self.tap.setMode(.swallow)
                self.authContext?.invalidate() // completion fires with LAError.appCancel
                Log.lock.info("InputLockManager: passthrough watchdog fired — re-locked")
            }
        }
    }

    private func cancelFallbackTimers() {
        fallbackGraceTimer?.invalidate(); fallbackGraceTimer = nil
        fallbackWatchdogTimer?.invalidate(); fallbackWatchdogTimer = nil
    }

    private func handleAuthResult(success: Bool, error: Error?) {
        cancelFallbackTimers()
        passthroughDeadline = nil
        authContext = nil
        guard case .authenticating = state else { return }

        if success {
            finishUnlock(reason: .authenticated)
            return
        }

        tap.setMode(.swallow) // re-arm before anything else
        consecutiveFailures += 1
        let code = (error as? NSError)?.code ?? 0
        let base: TimeInterval
        switch LAError.Code(rawValue: code) {
        case .userCancel, .appCancel, .systemCancel: base = 2
        case .biometryLockout: base = 5 // password is the only path now
        default: base = 3
        }
        // Escalate hard after repeated attempts so nobody can farm fallback windows.
        authCooldownUntil = Date().addingTimeInterval(consecutiveFailures >= 5 ? max(base, 30) : base)
        state = .locked(degraded: currentDegradation())
        curtain.setAuthPresentation(lowered: false) // dialog gone — full cover again
        Log.lock.info("InputLockManager: auth failed (LAError \(code)) — re-locked, cooldown \(Int(base))s, failures \(consecutiveFailures)")
    }

    // MARK: - Health

    private func startHeartbeat() {
        heartbeat?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.verifyTapHealth() }
        }
        t.tolerance = 1
        heartbeat = t
    }

    private func verifyTapHealth() {
        switch state {
        case .locked, .authenticating: break
        default: return
        }

        // Secure input flipping on mid-lock: degrade the chip, never auto-unlock
        // (that would make Terminal's menu item a one-click bypass).
        if case .locked = state {
            state = .locked(degraded: currentDegradation())
        }

        if tap.isHealthy() { return }
        if tap.reEnableIfNeeded() {
            Log.lock.info("InputLockManager: tap re-enabled by heartbeat")
            return
        }
        // Rebuild from scratch. If that fails too, say so — never quietly pretend.
        tap.arm(quietFor: 0) { [weak self] armed in
            Task { @MainActor in
                guard let self, self.isEngaged else { return }
                if armed {
                    Log.lock.info("InputLockManager: tap rebuilt")
                } else {
                    self.fail(.tapLostWhileLocked)
                }
            }
        }
    }

    private func installWakeObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ]
        for name in names {
            wakeObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.lastWakeAt = Date()
                    self.verifyTapHealth()
                }
            })
        }
    }

    // MARK: - Auto-lock

    private func restartIdleTimerIfNeeded() {
        idleTimer?.invalidate(); idleTimer = nil
        guard cfg.enabled, cfg.autoLockMinutes > 0, state == .unlocked || state.isFailed else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autoLockTick() }
        }
        t.tolerance = 5
        idleTimer = t
    }

    private func autoLockTick() {
        guard cfg.enabled, cfg.autoLockMinutes > 0, state == .unlocked else { return }
        // Post-wake debounce: idle counters can read huge right after wake, and
        // the user may just have typed their login password — don't double-prompt.
        guard Date().timeIntervalSince(lastWakeAt) > 30 else { return }
        guard SystemInputState.isOnConsole(), !SystemInputState.isScreenLocked() else { return }
        guard SystemInputState.idleSeconds() >= Double(cfg.autoLockMinutes * 60) else { return }
        Log.lock.info("InputLockManager: auto-locking after \(cfg.autoLockMinutes)m idle")
        lock(source: .autoIdle)
    }

    // MARK: - Failure

    private func fail(_ f: Failure) {
        cancelFallbackTimers()
        autoUnlockTimer?.invalidate(); autoUnlockTimer = nil
        heartbeat?.invalidate(); heartbeat = nil
        releaseDisplayAssertion()
        passthroughDeadline = nil
        // Sticky and loud: a failed lock must never look like a locked one. If
        // the chip is up (failure mid-lock), it turns red; preflight failures
        // surface in the menu bar and Settings instead.
        state = .failed(f)
        // Input is live on any failure — never leave the screen hidden while
        // the user could be blindly clicking through an invisible desktop.
        curtain.dismiss()
        if case .tapLostWhileLocked = f {
            if cfg.showChip { chip.present() }
        } else {
            chip.dismiss()
        }
        restartIdleTimerIfNeeded()
        Log.lock.error("InputLockManager: lock failed — \(f.message)")
    }

    /// Menu bar / Settings acknowledge a sticky failure.
    func clearFailure() {
        guard state.isFailed else { return }
        chip.dismiss()
        state = .unlocked
        restartIdleTimerIfNeeded()
    }

    // MARK: - Display assertion

    /// Own assertion, independent of AwakeManager — the screen must stay on
    /// while locked regardless of the user's AwakeConfig. IOPM refcounts
    /// per-assertion, so the two coexist.
    private func holdDisplayAssertion() {
        guard assertionID == IOPMAssertionID(0) else { return }
        var newID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Udha input lock — screen stays on while input is locked" as CFString,
            &newID
        )
        if result == kIOReturnSuccess {
            assertionID = newID
        } else {
            Log.lock.error("InputLockManager: display assertion failed (\(result))")
        }
    }

    private func releaseDisplayAssertion() {
        guard assertionID != IOPMAssertionID(0) else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = IOPMAssertionID(0)
    }

    // MARK: - Helpers

    private func currentDegradation() -> Degradation? {
        if let holder = SystemInputState.secureInputHolder() {
            return .secureInputKeyboardLive(app: holder.appName)
        }
        return nil
    }
}
