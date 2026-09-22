import Foundation

/// Structured reading of a Claude Code TUI pane.
///
/// Everything here comes from `tmux capture-pane -pe` — the *rendered* pane,
/// not the `pipe-pane` log stream. That distinction is the whole point: the log
/// stream is a redraw torrent (`✻thinking with xhigh effort✢a72577…`) in which
/// the footer never survives, so it can't be read reliably and it drags in the
/// user's own shell commands. The rendered pane is clean and always carries the
/// footer as its last chrome line.
struct PaneReading {
    enum PermissionMode: String {
        case bypass, acceptEdits, plan, ask
    }

    /// False when the pane holds something that isn't Claude Code (a plain
    /// shell, a build, a REPL). Callers fall back to `OutputClassifier`.
    var isClaudeTUI = false
    /// Claude is up, but one of its full-pane overlays (the `/btw` panel, the
    /// transcript scroller, the fork picker) is covering the chrome. Nothing
    /// about the run is visible, so the caller must hold the last known phase
    /// instead of inferring a new one — otherwise opening a scroll view
    /// mid-turn reads as the turn having ended.
    var isObscured = false
    /// Claude is generating right now — the footer carries "esc to interrupt".
    var isStreaming = false
    var permissionMode: PermissionMode = .ask
    /// A modal is up: tool permission, plan approval, or workspace trust.
    var hasDialog = false
    /// The dialog's numbered choices, in screen order.
    ///
    /// Remote clients could previously only ever press "1" or Escape, because
    /// nothing read what the choices actually were — so a three-option prompt
    /// was unanswerable from a phone and the session simply stopped.
    var options: [DialogOption] = []

    struct DialogOption: Equatable, Hashable, Sendable {
        /// The digit you press. Not the array index: Claude numbers from 1, and
        /// pressing the wrong digit answers the wrong question.
        var number: Int
        var label: String
        /// The one Claude has highlighted, marked with `❯`.
        var isSelected: Bool
    }
    /// Verb + parenthetical from the live spinner, e.g. ("Gallivanting",
    /// "40s · ↓ 2.7k tokens · thinking with xhigh effort").
    var spinnerVerb: String?
    var spinnerDetail: String?
    /// Set when the spinner is in its past-tense resting form ("Brewed for 4s"),
    /// which Claude paints for a while after a turn ends.
    var finishedDuration: String?
    /// Last `⏺ Tool(args)` line above the footer.
    var toolName: String?
    var toolArgs: String?
    /// Text the user has actually typed and not submitted. Ghost suggestions
    /// (Claude's dim next-prompt hints) are deliberately excluded — see
    /// `inputBoxDraft(...)`.
    var draft: String?
    var subagents: [String] = []
    /// Last line ending in "?" above the spinner — what an `awaitingReply`
    /// session is actually asking for.
    var question: String?
    /// Claude has stopped on a claude.ai usage limit and is holding the turn
    /// until the window resets: "Usage limit reached · continuing automatically
    /// at 1:40am · esc or type to cancel". No hook fires for this (only for the
    /// resume, `quota_auto_resume_fired`), so the pane is the one place it is
    /// visible. `resumesAt` is the clock Claude printed, verbatim.
    var usageLimit: UsageLimitNotice?

    struct UsageLimitNotice: Equatable, Hashable, Sendable {
        var text: String
        var resumesAt: String?
    }

    /// True when the spinner says the model is reasoning rather than running a
    /// tool. Claude spells this out in the spinner parenthetical.
    var isThinking: Bool {
        guard let spinnerDetail else { return false }
        return spinnerDetail.localizedCaseInsensitiveContains("thinking")
    }
}

enum ClaudePaneReader {

    // MARK: - Patterns

    /// Any of the markers Claude paints in its footer. Matching only
    /// "shift+tab to cycle" would be enough for every session that pins a
    /// permission mode, but a session left in default *ask* mode paints just
    /// "? for shortcuts" — anchoring on one marker misreads it as non-Claude.
    /// Claude Code 2.1.278 drops the "(shift+tab to cycle)" hint the moment a
    /// session has background shells or agents — the footer becomes
    /// "⏵⏵ bypass permissions on · 13 shells, 1 monitor · ← for agents" — so
    /// the mode row itself, and the "← for agents" tail, anchor too. Those
    /// were exactly the sessions that hit usage limits on 2026-09-18, and the
    /// reader saw no chrome in them, so the notice was never read.
    private static let footerAnchor = regex(
        #"(?i)shift\s*\+?\s*tab\s*to\s*cycle|\?\s*for\s*shortcuts|esc\s*to\s*interrupt|⏵⏵\s*\S|⏸\s*plan\s*mode\s*on|←\s*for\s*agents"#
    )
    private static let streamingMarker = regex(#"(?i)esc\s*to\s*interrupt"#)
    private static let planModeMarker  = regex(#"(?i)⏸\s*plan\s*mode\s*on"#)
    private static let bypassMarker    = regex(#"(?i)bypass\s*permissions\s*on"#)
    private static let acceptEditsMark = regex(#"(?i)accept\s*edits\s*on"#)
    private static let dialogMarker    = regex(#"(?i)esc\s*to\s*cancel|enter\s*to\s*confirm"#)
    /// Footers Claude paints for its full-pane overlays, which replace the
    /// normal chrome entirely.
    private static let overlayMarker   = regex(#"(?i)esc\s*to\s*close|to\s*scroll\s*·|c\s*to\s*copy"#)

    /// Spinner glyphs cycle through this set as it animates. The *verbs* are
    /// randomized per frame ("Cooked", "Brewed", "Gallivanting", "Sautéed"),
    /// so these match the shape and never a verb list.
    private static let spinnerGlyphs = "✻✳✽✢✶✷✸✹✺∗*·"
    private static let spinnerActive = regex(
        #"^\s*[✻✳✽✢✶✷✸✹✺∗*·]\s+([A-Za-zÀ-ÿ]+)…\s*\((.+)\)\s*$"#
    )
    /// "✻ Baked for 20s", and since 2.1.27x "✻ Baked for 20m 13s · done 8:36 PM
    /// · 13 shells, 1 monitor still running" — anything after the duration is
    /// a " · " suffix and is ignored.
    private static let spinnerDone = regex(
        #"^\s*[✻✳✽✢✶✷✸✹✺∗*·]\s+([A-Za-zÀ-ÿ]+)\s+for\s+(\d[\dhms\s]*?)\s*(?:·.*)?$"#
    )
    private static let toolLine = regex(#"^\s*[⏺●]\s+([A-Z][A-Za-z_]*)\((.{0,120})\)"#)
    /// "❯ 1. Yes" / "  2. No, exit". The caret marks the highlighted row and is
    /// optional; the number and the dot are what make it a choice rather than
    /// prose that happens to start with a digit.
    private static let optionLine = regex(#"^\s*(❯\s*)?(\d{1,2})\.\s+(\S.*?)\s*$"#)
    private static let subagentLine = regex(#"^\s*[◯◉]\s+(\S+)\s\s+\S"#)
    private static let ruleLine = regex(#"^\s*─{10,}\s*$"#)
    /// The notice Claude paints while it waits out a usage limit. Anchored on
    /// its own vocabulary in both halves so a transcript that merely mentions
    /// a usage limit never reads as one being hit.
    /// Seen on the box as "●Usage limit reached · continuing automatically at
    /// 1:30am · esc or type to cancel", and — with subagents still running —
    /// as a bare "Continuing automatically at 1:30am · esc to cancel" row.
    private static let usageLimitLine = regex(
        #"(?i)usage\s+limit\s+reached.*?(?:continuing\s+automatically\s+at\s+(\S+)|esc\s+or\s+type\s+to\s+cancel)|^\s*continuing\s+automatically\s+at\s+(\S+)\s*·\s*esc"#
    )

    /// ICU's escape for ESC is the six characters \u001B. Swift's own
    /// \u{1B} form must not be used: inside a raw string Swift leaves it
    /// alone, and ICU rejects the braced form, so the pattern fails to
    /// compile at first use.
    private static let ansi = regex(#"\u001B\[[0-9;?]*[a-zA-Z]"#)
    /// ANSI "dim". Claude renders its ghost next-prompt suggestions with it,
    /// and renders text the user actually typed in bright white — the only
    /// reliable way to tell an unsent draft from a suggestion.
    private static let dimMarker = "\u{1B}[2m"

    /// These patterns are compile-time constants, so a failure here is a
    /// programmer error — but it must not be a fatal one. `try!` here took the
    /// whole app down on launch when one pattern used Swift's `\u{1B}` instead
    /// of ICU's `\u001B`: every session's first `capture-pane` runs through this
    /// type, so a bad pattern crashes the supervisor rather than degrading one
    /// reading. Fall back to a matcher that never fires, and say so loudly.
    private static func regex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            Log.classify.error("ClaudePaneReader: bad pattern \(pattern): \(error.localizedDescription)")
            // `(?!)` can never match, so the affected signal simply reads as absent.
            return try! NSRegularExpression(pattern: #"(?!)"#)
        }
    }

    // MARK: - Entry point

    /// `raw` must be the output of `capture-pane -pe` (escapes intact).
    static func read(raw: String) -> PaneReading {
        var reading = PaneReading()

        let rawLines = raw.components(separatedBy: "\n")
        let plain = rawLines.map { strip($0) }

        // Anchor on the LAST footer line. Everything else is located relative
        // to it, so a transcript that happens to quote footer-ish text earlier
        // in the scrollback can't shift the frame.
        guard let footerIndex = plain.lastIndex(where: { matches(footerAnchor, $0) }) else {
            // No chrome. Either this isn't Claude at all, or one of its
            // full-pane overlays is covering it. Compare against the last few
            // *non-blank* lines: capture-pane returns the whole grid, so a
            // fixed tail window can land entirely in the blank padding below
            // the content.
            let tail = plain.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(6)
            if tail.contains(where: { matches(overlayMarker, $0) }) {
                reading.isClaudeTUI = true
                reading.isObscured = true
            }
            return reading
        }
        reading.isClaudeTUI = true

        let footer = plain[footerIndex]
        reading.isStreaming = matches(streamingMarker, footer)
        if matches(planModeMarker, footer) {
            reading.permissionMode = .plan
        } else if matches(bypassMarker, footer) {
            reading.permissionMode = .bypass
        } else if matches(acceptEditsMark, footer) {
            reading.permissionMode = .acceptEdits
        }

        // A modal replaces the input box, so only look in the chrome region.
        let dialogWindow = plain[max(0, footerIndex - 3)...min(plain.count - 1, footerIndex + 1)]
        reading.hasDialog = dialogWindow.contains { matches(dialogMarker, $0) }

        if reading.hasDialog {
            reading.options = readOptions(plain: plain, footerIndex: footerIndex)
        }
        reading.draft = inputBoxDraft(rawLines: rawLines, plain: plain, footerIndex: footerIndex)
        readSpinner(plain: plain, footerIndex: footerIndex, into: &reading)
        readTool(plain: plain, footerIndex: footerIndex, into: &reading)
        reading.subagents = plain[footerIndex...]
            .filter { matches(subagentLine, $0) }
            .compactMap { capture(subagentLine, $0, group: 1) }
        reading.question = trailingQuestion(plain: plain, footerIndex: footerIndex)
        reading.usageLimit = usageLimitNotice(plain: plain, footerIndex: footerIndex)

        return reading
    }

    /// The limit notice sits in the chrome above the input box, where the
    /// spinner normally is — with the spinner, subagent rows and the "waiting
    /// for N background agents" line able to sit between it and the footer.
    /// Only that band is read: the same words further up are scrollback from
    /// a limit already waited out.
    private static func usageLimitNotice(plain: [String], footerIndex: Int) -> PaneReading.UsageLimitNotice? {
        let band = plain[max(0, footerIndex - 14)..<footerIndex]
        for line in band.reversed() {
            guard let m = usageLimitLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }
            let clock = [1, 2].lazy.compactMap { Range(m.range(at: $0), in: line) }.first.map { String(line[$0]) }
            return PaneReading.UsageLimitNotice(text: line.trimmingCharacters(in: .whitespaces), resumesAt: clock)
        }
        return nil
    }

    // MARK: - Regions

    /// The input box is the band between the last two horizontal rules above
    /// the footer. Locating it by rules rather than by "the last ❯ line" matters
    /// because submitted messages are echoed into the transcript with the same
    /// ❯ glyph — without the rules, an old message reads as a live draft.
    ///
    /// Within the band a pane can show BOTH a real draft and a ghost
    /// suggestion; the dim one is the ghost, so only a non-dim line counts.
    private static func inputBoxDraft(rawLines: [String], plain: [String], footerIndex: Int) -> String? {
        // Walk up from the footer collecting rule positions. The statusLine
        // command's output can sit between the box and the footer, so this
        // deliberately doesn't assume the rule is directly adjacent.
        var rules: [Int] = []
        var i = footerIndex - 1
        while i >= 0, rules.count < 2, footerIndex - i <= 12 {
            if matches(ruleLine, plain[i]) { rules.append(i) }
            i -= 1
        }
        guard rules.count == 2 else { return nil }
        let (lower, upper) = (rules[0], rules[1])
        guard upper + 1 <= lower - 1 else { return nil }

        for idx in (upper + 1)...(lower - 1) {
            guard let caret = plain[idx].firstIndex(of: "❯") else { continue }
            // Dim ⇒ Claude's ghost suggestion, not something the user typed.
            if rawLines[idx].contains(dimMarker) { continue }
            let text = plain[idx][plain[idx].index(after: caret)...]
                .trimmingCharacters(in: .whitespaces)
            // Claude seeds an empty box with a dim placeholder; a bright but
            // empty box is simply an idle prompt.
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// The spinner sits just above the input box while streaming, and lingers
    /// in past-tense form after a turn ends.
    private static func readSpinner(plain: [String], footerIndex: Int, into reading: inout PaneReading) {
        var i = footerIndex - 1
        while i >= 0, footerIndex - i <= 16 {
            if let verb = capture(spinnerActive, plain[i], group: 1) {
                reading.spinnerVerb = verb
                reading.spinnerDetail = capture(spinnerActive, plain[i], group: 2)
                return
            }
            if let verb = capture(spinnerDone, plain[i], group: 1) {
                reading.spinnerVerb = verb
                reading.finishedDuration = capture(spinnerDone, plain[i], group: 2)?
                    .trimmingCharacters(in: .whitespaces)
                return
            }
            i -= 1
        }
    }

    private static func readTool(plain: [String], footerIndex: Int, into reading: inout PaneReading) {
        var i = footerIndex - 1
        while i >= 0 {
            if let name = capture(toolLine, plain[i], group: 1) {
                reading.toolName = name
                reading.toolArgs = capture(toolLine, plain[i], group: 2)
                return
            }
            i -= 1
        }
    }

    /// The dialog's choices, read upward from the footer.
    ///
    /// Bounded to the chrome band rather than the whole pane: a transcript can
    /// easily contain "1. Do the thing" from earlier output, and offering that
    /// as a button would send a digit answering a question nobody asked.
    private static func readOptions(plain: [String], footerIndex: Int) -> [PaneReading.DialogOption] {
        var found: [PaneReading.DialogOption] = []
        var i = footerIndex - 1
        while i >= 0, footerIndex - i <= 24 {
            let line = plain[i]
            if let numberText = capture(optionLine, line, group: 2),
               let number = Int(numberText),
               let label = capture(optionLine, line, group: 3) {
                found.append(PaneReading.DialogOption(
                    number: number,
                    label: label.trimmingCharacters(in: .whitespaces),
                    isSelected: line.contains("❯")
                ))
            } else if matches(ruleLine, line), !found.isEmpty {
                // A rule above the block ends it — anything past that is the
                // transcript, not the dialog.
                break
            }
            i -= 1
        }
        // Read upward, so reverse into screen order, and only trust a run that
        // starts at 1: a partial capture would mislabel every button.
        let ordered = found.reversed().map { $0 }
        guard ordered.first?.number == 1 else { return [] }
        // Numbering must be contiguous, or the digits we print do not match the
        // digits the dialog is listening for.
        for (index, option) in ordered.enumerated() where option.number != index + 1 {
            return []
        }
        return ordered
    }

    /// Last question mark above the chrome — what a finished session wants from
    /// you. Skips the chrome band itself so a dialog's own prompt isn't picked
    /// up as the assistant's question.
    private static func trailingQuestion(plain: [String], footerIndex: Int) -> String? {
        var i = footerIndex - 1
        while i >= 0, footerIndex - i <= 40 {
            let line = plain[i].trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("?"), line.count > 12,
               !matches(ruleLine, line), !matches(dialogMarker, line),
               !line.contains("❯"),
               // Skip the spinner and tool chrome.
               !spinnerGlyphs.contains(line.first ?? " ") {
                return line
            }
            i -= 1
        }
        return nil
    }

    // MARK: - Helpers

    static func strip(_ line: String) -> String {
        let range = NSRange(line.startIndex..., in: line)
        return ansi.stringByReplacingMatches(in: line, range: range, withTemplate: "")
            .replacingOccurrences(of: "\r", with: "")
    }

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func capture(_ pattern: NSRegularExpression, _ text: String, group: Int) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = pattern.firstMatch(in: text, range: range),
              m.numberOfRanges > group,
              let r = Range(m.range(at: group), in: text) else { return nil }
        return String(text[r])
    }
}
