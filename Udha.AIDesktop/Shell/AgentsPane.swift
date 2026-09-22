import SwiftUI
import AppKit

/// One agent: what it is, where to run it, and the prompt it will paste.
struct AgentsPane: View {
    let core: AppCore
    @Bindable var shell: UdhaShellModel

    @State private var editing: Agent?
    @State private var folderOverride: String?

    private var agent: Agent? {
        guard let slug = shell.selectedAgentSlug else { return core.agents.agents.first }
        return core.agents.agent(slug: slug) ?? core.agents.agents.first
    }

    /// Where "Run in …" will spawn: an explicit pick, else the selected
    /// session's folder, else the last folder used.
    private var runDirectory: String? {
        if let folderOverride { return folderOverride }
        if let id = shell.selectedSessionID, let snap = core.stateStore.snapshot(id: id) {
            return snap.directory
        }
        return core.config.recentDirectoriesForDisplay.first
    }

    var body: some View {
        Group {
            if let agent {
                detail(agent)
            } else {
                UdhaEmptyState(
                    title: "No agents",
                    text: "An agent is a reusable prompt in a .md file. Running one spawns a fresh Claude session on a folder and pastes the prompt in.",
                    action: ("New agent", "plus", { shell.newAgentPending = true })
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $editing) { target in
            AgentPromptEditor(store: core.agents, agent: target) { saved in
                shell.selectedAgentSlug = saved?.slug ?? shell.selectedAgentSlug
                editing = nil
            }
        }
        .onChange(of: shell.agentEditorSlug) { _, slug in
            guard let slug, let target = core.agents.agent(slug: slug) else { return }
            editing = target
            shell.agentEditorSlug = nil
        }
        .onChange(of: shell.newAgentPending) { _, pending in
            guard pending else { return }
            shell.newAgentPending = false
            let created = core.agents.create(name: "New agent")
            shell.selectedAgentSlug = created.slug
            editing = created
        }
    }

    private func detail(_ agent: Agent) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UdhaTheme.cardGap) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text(agent.name)
                            .font(UdhaTheme.text(22, .bold))
                            .tracking(-0.3)
                            .foregroundStyle(UdhaTheme.label)
                        if agent.isBuiltIn { UdhaPill("Built in", height: 20) }
                    }
                    Text(agent.description.isEmpty ? "No description yet." : agent.description)
                        .font(UdhaTheme.text(13, .regular))
                        .lineSpacing(3)
                        .foregroundStyle(UdhaTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button {
                        run(agent)
                    } label: {
                        UdhaLabel(title: "Run in \(folderName)", icon: "play.fill", iconSize: 11)
                    }
                    .udhaButton(.primary, height: 28, hPadding: 12)
                    .disabled(runDirectory == nil)

                    Button("Choose folder…") { chooseFolder() }
                        .udhaButton(.ghost, height: 28, hPadding: 12)

                    Button("Edit prompt") { editing = agent }
                        .udhaButton(.ghost, height: 28, hPadding: 12)

                    Spacer()

                    if !agent.isBuiltIn {
                        Button("Delete…") {
                            core.agents.delete(agent)
                            shell.selectedAgentSlug = core.agents.agents.first?.slug
                        }
                        .udhaButton(.danger, height: 28, hPadding: 12)
                    }
                }

                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Mono("\(agent.slug).md", size: 11.5)
                        Spacer()
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([
                                core.agents.agentsDirectory.appendingPathComponent("\(agent.slug).md")
                            ])
                        }
                        .udhaButton(.ghost, height: 24, hPadding: 10)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    HRule(color: UdhaTheme.hairline)
                    ScrollView {
                        Text(agent.prompt.isEmpty ? "(empty prompt)" : agent.prompt)
                            .font(UdhaTheme.mono(11.5))
                            .lineSpacing(6)
                            .foregroundStyle(UdhaTheme.inkCode)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                    }
                    .frame(maxHeight: 420)
                    .background(UdhaTheme.fill)
                }
                .udhaCard()
                .udhaRounded(UdhaTheme.cardRadius)

                if let runs = agentRuns(agent), !runs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        UdhaSectionHead(title: "Runs", note: "\(runs.count)")
                        VStack(spacing: 0) {
                            ForEach(Array(runs.enumerated()), id: \.element.id) { index, snap in
                                let style = UdhaSessionStyle(snapshot: snap,
                                                             staleAfter: core.config.config.staleAfterSeconds)
                                Button { shell.select(session: snap.id) } label: {
                                    HStack(spacing: 10) {
                                        Text(snap.label)
                                            .font(UdhaTheme.text(12.5, .medium))
                                            .foregroundStyle(UdhaTheme.label)
                                        style.chip
                                        Spacer()
                                        Mono(UdhaFormat.duration(since: snap.phaseEnteredAt), size: 11, color: UdhaTheme.tertiary)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 9)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .hoverBackground(base: .clear, hover: UdhaTheme.fill, radius: 0)
                                .overlay(alignment: .top) { if index > 0 { HRule(color: UdhaTheme.hairline) } }
                            }
                        }
                        .udhaCard()
                        .udhaRounded(UdhaTheme.cardRadius)
                    }
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.horizontal, UdhaTheme.contentInset)
            .padding(.top, 18)
            .padding(.bottom, 26)
        }
        .udhaScroll()
    }

    private var folderName: String {
        guard let dir = runDirectory else { return "…" }
        return (dir as NSString).lastPathComponent
    }

    private func agentRuns(_ agent: Agent) -> [SessionSnapshot]? {
        let runs = core.stateStore.all.filter { $0.agentName == agent.name }
        return runs.isEmpty ? nil : runs
    }

    private func run(_ agent: Agent) {
        guard let dir = runDirectory else { return }
        let source = shell.selectedSessionID.flatMap { core.stateStore.snapshot(id: $0) }
        let sourceID = source?.directory == dir ? source?.id : nil
        if let id = core.sessionManager.runAgent(agent, sourceSessionID: sourceID, directory: dir) {
            shell.select(session: id)
            shell.say("\(agent.name) running in \(folderName)")
        } else {
            shell.say("Could not start \(agent.name)")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            folderOverride = url.path
        }
    }
}

/// Frontmatter + prompt editor for one agent.
struct AgentPromptEditor: View {
    let store: AgentStore
    let agent: Agent
    let onClose: (Agent?) -> Void

    @State private var name: String
    @State private var description: String
    @State private var prompt: String

    init(store: AgentStore, agent: Agent, onClose: @escaping (Agent?) -> Void) {
        self.store = store
        self.agent = agent
        self.onClose = onClose
        _name = State(initialValue: agent.name)
        _description = State(initialValue: agent.description)
        _prompt = State(initialValue: agent.prompt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Edit agent")
                    .font(UdhaTheme.text(15, .bold))
                    .foregroundStyle(UdhaTheme.label)
                Spacer()
                Mono("\(agent.slug).md", size: 11)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            HRule()

            VStack(alignment: .leading, spacing: 14) {
                labelled("Name") { UdhaField(placeholder: "Security audit", text: $name, height: 28) }
                labelled("Description") {
                    UdhaField(placeholder: "One line shown in the picker", text: $description, height: 28)
                }
                labelled("Prompt") {
                    TextEditor(text: $prompt)
                        .font(UdhaTheme.mono(12))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(height: 300)
                        .background(RoundedRectangle(cornerRadius: UdhaTheme.rowRadius, style: .continuous).fill(UdhaTheme.card))
                        .udhaOutline(radius: UdhaTheme.rowRadius)
                }
            }
            .padding(18)

            Spacer()
            HRule()
            HStack {
                if agent.isBuiltIn {
                    Text("Built in — saving writes your own copy over the shipped one")
                        .font(UdhaTheme.text(11, .regular))
                        .foregroundStyle(UdhaTheme.secondary)
                }
                Spacer()
                Button("Cancel") { onClose(nil) }
                    .udhaButton(.ghost, height: 28, hPadding: 12)
                Button("Save") {
                    var updated = agent
                    updated.name = name
                    updated.description = description
                    updated.prompt = prompt
                    onClose(store.save(updated))
                }
                .udhaButton(.primary, height: 28, hPadding: 14)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 640, height: 560)
        .background(UdhaTheme.canvas)
    }

    private func labelled<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Eyebrow(title)
            content()
        }
    }
}
