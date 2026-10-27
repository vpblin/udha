import Foundation
import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Read-only probes of session-wide input state the input lock has to respect.
/// All static, no state — callers poll.
enum SystemInputState {

    struct SecureInputHolder: Equatable {
        let pid: pid_t?
        let appName: String?
    }

    /// Non-nil while ANY process holds Secure Keyboard Entry (Terminal's menu
    /// item is the usual culprit). While it's held, keyboard events bypass every
    /// CGEventTap — a lock engaged now would swallow the mouse and leave the
    /// keyboard wide open, which is worse than refusing.
    ///
    /// `IsSecureEventInputEnabled()` is the authoritative boolean; the PID from
    /// `CGSessionCopyCurrentDictionary` is best-effort enrichment so the UI can
    /// name the app (the key is only present while secure input is on).
    static func secureInputHolder() -> SecureInputHolder? {
        guard IsSecureEventInputEnabled() else { return nil }
        var pid: pid_t?
        var name: String?
        if let dict = CGSessionCopyCurrentDictionary() as? [String: Any] {
            // Key spelling is not in a public header; treat as optional enrichment.
            if let n = dict["kCGSSessionSecureInputPID"] as? Int {
                pid = pid_t(n)
                name = NSRunningApplication(processIdentifier: pid_t(n))?.localizedName
            }
        }
        return SecureInputHolder(pid: pid, appName: name)
    }

    /// True when this login session owns the console (not fast-user-switched away).
    static func isOnConsole() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return true // no session dictionary → assume console rather than wedge features
        }
        if let on = dict[kCGSessionOnConsoleKey as String] as? Bool { return on }
        return true
    }

    /// True when macOS's own lock screen / login window is up. Key is not in a
    /// public header — best-effort, defaults to false.
    static func isScreenLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// Seconds since the last human input in this session, taken as the minimum
    /// across the event types a person actually produces. `.combinedSessionState`
    /// covers hardware and session-posted events; Udha's own tmux writes go
    /// through a subprocess, not CGEventPost, so they don't reset this.
    static func idleSeconds() -> CFTimeInterval {
        let types: [CGEventType] = [
            .keyDown, .flagsChanged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged,
            .scrollWheel,
        ]
        return types.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min() ?? .greatestFiniteMagnitude
    }
}
