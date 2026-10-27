import Foundation
import CoreGraphics

/// The half of the input lock the C event-tap callback can legally touch.
///
/// The tap runs on its own thread's run loop, never the main one: AppCore's
/// `restoreSessions()` can block main for seconds, and a blocked run loop trips
/// `kCGEventTapDisabledByTimeout` — live input leaking through a lock the user
/// believes is armed. Off-main means the callback cannot touch
/// `InputLockManager` (`@MainActor`), so all shared state lives here behind an
/// `NSLock` and every notification hops to the main actor via `onSignal`.
final class InputLockTap: @unchecked Sendable {

    enum Mode { case swallow, passthrough }
    enum Signal: Sendable {
        case userIntent                  // a real key press / click was swallowed
        case reEnabled(timeout: Bool)    // macOS disabled the tap; we turned it back on
    }

    private let state = NSLock()
    private var mode: Mode = .swallow
    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastIntentAt: CFAbsoluteTime = 0
    /// Events before this instant don't count as intent — the click that
    /// dismissed the menu popover / the lock chord's key-up must not instantly
    /// open an auth prompt.
    private var quietUntil: CFAbsoluteTime = 0

    // Tap thread plumbing.
    private var thread: Thread?
    private var threadRunLoop: CFRunLoop?
    private let threadReady = DispatchSemaphore(value: 0)

    private let onSignal: @Sendable (Signal) -> Void
    init(onSignal: @escaping @Sendable (Signal) -> Void) { self.onSignal = onSignal }

    /// Every class of event a human can generate. `kCGEventTapDisabledBy*` are
    /// delivered regardless of the mask, so they're deliberately absent.
    static var mask: CGEventMask {
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .mouseMoved, .scrollWheel,
            .tabletPointer, .tabletProximity,
        ]
        var m = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        // NX_SYSDEFINED (14, IOLLEvent.h): media / brightness / volume keys and
        // the aux path for mouse buttons 4+. Not a CGEventType case, so it goes
        // into the mask by raw number.
        m |= (CGEventMask(1) << 14)
        return m
    }

    /// "A person is trying to use this Mac." Deliberately excludes
    /// `flagsChanged` (a bumped shift key must not spam the Touch ID prompt),
    /// key-ups, pointer movement, scrolls and tablet proximity — all still
    /// swallowed, just silently.
    private static let intentTypes: Set<UInt32> = [
        CGEventType.keyDown.rawValue,
        CGEventType.leftMouseDown.rawValue,
        CGEventType.rightMouseDown.rawValue,
        CGEventType.otherMouseDown.rawValue,
    ]

    // MARK: - Public API (callable from the main actor)

    /// Arms the tap on the dedicated tap thread; `completion` is invoked on an
    /// arbitrary queue with whether the tap actually engaged. `false` almost
    /// always means a missing or stale Accessibility grant — the caller MUST
    /// treat it as "the Mac is not locked" and say so loudly.
    func arm(quietFor quiet: TimeInterval = 0.8, completion: @escaping @Sendable (Bool) -> Void) {
        performOnTapThread { [self] in
            completion(armOnCurrentThread(quietFor: quiet))
        }
    }

    func setMode(_ m: Mode) {
        state.lock()
        mode = m
        state.unlock()
    }

    func disarm() {
        performOnTapThread { [self] in
            state.lock()
            let port = machPort
            let source = runLoopSource
            machPort = nil
            runLoopSource = nil
            state.unlock()
            if let port { CGEvent.tapEnable(tap: port, enable: false) }
            if let source {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
                CFRunLoopSourceInvalidate(source)
            }
            if let port { CFMachPortInvalidate(port) }
        }
    }

    /// True while the tap exists and macOS reports it enabled.
    func isHealthy() -> Bool {
        state.lock()
        let port = machPort
        state.unlock()
        guard let port, CFMachPortIsValid(port) else { return false }
        return CGEvent.tapIsEnabled(tap: port)
    }

    /// Kicks a disabled-but-valid tap back on. Returns whether the tap reports
    /// enabled afterwards; false means it needs a full rebuild (disarm + arm).
    func reEnableIfNeeded() -> Bool {
        state.lock()
        let port = machPort
        state.unlock()
        guard let port, CFMachPortIsValid(port) else { return false }
        if !CGEvent.tapIsEnabled(tap: port) {
            CGEvent.tapEnable(tap: port, enable: true)
        }
        return CGEvent.tapIsEnabled(tap: port)
    }

    // MARK: - Tap thread

    /// One long-lived thread whose run loop hosts the tap's mach-port source.
    private func performOnTapThread(_ block: @escaping @Sendable () -> Void) {
        state.lock()
        if thread == nil {
            let t = Thread { [self] in
                // A run loop with no sources exits immediately; park a dummy
                // port source so CFRunLoopRun() stays alive for the app's life.
                let keepAlive = NSMachPort()
                RunLoop.current.add(keepAlive, forMode: .common)
                state.lock()
                threadRunLoop = CFRunLoopGetCurrent()
                state.unlock()
                threadReady.signal()
                CFRunLoopRun()
            }
            t.name = "udha.inputlock.tap"
            t.qualityOfService = .userInteractive
            thread = t
            state.unlock()
            t.start()
            threadReady.wait()
        } else {
            state.unlock()
        }

        state.lock()
        let rl = threadRunLoop
        state.unlock()
        guard let rl else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(rl)
    }

    /// Must run on the tap thread.
    private func armOnCurrentThread(quietFor quiet: TimeInterval) -> Bool {
        state.lock()
        let existing = machPort
        state.unlock()
        if let existing, CFMachPortIsValid(existing) {
            // Already armed — refresh mode/quiet window and re-enable.
            CGEvent.tapEnable(tap: existing, enable: true)
            state.lock()
            mode = .swallow
            quietUntil = CFAbsoluteTimeGetCurrent() + quiet
            state.unlock()
            return CGEvent.tapIsEnabled(tap: existing)
        }

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.mask,
            callback: inputLockTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        state.lock()
        machPort = port
        runLoopSource = source
        mode = .swallow
        quietUntil = CFAbsoluteTimeGetCurrent() + quiet
        state.unlock()
        return CGEvent.tapIsEnabled(tap: port)
    }

    // MARK: - Callback body (tap thread)

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap whose callback was too slow, or on certain
        // user-input conditions. Re-enabling from inside the callback is the
        // supported fix; the manager also gets told so it can log/verify.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            state.lock(); let port = machPort; state.unlock()
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            onSignal(.reEnabled(timeout: type == .tapDisabledByTimeout))
            return Unmanaged.passUnretained(event)
        }

        state.lock()
        let mode = self.mode
        let quiet = self.quietUntil
        state.unlock()

        guard mode == .swallow else { return Unmanaged.passUnretained(event) }

        let now = CFAbsoluteTimeGetCurrent()
        if Self.intentTypes.contains(type.rawValue), now >= quiet {
            state.lock()
            let due = now - lastIntentAt > 0.25 // key-mashing must not flood main
            if due { lastIntentAt = now }
            state.unlock()
            if due { onSignal(.userIntent) }
        }
        return nil // swallowed
    }
}

// `userInfo` is an unretained pointer to the InputLockTap; InputLockManager
// holds the tap strongly for the lock's lifetime, so the round-trip is safe.
// passRetained would leak a tap per lock.
private let inputLockTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<InputLockTap>.fromOpaque(userInfo)
        .takeUnretainedValue()
        .handle(type: type, event: event)
}
