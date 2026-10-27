import SwiftUI
import AppKit

/// Routes the Meetings section between the live recorder and a stored meeting.
struct MeetingsPane: View {
    let core: AppCore
    @Bindable var shell: UdhaShellModel

    private var meeting: Meeting? {
        guard let id = shell.selectedMeetingID else { return core.meetings.store.meetings.first }
        return core.meetings.store.meetings.first { $0.id == id } ?? core.meetings.store.meetings.first
    }

    var body: some View {
        Group {
            if shell.showingLive, let live = core.meetings.live {
                LiveMeetingPane(core: core, shell: shell, live: live)
            } else if let meeting {
                MeetingDetailPane(core: core, shell: shell, meeting: meeting)
            } else {
                UdhaEmptyState(
                    title: "No meetings yet",
                    text: "Record a call and Udha captures both sides, transcribes it live, and writes it up when you stop.",
                    action: ("Record meeting", "record.circle", {
                        Task { await core.meetings.start(mode: .standard) }
                        shell.openLive()
                    })
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Live

/// The in-call layout: your rough notes on the left, and a rail on the right
/// that can show the transcript, the action items, the growing diagram, or an
/// answer to a question you asked mid-call.
struct LiveMeetingPane: View {
    let core: AppCore
    @Bindable var shell: UdhaShellModel
    @Bindable var live: LiveMeeting

    @State private var noteDraft = ""
    @State private var askDraft = ""

    private var paused: Bool { live.recorder.state == .paused }
    private var failed: String? {
        if case .failed(let reason) = live.recorder.state { return reason }
        return nil
    }

    /// Narrowest notes column still worth typing into.
    private static let minNotesWidth: CGFloat = 260
    /// The rail's preferred width, and the floor it will compress to.
    private static let idealRailWidth: CGFloat = 396
    private static let minRailWidth: CGFloat = 300
    /// Below this the columns stack rather than sit side by side.
    private static let stackBelow: CGFloat = minNotesWidth + 14 + minRailWidth

    /// Give the rail its full width when there is room, and take it back down
    /// to the floor — never past it — as the pane narrows.
    private static func railWidth(paneWidth: CGFloat) -> CGFloat {
        min(idealRailWidth, max(minRailWidth, paneWidth - 14 - minNotesWidth))
    }

    var body: some View {
        VStack(spacing: UdhaTheme.cardGap) {
            header
            if let failed { failureBanner(failed) }
            // The rail used to be pinned at a hard 396pt; it now gives ground
            // down to 300pt, and below the width where even that leaves a
            // typable notes column the two stack instead of competing.
            GeometryReader { geo in
                let w = geo.size.width
                if w >= Self.stackBelow {
                    HStack(alignment: .top, spacing: UdhaTheme.cardGap) {
                        notesColumn
                        rail.frame(width: Self.railWidth(paneWidth: w))
                    }
                } else {
                    VStack(spacing: UdhaTheme.cardGap) {
                        notesColumn
                        rail
                    }
                }
            }
            .frame(maxHeight: .infinity)
            footer
        }
        .padding(.horizontal, UdhaTheme.contentInset)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: Header

    /// A red-tinted card: the pulsing dot, the clock, the name (double-click
    /// to fix it mid-call), the two level meters, and the controls.
    private var header: some View {
        HStack(spacing: 14) {
            Pulsing(active: !paused, period: 1.6) {
                Circle().fill(paused ? UdhaTheme.warn : UdhaTheme.bad).frame(width: 9, height: 9)
            }
            Text(paused ? "Paused" : "Recording")
                .font(UdhaTheme.text(12, .semibold))
                .foregroundStyle(paused ? UdhaTheme.warnInk : UdhaTheme.badInk)

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(UdhaFormat.clock(live.recorder.activeDuration))
                    .font(UdhaTheme.mono(15, weight: .medium))
                    .foregroundStyle(UdhaTheme.label)
            }

            // The name, fixable mid-call: the calendar's guess, or the
            // placeholder, is often wrong exactly while you can still see
            // who is on the screen. A name typed here is final — neither the
            // calendar nor the write-up will replace it.
            UdhaEditableTitle(text: live.meeting.title, font: UdhaTheme.text(15, .semibold),
                              tracking: -0.2, color: UdhaTheme.label) { name in
                var updated = live.meeting
                updated.title = name
                live.meeting = updated
                core.meetings.store.save(updated)
                shell.say("Renamed to \(name)")
            }
            .lineLimit(1)
            .frame(maxWidth: 360, alignment: .leading)
            .layoutPriority(1)

            HStack(spacing: 8) {
                Text("Me").font(UdhaTheme.text(10.5, .semibold)).foregroundStyle(UdhaTheme.secondary)
                BarMeter(heights: meterBars(live.recorder.micLevelPercent),
                         color: paused ? UdhaTheme.tertiary : UdhaTheme.accent, maxHeight: 16)
                Text("Them").font(UdhaTheme.text(10.5, .semibold)).foregroundStyle(UdhaTheme.secondary)
                    .padding(.leading, 8)
                BarMeter(heights: meterBars(live.recorder.systemLevelPercent),
                         color: paused ? UdhaTheme.tertiary : UdhaTheme.bad, maxHeight: 16)
            }
            .padding(.leading, 12)

            Spacer()

            if live.meeting.mode == .standard {
                Button {
                    core.meetings.switchLiveToProcessMapping()
                    shell.liveTab = .diagram
                    shell.say("Mapping the process from here on — including what's already been said")
                } label: {
                    UdhaLabel(title: "Map process", icon: "arrow.triangle.branch")
                }
                .udhaButton(.ghost, height: 26)
            }

            Button {
                core.meetings.markBreak()
                let at = UdhaFormat.clock(live.recorder.activeDuration)
                shell.say("Next meeting starts at \(at) — split when you stop")
            } label: {
                UdhaLabel(
                    title: live.breakpoints.isEmpty
                        ? "New meeting from here"
                        : "New meeting from here · \(live.breakpoints.count)",
                    icon: "scissors", iconSize: 11
                )
            }
            .udhaButton(.ghost, height: 26)
            .help("Forgot to stop? Mark where the next meeting began; the recording is cut there when you stop.")
            .contextMenu {
                if !live.breakpoints.isEmpty {
                    Button("Clear break marks") {
                        core.meetings.clearBreaks()
                        shell.say("Break marks cleared")
                    }
                }
            }

            Button(paused ? "Resume" : "Pause") {
                if paused {
                    Task { await live.recorder.resume() }
                    shell.say("Recording resumed")
                } else {
                    live.recorder.pause()
                    shell.say("Recording paused")
                }
            }
            .udhaButton(.ghost, height: 26)

            Button {
                Task { await core.meetings.stop() }
                shell.showingLive = false
                shell.say("Meeting ended · writing it up")
            } label: {
                UdhaLabel(title: "Stop & write it up", icon: "stop.fill", iconSize: 11)
            }
            .udhaButton(.danger, height: 26)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .udhaCard(fill: UdhaTheme.badTint)
    }

    /// Eight bars scaled off the live level, so a quiet stream visibly differs
    /// from a dead one without pretending to be a real waveform.
    private func meterBars(_ percent: Double) -> [CGFloat] {
        let base: [CGFloat] = [0.3, 0.7, 0.45, 1.0, 0.55, 0.8, 0.35, 0.5]
        let level = CGFloat(max(0.06, min(1, percent / 100)))
        return base.map { 2 + $0 * level * 14 }
    }

    private func failureBanner(_ reason: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12))
            Text("Recording failed — \(reason)")
                .font(UdhaTheme.text(12, .semibold))
            Spacer()
            Button("Stop") { Task { await core.meetings.stop() }; shell.showingLive = false }
                .udhaButton(.ghost, height: 24, hPadding: 10)
        }
        .foregroundStyle(UdhaTheme.badInk)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .udhaCard(fill: UdhaTheme.badTint)
    }

    // MARK: Notes

    private var notesColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Your notes")
                    .font(UdhaTheme.text(13, .semibold))
                    .foregroundStyle(UdhaTheme.label)
                Text("Type badly and briefly. These stay the backbone — Udha writes around them when you stop.")
                    .font(UdhaTheme.text(11.5, .regular))
                    .foregroundStyle(UdhaTheme.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)
            HRule(color: UdhaTheme.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(noteLines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 12) {
                            Text("—").font(UdhaTheme.text(13, .regular)).foregroundStyle(UdhaTheme.tertiary).padding(.top, 2)
                            Text(line)
                                .font(UdhaTheme.text(14, .regular))
                                .lineSpacing(4)
                                .foregroundStyle(UdhaTheme.label)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 9)
                        .overlay(alignment: .bottom) { HRule(color: UdhaTheme.hairline) }
                    }

                    HStack(alignment: .top, spacing: 12) {
                        Text("—").font(UdhaTheme.text(13, .regular)).foregroundStyle(UdhaTheme.accent).padding(.top, 2)
                        TextField("next note…", text: $noteDraft)
                            .textFieldStyle(.plain)
                            .font(UdhaTheme.text(14, .regular))
                            .foregroundStyle(UdhaTheme.label)
                            .onSubmit(commitNote)
                    }
                    .padding(.vertical, 9)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Udha is listening for")
                            .font(UdhaTheme.text(11, .semibold))
                            .foregroundStyle(UdhaTheme.secondary)
                        Text(listeningFor)
                            .font(UdhaTheme.text(12, .regular))
                            .foregroundStyle(UdhaTheme.secondary)
                            .lineSpacing(3)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .udhaWell()
                    .padding(.top, 18)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: 680, alignment: .leading)
            }
            .udhaScroll()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .udhaCard()
        .udhaRounded(UdhaTheme.cardRadius)
    }

    private var noteLines: [String] {
        live.roughNotes
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private var listeningFor: String {
        guard core.meetings.hasNotesModel else {
            return "No notes model, so nothing is being extracted. Recording and transcription carry on regardless — add an Anthropic key or switch notes to the local model in Settings › Meetings and the notes catch up when you stop."
        }
        let cadence = core.config.config.meetings.liveUpdateIntervalSec
        let model = core.config.config.meetings.liveModel
        return "Decisions, owners and dates — updated every \(cadence)s by \(model). Nothing is written to the final notes until you stop."
    }

    private func commitNote() {
        let text = noteDraft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        live.roughNotes = live.roughNotes.isEmpty ? text : live.roughNotes + "\n" + text
        noteDraft = ""
    }

    // MARK: Rail

    private var rail: some View {
        VStack(spacing: 0) {
            HStack {
                UdhaSegmented(
                    options: LiveMeetingTab.allCases.map { (value: $0, label: $0.rawValue.capitalized) },
                    selection: $shell.liveTab
                )
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            HRule(color: UdhaTheme.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch shell.liveTab {
                    case .ask:        askPane
                    case .transcript: transcriptPane
                    case .items:      itemsPane
                    case .diagram:    diagramPane
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .udhaScroll()
            .frame(maxHeight: .infinity)

            askBar
            statusStrip
        }
        .udhaCard()
        .udhaRounded(UdhaTheme.cardRadius)
    }

    // MARK: Rail panes

    private var transcriptPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            let segs = live.recorder.transcript.segments
            let translator = core.meetings.translator
            TranslateBar(translator: translator, meeting: live.meeting, compact: true)
                .padding(.bottom, 8)
            if segs.isEmpty {
                Text("Transcript appears as people speak.")
                    .font(UdhaTheme.text(12.5, .regular))
                    .foregroundStyle(UdhaTheme.secondary)
            }
            ForEach(Array(segs.suffix(80).enumerated()), id: \.element.id) { idx, seg in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(seg.speaker)
                            .font(UdhaTheme.text(11, .semibold))
                            .foregroundStyle(seg.source == .mic ? UdhaTheme.accentInk : UdhaTheme.badInk)
                        Spacer()
                        Mono(UdhaFormat.clock(seg.startTime), size: 10, color: UdhaTheme.tertiary)
                    }
                    Text(seg.text)
                        .font(UdhaTheme.text(13, .regular))
                        .lineSpacing(3)
                        .foregroundStyle(idx == segs.suffix(80).count - 1 ? UdhaTheme.secondary : UdhaTheme.label)
                        .textSelection(.enabled)
                    if translator.isOn {
                        TranslatedLine(text: translator.text(for: seg, in: live.meeting), size: 13)
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { HRule(color: UdhaTheme.hairline) }
            }
            liveTicker(live.recorder.sttHealthy
                ? "transcribing"
                : "transcription is retrying — audio is still being captured")
        }
        .onAppear { translateLive() }
        .onChange(of: live.recorder.transcript.segments.count) { _, _ in translateLive() }
        .onChange(of: core.meetings.translator.language) { _, _ in translateLive() }
    }

    private func translateLive() {
        core.meetings.translator.ensure(live.recorder.transcript.segments, for: live.meeting, newestFirst: true)
    }

    private var itemsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            let items = live.intelligence.actionItems
            if items.isEmpty {
                Text(core.meetings.hasNotesModel
                     ? "Action items appear once the first pass runs."
                     : "No notes model — no live items. The transcript is still being captured.")
                    .font(UdhaTheme.text(12.5, .regular))
                    .foregroundStyle(UdhaTheme.secondary)
            }
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 10) {
                    checkbox(item.done)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.text)
                            .font(UdhaTheme.text(13, .regular))
                            .lineSpacing(3)
                            .foregroundStyle(UdhaTheme.label)
                        if let owner = item.owner, !owner.isEmpty {
                            UdhaPill(owner, size: 10.5, height: 18)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 9)
                .overlay(alignment: .bottom) { HRule(color: UdhaTheme.hairline) }
            }
        }
    }

    private func checkbox(_ done: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(done ? UdhaTheme.accent : UdhaTheme.fill)
            .frame(width: 16, height: 16)
            .overlay {
                if done {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(UdhaTheme.onAccent)
                } else {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(UdhaTheme.separator, lineWidth: 1)
                }
            }
    }

    private var diagramPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            if live.meeting.mode != .processMapping {
                Text("Process mapping is off for this call.")
                    .font(UdhaTheme.text(12.5, .regular))
                    .foregroundStyle(UdhaTheme.secondary)
                Button("Start mapping now") {
                    core.meetings.switchLiveToProcessMapping()
                }
                .udhaButton(.ghost, height: 28, hPadding: 10)
            } else {
                let model = live.intelligence.processModel
                if model.isEmpty {
                    placeholderBox(
                        title: "Waiting for the first pass",
                        subtitle: "steps appear as the process is described"
                    )
                } else {
                    ProcessDiagramView(model: model)
                        .frame(height: 300)
                        .udhaRounded(10)
                        .udhaOutline(radius: 10)
                    Text("\(model.roles.count) lanes · \(model.steps.count) steps so far. Ids stay stable, so the diagram animates instead of jumping.")
                        .font(UdhaTheme.text(12, .regular))
                        .foregroundStyle(UdhaTheme.secondary)
                        .lineSpacing(2)
                }
            }
        }
    }

    private var askPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if live.ask.turns.isEmpty {
                Text("Ask anything about the call so far — “catch me up”, “what have they committed to”. The answer lands here, never in the call audio.")
                    .font(UdhaTheme.text(12.5, .regular))
                    .foregroundStyle(UdhaTheme.secondary)
                    .lineSpacing(3)
            }
            ForEach(live.ask.turns) { turn in
                VStack(alignment: .leading, spacing: 4) {
                    Text(turn.role == .you ? "You asked" : "Udha")
                        .font(UdhaTheme.text(11, .semibold))
                        .foregroundStyle(turn.role == .you ? UdhaTheme.secondary : UdhaTheme.accentInk)
                    Text(turn.text)
                        .font(UdhaTheme.text(13.5, turn.role == .you ? .medium : .regular))
                        .lineSpacing(3)
                        .foregroundStyle(turn.failed ? UdhaTheme.badInk : UdhaTheme.label)
                        .textSelection(.enabled)
                    if !turn.cite.isEmpty {
                        Mono("from transcript \(turn.cite)", size: 10, color: UdhaTheme.tertiary)
                    }
                }
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { HRule(color: UdhaTheme.hairline) }
            }
            if live.ask.isAnswering {
                liveTicker("reading the transcript…")
            } else {
                liveTicker("answers stay in your headphones — never in the call audio")
            }
        }
    }

    private func placeholderBox(title: String, subtitle: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(UdhaTheme.text(12, .medium)).foregroundStyle(UdhaTheme.secondary)
            Text(subtitle).font(UdhaTheme.text(11, .regular)).foregroundStyle(UdhaTheme.tertiary)
        }
        .frame(height: 260)
        .frame(maxWidth: .infinity)
        .udhaWell(radius: 10)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(UdhaTheme.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    private func liveTicker(_ text: String) -> some View {
        HStack(spacing: 8) {
            Pulsing(period: 1.0) {
                Circle().fill(UdhaTheme.bad).frame(width: 7, height: 7)
            }
            Text(text).font(UdhaTheme.text(11, .regular)).foregroundStyle(UdhaTheme.secondary)
        }
        .padding(.vertical, 10)
    }

    // MARK: Ask bar

    private var askBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(MeetingAsk.suggestions, id: \.self) { s in
                        Button {
                            shell.liveTab = .ask
                            live.ask.ask(s, speakAnswer: false)
                        } label: {
                            Text(s)
                        }
                        .udhaButton(.ghost, height: 24, hPadding: 9)
                    }
                }
                .padding(.bottom, 9)
            }

            HStack(spacing: 8) {
                UdhaField(placeholder: "Ask about this call…", text: $askDraft, height: 30) {
                    submitAsk(speak: false)
                }
                Button("Ask") { submitAsk(speak: false) }
                    .udhaButton(.primary, height: 30, hPadding: 12)
            }

            Text("Answered privately, never into the call")
                .font(UdhaTheme.text(10.5, .regular))
                .foregroundStyle(UdhaTheme.tertiary)
                .padding(.top, 7)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(UdhaTheme.fill)
        .overlay(alignment: .top) { HRule(color: UdhaTheme.hairline) }
    }

    private func submitAsk(speak: Bool) {
        let q = askDraft.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        shell.liveTab = .ask
        live.ask.ask(q, speakAnswer: speak)
        askDraft = ""
    }

    // MARK: Strips

    private var statusStrip: some View {
        HStack(spacing: 12) {
            streamDot("mic", live: !live.recorder.micUnavailable)
            streamDot("system audio", live: !live.recorder.systemAudioUnavailable)
            Spacer()
            Text(core.config.config.meetings.keepAudioRecordings ? "audio archiving" : "audio not kept")
                .font(UdhaTheme.text(10.5, .regular))
                .foregroundStyle(UdhaTheme.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { HRule(color: UdhaTheme.hairline) }
    }

    private func streamDot(_ label: String, live: Bool) -> some View {
        HStack(spacing: 5) {
            Circle().fill(live ? UdhaTheme.good : UdhaTheme.bad).frame(width: 6, height: 6)
            Text(live ? label : "\(label) unavailable")
                .font(UdhaTheme.text(10.5, .regular))
                .foregroundStyle(live ? UdhaTheme.secondary : UdhaTheme.badInk)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text(startedNote)
            Spacer()
            Text("⌘⇧R stop")
            Text("narration muted while recording")
        }
        .font(UdhaTheme.text(11, .regular))
        .foregroundStyle(UdhaTheme.tertiary)
        .padding(.horizontal, 4)
    }

    private var startedNote: String {
        guard let started = live.recorder.startedAt else { return "starting…" }
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return "Started \(f.string(from: started))"
    }
}

/// The 45° hatch used as a placeholder surface.
struct HatchPattern: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(UdhaTheme.fill))
            let step: CGFloat = 16
            var x = -size.height
            while x < size.width {
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x + size.height, y: 0))
                ctx.stroke(p, with: .color(UdhaTheme.fillStrong), lineWidth: 8)
                x += step
            }
        }
    }
}

// MARK: - Stored meeting

/// A finished meeting: notes, transcript, diagram.
struct MeetingDetailPane: View {
    let core: AppCore
    @Bindable var shell: UdhaShellModel
    let meeting: Meeting

    @State private var transcript: [TranscriptSegment] = []
    @State private var process: ProcessModel?
    @State private var aiNotes = ""
    @State private var userNotes = ""
    @State private var noteDraft = ""
    /// The transcript line the next meeting would start on, awaiting a yes.
    @State private var splitAt: TranscriptSegment?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UdhaTheme.cardGap) {
                header
                switch shell.meetingTab {
                case .notes:      notesTab
                case .transcript: transcriptTab
                case .diagram:    diagramTab
                }
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(.horizontal, UdhaTheme.contentInset)
            .padding(.top, 18)
            .padding(.bottom, 26)
        }
        .udhaScroll()
        .onAppear(perform: reload)
        .onChange(of: meeting.id) { _, _ in reload() }
        .onChange(of: meeting.finalized) { _, _ in reload() }
        .confirmationDialog(
            "Split “\(meeting.title)” at \(UdhaFormat.clock(splitAt?.startTime ?? 0))?",
            isPresented: Binding(get: { splitAt != nil }, set: { if !$0 { splitAt = nil } }),
            presenting: splitAt
        ) { seg in
            Button("Split into two meetings") { split(at: seg) }
            Button("Cancel", role: .cancel) {}
        } message: { seg in
            Text("Everything from “\(String(seg.text.prefix(60)))…” on becomes its own meeting. Both halves are written up again.")
        }
    }

    /// Other finished recordings within 12 hours of this one, nearest first.
    private var joinCandidates: [Meeting] {
        let liveID = core.meetings.live?.meeting.id
        return core.meetings.store.meetings
            .filter { $0.id != meeting.id && $0.id != liveID && $0.endedAt != nil }
            .filter { abs($0.createdAt.timeIntervalSince(meeting.createdAt)) < 12 * 3600 }
            .sorted { abs($0.createdAt.timeIntervalSince(meeting.createdAt)) < abs($1.createdAt.timeIntervalSince(meeting.createdAt)) }
    }

    private func join(with other: Meeting) {
        let mine = meeting
        shell.say("Joining \(mine.title) with \(other.title)")
        Task {
            if let joined = await core.meetings.join([mine, other]) {
                shell.selectedMeetingID = joined.id
                shell.meetingTab = .notes
                shell.say("Joined · writing it up")
            } else {
                shell.say("Couldn't join those")
            }
        }
    }

    private func split(at seg: TranscriptSegment) {
        let source = meeting
        shell.say("Splitting \(source.title) at \(UdhaFormat.clock(seg.startTime))")
        Task {
            if let second = await core.meetings.split(source, at: seg.startTime) {
                shell.selectedMeetingID = second.id
                shell.meetingTab = .notes
                shell.say("Split · writing up both meetings")
            } else {
                shell.say("Couldn't split there")
            }
        }
    }

    private func translateStored() {
        core.meetings.translator.ensure(transcript, for: meeting, newestFirst: false)
    }

    private func reload() {
        transcript = core.meetings.store.loadTranscript(for: meeting)
        process = core.meetings.store.loadProcessModel(for: meeting)
        aiNotes = core.meetings.store.loadAINotes(for: meeting)
        userNotes = core.meetings.store.loadUserNotes(for: meeting)
        noteDraft = ""
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    UdhaEditableTitle(text: meeting.title) { name in
                        var updated = meeting
                        updated.title = name
                        core.meetings.store.save(updated)
                        shell.say("Renamed to \(name)")
                    }
                    .padding(.leading, -6)
                    Text(stamp)
                        .font(UdhaTheme.text(12, .regular))
                        .foregroundStyle(UdhaTheme.secondary)
                    if let cal = meeting.calendarEvent {
                        Text(who(cal))
                            .font(UdhaTheme.text(12, .regular))
                            .foregroundStyle(UdhaTheme.secondary)
                            .lineLimit(1)
                            .help(([cal.organizer].compactMap { $0 } + cal.attendees).joined(separator: ", "))
                    }
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    if core.meetings.isFinalizing(meeting) {
                        UdhaPill("writing…", fg: UdhaTheme.accentInk, bg: UdhaTheme.accentTint)
                    }
                    Button(meeting.finalized ? "Regenerate" : "Generate notes") {
                        Task { await core.meetings.finalize(meeting) }
                        shell.say("Writing up \(meeting.title)")
                    }
                    .udhaButton(meeting.finalized ? .ghost : .primary, height: 26)
                    .disabled(!core.meetings.hasNotesModel || core.meetings.isFinalizing(meeting))

                    Menu {
                        Button("Export notes as Markdown…") {
                            MeetingExporter.exportNotes(meeting: meeting, store: core.meetings.store)
                        }
                        Button("Copy notes") {
                            MeetingExporter.copyNotes(meeting: meeting, store: core.meetings.store)
                            shell.say("Notes copied")
                        }
                        if let process {
                            Button("Copy mermaid") {
                                MeetingExporter.copyMermaid(model: process)
                                shell.say("Mermaid copied")
                            }
                            Button("Export diagram as PNG…") {
                                MeetingExporter.exportDiagramPNG(model: process, title: meeting.title)
                            }
                        } else if core.meetings.hasNotesModel {
                            Button("Map the process from the transcript") {
                                Task {
                                    await core.meetings.generateProcessMap(for: meeting)
                                    reload()
                                }
                            }
                        }
                        Divider()
                        Button("Split into two meetings…") {
                            shell.meetingTab = .transcript
                            shell.say("Right-click the line the next meeting starts on")
                        }
                        .disabled(transcript.count < 2 || core.meetings.live?.meeting.id == meeting.id)
                        // The inverse: a call recorded in pieces. Candidates
                        // are the other finished recordings from the same
                        // stretch of the day, nearest first.
                        Menu("Join with…") {
                            let candidates = joinCandidates
                            if candidates.isEmpty {
                                Text("No other recording within 12 hours")
                            }
                            ForEach(candidates) { other in
                                Button("\(other.createdAt.formatted(date: .omitted, time: .shortened)) · \(other.title)") {
                                    join(with: other)
                                }
                            }
                        }
                        .disabled(core.meetings.live?.meeting.id == meeting.id || core.meetings.isFinalizing(meeting))
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([core.meetings.store.folderURL(for: meeting)])
                        }
                    } label: {
                        UdhaLabel(title: "Export", icon: "square.and.arrow.up")
                            .foregroundStyle(UdhaTheme.label)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: UdhaTheme.controlRadius, style: .continuous).fill(UdhaTheme.fill))
                    .font(UdhaTheme.text(12, .medium))
                }
            }

            UdhaSegmented(
                options: MeetingDetailTab.allCases.map { (value: $0, label: $0.rawValue.capitalized) },
                selection: $shell.meetingTab
            )
        }
    }

    /// "you@example.com · Alice, Bob, Carol +6" — the calendar the event
    /// came from and who was invited, trimmed to fit one line.
    private func who(_ cal: CalendarEventRef) -> String {
        var parts = [cal.calendarTitle]
        if !cal.attendees.isEmpty {
            let shown = cal.attendees.prefix(3).map { $0.components(separatedBy: " ").first ?? $0 }
            let more = cal.attendees.count - shown.count
            parts.append(shown.joined(separator: ", ") + (more > 0 ? " +\(more)" : ""))
        }
        return parts.joined(separator: " · ")
    }

    private var stamp: String {
        var parts = [UdhaFormat.stamp(meeting.createdAt)]
        if let d = meeting.durationSeconds { parts.append(UdhaFormat.elapsed(d)) }
        parts.append(meeting.hasAudio ? "mic + system audio" : "transcript only")
        if meeting.endedAt != nil && !meeting.finalized { parts.append("needs summary") }
        return parts.joined(separator: " · ")
    }

    // MARK: Tabs

    private var notesTab: some View {
        VStack(alignment: .leading, spacing: UdhaTheme.cardGap) {
            if !meeting.summary.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Summary").font(UdhaTheme.text(13, .semibold)).foregroundStyle(UdhaTheme.label)
                    Text(meeting.summary)
                        .font(UdhaTheme.text(14, .regular))
                        .lineSpacing(5)
                        .foregroundStyle(UdhaTheme.label)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .udhaCard()
            } else if !meeting.finalized {
                Text(core.meetings.hasNotesModel
                     ? "Not written up yet. Hit Generate notes."
                     : "Not written up — no notes model. The transcript below is complete.")
                    .font(UdhaTheme.text(13, .regular))
                    .foregroundStyle(UdhaTheme.secondary)
                    .padding(.horizontal, 4)
            }

            yourNotesSection

            if !meeting.actionItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    UdhaSectionHead(title: "Action items", note: "\(meeting.actionItems.count) items")
                    VStack(spacing: 0) {
                        ForEach(Array(meeting.actionItems.enumerated()), id: \.element.id) { index, item in
                            HStack(alignment: .top, spacing: 11) {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(item.done ? UdhaTheme.accent : UdhaTheme.fill)
                                    .frame(width: 17, height: 17)
                                    .overlay {
                                        if item.done {
                                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(UdhaTheme.onAccent)
                                        } else {
                                            RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(UdhaTheme.separator, lineWidth: 1)
                                        }
                                    }
                                    .padding(.top, 1)
                                Text(item.text)
                                    .font(UdhaTheme.text(13, .regular))
                                    .lineSpacing(3)
                                    .foregroundStyle(UdhaTheme.label)
                                Spacer(minLength: 10)
                                if let owner = item.owner, !owner.isEmpty {
                                    UdhaPill(owner, size: 10.5, height: 20)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(alignment: .top) { if index > 0 { HRule(color: UdhaTheme.hairline) } }
                        }
                    }
                    .udhaCard()
                    .udhaRounded(UdhaTheme.cardRadius)
                }
            }

            if !aiNotes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    UdhaSectionHead(title: "Notes")
                    UdhaMarkdown(text: aiNotes, size: 13.5)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .udhaCard()
                }
            }
        }
    }

    /// The notes you typed during the call, in the same dash-per-line form the
    /// live pane writes them. Still appendable, because the follow-up you
    /// remember five minutes later belongs with them.
    private var yourNotesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            UdhaSectionHead(title: "Your notes")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(userNoteLines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .top, spacing: 12) {
                        Text("—").font(UdhaTheme.text(13, .regular)).foregroundStyle(UdhaTheme.tertiary).padding(.top, 2)
                        Text(line)
                            .font(UdhaTheme.text(13.5, .regular))
                            .lineSpacing(4)
                            .foregroundStyle(UdhaTheme.label)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .overlay(alignment: .top) { if index > 0 { HRule(color: UdhaTheme.hairline) } }
                }

                HStack(alignment: .top, spacing: 12) {
                    Text("—").font(UdhaTheme.text(13, .regular)).foregroundStyle(UdhaTheme.accent).padding(.top, 2)
                    TextField(userNoteLines.isEmpty ? "nothing typed during this call — add a note…" : "add a note…",
                              text: $noteDraft)
                        .textFieldStyle(.plain)
                        .font(UdhaTheme.text(13.5, .regular))
                        .foregroundStyle(UdhaTheme.label)
                        .onSubmit(commitNote)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .overlay(alignment: .top) { if !userNoteLines.isEmpty { HRule(color: UdhaTheme.hairline) } }
            }
            .udhaCard()
            .udhaRounded(UdhaTheme.cardRadius)
        }
    }

    private var userNoteLines: [String] {
        userNotes
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func commitNote() {
        let text = noteDraft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        userNotes = userNotes.isEmpty ? text : userNotes + "\n" + text
        noteDraft = ""
        core.meetings.store.writeUserNotes(userNotes, for: meeting)
        shell.say(meeting.finalized ? "Note added — Regenerate to fold it in" : "Note added")
    }

    private var transcriptTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !transcript.isEmpty {
                TranslateBar(translator: core.meetings.translator, meeting: meeting, compact: false)
            }
            transcriptCard
                .onAppear { translateStored() }
                .onChange(of: transcript.count) { _, _ in translateStored() }
                .onChange(of: core.meetings.translator.language) { _, _ in translateStored() }
            if transcript.count > 1 {
                Text("Right-click a line to start a new meeting from it.")
                    .font(UdhaTheme.text(11, .regular))
                    .foregroundStyle(UdhaTheme.tertiary)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if transcript.isEmpty {
                Text("No transcript stored for this meeting.")
                    .font(UdhaTheme.text(13, .regular))
                    .foregroundStyle(UdhaTheme.secondary)
                    .padding(16)
            }
            ForEach(Array(transcript.enumerated()), id: \.element.id) { index, seg in
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(seg.speaker)
                            .font(UdhaTheme.text(11, .semibold))
                            .foregroundStyle(seg.source == .mic ? UdhaTheme.accentInk : UdhaTheme.badInk)
                        Mono(UdhaFormat.clock(seg.startTime), size: 10, color: UdhaTheme.tertiary)
                    }
                    .frame(width: 92, alignment: .leading)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(seg.text)
                            .font(UdhaTheme.text(13.5, .regular))
                            .lineSpacing(4)
                            .foregroundStyle(UdhaTheme.label)
                            .textSelection(.enabled)
                        if core.meetings.translator.isOn {
                            TranslatedLine(text: core.meetings.translator.text(for: seg, in: meeting), size: 13.5)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .overlay(alignment: .top) { if index > 0 { HRule(color: UdhaTheme.hairline) } }
                .contentShape(Rectangle())
                .contextMenu {
                    if index > 0 {
                        Button("New meeting starts here") { splitAt = seg }
                            .disabled(core.meetings.live?.meeting.id == meeting.id)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .udhaCard()
        .udhaRounded(UdhaTheme.cardRadius)
    }

    private var diagramTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let process, !process.isEmpty {
                ProcessDiagramView(model: process)
                    .frame(height: 360)
                    .udhaCard()
                    .udhaRounded(UdhaTheme.cardRadius)
                Text("\(process.roles.count) lanes · \(process.steps.count) steps — export as PNG or mermaid")
                    .font(UdhaTheme.text(11.5, .regular))
                    .foregroundStyle(UdhaTheme.secondary)
                    .padding(.horizontal, 4)
            } else if core.meetings.isGeneratingProcess(meeting) {
                Text("Mapping the process from the transcript…")
                    .font(UdhaTheme.text(13, .regular))
                    .foregroundStyle(UdhaTheme.secondary)
                    .padding(.horizontal, 4)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No diagram for this meeting.")
                        .font(UdhaTheme.text(13, .regular))
                        .foregroundStyle(UdhaTheme.secondary)
                    Button("Map the process from the transcript") {
                        Task {
                            await core.meetings.generateProcessMap(for: meeting)
                            reload()
                        }
                    }
                    .udhaButton(.ghost, height: 28)
                    .disabled(!core.meetings.hasNotesModel || transcript.count < 5)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .udhaCard()
            }
        }
    }
}


// MARK: - Translation

/// "Translate · [Albanian ▾] · translating…" — the language picker that sits
/// above a transcript. The choice is one setting for every meeting, live or
/// stored, because you read them all in the same language.
struct TranslateBar: View {
    let translator: MeetingTranslator
    let meeting: Meeting
    var compact: Bool

    private var options: [(value: String, label: String)] {
        [("", "Off")] + MeetingTranslator.languages.map { ($0, $0) }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "character.bubble")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(UdhaTheme.secondary)
            if !compact {
                Text("Translate")
                    .font(UdhaTheme.text(12, .medium))
                    .foregroundStyle(UdhaTheme.secondary)
            }
            UdhaSelect(
                options: options,
                selection: Binding(get: { translator.language }, set: { translator.setLanguage($0) }),
                minWidth: compact ? 124 : 150
            )
            if translator.isOn && translator.isBusy(meeting) {
                HStack(spacing: 5) {
                    WorkingDots()
                    Text("translating on the box")
                        .font(UdhaTheme.text(11, .regular))
                        .foregroundStyle(UdhaTheme.tertiary)
                }
            } else if translator.isOn, let err = translator.lastError {
                Text(err)
                    .font(UdhaTheme.text(11, .regular))
                    .foregroundStyle(UdhaTheme.badInk)
                    .lineLimit(1)
                    .help(err)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, compact ? 0 : 4)
    }
}

/// The translated line under an original: accent ink so the eye can tell
/// the two apart, a faint dash while the batch is still on its way.
struct TranslatedLine: View {
    let text: String?
    var size: CGFloat

    var body: some View {
        if let text {
            Text(text)
                .font(UdhaTheme.text(size, .regular))
                .lineSpacing(size * 0.28)
                .foregroundStyle(UdhaTheme.accentInk)
                .textSelection(.enabled)
        } else {
            Text("···")
                .font(UdhaTheme.text(size, .regular))
                .foregroundStyle(UdhaTheme.tertiary)
        }
    }
}
