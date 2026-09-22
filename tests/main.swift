// Desktop-side bridge tests.
//
// The important one is the CONTRACT test: the desktop's `wireRow` output is fed
// straight into the *mobile app's own decoder* (compiled in from the sibling
// repo). That is the only check that actually catches the two repos disagreeing
// about a field name or type — the costCents-vs-costUSD class of bug.
import Foundation
@testable import UdhaClient

var failures = 0, checks = 0
func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if cond { print("PASS  \(name)") }
    else { failures += 1; let d = detail(); print("FAIL  \(name)\(d.isEmpty ? "" : "  — " + d)") }
}

func decodeAsClient(_ row: [String: Any]) -> UdhaClient.SessionRow? {
    let envelope: [String: Any] = ["type": "sessions_full", "sessions": [row]]
    guard case .sessionsFull(let full) = UdhaClient.BridgeDecoder.decode(payload: envelope) else { return nil }
    return full.rows.first
}

func snapshot(
    label: String = "scholar-health",
    directory: String = "/Users/dev/code/scholar-health",
    state: SessionState = .working,
    phase: SessionPhase = .thinking,
    phaseAge: TimeInterval = 14
) -> SessionSnapshot {
    var s = SessionSnapshot(
        id: UUID(), label: label, directory: directory, state: state,
        stateEnteredAt: Date().addingTimeInterval(-60),
        currentActivity: nil, pendingPrompt: nil, lastErrorMessage: nil,
        lastSpoken: nil, priority: .normal, exitCode: nil
    )
    s.phase = phase
    s.phaseEnteredAt = Date().addingTimeInterval(-phaseAge)
    return s
}

// Regression: a live Codex session used to update state but remain Starting
// forever in the sidebar, which renders phase. Use actual Codex footer shapes.
do {
    let classifier = OutputClassifier(destructiveKeywords: ["rm -rf"])
    func classify(_ text: String) -> ClassifierResult {
        classifier.classifyCodexPane(lines: text.components(separatedBy: "\n"))
    }
    let footer = "\n› Ask Codex to do anything\n\n  gpt-6-astra default · ~/project\n\n"
    check("Codex ready prompt", classify("• Updated the app." + footer).state == .idle)
    check("Codex busy prompt is not ready",
          classify("• Working (23s • esc to interrupt)\n\n" + footer).state == .working)
    check("Codex long silent task stays working",
          classify("• Waiting (12m 5s • esc to interrupt)" + footer).state == .working)
    check("Codex quoted completion is not completion",
          classify("• successfully deployed and all tasks completed" + footer).state == .idle)
    check("Codex quoted error is not an error",
          classify("Error: example from a log" + footer).state == .idle)
    check("Codex old working row is not current",
          classify("• Working (1s • esc to interrupt)\n• Finished\nfirst\nsecond\nthird" + footer).state == .idle)
    let approval = classify("Would you like to run the following command?\nrm -rf build\n› 1. Yes, proceed\n  2. No\nPress enter to confirm or esc to cancel")
    check("Codex approval dialog", approval.state == .needsInput)
    check("Codex approval choice style", approval.pendingPrompt?.style == .numbered)
    check("Codex destructive prompt retained", approval.pendingPrompt?.isDestructive == true)
    check("Codex missing UI is unknown", classify("some transcript text").state == nil)
    var snap = snapshot(state: .idle, phase: .starting)
    snap.tool = .codex
    snap.applyClassifiedState(.idle)
    check("Codex restored idle clears Starting", snap.statusPresentation().label == "Ready")
    snap.applyClassifiedState(.working)
    check("Codex working updates displayed phase", snap.statusPresentation().label == "Working")
    snap.applyClassifiedState(.needsInput)
    check("Codex approval updates displayed phase", snap.statusPresentation().label == "Needs approval")
    snap.applyClassifiedState(.idle)
    check("Codex finishing clears working phase", snap.phase == .awaitingReply && snap.state == .idle)
    let entered = snap.phaseEnteredAt
    snap.applyClassifiedState(.idle)
    check("Repeated ready captures preserve duration", snap.phaseEnteredAt == entered)
    var shell = snapshot(state: .starting, phase: .starting)
    shell.applyClassifiedState(.idle)
    check("Generic session launch clears Starting", shell.statusPresentation().label == "Idle")
}

// MARK: - Contract: desktop row -> mobile decoder

var rich = snapshot(phase: .awaitingApproval)
rich.phaseDetail = "Editing IntakeForm.swift"
rich.contextPercent = 62
rich.costCents = 187
rich.subagentCount = 2
rich.lastQuestion = "migrate?"
rich.pendingPrompt = PendingPrompt(text: "Run npm run migrate?", style: .yesNo,
                                   isDestructive: true, detectedAt: Date())

if let client = decodeAsClient(rich.wireRow(staleAfter: 1800)) {
    check("id survives", client.id == rich.id.uuidString)
    check("label survives", client.label == "scholar-health")
    check("directory survives", client.directory == rich.directory)
    check("phase survives", client.phase == UdhaClient.SessionPhase.awaitingApproval, "\(client.phase)")
    check("phaseDetail survives", client.phaseDetail == "Editing IntakeForm.swift")
    check("attention is needsYou", client.attention == UdhaClient.SessionAttention.needsYou, "\(client.attention)")
    check("contextPercent survives", client.contextPercent == 62)
    // The field the plan corrected from costUSD. A rename on either side
    // silently drops the cost from every card; this is the guard.
    check("costCents survives as Int", client.costCents == 187, "\(String(describing: client.costCents))")
    check("cost renders", client.costDisplay == "$1.87", client.costDisplay ?? "nil")
    check("subagentCount survives", client.subagentCount == 2)
    check("lastQuestion survives", client.lastQuestion == "migrate?")
    check("hasPendingPrompt survives", client.hasPendingPrompt)
    check("phase age is seconds not ms", client.phaseEnteredSecAgo >= 13 && client.phaseEnteredSecAgo <= 16,
          "\(client.phaseEnteredSecAgo)")
    check("state survives", client.state == UdhaClient.SessionState.working, "\(client.state)")
} else {
    check("desktop row decodes on the client", false)
}

// MARK: - Machine stats survive the bridge

// The Machines pane reads a remote box entirely through this dictionary, so a
// field that does not survive the round trip is a gauge that silently reads
// "—" on the PC while looking fine on the Mac.
var stats = MachineStats()
stats.host = "devbox"
stats.os = "Ubuntu 26.04.1 LTS"
stats.kernel = "6.14.0-33-generic"
stats.arch = "x86_64"
stats.cpuModel = "AMD Ryzen 7 9800X3D 8-Core Processor"
stats.cpuThreads = 16
stats.uptimeSeconds = 36_660
stats.agentKind = "udha-agent"
stats.agentVersion = "0.2.0"
stats.agentResidentBytes = 95_420_416
stats.cpuPercent = 3.4
stats.load = [0.45, 0.24, 0.2]
stats.memoryUsed = 14_260_000_000
stats.memoryTotal = 63_570_000_000
stats.swapUsed = 452_000_000
stats.swapTotal = 8_590_000_000
stats.diskUsed = 157_000_000_000
stats.diskTotal = 1_920_000_000_000
stats.diskDevice = "nvme1n1p2"
stats.temperatures = [.init(label: "k10temp Tctl", celsius: 46), .init(label: "nvme Composite", celsius: 23)]
stats.gpu = .init(name: "NVIDIA GeForce RTX 5090", utilPercent: 0, memUsedMB: 18,
                  memTotalMB: 32_607, celsius: 35, watts: 15.84, fanPercent: 0)
stats.docker = .init(running: 36, note: "web · api")
stats.net = .init(interface: "wlp15s0", rxBytesPerSec: 3_400_000, txBytesPerSec: 812_000)
stats.topProcesses = [.init(name: "awslocal", cpuPercent: 6.8)]
stats.tools = [.init(name: "claude", version: "2.1.260"), .init(name: "tmux", version: "3.4")]
stats.sessionCount = 2
stats.tmuxNote = "/tmp/tmux-1000/default"
stats.loggedInUsers = 2
stats.collector = "/proc · hwmon · statvfs · nvidia-smi · docker"
stats.relay = .init(instanceID: "udha-00b891", url: "wss://relay.example.com",
                    transport: "NIORelaySocket (SwiftNIO)", connectedAt: Date(timeIntervalSince1970: 1_756_999_000),
                    lastPongAt: Date(timeIntervalSince1970: 1_756_999_400), rttMilliseconds: 17.8,
                    capabilities: ["delta", "stats"], deltaSeq: 10_482, signedIn: true)
stats.logTail = ["13:26:08 INFO [bridge] relay: connecting"]
stats.errors = [.init(at: Date(timeIntervalSince1970: 1_756_998_000), code: "close 1006", text: "network changed")]

let rebuilt = MachineStats(wire: stats.wire)
check("stats host survives", rebuilt.host == stats.host)
check("stats os survives", rebuilt.os == stats.os)
check("stats cpu percent survives", rebuilt.cpuPercent == stats.cpuPercent, "\(String(describing: rebuilt.cpuPercent))")
check("stats load survives", rebuilt.load == stats.load)
// UInt64 through JSON is the field most likely to be quietly truncated.
check("stats memory survives 64-bit", rebuilt.memoryTotal == stats.memoryTotal, "\(rebuilt.memoryTotal)")
check("stats disk survives 64-bit", rebuilt.diskTotal == stats.diskTotal, "\(rebuilt.diskTotal)")
check("stats swap survives", rebuilt.swapUsed == stats.swapUsed)
check("stats temperatures survive", rebuilt.temperatures == stats.temperatures)
check("stats gpu survives", rebuilt.gpu == stats.gpu, "\(String(describing: rebuilt.gpu))")
check("stats docker survives", rebuilt.docker == stats.docker)
check("stats net survives", rebuilt.net == stats.net)
check("stats tools survive", rebuilt.tools == stats.tools)
check("stats relay survives", rebuilt.relay == stats.relay, "\(String(describing: rebuilt.relay))")
check("stats errors survive", rebuilt.errors == stats.errors)
check("stats log tail survives", rebuilt.logTail == stats.logTail)
check("stats collector note survives", rebuilt.collector == stats.collector)
check("stats agent identity survives", rebuilt.agentKind == "udha-agent" && rebuilt.agentVersion == "0.2.0")

// An empty machine must not decode as a machine reporting zeroes: the pane
// keys "—" off nil, and a zero would render as a real, wrong reading.
let blank = MachineStats(wire: [:])
check("absent cpu decodes as nil", blank.cpuPercent == nil)
check("absent gpu decodes as nil", blank.gpu == nil)
check("absent docker decodes as nil", blank.docker == nil)
check("absent relay decodes as nil", blank.relay == nil)
check("memory percent is nil without a total", blank.memoryPercent == nil)

// The wire form has to survive real JSON, not just a dictionary copy.
if let json = try? JSONSerialization.data(withJSONObject: stats.wire),
   let back = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] {
    let decoded = MachineStats(wire: back)
    check("stats survive JSON encoding", decoded.memoryTotal == stats.memoryTotal
          && decoded.gpu?.watts == 15.84 && decoded.relay?.deltaSeq == 10_482)
} else {
    check("stats wire is JSON-serializable", false)
}

check("temperature lookup finds the CPU die", stats.temperature(matching: ["tctl"]) == 46)
check("temperature lookup misses cleanly", stats.temperature(matching: ["nosuch"]) == nil)

// MARK: - Contract: attention grouping agrees across the wire

var working = snapshot(phase: .usingTool)
check("working groups working",
      decodeAsClient(working.wireRow(staleAfter: 1800))?.attention == UdhaClient.SessionAttention.working)

var idle = snapshot(phase: .idle)
check("idle groups quiet",
      decodeAsClient(idle.wireRow(staleAfter: 1800))?.attention == UdhaClient.SessionAttention.quiet)

// awaitingReply WITH a question and under threshold -> needsYou
var ready = snapshot(phase: .awaitingReply, phaseAge: 60)
ready.lastQuestion = "Open a PR?"
ready.supportsAttentionEvents = false
if let c = decodeAsClient(ready.wireRow(staleAfter: 1800)) {
    check("fresh answered-question is needsYou", c.attention == UdhaClient.SessionAttention.needsYou, "\(c.attention)")
    check("fresh is not stale", !c.stale)
    // Was "Ready". These three lines are the whole reason the label changed:
    // this row and the silent-turn row below are both `awaitingReply`, and both
    // used to render the same word while carrying different colours — the only
    // thing separating "answer me" from "nothing pending" was a hue the reader
    // had to already know how to interpret. The word carries it now.
    check("an answered question names itself", c.statusLabel == "Needs reply", c.statusLabel)
}

// Same session past the threshold -> quiet + stale
var stale = snapshot(phase: .awaitingReply, phaseAge: 7200)
stale.lastQuestion = "Open a PR?"
if let c = decodeAsClient(stale.wireRow(staleAfter: 1800)) {
    check("abandoned question drops to quiet", c.attention == UdhaClient.SessionAttention.quiet, "\(c.attention)")
    check("stale flag set", c.stale)
    check("client renders Stale", c.statusLabel == "Stale", c.statusLabel)
}

// A silent turn is quiet even when fresh — the rule the sidebar already used.
let silent = snapshot(phase: .awaitingReply, phaseAge: 30)
check("silent turn is quiet", decodeAsClient(silent.wireRow(staleAfter: 1800))?.attention == UdhaClient.SessionAttention.quiet)
// ...and it keeps the calm word, so the pair above and here read differently on
// the board instead of relying on colour alone to tell them apart.
check("a silent turn still renders Ready",
      decodeAsClient(silent.wireRow(staleAfter: 1800))?.statusLabel == "Ready",
      decodeAsClient(silent.wireRow(staleAfter: 1800))?.statusLabel ?? "nil")

// MARK: - isStale is shared, not re-derived

check("isStale false off awaitingReply", !snapshot(phase: .usingTool, phaseAge: 99999).isStale(staleAfter: 1800))
check("isStale true past threshold", snapshot(phase: .awaitingReply, phaseAge: 2000).isStale(staleAfter: 1800))
check("isStale respects config", !snapshot(phase: .awaitingReply, phaseAge: 2000).isStale(staleAfter: 9000))
check("presentation agrees with isStale",
      snapshot(phase: .awaitingReply, phaseAge: 2000).statusPresentation(staleAfter: 1800).label == "Stale")

// MARK: - Worktree provenance

let wt = snapshot(directory: "/Users/dev/code/scholar-health-wt/udha-cov")
if let c = decodeAsClient(wt.wireRow(staleAfter: 1800)) {
    check("worktree detected", c.isWorktree)
    check("branch from path", c.branch == "udha-cov", c.branch ?? "nil")
    check("repo strips -wt", c.repo == "scholar-health", c.repo ?? "nil")
}
check("plain dir is not a worktree",
      decodeAsClient(snapshot().wireRow(staleAfter: 1800))?.isWorktree == false)

// MARK: - Wire row must be JSON-serialisable

check("row is valid JSON", JSONSerialization.isValidJSONObject(rich.wireRow(staleAfter: 1800)))

// MARK: - send_keys validator

check("accepts arrows", TmuxKeyValidator.validate(["Down", "Down", "Enter"]))
check("accepts ctrl chord", TmuxKeyValidator.validate(["C-c"]))
check("accepts BTab", TmuxKeyValidator.validate(["BTab"]))
check("accepts F-keys", TmuxKeyValidator.validate(["F5"]))
check("rejects F13", !TmuxKeyValidator.validate(["F13"]))
check("rejects shell metachars", !TmuxKeyValidator.validate(["; rm -rf /"]))
check("rejects substitution", !TmuxKeyValidator.validate(["$(whoami)"]))
check("rejects backtick", !TmuxKeyValidator.validate(["`id`"]))
check("rejects spaces", !TmuxKeyValidator.validate(["Down Enter"]))
check("rejects flag-like", !TmuxKeyValidator.validate(["-X"]))
check("rejects empty", !TmuxKeyValidator.validate([]))
check("one bad element rejects all", !TmuxKeyValidator.validate(["Down", "; ls"]))
check("caps sequence length", !TmuxKeyValidator.validate(Array(repeating: "a", count: 33)))

// MARK: - Decisions parser

let notes = """
# Summary
Some prose.

## Decisions
- Track execution errors across every team.
- Reboot the QA program.

## Action items
- not a decision
"""
let decisions = MeetingNotes.decisions(from: notes)
check("parses decisions", decisions.count == 2, "\(decisions)")
check("stops at next heading", !decisions.contains("not a decision"))
check("strips bullet", decisions.first == "Track execution errors across every team.", decisions.first ?? "nil")
check("no decisions section is empty", MeetingNotes.decisions(from: "# Summary\n- x").isEmpty)

// MARK: - GitDiff against real repositories

/// Builds a throwaway repo so the diff engine is exercised against real git
/// output rather than a fixture that can drift from what git actually prints.
func makeRepo() -> String {
    let dir = NSTemporaryDirectory() + "udha-difftest-" + UUID().uuidString
    func sh(_ cmd: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
    }
    sh("mkdir -p \(dir)")
    sh("cd \(dir) && git init -q -b main && git config user.email t@t && git config user.name t")
    sh("cd \(dir) && printf 'one\\ntwo\\nthree\\n' > a.txt && git add -A && git commit -qm first")
    return dir
}

func rm(_ dir: String) { try? FileManager.default.removeItem(atPath: dir) }

// -- clean tree
let cleanRepo = makeRepo()
let clean = GitDiff.run(directory: cleanRepo, mode: "working")
check("clean repo has no files", clean.files.isEmpty, "\(clean.files.count)")
check("clean repo has no error", clean.error == nil, clean.error ?? "")

// -- working tree changes
func shell(_ cmd: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", cmd]
    p.standardOutput = Pipe(); p.standardError = Pipe()
    try? p.run(); p.waitUntilExit()
}
shell("cd \(cleanRepo) && printf 'one\\nTWO\\nthree\\nfour\\n' > a.txt && printf 'new\\n' > b.txt && git add b.txt")

let workingDiff = GitDiff.run(directory: cleanRepo, mode: "working")
check("working diff finds the edited file", workingDiff.files.contains { $0.path == "a.txt" },
      workingDiff.files.map(\.path).joined(separator: ","))
check("working diff counts additions", (workingDiff.files.first { $0.path == "a.txt" }?.additions ?? 0) >= 2)
check("working diff counts deletions", (workingDiff.files.first { $0.path == "a.txt" }?.deletions ?? 0) >= 1)
check("working diff has a stat line", !workingDiff.stat.isEmpty, workingDiff.stat)
check("patch text is a real unified diff",
      workingDiff.files.first?.patch.contains("@@") == true)

// -- staged only
let staged = GitDiff.run(directory: cleanRepo, mode: "staged")
check("staged sees the added file", staged.files.contains { $0.path == "b.txt" },
      staged.files.map(\.path).joined(separator: ","))
check("staged excludes unstaged edit", !staged.files.contains { $0.path == "a.txt" },
      staged.files.map(\.path).joined(separator: ","))

// -- branch mode against a merge base
shell("cd \(cleanRepo) && git add -A && git commit -qm second && git checkout -qb feature && printf 'feat\\n' > c.txt && git add -A && git commit -qm third")
let branch = GitDiff.run(directory: cleanRepo, mode: "branch")
check("branch mode finds the branch-only file", branch.files.contains { $0.path == "c.txt" },
      branch.files.map(\.path).joined(separator: ","))

// -- not a repo
let plain = NSTemporaryDirectory() + "udha-notrepo-" + UUID().uuidString
try? FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
let notRepo = GitDiff.run(directory: plain, mode: "working")
check("non-repo reports an error", notRepo.error == "not a git repository", notRepo.error ?? "nil")
check("non-repo returns no files", notRepo.files.isEmpty)
check("empty directory is rejected", GitDiff.run(directory: "", mode: "working").error != nil)

// -- big diff is capped rather than flooding the relay
let bigRepo = makeRepo()
shell("cd \(bigRepo) && python3 -c \"open('big.txt','w').write('x'*900000)\" && git add -A")
let big = GitDiff.run(directory: bigRepo, mode: "staged")
let payload = big.files.reduce(0) { $0 + $1.patch.count }
check("oversized diff is bounded", payload <= 600_000, "\(payload) chars")
check("oversized diff is flagged", big.truncated || big.files.contains { $0.truncated })

rm(cleanRepo); rm(bigRepo); rm(plain)

// MARK: - Delta coalescing and sequencing

@MainActor
func deltaTests() {
    let st = BridgeV2State()

    check("idle drain emits nothing", st.drain() == nil)

    let a = snapshot(label: "a"), b = snapshot(label: "b")
    st.enqueue(changed: a, removed: nil)
    st.enqueue(changed: b, removed: nil)
    guard let first = st.drain() else { return check("first batch", false) }
    check("batch carries both rows", first.changed.count == 2, "\(first.changed.count)")
    check("sequence starts at 1", first.seq == 1, "\(first.seq)")
    check("drain clears the queue", st.drain() == nil)

    // Repeated edits inside one window collapse to the latest row.
    var a2 = a; a2.phase = .usingTool
    st.enqueue(changed: a, removed: nil)
    st.enqueue(changed: a2, removed: nil)
    guard let second = st.drain() else { return check("second batch", false) }
    check("repeat edits collapse", second.changed.count == 1, "\(second.changed.count)")
    check("collapse keeps the latest", second.changed.first?.phase == .usingTool)
    check("sequence increments", second.seq == 2, "\(second.seq)")

    // Edited then closed in the same window must arrive only as a removal —
    // otherwise the client re-adds a session that is already gone.
    st.enqueue(changed: a, removed: nil)
    st.enqueue(changed: nil, removed: a.id)
    guard let third = st.drain() else { return check("third batch", false) }
    check("close beats edit", third.changed.isEmpty, "\(third.changed.count)")
    check("removal is reported", third.removed == [a.id])

    // Closed then respawned with the same id resolves to present.
    st.enqueue(changed: nil, removed: b.id)
    st.enqueue(changed: b, removed: nil)
    guard let fourth = st.drain() else { return check("fourth batch", false) }
    check("respawn beats close", fourth.changed.count == 1 && fourth.removed.isEmpty)

    // A full snapshot supersedes the queue without consuming a sequence number,
    // or the client would see a gap it could not explain.
    let before = fourth.seq
    st.enqueue(changed: a, removed: nil)
    check("supersede reports it had work", st.drainWithoutSequencing())
    check("supersede empties the queue", st.drain() == nil)
    st.enqueue(changed: a, removed: nil)
    check("sequence did not skip", st.drain()?.seq == before + 1)

    // Frame dedup
    check("first frame sends", st.shouldSendFrame("hello"))
    st.lastFrame = "hello"
    check("identical frame is suppressed", !st.shouldSendFrame("hello"))
    check("changed frame sends", st.shouldSendFrame("hello world"))

    // reset() must clear a client's negotiated state on re-handshake
    st.protocolVersion = 2
    st.capabilities = ["delta"]
    st.attachedSessionID = a.id
    st.reset()
    check("reset drops to protocol 1", !st.isV2)
    check("reset clears capabilities", st.capabilities.isEmpty)
    check("reset detaches terminal", st.attachedSessionID == nil)
    check("reset rewinds the sequence", st.seq == 0)

    // Capability negotiation is an intersection: a client asking for something
    // this host cannot do must not be told it can.
    let agreed = Set(["delta", "actions", "pty", "telepathy"])
        .intersection(BridgeV2State.serverCapabilities)
    check("negotiates the overlap", agreed == ["delta", "actions"], "\(agreed.sorted())")
    check("pty is not advertised yet", !BridgeV2State.serverCapabilities.contains("pty"))

    // Window sizing is negotiated, not assumed. The client only sends
    // `resize_terminal` — and only shows its MATCH control — when this host
    // says it can size its tmux window; an older desktop must keep its
    // desk-sized pane rather than being sent verbs it will drop on the floor.
    check("host advertises resize", BridgeV2State.serverCapabilities.contains("resize"))
    check("client and host agree on the resize capability name",
          UdhaClient.BridgeProtocolVersion.capabilities.contains("resize"))

    // The size we found the window at has to outlive reset(): the caller
    // restores the Mac's window and clears these itself, and wiping them here
    // would strand a resized pane at phone width with nothing recording its
    // original size.
    st.sizeBeforeResize = (cols: 362, rows: 93)
    st.resizedSessionID = a.id
    st.reset()
    check("reset keeps the pre-resize size for the caller to restore",
          st.sizeBeforeResize?.cols == 362 && st.resizedSessionID == a.id)
}

MainActor.assumeIsolated { deltaTests() }

// MARK: - Terminal frame trimming

// capture-pane pads to the full pane height; those blank rows are why an idle
// session looked like a screen of empty space after auto-scrolling to bottom.
let padded = "line one\nline two\n\n   \n\n"
check("trims trailing blank rows",
      TerminalFrameText.trimTrailingBlankLines(padded) == "line one\nline two",
      TerminalFrameText.trimTrailingBlankLines(padded).debugDescription)

// A row of pure colour codes renders as nothing but is not an empty string.
let escaped = "real output\n\u{1B}[0m\n\u{1B}[38;5;39m   \u{1B}[0m\n"
check("trims rows that are only escapes",
      TerminalFrameText.trimTrailingBlankLines(escaped) == "real output",
      TerminalFrameText.trimTrailingBlankLines(escaped).debugDescription)

check("keeps interior blank lines",
      TerminalFrameText.trimTrailingBlankLines("a\n\nb\n\n") == "a\n\nb")
check("leading blanks are untouched",
      TerminalFrameText.trimTrailingBlankLines("\n\na") == "\n\na")
check("all-blank collapses to empty",
      TerminalFrameText.trimTrailingBlankLines("\n   \n\u{1B}[0m\n").isEmpty)
check("no trailing blanks is a no-op",
      TerminalFrameText.trimTrailingBlankLines("a\nb") == "a\nb")
check("blank detection ignores escapes", TerminalFrameText.isBlank("\u{1B}[31m  \u{1B}[0m"))
check("blank detection sees real text", !TerminalFrameText.isBlank("\u{1B}[31mx\u{1B}[0m"))

// MARK: - Worktree creation

check("leaf folds slashes", GitWorktree.leaf(for: "udha/cov-a3f2") == "udha-cov-a3f2",
      GitWorktree.leaf(for: "udha/cov-a3f2"))
check("leaf collapses runs", GitWorktree.leaf(for: "feat//x") == "feat-x",
      GitWorktree.leaf(for: "feat//x"))
check("leaf handles colons", GitWorktree.leaf(for: "wip:thing") == "wip-thing")
check("leaf never empty", GitWorktree.leaf(for: "///") == "work", GitWorktree.leaf(for: "///"))

check("worktree path follows -wt convention",
      GitWorktree.worktreePath(repoRoot: "/x/scholar-health", branch: "udha/cov")
        == "/x/scholar-health-wt/udha-cov",
      GitWorktree.worktreePath(repoRoot: "/x/scholar-health", branch: "udha/cov"))
check("worktree path at filesystem root",
      GitWorktree.worktreePath(repoRoot: "/repo", branch: "main") == "/repo-wt/main",
      GitWorktree.worktreePath(repoRoot: "/repo", branch: "main"))

// Real throwaway repos, reusing the helper the diff tests already use.
let repo = makeRepo()

switch GitWorktree.create(repoRoot: repo, branch: "udha/cov-a3f2", base: "main", isNewBranch: true) {
case .success(let path):
    check("new-branch worktree created", FileManager.default.fileExists(atPath: path), path)
    check("worktree path is the -wt leaf", path.hasSuffix("-wt/udha-cov-a3f2"), path)
    // The whole point of storing the branch: the slash does not survive the path.
    check("git agrees on the real branch",
          Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: path).trimmedOut == "udha/cov-a3f2",
          Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: path).trimmedOut)
case .failure(let f):
    check("new-branch worktree created", false, f.message)
}

// Second attempt on the same branch must fail, not clobber.
switch GitWorktree.create(repoRoot: repo, branch: "udha/cov-a3f2", base: "main", isNewBranch: true) {
case .success: check("duplicate worktree path refused", false)
case .failure(let f): check("duplicate worktree path refused", f.message.contains("already exists"), f.message)
}

switch GitWorktree.create(repoRoot: repo, branch: "other", base: "no-such-ref", isNewBranch: true) {
case .success: check("invalid base refused", false)
case .failure(let f): check("invalid base refused", f.message.contains("unknown base ref"), f.message)
}

switch GitWorktree.create(repoRoot: repo, branch: "no-such-branch", base: nil, isNewBranch: false) {
case .success: check("existing-branch mode verifies the ref", false)
case .failure(let f): check("existing-branch mode verifies the ref",
                            f.message.contains("unknown branch"), f.message)
}

// Attaching to a branch that really exists is the other half of the feature.
_ = Git.run(["branch", "feature/ready"], in: repo)
switch GitWorktree.create(repoRoot: repo, branch: "feature/ready", base: nil, isNewBranch: false) {
case .success(let path):
    check("existing-branch worktree created", FileManager.default.fileExists(atPath: path), path)
    check("existing branch checked out",
          Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: path).trimmedOut == "feature/ready")
case .failure(let f):
    check("existing-branch worktree created", false, f.message)
}

let listed = GitWorktree.branches(in: repo)
check("branches lists local refs", listed.all.contains("main") && listed.all.contains("feature/ready"),
      listed.all.joined(separator: ","))
check("branches reports current", listed.current == "main", listed.current ?? "nil")
check("non-repo has no root", GitWorktree.repoRoot(for: NSTemporaryDirectory()) == nil)

rm(repo)
rm(repo + "-wt")

// MARK: - Stored branch beats the path guess (contract)

var stored = snapshot(directory: "/Users/dev/code/scholar-health-wt/udha-cov-a3f2")
stored.branch = "udha/cov-a3f2"
if let c = decodeAsClient(stored.wireRow(staleAfter: 1800)) {
    // The assertion that would have caught the doc/implementation disagreement:
    // BRIDGE_V2_PLAN 1.2 shows a slashed branch the old path derivation could
    // never produce.
    check("stored branch survives the wire with its slash",
          c.branch == "udha/cov-a3f2", c.branch ?? "nil")
    check("stored branch still reports the repo", c.repo == "scholar-health", c.repo ?? "nil")
    check("stored branch still marks the worktree", c.isWorktree)
}

// Back-compat: every session already on disk has no stored branch.
if let c = decodeAsClient(snapshot(directory: "/x/repo-wt/legacy").wireRow(staleAfter: 1800)) {
    check("nil stored branch falls back to the path", c.branch == "legacy", c.branch ?? "nil")
}

// MARK: - Permission mode (cross-repo contract)

// The raw values are the wire contract: the phone sends `permission` as a raw
// string and this enum is what reads it. A rename on either side would
// silently change which flags Claude launches with — which is exactly the
// class of bug the costCents/costUSD contract test exists to catch.
check("permission raw values match the client",
      ClaudePermissionMode.allCases.map(\.rawValue)
        == UdhaClient.SessionTool.claude.modes.map(\.rawValue),
      ClaudePermissionMode.allCases.map(\.rawValue).joined(separator: ","))

for mode in UdhaClient.SessionTool.claude.modes {
    check("client mode \(mode.rawValue) is known to the host",
          ClaudePermissionMode(rawValue: mode.rawValue) != nil)
}

check("acceptEdits maps to its flag",
      ClaudePermissionMode.acceptEdits.args == ["--permission-mode", "acceptEdits"])
check("ask maps to default, not \"ask\"",
      ClaudePermissionMode.ask.args == ["--permission-mode", "default"])
check("plan maps to its flag",
      ClaudePermissionMode.plan.args == ["--permission-mode", "plan"])
check("bypass skips permissions entirely",
      ClaudePermissionMode.bypass.args == ["--dangerously-skip-permissions"])

// An unknown string must not silently become bypass.
check("unknown permission does not decode", ClaudePermissionMode(rawValue: "yolo") == nil)

// `normalizedClaudeArgs` must not append acceptEdits onto an explicit choice —
// duplicating a plan-only or bypass session would otherwise upgrade it.
for mode in [ClaudePermissionMode.plan, .bypass, .ask, .acceptEdits] {
    check("duplicating a \(mode.rawValue) session keeps its mode",
          SessionConfig.normalizedClaudeArgs(command: "claude", args: mode.args) == mode.args,
          SessionConfig.normalizedClaudeArgs(command: "claude", args: mode.args).joined(separator: " "))
}

// MARK: - Assistant choice (Claude vs ChatGPT)

// The tool is derived from the command, never stored beside it, so every
// session already on disk keeps working and a hand-typed command still has no
// assistant — which is what suppresses the sidecar and the permission picker.
check("claude command detects as Claude", SessionConfig(label: "a", directory: "/tmp").tool == .claude)
check("codex command detects as ChatGPT",
      SessionConfig(label: "a", directory: "/tmp", command: "codex").tool == .codex)
check("a shell command has no assistant",
      SessionConfig(label: "a", directory: "/tmp", command: "npm run dev").tool == nil)

// The raw value is the binary tmux launches; renaming a case would launch the
// wrong program.
check("tool raw values are the binaries",
      SessionTool.claude.command == "claude" && SessionTool.codex.command == "codex")

// `create_session` sends the posture as a raw string, the same way the phone
// sends Claude's. An unknown or absent one must fall back, never fail closed
// into something more permissive.
check("codex default posture is workspace-write",
      SessionTool.codex.args(permission: nil) == CodexApprovalMode.workspaceWrite.args)
check("unknown codex posture falls back, not to bypass",
      SessionTool.codex.args(permission: "yolo") == CodexApprovalMode.workspaceWrite.args)
check("claude default posture is unchanged",
      SessionTool.claude.args(permission: nil) == ClaudePermissionMode.acceptEdits.args)
check("a claude posture name is not read as a codex one",
      SessionTool.codex.args(permission: "acceptEdits") == CodexApprovalMode.workspaceWrite.args)

check("codex read-only never asks and never writes",
      CodexApprovalMode.readOnly.args == ["--sandbox", "read-only", "--ask-for-approval", "never"])
check("codex bypass drops the sandbox too",
      CodexApprovalMode.bypass.args == ["--dangerously-bypass-approvals-and-sandbox"])
for mode in CodexApprovalMode.allCases {
    check("codex \(mode.rawValue) round-trips through its own flags",
          CodexApprovalMode.from(args: mode.args) == mode,
          mode.args.joined(separator: " "))
}

// The tool travels to remote clients on the row, and its absence means Claude —
// which is exactly what every host before this one ran.
do {
    var snap = SessionSnapshot(id: UUID(), label: "x", directory: "/tmp", state: .idle,
                               stateEnteredAt: Date(), currentActivity: nil, pendingPrompt: nil,
                               lastErrorMessage: nil, lastSpoken: nil, priority: .normal,
                               exitCode: nil)
    snap.tool = .codex
    let row = snap.wireRow(staleAfter: 600)
    check("tool rides the wire row", row["tool"] as? String == "codex")
    check("a ChatGPT session is not reported as a Claude TUI", row["isClaudeTUI"] as? Bool == false)
    check("tool decodes back", SessionSnapshot(wireRow: row)?.tool == .codex)
    var pooled = snapshot(); pooled.account = "work-2"
    let pooledRow = pooled.wireRow(staleAfter: 600)
    check("the login rides the row", pooledRow["account"] as? String == "work-2")
    check("a row without a pool carries no login key", row["account"] == nil)
    check("the login decodes back", SessionSnapshot(wireRow: pooledRow)?.account == "work-2")
    check("the mobile decoder tolerates the login key", decodeAsClient(pooledRow) != nil)
    // The tmux name rides too: it is fixed at spawn while the label is not,
    // so a client that re-derived it from a renamed label attached to nothing.
    snap.tmuxName = "udha-x-deadbeef"
    check("tmux name rides the wire row", snap.wireRow(staleAfter: 600)["tmux"] as? String == "udha-x-deadbeef")
    check("tmux name decodes back", SessionSnapshot(wireRow: snap.wireRow(staleAfter: 600))?.tmuxName == "udha-x-deadbeef")
    check("a row without a tmux name decodes as unknown", SessionSnapshot(wireRow: row)?.tmuxName == nil)
    var claudeRow = row
    claudeRow["tool"] = nil
    check("a row without a tool decodes as unknown, not wrong",
          SessionSnapshot(wireRow: claudeRow)?.tool == nil)
}

// MARK: - Dialog option parsing

// The pane is the only place the choices exist — the hook feed reports that a
// dialog is up, never what is on it. Getting these wrong sends the wrong digit
// into a live session, so the parser refuses anything it cannot read exactly.
//
// Every fixture keeps a real footer line. The reader anchors on the footer and
// locates everything relative to it, so a pane without one is not a Claude pane
// as far as it is concerned — options included.

let permissionPane = """
● Bash(npm run migrate)

 Run `npm run migrate` against the production database?

 ❯ 1. Yes
   2. Yes, and don't ask again for npm commands
   3. No, and tell Claude what to do differently (esc)

 Esc to cancel · Enter to confirm
 ⏵⏵ auto mode on (shift+tab to cycle)
"""
let permission = ClaudePaneReader.read(raw: permissionPane)
check("a permission prompt is a dialog", permission.hasDialog)
check("every choice is read", permission.options.count == 3, "\(permission.options.count)")
check("digits are the ones the dialog listens for",
      permission.options.map(\.number) == [1, 2, 3])
check("choices come back in screen order",
      permission.options.first?.label == "Yes", permission.options.first?.label ?? "nil")
check("a label keeps its commas",
      permission.options.count > 1 && permission.options[1].label.contains("don't ask again"))
check("the caret marks the highlighted row",
      permission.options.first?.isSelected == true
        && permission.options.dropFirst().allSatisfy { !$0.isSelected })

// Numbering that skips means the read is partial — and a partial read mislabels
// every button. Better to offer none than the wrong ones.
let skipped = """
 ❯ 1. Yes
   3. No
 Esc to cancel · Enter to confirm
 ⏵⏵ auto mode on (shift+tab to cycle)
"""
check("non-contiguous numbering is refused",
      ClaudePaneReader.read(raw: skipped).options.isEmpty)

let notFromOne = """
   2. Second
   3. Third
 Esc to cancel · Enter to confirm
 ⏵⏵ auto mode on (shift+tab to cycle)
"""
check("numbering that does not start at 1 is refused",
      ClaudePaneReader.read(raw: notFromOne).options.isEmpty)

// A pane with no dialog must offer nothing, however many numbered lines the
// transcript happens to contain — otherwise a plan Claude wrote out becomes a
// row of buttons that send digits into a session expecting prose.
let transcriptWithNumbers = """
● Here is the plan:
  1. Read the file
  2. Change the thing
  3. Run the tests

 ⏵⏵ auto mode on (shift+tab to cycle)
"""
let noDialog = ClaudePaneReader.read(raw: transcriptWithNumbers)
check("prose numbering is not a dialog", !noDialog.hasDialog)
check("and offers no options", noDialog.options.isEmpty)

// Two choices is the other common shape (workspace trust).
let twoWay = """
 Do you trust the files in this folder?

 ❯ 1. Yes, I trust this folder
   2. No, exit

 Enter to confirm · Esc to cancel
 ⏵⏵ auto mode on (shift+tab to cycle)
"""
let trust = ClaudePaneReader.read(raw: twoWay)
check("a two-way prompt reads both choices", trust.options.count == 2, "\(trust.options.count)")
check("the second is still numbered 2", trust.options.last?.number == 2)

// MARK: - Local meeting upload contract
//
// The phone's real `wirePayload` fed through the desktop's real parser. This is
// the check that catches the two sides disagreeing about a phone recording —
// the class of bug where an upload succeeded and the phone still lost track of
// its own meeting.

do {
    let phoneID = UUID()
    let local = UdhaClient.Meeting(
        id: phoneID.uuidString,
        title: "Standup — recorded on iPhone",
        createdAt: Date(timeIntervalSince1970: 1787200000),
        endedAt: Date(timeIntervalSince1970: 1787201800),
        origin: .local,
        hasAudio: true,
        finalized: false,
        transcript: [
            UdhaClient.TranscriptSegment(id: "t1", source: .mic, speaker: "Me",
                                         text: "Blockers first.", startTime: 3, endTime: 8),
        ],
        userNotes: "ship the migration Thursday",
        syncState: .queued
    )

    guard let wire = local.wirePayload else {
        check("phone meeting serialises", false)
        exit(1)
    }

    switch LocalMeetingUpload.parse(["meeting": wire]) {
    case .failure(let why):
        check("desktop parses a phone upload", false, "\(why)")
    case .success(let parsed):
        // The one that mattered: the desktop used to throw this away and mint
        // a new UUID, orphaning the phone's copy permanently.
        check("the phone's id survives the trip", parsed.id == phoneID, "\(parsed.id)")
        check("title survives", parsed.title == "Standup — recorded on iPhone")
        check("createdAt survives as epoch",
              Int(parsed.createdAt?.timeIntervalSince1970 ?? 0) == 1787200000)
        check("endedAt survives as epoch",
              Int(parsed.endedAt?.timeIntervalSince1970 ?? 0) == 1787201800)
        check("hasAudio survives", parsed.hasAudio)
        // Without these the finalize pass has no backbone to build notes on.
        check("the rough notes survive", parsed.userNotes == "ship the migration Thursday")
        check("the transcript survives", parsed.transcript.count == 1)
        check("transcript text survives", parsed.transcript.first?.text == "Blockers first.")
        check("transcript speaker survives", parsed.transcript.first?.speaker == "Me")
        check("transcript timing survives", parsed.transcript.first?.start == 3)
    }
}

// A payload the desktop cannot identify must be refused with a reason, not
// quietly turned into a new meeting the phone will never find.
do {
    switch LocalMeetingUpload.parse(["meeting": ["id": "not-a-uuid", "title": "T"]]) {
    case .failure(let why): check("a non-UUID id is refused", why == .badID)
    case .success:          check("a non-UUID id is refused", false)
    }
    switch LocalMeetingUpload.parse(["meeting": ["id": UUID().uuidString]]) {
    case .failure(let why): check("a titleless meeting is refused", why == .missingTitle)
    case .success:          check("a titleless meeting is refused", false)
    }
    switch LocalMeetingUpload.parse(["meeting": "nonsense"]) {
    case .failure(let why): check("a non-object payload is refused", why == .notAnObject)
    case .success:          check("a non-object payload is refused", false)
    }
    // Empty notes are absent notes — the finalize prompt should not be handed
    // an empty "the user wrote this" section.
    switch LocalMeetingUpload.parse(["meeting": ["id": UUID().uuidString, "title": "T", "userNotes": ""]]) {
    case .failure:          check("empty notes are treated as none", false)
    case .success(let p):   check("empty notes are treated as none", p.userNotes == nil)
    }
}

// The other direction: what this Mac sends for a phone-recorded meeting has to
// come back to the phone still labelled as its own.
do {
    let row: [String: Any] = [
        "id": UUID().uuidString,
        "title": "From the Mac",
        "createdAt": 1787200000.0,
        "endedAt": 1787201800.0,
        "mode": "standard",
        "origin": "local",
        "hasAudio": true,
        "finalized": true,
        "summary": "blurb",
        "notesMarkdown": "## Polished\n- a point",
        "userNotes": "rough",
    ]
    let envelope: [String: Any] = ["type": "meeting_detail", "meeting": row]
    if case .meetingDetail(let m) = UdhaClient.BridgeDecoder.decode(payload: envelope) {
        check("origin round-trips as local", m.origin == .local)
        check("notesMarkdown reaches the phone", m.notesMarkdown == "## Polished\n- a point")
        check("polished notes are what the phone shows", m.displayNotes == "## Polished\n- a point")
        check("user notes reach the phone", m.userNotes == "rough")
    } else {
        check("client decodes a local-origin detail", false)
    }
}

// Directory-scoped Claude logins: which config dir (i.e. which account) a
// session in a given folder launches with.
do {
    let home = NSHomeDirectory()
    check("no accounts are configured out of the box", ClaudeAccount.defaults.isEmpty)
    let accounts = [ClaudeAccount(pathPrefix: "~/projects/work", configDir: "~/.claude-work")]
    func dir(_ path: String) -> String? { ClaudeAccount.configDir(for: path, accounts: accounts) }

    check("a folder under the work tree gets the work account",
          dir("\(home)/projects/work/some-app") == "\(home)/.claude-work",
          String(describing: dir("\(home)/projects/work/some-app")))
    check("the tree root itself counts", dir("~/projects/work") == "\(home)/.claude-work")
    check("a trailing slash doesn't defeat the match", dir("\(home)/projects/work/") == "\(home)/.claude-work")
    check("everything else keeps the default login", dir("\(home)/projects/personal/Udha.AIDesktop") == nil)
    check("a sibling folder sharing the prefix string does not match",
          dir("\(home)/projects/work-archive") == nil)

    // Longest prefix wins, so a nested tree can carve itself out of a broader one.
    let nested = accounts + [ClaudeAccount(pathPrefix: "~/projects", configDir: "~/.claude-broad")]
    check("the more specific tree wins over the broader one",
          ClaudeAccount.configDir(for: "\(home)/projects/work/app", accounts: nested) == "\(home)/.claude-work")
    check("the broader tree still covers its other folders",
          ClaudeAccount.configDir(for: "\(home)/projects/personal", accounts: nested) == "\(home)/.claude-broad")
}

// Login pools: several logins for one tree, and moving between them when one
// hits its usage limit.
do {
    let home = NSHomeDirectory()
    let account = ClaudeAccount(pathPrefix: "~/projects/work", configDir: "~/.claude-work",
                                alternates: ["~/.claude-work-2", "~/.claude-work-3/", "~/.claude-work"])
    check("the pool is the primary first, then the alternates, without repeats or trailing slashes",
          account.pool == ["\(home)/.claude-work", "\(home)/.claude-work-2", "\(home)/.claude-work-3"],
          account.pool.joined(separator: ","))
    check("an entry without alternates is a pool of one",
          ClaudeAccount(pathPrefix: "~/x", configDir: "~/.claude-x").pool == ["\(home)/.claude-x"])
    check("the account itself is found by folder",
          ClaudeAccount.account(for: "\(home)/projects/work/app", accounts: [account])?.pathPrefix == "~/projects/work")
    check("short names drop the .claude- prefix", ClaudeAccountPool.shortName("~/.claude-work-2") == "work-2")
    check("the default dir reads as default", ClaudeAccountPool.shortName("~/.claude") == "default")

    // The statusLine's documented rate_limits block, and the probe's undocumented shape.
    let limits: [String: Any] = ["five_hour": ["used_percentage": 18.0, "resets_at": 1789379400],
                                 "seven_day": ["used_percentage": 83, "resets_at": 1789754400]]
    let reading = ClaudeAccountUsage.fromStatusLine(limits)
    check("statusLine rate limits are read", reading?.fiveHourPercent == 18 && reading?.sevenDayPercent == 83)
    check("resets_at is Unix seconds", reading?.fiveHourResetsAt == Date(timeIntervalSince1970: 1789379400))
    check("the fuller window is the one that counts",
          reading?.usedPercent(at: Date(timeIntervalSince1970: 1789000000)) == 83)
    check("a window past its reset is ignored",
          reading?.usedPercent(at: Date(timeIntervalSince1970: 1789754401)) == nil)
    check("a seven_day-only block still reads",
          ClaudeAccountUsage.fromStatusLine(["seven_day": ["used_percentage": 40, "resets_at": 1]])?.sevenDayPercent == 40)
    check("a block with neither window is nothing", ClaudeAccountUsage.fromStatusLine(["x": 1]) == nil)
    let api: [String: Any] = ["five_hour": ["utilization": 18.0, "resets_at": "2026-09-18T10:30:00.672633+00:00"],
                              "seven_day": ["utilization": 18.0, "resets_at": "2026-09-25T00:00:00.672661+00:00"]]
    let probed = ClaudeUsageProbe.parse(api)
    check("the probe's utilization is read", probed?.fiveHourPercent == 18 && probed?.source == "api")
    check("six fractional digits do not defeat the ISO parse",
          probed?.fiveHourResetsAt == Date(timeIntervalSince1970: 1789727400), String(describing: probed?.fiveHourResetsAt))

    // Choosing where to go. The pool is main-actor state, like the store.
    let pool = ["\(home)/.claude-a", "\(home)/.claude-b", "\(home)/.claude-c"]
    let now = Date()
    MainActor.assumeIsolated {
    @MainActor func choose(_ setup: (ClaudeAccountPool) -> Void, avoiding: String? = nil) -> String? {
        let p = ClaudeAccountPool(); setup(p); return p.choose(from: pool, avoiding: avoiding, now: now)
    }
    check("with nothing known the primary is first", choose { _ in } == pool[0])
    check("a measured emptier login beats an unknown one",
          choose { $0.record(ClaudeAccountUsage(fiveHourPercent: 5), for: pool[2]) } == pool[2])
    check("a measured fuller login loses to an unknown one",
          choose { $0.record(ClaudeAccountUsage(fiveHourPercent: 60), for: pool[0]) } == pool[1])
    check("the login being left is not where you go",
          choose({ $0.record(ClaudeAccountUsage(fiveHourPercent: 1), for: pool[0]) }, avoiding: pool[0]) == pool[1])
    check("a limited login is skipped",
          choose { $0.markLimited(pool[0], until: now.addingTimeInterval(3600)) } == pool[1])
    check("a limit that has passed no longer counts",
          choose { $0.markLimited(pool[0], until: now.addingTimeInterval(-1)) } == pool[0])
    check("a reading under the cap clears the limit",
          choose { $0.markLimited(pool[0], until: now.addingTimeInterval(3600))
                   $0.record(ClaudeAccountUsage(fiveHourPercent: 3), for: pool[0]) } == pool[0])
    check("every login limited is nowhere to go",
          choose { p in pool.forEach { p.markLimited($0, until: now.addingTimeInterval(3600)) } } == nil)
    check("only the current one open means stay",
          choose({ p in p.markLimited(pool[1], until: now.addingTimeInterval(3600)); p.markLimited(pool[2], until: now.addingTimeInterval(3600)) },
                 avoiding: pool[0]) == pool[0])
    let stale = ClaudeAccountPool()
    stale.record(ClaudeAccountUsage(fiveHourPercent: 50, observedAt: now), for: pool[0])
    stale.record(ClaudeAccountUsage(fiveHourPercent: 1, observedAt: now.addingTimeInterval(-60)), for: pool[0])
    check("a stale reading never overwrites a newer one", stale.usage(for: pool[0])?.fiveHourPercent == 50)
    }

    // Claude's own clock in the notice → the next moment it reads so.
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/New_York")!
    let noon = cal.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 12))!
    func at(_ text: String) -> DateComponents? {
        ClaudeAccountPool.parseResumeClock(text, now: noon, calendar: cal).map { cal.dateComponents([.day, .hour, .minute], from: $0) }
    }
    check("1:40am after noon is tomorrow morning", at("1:40am") == DateComponents(day: 19, hour: 1, minute: 40), String(describing: at("1:40am")))
    check("3pm after noon is today", at("3pm") == DateComponents(day: 18, hour: 15, minute: 0))
    check("12pm reads as noon, so from noon it is tomorrow", at("12pm") == DateComponents(day: 19, hour: 12, minute: 0))
    check("12am is midnight", at("12am") == DateComponents(day: 19, hour: 0, minute: 0))
    check("a 24-hour clock is accepted", at("22:15") == DateComponents(day: 18, hour: 22, minute: 15))
    check("garbage is nil", ClaudeAccountPool.parseResumeClock("soon", now: noon, calendar: cal) == nil)

    // Resume arguments and transcript paths.
    let id = "e3aef11c-22dc-4dd1-9f76-40fedd67f18a"
    let staged = "\(home)/.claude-work/projects/-Users-dev-proj-app/\(id).jsonl"
    let resolved = ClaudeAccountPool.resolvingResume(["--permission-mode", "plan", "--resume", id],
                                                     directory: "/Users/dev/proj/app", primaryDir: "~/.claude-work",
                                                     chosenDir: "~/.claude-work-2", exists: { $0 == staged })
    check("--resume <id> becomes the primary's transcript path when starting on another login",
          resolved == ["--permission-mode", "plan", "--resume", staged], resolved.joined(separator: " "))
    check("on the primary itself the id is left alone",
          ClaudeAccountPool.resolvingResume(["--resume", id], directory: "/x", primaryDir: "~/.claude-work",
                                            chosenDir: "~/.claude-work/", exists: { _ in true }) == ["--resume", id])
    check("a path that is not there is left alone",
          ClaudeAccountPool.resolvingResume(["--resume", id], directory: "/x", primaryDir: "~/.claude-work",
                                            chosenDir: "~/.claude-work-2", exists: { _ in false }) == ["--resume", id])
    check("a --resume that is already a path is left alone",
          ClaudeAccountPool.resolvingResume(["--resume", "/tmp/x.jsonl"], directory: "/x", primaryDir: "~/.claude-work",
                                            chosenDir: "~/.claude-work-2", exists: { _ in true }) == ["--resume", "/tmp/x.jsonl"])
    check("dots in a folder escape like slashes", ClaudeAccountPool.escapedProjectDir("/home/b/projects/work/Udha.AIDesktop") == "-home-b-projects-work-Udha-AIDesktop")
    check("the config dir is read back off a transcript path",
          ClaudeAccountPool.configDir(fromTranscriptPath: staged) == "\(home)/.claude-work")
    check("a path with no projects segment is nothing", ClaudeAccountPool.configDir(fromTranscriptPath: "/tmp/x.jsonl") == nil)
}

// The usage-limit notice in the pane: the one place a hit limit is visible.
do {
    let limited = """
    ⏺ Updated the migration and re-ran the suite.

    ⏺ You've hit your session limit · resets 1:40am (America/New_York)

      Usage limit reached · continuing automatically at 1:40am · esc or type to cancel
    ──────────────────────────────────────────────────
    ❯
    ──────────────────────────────────────────────────
      ⏵⏵ bypass permissions on (shift+tab to cycle)
    """
    let r = ClaudePaneReader.read(raw: limited)
    check("the notice is read", r.usageLimit != nil)
    check("with the clock Claude printed", r.usageLimit?.resumesAt == "1:40am", r.usageLimit?.resumesAt ?? "nil")
    check("a limited session is not streaming", !r.isStreaming)
    let scrolled = """
      Usage limit reached · continuing automatically at 1:40am · esc or type to cancel
    ⏺ Back. Continuing with the migration.
    ⏺ Bash(npm test)
      ⎿  42 passing
    ⏺ Done — all green. Anything else?
    ⏺ Now let me look at the second suite.
    ⏺ Bash(npm run lint)
      ⎿  clean
    ⏺ Lint is clean too.
    ⏺ Bash(git status --short)
      ⎿  clean
    ⏺ Bash(git log -1)
      ⎿  abc123 tidy
    ⏺ Nothing left to commit.
    ⏺ Finished.
    ──────────────────────────────────────────────────
    ❯
    ──────────────────────────────────────────────────
      ⏵⏵ bypass permissions on (shift+tab to cycle)
    """
    check("the same words far up the scrollback are history, not a limit",
          ClaudePaneReader.read(raw: scrolled).usageLimit == nil)
    let prose = """
    ⏺ The usage limit reached yesterday was a session cap, not the weekly one.
    ──────────────────────────────────────────────────
    ❯
    ──────────────────────────────────────────────────
      ⏵⏵ bypass permissions on (shift+tab to cycle)
    """
    check("prose about a limit without Claude's own notice words is not a limit",
          ClaudePaneReader.read(raw: prose).usageLimit == nil)
    check("a pane with no notice has none", permission.usageLimit == nil)
    // A frame as the box actually painted one, subagents still running.
    let withAgents = """
    ⏺ Agent "Omega PPC program lead" failed: Agent terminated early due to an API error: You've
      hit your session limit · resets 5:50pm (America/New_York) (error type rate_limit, HTTP 429)
      ⎿  You've hit your session limit · resets 1:30am (America/New_York)
        Continuing automatically at 1:30am · esc to cancel
    ● Usage limit reached · continuing automatically at 1:30am · esc or type to cancel
    ✻ Waiting for 3 background agents to finish
      ◯ ppc-audit        reading ads.csv
      ◯ seo-audit        grepping sitemap
      ◯ content-audit    reading brief.md

    ──────────────────────────────────────────────────
    ❯
    ──────────────────────────────────────────────────
      ⏵⏵ bypass permissions on (shift+tab to cycle)
    """
    let agents = ClaudePaneReader.read(raw: withAgents)
    check("the notice is found above subagent rows", agents.usageLimit != nil)
    check("its clock is Claude's, not the failed agent's", agents.usageLimit?.resumesAt == "1:30am", agents.usageLimit?.resumesAt ?? "nil")
    let bare = """
      ⎿  You've hit your session limit · resets 1:30am (America/New_York)
        Continuing automatically at 1:30am · esc to cancel
    ──────────────────────────────────────────────────
    ❯
    ──────────────────────────────────────────────────
      ⏵⏵ bypass permissions on (shift+tab to cycle)
    """
    check("the bare continuing row alone is a notice", ClaudePaneReader.read(raw: bare).usageLimit?.resumesAt == "1:30am")

    // Claude Code 2.1.278 on the box, 2026-09-21: with background shells the
    // footer loses its "(shift+tab to cycle)" hint. Both sessions that hit a
    // limit on the 18th had this footer, and the reader saw no chrome at all.
    let shellsFooter = """
    ⏺ Confirmed. Nothing else independent tonight.

    ● Usage limit reached · continuing automatically at 4:30pm · esc or type to cancel
    ✻ Baked for 20m 13s · done 8:36 PM · 13 shells, 1 monitor still running

    ────────────────────────────────────────
    ❯ yes go ahead and tear down those 21 rigs
    ────────────────────────────────────────
      udha
      ⏵⏵ bypass permissions on · 13 shells, 1 monitor · ← for agents
      ● main
      ◯ general-purpose  Checking shanesmith-h1 rig in nginx.conf
      ◯ general-purpose  Listing deliverables in fhvlaw-1218323336301442
      ↓ 1 more
    """
    let shells = ClaudePaneReader.read(raw: shellsFooter)
    check("a footer without the shift+tab hint is still Claude", shells.isClaudeTUI)
    check("and it is not read as an overlay", !shells.isObscured)
    check("its mode is still read", shells.permissionMode == .bypass)
    check("the notice is read through that footer", shells.usageLimit?.resumesAt == "4:30pm", shells.usageLimit?.resumesAt ?? "nil")
    check("the done spinner survives its new suffix", shells.finishedDuration != nil, shells.finishedDuration ?? "nil")
    check("a draft is still read above that footer", shells.draft?.contains("tear down") == true)
    let agentsFooter = """
    ⏺ Done.
    ✻ Churned for 3s · done 2:46 PM
    ──────────────────────────────────────────────────
    ❯
    ──────────────────────────────────────────────────
      udha
      ⏵⏵ auto mode on · 3 shells · 3 memories · ← for agents
    """
    let autoAgents = ClaudePaneReader.read(raw: agentsFooter)
    check("the auto-mode shells footer anchors too", autoAgents.isClaudeTUI && !autoAgents.isStreaming)
    check("done with a clock suffix still reads as done", autoAgents.finishedDuration == "3s", autoAgents.finishedDuration ?? "nil")
}

// MCP configuration must survive both JSON and TOML parsing, including paths with spaces.
let codexAttentionArgs = try! AttentionAgent.configurationArguments(for: .codex,
    scriptPath: "/tmp/Udha Test/attention.py", mailboxPath: "/tmp/session")
check("Codex MCP arguments are TOML-compatible", !codexAttentionArgs.last!.contains("\\/"))
check("Codex receives session-specific arguments", codexAttentionArgs.last!.contains("/tmp/session"))
let claudeAttentionArgs = try! AttentionAgent.configurationArguments(for: .claude,
    scriptPath: "/tmp/Udha Test/attention.py", mailboxPath: "/tmp/session")
let claudeConfig = try! JSONSerialization.jsonObject(with: Data(claudeAttentionArgs[1].utf8)) as! [String: Any]
check("Claude receives a valid additive MCP config", claudeConfig["mcpServers"] != nil)
let hook = ClaudeStatusSidecar.parseEvent(line: #"{"udha_at":42,"payload":{"hook_event_name":"UserPromptSubmit"}}"#)
check("live hooks preserve their original event time", hook?.emittedAt == 42 && hook?.phase == .thinking)
check("legacy hook events still decode", ClaudeStatusSidecar.parseEvent(line: #"{"hook_event_name":"Stop"}"#)?.phase == .awaitingReply)

// MARK: - Explicit attention lifecycle, persistence, and wire compatibility
MainActor.assumeIsolated {
    let store = SessionStateStore()
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("udha-attention-tests-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: file) }
    store.loadAttention(from: file)
    var s = snapshot(state: .working, phase: .usingTool)
    s.tool = .claude
    let id = s.id
    store.insert(s)
    var notifications: [AttentionEvent] = []
    store.onAttentionEvent = { _, event in notifications.append(event) }
    store.update(id: id) {
        $0.lastQuestion = "An old rhetorical question?"
        $0.setPhase(.awaitingReply, detail: nil)
        $0.state = .idle
    }
    check("parsed questions no longer demand attention", store.snapshot(id: id)!.attention() == .quiet)
    check("parsed questions never push", notifications.isEmpty)
    store.update(id: id) { $0.attentionState.add(kind: .decision, summary: "Keep an archive?", id: "decision-1") }
    check("explicit decision sends one notification", notifications.count == 1)
    if let row = decodeAsClient(store.snapshot(id: id)!.wireRow(staleAfter: 1800)) {
        check("attention event ID crosses the wire", row.attentionState.events.first?.id == "decision-1")
        check("new attention capability survives decoding", row.supportsAttentionEvents)
        check("explicit decision is blocking on mobile", row.isBlocking)
        check("mobile names explicit decision", row.statusLabel == "Decision needed")
    } else { check("attention row decodes", false) }
    store.update(id: id) { $0.attentionState.add(kind: .decision, summary: "Keep an archive?", id: "retry") }
    check("same-turn duplicate cannot push again", notifications.count == 1)
    check("snooze accepted", store.changeAttention(id: id, action: "snooze", eventID: "decision-1"))
    check("snooze hides request", store.snapshot(id: id)!.attentionState.visibleEvents.isEmpty)
    store.update(id: id) { $0.attentionState.events[0].snoozedUntil = 1 }
    check("snooze expiry resurfaces the same event", store.snapshot(id: id)!.attentionState.visibleEvents.first?.id == "decision-1")
    check("snooze expiry does not resend push", notifications.count == 1)
    check("dismiss accepted", store.changeAttention(id: id, action: "dismiss", eventID: "decision-1"))
    check("stale action rejected", !store.changeAttention(id: id, action: "dismiss", eventID: "decision-1"))
    let restored = SessionStateStore()
    restored.loadAttention(from: file)
    var replayed = 0
    restored.onAttentionEvent = { _, _ in replayed += 1 }
    restored.insert(s)
    check("dismissal survives restart", restored.snapshot(id: id)!.attentionState.events.first?.state == .dismissed)
    check("restoring inbox never replays notifications", replayed == 0)
    store.beginAttentionTurn(id: id)
    store.update(id: id) { $0.attentionState.add(kind: .decision, summary: "Keep an archive?", id: "decision-2") }
    check("same text in a new turn can notify", notifications.count == 2)
    store.beginAttentionTurn(id: id)
    check("new user input resolves actionable request", store.snapshot(id: id)!.attentionState.visibleEvents.isEmpty)
    store.update(id: id) { $0.attentionState.add(kind: .review, summary: "Review the preview", url: "https://example.com") }
    check("reviews stay quiet by default", notifications.count == 2)
    store.beginAttentionTurn(id: id)
    check("review artifact survives another turn", store.snapshot(id: id)!.attentionState.visibleEvents.count == 1)
    _ = store.changeAttention(id: id, action: "reviews", enabled: true)
    store.update(id: id) { $0.attentionState.add(kind: .review, summary: "Another preview") }
    check("review opt-in allows notifications", notifications.count == 3)
    _ = store.changeAttention(id: id, action: "watch", enabled: true)
    store.update(id: id) { $0.phaseDetail = "Still idle" }
    check("arming idle session does not announce old completion", notifications.count == 3)
    store.update(id: id) { $0.setPhase(.thinking, detail: nil); $0.state = .working }
    store.update(id: id) { $0.attentionState.add(kind: .blocked, summary: "Need credentials") }
    store.update(id: id) { $0.setPhase(.awaitingReply, detail: nil); $0.state = .idle }
    check("blocked turn cannot satisfy completion watch", store.snapshot(id: id)!.attentionState.notifyWhenDone)
    store.beginAttentionTurn(id: id)
    store.update(id: id) { $0.setPhase(.thinking, detail: nil); $0.state = .working }
    store.update(id: id) { $0.setPhase(.awaitingReply, detail: nil); $0.state = .idle }
    check("ordinary turn end cannot claim task completion", store.snapshot(id: id)!.attentionState.notifyWhenDone)
    let completionCommand: [String: Any] = ["action": "task_completed", "commandID": UUID().uuidString,
        "createdAt": Date().timeIntervalSince1970, "summary": "Build verified and ready for review"]
    check("explicit task completion acknowledged", store.processAttentionCommand(id: id, command: completionCommand)["ok"] as? Bool == true)
    check("completion watch fires once", notifications.filter { $0.source == "watch" }.count == 1)
    _ = store.processAttentionCommand(id: id, command: completionCommand)
    check("replayed tool command is idempotent", notifications.filter { $0.source == "watch" }.count == 1)
    check("completion watch disarms", !store.snapshot(id: id)!.attentionState.notifyWhenDone)
    store.update(id: id) { $0.phaseDetail = "Ready" }
    check("repeated idle snapshots cannot push again", notifications.filter { $0.source == "watch" }.count == 1)
    store.update(id: id) { $0.setPhase(.awaitingApproval, detail: "Review command") }
    let approvalID = store.snapshot(id: id)!.attentionState.events.last(where: { $0.source == "approval" })!.id
    store.update(id: id) { $0.phaseDetail = "Review command again" }
    check("same live approval is not repeated", notifications.filter { $0.source == "approval" }.count == 1)
    store.update(id: id) { $0.setPhase(.usingTool, detail: nil) }
    check("leaving approval resolves that event", store.snapshot(id: id)!.attentionState.events.first(where: { $0.id == approvalID })?.state == .resolved)
    store.update(id: id) { $0.setPhase(.awaitingApproval, detail: "A different command") }
    let nextApproval = store.snapshot(id: id)!.attentionState.events.last(where: { $0.source == "approval" })!.id
    check("a second approval in the same turn is a new event", nextApproval != approvalID)
    _ = store.changeAttention(id: id, action: "dismiss", eventID: nextApproval)
    store.update(id: id) { $0.setPhase(.usingTool, detail: nil) }
    store.update(id: id) { $0.setPhase(.awaitingApproval, detail: "Third command") }
    check("dismissed approval does not hide later approvals", store.snapshot(id: id)!.attentionState.visibleEvents.contains(where: { $0.source == "approval" }))
    let staleCommand: [String: Any] = ["action": "request_attention", "commandID": UUID().uuidString,
        "kind": "decision", "summary": "Old decision", "createdAt": 1.0]
    check("stale queued command rejected", store.processAttentionCommand(id: id, command: staleCommand)["ok"] as? Bool == false)
    var unsafe = AttentionEvent(id: "unsafe", turnID: "t", kind: .review, summary: "Preview", url: "javascript:alert(1)", createdAt: 0)
    check("artifact actions reject executable URLs", unsafe.safeURL == nil)
    unsafe.url = "https://example.com/preview"
    check("artifact actions allow web previews", unsafe.safeURL != nil)
}

// Folder placement must support both edges, especially adjacent downward
// moves and appending after the final row (previously both were no-ops).
do {
    let a = UUID(), b = UUID(), c = UUID()
    let ids = [a, b, c]
    check("folder moves below its next neighbor", SessionFolder.reordered(ids, moving: a, target: b, after: true) == [b, a, c])
    check("folder moves to the very end", SessionFolder.reordered(ids, moving: a, target: c, after: true) == [b, c, a])
    check("folder moves to the very beginning", SessionFolder.reordered(ids, moving: c, target: a, after: false) == [c, a, b])
    check("folder moves upward after a target", SessionFolder.reordered(ids, moving: c, target: a, after: true) == [a, c, b])
    check("folder before its neighbor stays put", SessionFolder.reordered(ids, moving: a, target: b, after: false) == ids)
    check("folder dropped on itself stays put", SessionFolder.reordered(ids, moving: b, target: b, after: true) == ids)
    check("foreign folder cannot enter this host", SessionFolder.reordered(ids, moving: UUID(), target: a, after: true) == ids)
    check("deleted folder target leaves order intact", SessionFolder.reordered(ids, moving: a, target: UUID(), after: false) == ids)
}

// MARK: - Folders + hidden

// Both keys are optional by absence: a loose, visible row is byte-for-byte
// what every client saw before folders existed, and the phone's decoder must
// read a `sessions_full` that carries a `folders` list without noticing.
do {
    let folder = UUID()
    var snap = snapshot()
    let plain = snap.wireRow(staleAfter: 1800)
    check("a loose visible row carries neither key", plain["folder"] == nil && plain["hidden"] == nil)
    check("absent keys decode loose and visible",
          SessionSnapshot(wireRow: plain)?.folderID == nil && SessionSnapshot(wireRow: plain)?.hidden == false)
    snap.folderID = folder
    snap.hidden = true
    let row = snap.wireRow(staleAfter: 1800)
    check("folder rides as a uuid string", row["folder"] as? String == folder.uuidString)
    check("hidden rides only as true", row["hidden"] as? Bool == true)
    check("folder decodes back", SessionSnapshot(wireRow: row)?.folderID == folder)
    check("hidden decodes back", SessionSnapshot(wireRow: row)?.hidden == true)
    check("the phone's decoder ignores the new keys", decodeAsClient(row)?.id == snap.id.uuidString)

    let f = SessionFolder(id: folder, name: "Client A", hidden: true)
    check("folder wire round-trips", SessionFolder(wire: f.wireValue) == f)
    check("a visible folder omits hidden", SessionFolder(name: "x").wireValue["hidden"] == nil)
    check("a folder without hidden decodes visible",
          SessionFolder(wire: ["id": folder.uuidString, "name": "x"])?.hidden == false)
    check("a folder without a name is refused", SessionFolder(wire: ["id": folder.uuidString]) == nil)

    let envelope: [String: Any] = ["type": "sessions_full", "sessions": [row], "folders": [f.wireValue]]
    check("sessions_full with folders is valid JSON", JSONSerialization.isValidJSONObject(envelope))
    if case .sessionsFull(let full) = UdhaClient.BridgeDecoder.decode(payload: envelope) {
        check("the phone still reads the rows beside a folders key", full.rows.count == 1)
    } else {
        check("the phone decodes sessions_full with folders", false)
    }
    check("this host advertises folders", BridgeV2State.serverCapabilities.contains("folders"))

    // A folder written before `hidden` existed — or by hand — still loads.
    let legacyFolder = #"{"id":"\#(folder.uuidString)","name":"Old"}"#.data(using: .utf8)!
    check("a pre-hidden folder entry still decodes", (try? JSONDecoder().decode(SessionFolder.self, from: legacyFolder))?.hidden == false)
}

// The `accounts` reply: every login of a tree with its headroom, so the pane
// on the other machine shows the box's own numbers.
do {
    let usage = ClaudeAccountUsage(fiveHourPercent: 26, fiveHourResetsAt: Date(timeIntervalSince1970: 1_800_000_000),
                                   sevenDayPercent: 7, sevenDayResetsAt: nil,
                                   scopedPercent: 13, scopedResetsAt: Date(timeIntervalSince1970: 1_800_400_000), scopedLabel: "Fable",
                                   observedAt: Date(timeIntervalSince1970: 1_790_000_000), source: "api")
    let pool = ClaudeLoginPoolOverview(pathPrefix: "/home/b/projects/work", members: [
        ClaudeLoginOverview(dir: "/home/b/.claude-work", name: "work", email: "you@example.com", usage: usage),
        ClaudeLoginOverview(dir: "/home/b/.claude-work-2", name: "work-2",
                            limitedUntil: Date(timeIntervalSince1970: 1_800_000_000)),
    ])
    let envelope: [String: Any] = ["type": "accounts", "pools": [pool.wire]]
    check("accounts is valid JSON", JSONSerialization.isValidJSONObject(envelope))
    let back = ClaudeLoginPoolOverview(wire: pool.wire)
    check("a pool survives the wire", back == pool, "\(String(describing: back))")
    check("a login with no reading survives as no reading", back?.members[1].usage == nil)
    check("the signed-in email rides the wire", back?.members[0].email == "you@example.com")
    check("the Fable cap rides the wire", back?.members[0].usage?.scopedPercent == 13 && back?.members[0].usage?.scopedLabel == "Fable")
    check("the summary names the scoped model", usage.summary == "5h 26% · 7d 7% · Fable 13%", usage.summary)
    // The probe's reply, as api.anthropic.com shaped it on 2026-09-21.
    let probe: [String: Any] = [
        "five_hour": ["utilization": 4.0, "resets_at": "2026-09-22T07:00:00.354422+00:00"],
        "seven_day": ["utilization": 9.0, "resets_at": "2026-09-26T13:00:00.354439+00:00"],
        "limits": [
            ["kind": "session", "group": "session", "percent": 4],
            ["kind": "weekly_all", "group": "weekly", "percent": 9],
            ["kind": "weekly_scoped", "group": "weekly", "percent": 13,
             "resets_at": "2026-09-26T13:00:00.942879+00:00",
             "scope": ["model": ["id": NSNull(), "display_name": "Fable"]]],
        ],
    ]
    let parsed = ClaudeUsageProbe.parse(probe)
    check("the probe reads the scoped window", parsed?.scopedPercent == 13 && parsed?.scopedLabel == "Fable", parsed?.summary ?? "nil")
    check("the scoped window counts toward fullness", parsed?.usedPercent(at: Date(timeIntervalSince1970: 1_790_000_000)) == 13)
    let tick = ClaudeAccountUsage(fiveHourPercent: 5, sevenDayPercent: 9)
    check("a statusLine tick keeps the probe's Fable number", tick.keepingScoped(from: parsed).scopedPercent == 13)
    check("a login shows its email, else its short name",
          back?.members[0].displayName == "you@example.com" && back?.members[1].displayName == "work-2")
    check("a limited login stays limited across the wire", back?.members[1].isLimited(at: Date(timeIntervalSince1970: 1_799_999_999)) == true)
    check("a pool matches its tree by prefix",
          pool.covers("/home/b/projects/work/clients") && pool.covers("/home/b/projects/work")
          && !pool.covers("/home/b/projects/workx"))
    check("this host advertises accounts", BridgeV2State.serverCapabilities.contains("accounts"))
}

// A session entry written before folders existed must still decode — the
// config merge cannot fill defaults inside the `sessions` array, so a
// non-optional key here would reset the whole config on first launch.
do {
    let legacy = #"{"id":"\#(UUID().uuidString)","label":"a","directory":"/tmp","command":"claude","args":[],"env":{},"priority":"normal","enabled":true}"#.data(using: .utf8)!
    let cfg = try? JSONDecoder().decode(SessionConfig.self, from: legacy)
    check("a pre-folders session entry still decodes", cfg != nil)
    check("…as loose and visible", cfg?.folderID == nil && (cfg?.hidden ?? false) == false)
}

// The store keeps folders per host, only announces its own machine's, and
// derives `visible` from both the row's flag and its folder's.
MainActor.assumeIsolated {
    let store = SessionStateStore()
    var fired: [(SessionSnapshot?, UUID?)] = []
    store.onChange = { fired.append(($0, $1)) }
    let f = SessionFolder(name: "Work"), g = SessionFolder(name: "Parked", hidden: true)
    store.setFolders([f, g], host: nil)
    check("local folders fire the hook with nothing changed", fired.count == 1 && fired[0].0 == nil && fired[0].1 == nil)
    store.setFolders([f, g], host: nil)
    check("an identical list is de-duplicated", fired.count == 1)
    store.setFolders([SessionFolder(name: "Box")], host: "devbox")
    check("a remote host's folders never fire the hook", fired.count == 1)
    check("folders are kept per host",
          store.folders(host: nil).map(\.name) == ["Work", "Parked"] && store.folders(host: "devbox").map(\.name) == ["Box"])
    var a = snapshot(label: "a"); a.folderID = f.id
    var b = snapshot(label: "b"); b.folderID = g.id
    var c = snapshot(label: "c"); c.hidden = true
    var d = snapshot(label: "d"); d.folderID = UUID()          // folder deleted meanwhile
    for s in [a, b, c, d] { store.insert(s) }
    check("visible drops hidden rows and rows in hidden folders", store.visible.map(\.label) == ["a", "d"])
    check("all still holds everything", store.all.count == 4)
    check("hidden counts cover folders and sessions", store.hiddenCounts.folders == 1 && store.hiddenCounts.sessions == 2)
    store.setFolders([f, SessionFolder(id: g.id, name: "Parked")], host: nil)
    check("unhiding a folder brings its rows back", store.visible.map(\.label) == ["a", "b", "d"])
    store.update(id: c.id) { $0.hidden = false }
    check("a hidden flip alone is a change", fired.last?.0?.id == c.id && store.visible.count == 4)
    let n = fired.count
    store.update(id: c.id) { $0.hidden = false }
    check("a no-op hidden write is de-duplicated", fired.count == n)
    store.setFolders([], host: "devbox")
    check("clearing a remote host's folders is silent", fired.count == n && store.folders(host: "devbox").isEmpty)
}

print("\n\(checks - failures)/\(checks) passed")
exit(failures == 0 ? 0 : 1)
