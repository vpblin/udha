import Foundation
import Carbon.HIToolbox

/// System-global hotkey via Carbon `RegisterEventHotKey`. Chosen over an
/// `NSEvent` global monitor because it needs **no Accessibility grant** (the
/// lock hotkey must be live before the user has granted anything) and it
/// **consumes** the chord, so the keystroke never leaks into the focused app.
///
/// No *unlock* hotkey exists anywhere: while the input lock's session tap is
/// armed it swallows events upstream of HIToolbox dispatch, so a chord can
/// never match. Unlock is authentication-only, by construction.
@MainActor
final class GlobalHotkey {
    typealias Handler = @MainActor () -> Void
    enum RegisterError: Error { case alreadyTaken, failed(OSStatus) }

    private static var handlers: [UInt32: Handler] = [:]
    private static var nextID: UInt32 = 1
    private static var dispatcher: EventHandlerRef?
    private static let signature: OSType = 0x5544_4841 // 'UDHA'

    private var ref: EventHotKeyRef?
    private let id: UInt32
    let binding: HotkeyBinding

    init(binding: HotkeyBinding, handler: @escaping Handler) throws {
        self.binding = binding
        self.id = Self.nextID
        Self.nextID += 1
        try Self.installDispatcherIfNeeded()

        var hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var newRef: EventHotKeyRef?
        // kEventHotKeyExclusive: a chord someone else owns fails with
        // eventHotKeyExistsErr instead of silently double-firing.
        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &newRef
        )
        guard status == noErr, let newRef else {
            if status == OSStatus(eventHotKeyExistsErr) { throw RegisterError.alreadyTaken }
            throw RegisterError.failed(status)
        }
        ref = newRef
        Self.handlers[id] = handler
        Log.hotkey.info("GlobalHotkey: registered id=\(id) keyCode=\(binding.keyCode) mods=0x\(String(binding.modifiers, radix: 16))")
    }

    func unregister() {
        if let ref {
            UnregisterEventHotKey(ref)
            self.ref = nil
        }
        Self.handlers[id] = nil
    }

    deinit {
        // Carbon refs are main-thread objects and this class is @MainActor-bound
        // for its whole life; deinit runs after the last main-actor reference drops.
        MainActor.assumeIsolated {
            unregister()
        }
    }

    /// One app-wide Carbon handler; per-instance handlers dispatch by EventHotKeyID.
    private static func installDispatcherIfNeeded() throws {
        guard dispatcher == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return noErr }
                var hkID = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                guard err == noErr, hkID.signature == GlobalHotkey.signature else { return noErr }
                // Carbon delivers on the main thread; assumeIsolated avoids a
                // run-loop turn of delay on the one action that must feel instant.
                MainActor.assumeIsolated {
                    GlobalHotkey.handlers[hkID.id]?()
                }
                return noErr
            },
            1,
            &spec,
            nil,
            &dispatcher
        )
        guard status == noErr else { throw RegisterError.failed(status) }
    }
}
