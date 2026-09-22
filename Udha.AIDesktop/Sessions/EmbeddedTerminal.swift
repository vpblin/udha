import AppKit
import SwiftUI
import SwiftTerm

/// `LocalProcessTerminalView` with the one behaviour it is missing when it is
/// hosted rather than filling a window of its own.
///
/// SwiftTerm's `mouseDown` forwards the click to the remote application and
/// **returns early** whenever mouse reporting is on — and tmux and Claude Code
/// both turn it on. That early return happens before the view takes first
/// responder, so a hosted terminal renders perfectly and silently never
/// receives a keystroke: arrows don't move Claude's model picker, Enter does
/// nothing, the pane looks live but is read-only. Taking focus first, then
/// deferring to super, fixes the whole class of that.
private final class UdhaTerminalView: LocalProcessTerminalView {
    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        super.mouseDown(with: event)
    }

    /// A click that lands while some other window is key should go into the
    /// terminal, not be spent activating Udha.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// **Why dictation drops its result without this.** macOS dictation shows
    /// its hypothesis as marked text and then commits the sentence through
    /// `insertText` as an *attributed* string. SwiftTerm's implementation only
    /// unwraps `NSString` (`string as? NSString`), so the commit matches
    /// nothing and the words vanish the moment the overlay disappears — which
    /// reads exactly like "dictation doesn't work in this app".
    ///
    /// The commit is then delivered the way a paste is — literal UTF-8, wrapped
    /// in bracketed-paste markers when the app asked for them — rather than
    /// through `super`. Super's path re-encodes text as kitty key events
    /// whenever the app has negotiated keyboard enhancement flags, and whether
    /// that negotiation happened differs between a local session and one
    /// reached over `ssh`; that asymmetry is why a sentence could land on this
    /// Mac and vanish on the box. A sentence is not a keystroke, so send it as
    /// text on both. Typed characters still take super's path: bracketing every
    /// keypress as a paste would be far worse.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard let attributed = string as? NSAttributedString else {
            // Typing arrives here one character at a time; a multi-character
            // plain insert is dictation or an IME committing a whole phrase,
            // and that is the case worth being able to see in the log when
            // someone says "it dropped what I said". One line per keystroke
            // would be useless noise, so only the phrase case is logged.
            if let plain = string as? String, plain.count > 1 {
                Log.pty.info("""
                    embedded terminal: plain commit, \(plain.count) chars, \
                    bracketed=\(getTerminal().bracketedPasteMode) \
                    kitty=\(getTerminal().keyboardEnhancementFlags.rawValue)
                    """)
            }
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        let text = attributed.string
        guard !text.isEmpty else { return }
        Log.pty.info("""
            embedded terminal: attributed commit, \(text.count) chars, \
            bracketed=\(getTerminal().bracketedPasteMode) \
            kitty=\(getTerminal().keyboardEnhancementFlags.rawValue)
            """)
        if getTerminal().bracketedPasteMode {
            send(data: EscapeSequences.bracketedPasteStart[0...])
            send(txt: text)
            send(data: EscapeSequences.bracketedPasteEnd[0...])
        } else {
            send(txt: text)
        }
    }
}


/// A live terminal for a supervised session, drawn inside Udha's own window.
///
/// macOS cannot host another application's window inside yours — there is no
/// native equivalent of an iframe — so "embedding iTerm2" is not a thing that
/// exists. What every editor with an integrated terminal actually does is run
/// its *own* emulator: VS Code and Cursor render xterm.js over node-pty, Zed
/// wraps the `alacritty_terminal` crate, CodeEdit uses SwiftTerm. This is the
/// same move, with the feed pointed at the tmux session Udha already owns.
///
/// Because the session lives in tmux, this view is only ever a *second client*
/// attached to it. Nothing here owns the session: closing the pane, toggling
/// the feature off or quitting Udha detaches and leaves the work running, and
/// "Open in Terminal" can be attached to the same session at the same time.
///
/// **The emulator is deliberately walled into this one file.** `SwiftTerm` is
/// imported here and nowhere else in the app, and the rest of the code sees
/// only `EmbeddedTerminalController`. Ghostty's terminal core is being carved
/// out as an embeddable Swift package (`libghostty`); when its API is stable
/// that swap should be a rewrite of this file and nothing else.
@MainActor
final class EmbeddedTerminalController: NSObject, LocalProcessTerminalViewDelegate {

    /// What the pane needs to know to render around the terminal.
    enum Status: Equatable {
        case attached
        /// The client exited: the session was detached, killed, or the SSH
        /// link dropped. The tmux session itself is usually still alive.
        case ended(String)
    }

    let sessionID: UUID
    private(set) var status: Status = .attached
    /// Bumped on every status change so SwiftUI redraws the chrome. The
    /// terminal view itself is an NSView and repaints on its own.
    var onStatusChange: ((Status) -> Void)?

    let view: LocalProcessTerminalView
    /// Fixed at creation: a rename changes the tmux name, and the store
    /// swaps this controller for a new one rather than let it reattach to a
    /// name tmux no longer knows.
    let attachCommand: String
    private var started = false
    private var appearanceObservation: NSKeyValueObservation?
    /// "remote" or "local", for the log — dictation refusing to start in one
    /// and not the other is a question about which view holds focus, and the
    /// log is unreadable without knowing which kind of session it was.
    var kind: String { attachCommand.contains("/usr/bin/ssh") ? "remote" : "local" }

    /// - Parameter attachCommand: a `/bin/sh -c` line that attaches to the
    ///   session's tmux, locally or over SSH.
    init(sessionID: UUID, attachCommand: String) {
        self.sessionID = sessionID
        self.attachCommand = attachCommand
        self.view = UdhaTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        super.init()

        view.processDelegate = self
        applyTheme()
        // The palette is resolved against the app's appearance at the moment
        // it is applied — SwiftTerm keeps components, not dynamic colours —
        // so it is re-applied whenever the appearance changes (a settings
        // switch, or the Mac flipping to dark in the evening).
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.applyTheme() }
        }
        // Claude Code redraws the whole pane constantly; the Metal renderer is
        // what keeps that cheap. It is not available on every machine, and a
        // failure here is not worth refusing to draw a terminal over — the
        // CoreGraphics path is the fallback and is perfectly usable.
        do { try view.setUseMetal(true) }
        catch { Log.pty.info("embedded terminal: Metal unavailable, using CoreGraphics (\(error.localizedDescription))") }
    }

    /// The palette is the app's own card/label rather than macOS defaults,
    /// because a terminal that ships its own white is the one rectangle on
    /// screen that looks pasted on. Resolved against the app's current
    /// appearance, so it is a light terminal in light and a dark one in dark.
    ///
    /// Resolved to *static* colours, deliberately. The theme's tokens are
    /// dynamic `NSColor`s, and SwiftTerm keeps whatever it is handed and reads
    /// it again on every frame — the Metal pass converts the clear colour and
    /// the glyph colours with `usingColorSpace` at draw time, off AppKit's
    /// drawing path, where a dynamic colour resolves against the *system*
    /// appearance rather than the app's. With the Mac in light and Udha set
    /// to dark, that painted a white terminal with black text inside a dark
    /// window. A plain sRGB colour has nothing left to resolve.
    private func applyTheme() {
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.nativeBackgroundColor = Self.resolved(UdhaTheme.card)
            view.nativeForegroundColor = Self.resolved(UdhaTheme.label)
            view.caretColor = Self.resolved(UdhaTheme.accent)
            view.selectedTextBackgroundColor = Self.resolved(UdhaTheme.accent).withAlphaComponent(0.25)
        }
        view.allowMouseReporting = true
        // tmux and Claude both drive the mouse; without this a scroll gesture
        // is swallowed by the app rather than moving tmux's scrollback.
        view.optionAsMetaKey = true
    }

    /// A token's value under the current drawing appearance, as a colour with
    /// fixed components. Call inside `performAsCurrentDrawingAppearance`.
    private static func resolved(_ color: SwiftUI.Color) -> NSColor {
        NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
    }

    /// Attaches for the first time. Safe to call repeatedly — only the first
    /// call spawns, which is what keeps switching between cards free.
    func startIfNeeded() {
        guard !started else { return }
        started = true
        view.startProcess(executable: "/bin/sh", args: ["-c", attachCommand],
                          environment: Terminal.getEnvironmentVariables(termName: "xterm-256color"))
        Log.pty.info("embedded terminal: attached \(self.sessionID) via \(self.attachCommand)")
    }

    /// Re-attach after the client exited, reusing the same view.
    func reattach() {
        started = false
        setStatus(.attached)
        startIfNeeded()
    }

    /// Detach this client. The tmux session keeps running.
    func detach() {
        guard started else { return }
        started = false
        view.terminate()
        Log.pty.info("embedded terminal: detached \(self.sessionID)")
    }

    private func setStatus(_ new: Status) {
        guard new != status else { return }
        status = new
        onStatusChange?(new)
    }

    // MARK: - LocalProcessTerminalViewDelegate

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated {
            // Exit 0 is the ordinary path: you pressed the tmux detach key, or
            // the SSH link closed cleanly. Anything else is worth naming.
            let reason = (exitCode ?? 0) == 0
                ? "Detached. The session is still running."
                : "Connection ended (exit \(exitCode ?? -1)). The session is still running."
            setStatus(.ended(reason))
            Log.pty.info("embedded terminal: client for \(self.sessionID) exited code=\(exitCode ?? -1)")
        }
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}


// MARK: - Store

/// Keeps one attached terminal per session for as long as the session exists.
///
/// Cached on purpose: clicking between two cards must not tear down and
/// re-attach a tmux client each time — that costs a full screen redraw and
/// loses the scroll position. Controllers are dropped when their session goes
/// away, or when the whole feature is switched off.
@MainActor
final class EmbeddedTerminalStore {
    /// How many sessions stay attached at once.
    ///
    /// Caching is what makes clicking between two cards free, but it cannot be
    /// unbounded: a desk of fifteen sessions browsed once each would leave
    /// fifteen live tmux clients, and every remote one of those is its own SSH
    /// connection. Four covers the handful you actually alternate between; the
    /// fifth costs one re-attach, which is a screen redraw.
    private static let maxAttached = 4

    private var controllers: [UUID: EmbeddedTerminalController] = [:]
    /// Least-recently-used first.
    private var lru: [UUID] = []

    /// The controller for a session, attaching on first ask.
    func controller(for snapshot: SessionSnapshot) -> EmbeddedTerminalController {
        touch(snapshot.id)
        let command = Self.attachCommand(tmuxName: snapshot.tmuxTarget, host: snapshot.hostName)
        if let existing = controllers[snapshot.id] {
            if existing.attachCommand == command { return existing }
            // Renaming a session renames its tmux session too, so a cached
            // client carries a name tmux no longer knows: its next reattach
            // would say "can't find session" for a session that is alive.
            existing.detach()
            Log.pty.info("embedded terminal: re-attaching \(snapshot.id) under its new tmux name \(snapshot.tmuxTarget)")
        }
        let c = EmbeddedTerminalController(sessionID: snapshot.id, attachCommand: command)
        controllers[snapshot.id] = c
        evictIfNeeded()
        return c
    }

    private func touch(_ id: UUID) {
        lru.removeAll { $0 == id }
        lru.append(id)
    }

    private func evictIfNeeded() {
        while lru.count > Self.maxAttached {
            let victim = lru.removeFirst()
            controllers.removeValue(forKey: victim)?.detach()
            Log.pty.info("embedded terminal: evicted \(victim) (over \(Self.maxAttached) attached)")
        }
    }

    /// Detach and forget everything not in `ids` — sessions that were removed
    /// while their terminal was cached.
    func prune(keeping ids: Set<UUID>) {
        for (id, c) in controllers where !ids.contains(id) {
            c.detach()
            controllers.removeValue(forKey: id)
        }
        lru.removeAll { !ids.contains($0) }
    }

    /// Tear everything down: the feature was switched off, or the app is quitting.
    func closeAll() {
        for c in controllers.values { c.detach() }
        controllers.removeAll()
        lru.removeAll()
    }

    /// The shell line that attaches one client to a session's tmux.
    ///
    /// `window-size latest` is the load-bearing part. By default tmux sizes a
    /// window to the *smallest* client attached to it, so opening this pane
    /// beside an already-attached Terminal window would shrink both to the
    /// lesser of the two and wrap Claude's output. `latest` sizes to whichever
    /// client was used most recently, which is the one you are looking at.
    static func attachCommand(tmuxName: String, host: String?) -> String {
        let inner = "tmux set -g window-size latest 2>/dev/null; exec tmux -u attach -t \(shellQuote(tmuxName))"
        guard let host else {
            // Local: tmux is not necessarily on the PATH `/bin/sh` inherits.
            return inner.replacingOccurrences(of: "tmux ", with: "\(shellQuote(TmuxSession.tmuxPath)) ")
        }
        // Remote: the box's login shell finds its own tmux. `-t` forces a TTY,
        // without which tmux refuses to attach at all.
        return "exec /usr/bin/ssh -t \(shellQuote(host)) \(shellQuote(inner))"
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}


// MARK: - SwiftUI host

/// Hosts one controller's terminal. The controller outlives this view, so
/// scrolling away from a session and back does not re-attach.
struct EmbeddedTerminalSurface: NSViewRepresentable {
    let controller: EmbeddedTerminalController

    func makeNSView(context: Context) -> NSView {
        // A plain container with the terminal pinned to its bounds. The
        // terminal does its own layout in `setFrameSize`, so letting the
        // autoresizing mask drive it is both correct and cheaper than
        // constraints.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        let term = controller.view
        term.autoresizingMask = [.width, .height]
        term.frame = container.bounds
        container.addSubview(term)
        controller.startIfNeeded()
        // Focus the terminal as soon as it is in a window, so switching to the
        // Terminal tab means you can type — without hunting for a click target
        // first. Deferred because the view has no window yet at make time.
        let kind = controller.kind
        DispatchQueue.main.async { [weak term] in
            guard let term, let window = term.window else { return }
            window.makeFirstResponder(term)
            Log.pty.info("embedded terminal[\(kind)]: shown, focused=\(window.firstResponder === term) inputContext=\(term.inputContext != nil)")
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let term = controller.view
        if term.superview !== nsView {
            term.removeFromSuperview()
            term.autoresizingMask = [.width, .height]
            term.frame = nsView.bounds
            nsView.addSubview(term)
            // A cached controller (the store keeps four attached) is re-homed
            // here rather than through `makeNSView`, so this is the only place
            // that can hand focus back to it. Without it the terminal renders
            // but the window's first responder is still whatever the previous
            // card left behind — you can watch output and not type into it,
            // and dictation, which starts on the focused view, does nothing.
            let kind = controller.kind
            DispatchQueue.main.async { [weak term] in
                guard let term, let window = term.window else { return }
                window.makeFirstResponder(term)
                Log.pty.info("embedded terminal[\(kind)]: re-homed, focused=\(window.firstResponder === term) inputContext=\(term.inputContext != nil)")
            }
        }
        controller.startIfNeeded()
    }
}
