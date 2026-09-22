import SwiftUI
import AppKit

/// Start a supervised session: pick a folder, a command, and how much Claude
/// is allowed to do without asking.
struct UdhaNewSessionSheet: View {
    let core: AppCore
    /// "New session here" on a folder: the machine and folder to start in.
    /// Applied once, before the defaults, then cleared so ⌘N never inherits it.
    var seed: UdhaShellModel.NewSessionSeed? = nil
    var clearSeed: () -> Void = {}
    @Binding var isPresented: Bool
    var onStarted: (UUID) -> Void

    @State private var label = ""
    /// Set once the user types in the Label field. Until then the label is a
    /// mirror of the chosen folder and follows every change to it.
    @State private var labelIsMine = false
    @State private var directory = ""
    @State private var command = ""
    /// Which assistant to run: nil means the plain shell command below, which
    /// is what the Command field was before there was anything to choose.
    @State private var tool: SessionTool? = .claude
    /// The last hand-typed command, so flipping to Claude and back doesn't
    /// eat what you typed.
    @State private var shellCommand = ""
    @State private var permission: ClaudePermissionMode = .acceptEdits
    @State private var codexApproval: CodexApprovalMode = .workspaceWrite
    @State private var qwenApproval: QwenApprovalMode = .autoEdit
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("New session")
                    .font(UdhaTheme.text(15, .bold))
                    .tracking(-0.15)
                    .foregroundStyle(UdhaTheme.label)
                Spacer()
                UdhaKeyHint("⌘N")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            HRule()

            VStack(alignment: .leading, spacing: 14) {
                if !recents.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow("Recent projects")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(recents, id: \.self) { dir in
                                    Button {
                                        directory = dir
                                    } label: {
                                        Text((dir as NSString).lastPathComponent)
                                            .font(UdhaTheme.text(11.5, .medium))
                                            .foregroundStyle(dir == directory ? UdhaTheme.onAccent : UdhaTheme.label)
                                            .padding(.horizontal, 9)
                                            .frame(height: 24)
                                            .background(Capsule().fill(dir == directory ? UdhaTheme.accent : UdhaTheme.fill))
                                            .contentShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .help(dir)
                                }
                            }
                            .padding(.bottom, 2)
                        }
                    }
                }

                field("Label") {
                    UdhaField(placeholder: "project name", text: Binding(
                        get: { label },
                        set: { typed in
                            guard typed != label else { return }
                            label = typed
                            labelIsMine = true
                        }
                    ), height: 28)
                }

                if !core.remoteHostClient.onlineHosts.isEmpty {
                    field("Machine") {
                        Picker("", selection: $targetHost) {
                            Text("This Mac").tag(String?.none)
                            ForEach(core.remoteHostClient.onlineHosts.sorted(), id: \.self) { h in
                                Text(h).tag(String?.some(h))
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }

                field("Working directory") {
                    HStack(spacing: 6) {
                        UdhaField(placeholder: "~/projects/…", text: $directory, height: 28, mono: true)
                        if isRemote {
                            Button("Browse…") { showRemoteBrowser = true }
                                .udhaButton(.ghost, height: 28, hPadding: 10)
                        } else {
                            Button("Choose…") { choose() }
                                .udhaButton(.ghost, height: 28, hPadding: 10)
                        }
                    }
                }

                field("Assistant") {
                    UdhaSegmented(options: Self.assistantOptions, selection: $tool)
                }

                // Only a plain shell command needs typing — every assistant in
                // the picker is the binary the picker just chose.
                if tool == nil {
                    field("Command") {
                        UdhaField(placeholder: "npm run dev", text: $command, height: 28, mono: true)
                    }
                }

                switch tool {
                case .claude:
                    field("Permissions") {
                        VStack(alignment: .leading, spacing: 5) {
                            UdhaSelect(
                                options: ClaudePermissionMode.allCases.map { ($0, $0.label) },
                                selection: $permission,
                                minWidth: 280
                            )
                            Text(permission.detail)
                                .font(UdhaTheme.text(12, .regular))
                                .foregroundStyle(permission == .bypass ? UdhaTheme.redInk : UdhaTheme.muted)
                        }
                    }
                case .codex:
                    field("Approvals") {
                        VStack(alignment: .leading, spacing: 5) {
                            UdhaSelect(
                                options: CodexApprovalMode.allCases.map { ($0, $0.label) },
                                selection: $codexApproval,
                                minWidth: 280
                            )
                            Text(codexApproval.detail)
                                .font(UdhaTheme.text(12, .regular))
                                .foregroundStyle(codexApproval == .bypass ? UdhaTheme.redInk : UdhaTheme.muted)
                        }
                    }
                case .qwen:
                    field("Approvals") {
                        VStack(alignment: .leading, spacing: 5) {
                            UdhaSelect(
                                options: QwenApprovalMode.allCases.map { ($0, $0.label) },
                                selection: $qwenApproval,
                                minWidth: 280
                            )
                            Text(qwenApproval.detail)
                                .font(UdhaTheme.text(12, .regular))
                                .foregroundStyle(qwenApproval == .yolo ? UdhaTheme.redInk : UdhaTheme.muted)
                        }
                    }
                case nil:
                    EmptyView()
                }

                if !error.isEmpty {
                    Text(error)
                        .font(UdhaTheme.text(12, .regular))
                        .foregroundStyle(UdhaTheme.redInk)
                }
            }
            .padding(18)

            Spacer(minLength: 0)
            HRule(color: UdhaTheme.rule)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .udhaButton(.ghost, height: 28, hPadding: 12)
                Button("Start") { start() }
                    .udhaButton(.primary, height: 28, hPadding: 16)
                    .disabled(label.isEmpty || directory.isEmpty)
                    .keyboardShortcut(.return)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 520)
        .background(UdhaTheme.canvas)
        .onAppear {
            if let seed {
                targetHost = seed.host
                folderID = seed.folderID
                clearSeed()
            }
            prefill()
        }
        // The folder can change from the recents chips, the Choose… panel or
        // by typing a path. All three land here, so the name can never be left
        // pointing at the previously selected project.
        .onChange(of: directory) { _, dir in syncLabelToDirectory(dir) }
        .onChange(of: targetHost) { _, _ in directory = ""; folderID = nil; prefill() }
        // The command is what actually launches, so the picker writes it. A
        // hand-typed one is parked, not lost, while an assistant is selected.
        .onChange(of: tool) { previous, new in
            if previous == nil { shellCommand = command }
            command = new?.command ?? shellCommand
        }
        .sheet(isPresented: $showRemoteBrowser) {
            RemoteFolderPicker(core: core, host: targetHost ?? "", directory: $directory,
                               isPresented: $showRemoteBrowser)
        }
    }

    /// Claude · ChatGPT · Qwen · Command. `nil` is the plain-command escape
    /// hatch the Command field used to be on its own.
    private static let assistantOptions: [(value: SessionTool?, label: String)] =
        SessionTool.allCases.map { (Optional($0), $0.label) } + [(nil, "Command")]

    /// Where to create the session: nil = this Mac, else a connected host.
    @State private var targetHost: String? = nil
    /// The folder the new session is filed in on `targetHost`; nil = loose.
    @State private var folderID: UUID? = nil
    @State private var showRemoteBrowser = false
    private var isRemote: Bool { targetHost != nil }
    private var recents: [String] {
        isRemote ? core.remoteHostClient.recentDirs : core.config.recentDirectoriesForDisplay
    }

    private func field<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Eyebrow(title)
            content()
        }
    }

    private func prefill() {
        let defaults = core.config.config.newSession
        if command.isEmpty {
            command = defaults.command
            tool = defaults.tool
            if tool == nil { shellCommand = command }
        }
        if directory.isEmpty {
            // In remote mode the Mac's default path doesn't exist on the host —
            // seed from the host's own recents, or leave blank for the user.
            directory = isRemote ? (recents.first ?? "")
                                 : (defaults.directory.isEmpty ? (recents.first ?? "") : defaults.directory)
        }
        syncLabelToDirectory(directory)
        permission = defaults.permission
        codexApproval = defaults.codexApproval
        qwenApproval = defaults.qwenApproval
    }

    /// Name the session after its folder — including the collision suffix, so
    /// what the sheet shows is what the sidebar, the tmux session and the
    /// Terminal title will say. Stops as soon as the user names it themselves.
    private func syncLabelToDirectory(_ dir: String) {
        guard !labelIsMine else { return }
        let folder = (dir as NSString).lastPathComponent
        label = folder.isEmpty ? "" : core.sessionManager.availableLabel(folder)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        // A new project starts with a folder that does not exist yet. Without
        // this the panel can only find folders, which sends you to a terminal
        // to run `mkdir` and back again.
        panel.canCreateDirectories = true
        panel.prompt = "Use folder"
        panel.message = "Pick the folder for this session — or make a new one."
        if panel.runModal() == .OK, let url = panel.url {
            directory = url.path
        }
    }

    /// The raw name of the chosen posture for whichever assistant is selected,
    /// or nil for a plain command — the one value the sheet, the config and the
    /// bridge all speak in.
    private var permissionRaw: String? {
        switch tool {
        case .claude: return permission.rawValue
        case .codex:  return codexApproval.rawValue
        case .qwen:   return qwenApproval.rawValue
        case nil:     return nil
        }
    }

    /// The tool name sent to a host. Remote sessions used to always be Claude.
    private var chosenTool: String? { tool?.rawValue }

    private func start() {
        if let host = targetHost {
            // The host owns creation: it spawns the tmux/Claude session, makes the
            // label unique, and the new session arrives back over the session
            // feed — so there's no local id to hand to `onStarted`.
            let dir = directory, lbl = label
            let perm = permissionRaw
            let folder = folderID
            if core.currentHostName != host { core.selectHost(host) }
            Task { @MainActor in
                for _ in 0..<40 {
                    if core.remoteHostClient.state == .connected { break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                core.remoteHostClient.createSession(directory: dir, label: lbl, prompt: nil,
                                                    tool: chosenTool, permission: perm, folder: folder)
            }
            isPresented = false
            return
        }
        var cfg = SessionConfig(
            label: core.sessionManager.availableLabel(label),
            directory: directory,
            command: command,
            args: tool?.args(permission: permissionRaw) ?? []
        )
        cfg.folderID = folderID
        core.config.mutate { $0.sessions.append(cfg) }
        core.config.recordRecentDirectory(directory)
        do {
            let id = try core.sessionManager.spawn(sessionConfig: cfg)
            onStarted(id)
            isPresented = false
        } catch {
            self.error = error.localizedDescription
            Log.app.error("spawn failed: \(error.localizedDescription)")
        }
    }
}
