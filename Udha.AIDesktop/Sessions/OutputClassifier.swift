import Foundation

struct ClassifierResult: Sendable {
    var state: SessionState?
    var activity: String?
    var pendingPrompt: PendingPrompt?
    var errorMessage: String?
    var completed: Bool = false
    /// The question the turn ended on, for a TUI that has no hook feed to
    /// say so (Codex). Drives "Waiting on you" the way `lastQuestion` does.
    var question: String? = nil
}

struct ClaudeCodePatterns {
    // Patterns applied to ONLY the LAST ~15 lines of the pane — the active UI region.
    // Earlier lines contain historical content (tool descriptions, prior responses)
    // that would produce false positives.
    static let needsInputMarkers: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"(?i)do\s*you\s*want\s*to\s*proceed"#),
        try! NSRegularExpression(pattern: #"❯\s*\d+\s*\.\s*\S"#),
        try! NSRegularExpression(pattern: #"(?i)this\s*command\s*requires\s*approval"#),
        try! NSRegularExpression(pattern: #"(?i)waiting\s*for\s*your\s*approval"#),
        try! NSRegularExpression(pattern: #"(?i)esc\s*to\s*cancel\s*·\s*tab\s*to\s*amend"#),
        try! NSRegularExpression(pattern: #"(?i)\[y/n\]"#),
        try! NSRegularExpression(pattern: #"(?i)\(y/n\)"#),
        try! NSRegularExpression(pattern: #"(?i)press\s*enter\s*to\s*continue"#),
    ]

    // Working = Claude Code is ACTIVELY processing RIGHT NOW.
    // The reliable signal is "esc to interrupt" (shown during streaming).
    // Bare spinner glyphs (✻ etc) show up in past-tense summaries too, don't trust them.
    static let workingMarkers: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"(?i)esc\s*to\s*interrupt"#),
        try! NSRegularExpression(pattern: #"⎿\s*Running"#),
    ]

    // Error markers: require a real error line, not just a keyword in discussion.
    static let errorMarkers: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"^\s*Error:\s"#),
        try! NSRegularExpression(pattern: #"^\s*API\s*Error:\s"#),
        try! NSRegularExpression(pattern: #"(?i)\b(429|500|502|503|504)\s+(Too Many Requests|Server Error|Bad Gateway|Service Unavailable|Gateway Timeout)"#),
        try! NSRegularExpression(pattern: #"(?i)connection\s*refused"#),
        try! NSRegularExpression(pattern: #"^\s*Traceback\b"#),
        try! NSRegularExpression(pattern: #"(?i)^\s*FATAL:"#),
    ]

    static let completedMarkers: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"(?i)all\s*tasks\s*completed"#),
        try! NSRegularExpression(pattern: #"✓\s*finished"#),
        try! NSRegularExpression(pattern: #"(?i)✨\s*done"#),
        try! NSRegularExpression(pattern: #"(?i)successfully\s*(deployed|completed|finished|merged|pushed)"#),
    ]

    // Claude Code paints an idle input-box footer ("⏵⏵ accept edits on",
    // "shift+tab to cycle", "? for shortcuts") whenever it is waiting for the
    // USER to type a new message. A real permission dialog paints an
    // "Esc to cancel" footer instead. If the idle footer is visible with no
    // dialog footer, any needsInput marker in the tail is quoted TEXT — a
    // transcript that happens to discuss prompts — not a live dialog. Without
    // this veto a session sitting idle reads as "needs input" and the voice
    // engine nags about a dialog that isn't on screen.
    // `\s*` between words also matches capture-pane's space-collapsed form
    // ("accepteditson").
    static let idleInputFooterMarker = try! NSRegularExpression(
        pattern: #"(?i)accept\s*edits\s*(on|off)|shift\s*\+?\s*tab\s*to\s*cycle|\?\s*for\s*shortcuts"#
    )
    static let dialogFooterMarker = try! NSRegularExpression(
        pattern: #"(?i)esc\s*to\s*cancel"#
    )

    static let activityExtractors: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"⏺\s*(Read|Bash|Edit|Write|Grep|Glob|WebFetch|WebSearch|Task)\s*\(([^)]{0,120})\)"#),
        try! NSRegularExpression(pattern: #"●\s*(Read|Bash|Edit|Write|Grep|Glob|WebFetch|WebSearch|Task)\s*\(([^)]{0,120})\)"#),
        try! NSRegularExpression(pattern: #"(?i)(Reading|Writing|Editing|Searching|Running|Fetching)\s*\S.{0,100}"#),
    ]
}

struct OutputClassifier {
    let destructiveKeywords: [String]

    func classify(lines: [String]) -> ClassifierResult {
        var result = ClassifierResult()

        // Only check the active UI region — last ~15 lines.
        // Checking more picks up historical text (past responses, tool descriptions)
        // and produces false positives.
        let recentText = lines.suffix(15).joined(separator: "\n")
        let lastLines = lines.suffix(8)

        for pattern in ClaudeCodePatterns.completedMarkers {
            if match(pattern, in: recentText) {
                result.state = .completed
                result.completed = true
                return result
            }
        }

        // See idleInputFooterMarker: idle chat box visible + no dialog footer
        // means prompt-like text in the tail is transcript, not a live dialog.
        let idleBoxWithoutDialog =
            match(ClaudeCodePatterns.idleInputFooterMarker, in: recentText)
            && !match(ClaudeCodePatterns.dialogFooterMarker, in: recentText)

        for pattern in ClaudeCodePatterns.needsInputMarkers where !idleBoxWithoutDialog {
            if match(pattern, in: recentText) {
                let promptBlock = Self.extractPromptBlock(lines: Array(lastLines))
                let style = Self.detectPromptStyle(recentText)
                let destructive = Self.isDestructive(text: promptBlock, keywords: destructiveKeywords)
                result.state = .needsInput
                result.pendingPrompt = PendingPrompt(
                    text: promptBlock,
                    style: style,
                    isDestructive: destructive,
                    detectedAt: Date()
                )
                return result
            }
        }

        for pattern in ClaudeCodePatterns.errorMarkers {
            if let hit = firstMatch(pattern, in: recentText) {
                result.state = .errored
                result.errorMessage = hit
                return result
            }
        }

        for pattern in ClaudeCodePatterns.workingMarkers {
            if match(pattern, in: recentText) {
                result.state = .working
                for extractor in ClaudeCodePatterns.activityExtractors {
                    if let activity = firstMatch(extractor, in: recentText) {
                        result.activity = activity.trimmingCharacters(in: .whitespacesAndNewlines)
                        break
                    }
                }
                return result
            }
        }

        return result
    }

    /// Codex, read from its pane. Every frame below was captured from
    /// codex-cli 0.154 on a Linux dev box (`scripts/verify-status.py` has none of
    /// these; the probe transcripts are what this was written against):
    ///
    ///   • Working (7s • esc to interrupt)                       ← a turn in flight
    ///   • Running touch ~/x  /  • Ran curl …                   ← the tool above it
    ///   Would you like to run the following command?
    ///   › 1. Yes, proceed (y) … Press enter to confirm or esc to cancel   ← approval
    ///   › 1. Update now … / › 1. Yes, continue … Press enter to continue  ← update / trust
    ///   • Queued follow-up inputs  ? 1 question  shift + ↵ to answer      ← a question queued for you
    ///   • Which colour do you prefer?   then   › Ask Codex to do anything ← turn ended on a question
    ///   ─ Worked for 3m 48s ─                                              ← a long turn's end
    ///
    /// Codex redraws the prompt even while working, so only the status row
    /// immediately above the prompt separates a running turn from a finished
    /// one. Never read claims or quoted errors in the conversation as status.
    func classifyCodexPane(lines: [String]) -> ClassifierResult {
        let lines = lines.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let tail = Array(lines.suffix(12))
        let text = tail.joined(separator: "\n")

        // 1. A dialog: a numbered choice with a confirm footer. Covers the
        //    command approval, the update banner and the directory-trust
        //    prompt — the last two are why a fresh Codex session could sit on
        //    "Starting" for an hour: nothing else on that screen matches.
        let dialogFooter = text.range(
            of: #"(?i)esc to cancel|press enter to confirm|press enter to continue"#,
            options: .regularExpression
        ) != nil
        let numberedChoice = text.range(
            of: #"(?m)^[›❯]\s*\d+[.)]\s*"#, options: .regularExpression
        ) != nil
        if dialogFooter && numberedChoice {
            let block = Self.codexDialogBlock(tail)
            return ClassifierResult(state: .needsInput, pendingPrompt: PendingPrompt(
                text: block, style: .numbered,
                isDestructive: Self.isDestructive(text: block, keywords: destructiveKeywords),
                detectedAt: Date()
            ))
        }

        // 2. The prompt anchors everything else.
        guard let prompt = lines.lastIndex(where: { $0.hasPrefix("›") }),
              lines.distance(from: prompt, to: lines.endIndex) <= 5 else { return ClassifierResult() }
        let above = lines[..<prompt]
        let status = above.suffix(3)

        // 3. In flight.
        let working = status.contains {
            $0.range(of: #"^[•●] .+\([^\n]*esc to interrupt\)$"#,
                     options: .regularExpression) != nil
        }
        if working {
            let tool = above.suffix(6).last {
                $0.range(of: #"^[•●] (Running|Ran|Reading|Read|Editing|Edited|Searching|Searched|Exploring|Explored|Listing|Listed)\b"#,
                         options: .regularExpression) != nil
            }
            return ClassifierResult(state: .working, activity: tool.map { Self.codexActivity($0) })
        }
        // A partially repainted busy footer is not evidence that the turn ended.
        if status.contains(where: { $0.localizedCaseInsensitiveContains("esc to interrupt") }) {
            return ClassifierResult()
        }

        // 4. Codex queued a question for you (its request-user-input tool):
        //    "? 1 question" + "shift + ↵ to answer" right above the prompt.
        let queued = above.suffix(6)
        if let count = queued.last(where: { $0.range(of: #"^\?\s*\d+ questions?$"#, options: .regularExpression) != nil }),
           queued.contains(where: { $0.localizedCaseInsensitiveContains("to answer") }) {
            let n = count.drop(while: { !$0.isNumber })
            let block = "\(n) queued for you · shift + ↵ in the terminal to answer"
            return ClassifierResult(state: .needsInput, pendingPrompt: PendingPrompt(
                text: block, style: .freeform, isDestructive: false, detectedAt: Date()
            ), question: block)
        }

        // 5. Finished. If the last thing Codex said was a question, that is
        //    what the card should carry.
        let said = above.reversed().first {
            $0.hasPrefix("•") && !$0.hasPrefix("• Worked for") && !$0.hasPrefix("• Queued")
        }
        if let said {
            let line = said.dropFirst().trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("?") { return ClassifierResult(state: .idle, question: line) }
        }
        return ClassifierResult(state: .idle)
    }

    /// The dialog and what it is about, from its first line to the footer.
    private static func codexDialogBlock(_ tail: [String]) -> String {
        let start = tail.firstIndex {
            $0.range(of: #"(?i)would you like|update available|do you trust|\?$"#, options: .regularExpression) != nil
        } ?? max(0, tail.count - 6)
        return tail[start...].joined(separator: " ")
    }

    /// "• Running touch ~/x" → "Running touch ~/x", trimmed to a card's width.
    private static func codexActivity(_ line: String) -> String {
        let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
        return body.count > 90 ? String(body.prefix(88)) + "…" : body
    }

    private func match(_ pattern: NSRegularExpression, in text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.firstMatch(in: text, options: [], range: range) != nil
    }

    private func firstMatch(_ pattern: NSRegularExpression, in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = pattern.firstMatch(in: text, options: [], range: range),
              let r = Range(m.range, in: text) else { return nil }
        return String(text[r])
    }

    private static func extractPromptBlock(lines: [String]) -> String {
        let cleaned = lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return cleaned.joined(separator: " ")
    }

    private static func detectPromptStyle(_ text: String) -> PendingPrompt.Style {
        // Claude Code's selection menu: "❯ 1. Yes" or the space-collapsed "❯1.Yes".
        // Checking the ❯ form first is reliable; the bare "\d+\.\s" fallback
        // misses the collapsed case and misroutes to .yesNo (sending "y" which
        // Claude Code's numbered menu ignores).
        if text.range(of: #"❯\s*\d+\s*\.\s*\S"#, options: .regularExpression) != nil {
            return .numbered
        }
        if text.range(of: #"\d+\.\s"#, options: .regularExpression) != nil {
            return .numbered
        }
        if text.range(of: #"(?i)\[y/n\]|\(y/n\)|\byes\b|\bno\b"#, options: .regularExpression) != nil {
            return .yesNo
        }
        if text.range(of: #"(?i)press enter"#, options: .regularExpression) != nil {
            return .enterToContinue
        }
        return .freeform
    }

    static func isDestructive(text: String, keywords: [String]) -> Bool {
        let lower = text.lowercased()
        return keywords.contains(where: { lower.contains($0.lowercased()) })
    }
}
