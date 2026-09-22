import SwiftUI

/// Folder browser for a remote host — the equivalent of the native "Choose…"
/// panel (which can only see this Mac's disk) for sessions that will run on
/// the box. Backed by the relay's `list_directory`, which returns directories
/// only, so every row is somewhere a session can start.
struct RemoteFolderPicker: View {
    let core: AppCore
    let host: String
    @Binding var directory: String
    @Binding var isPresented: Bool

    @State private var showHidden = false
    @State private var requestedPath = ""
    /// Non-nil while the inline "New folder" field is open; its value is the name.
    @State private var newFolderName: String?
    @FocusState private var newFolderFocused: Bool

    private var listing: RemoteHostClient.DirectoryListing? { core.remoteHostClient.directoryListing }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: where we are.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Eyebrow("Folder on \(host)", tracking: 1.0)
                Spacer()
                Toggle("Hidden", isOn: $showHidden)
                    .toggleStyle(.checkbox)
                    .font(UdhaTheme.text(11, .regular))
                    .onChange(of: showHidden) { _, _ in request(listing?.path ?? requestedPath) }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)

            HStack(spacing: 8) {
                Button {
                    if let parent = listing?.parent, !parent.isEmpty { request(parent) }
                } label: {
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .semibold))
                }
                .udhaButton(.ghost, height: 26, hPadding: 8)
                .disabled((listing?.parent ?? "").isEmpty)
                Mono(listing?.path ?? requestedPath, size: 11.5, color: UdhaTheme.ink)
                    .lineLimit(1).truncationMode(.head)
                Spacer(minLength: 0)
                // Starting a new project means the folder does not exist yet,
                // which is exactly when a browser that can only *find* folders
                // sends you to a terminal instead.
                Button {
                    newFolderName = ""
                    newFolderFocused = true
                } label: {
                    UdhaLabel(title: "New folder", icon: "folder.badge.plus")
                }
                .udhaButton(.ghost, height: 26, hPadding: 8)
                .disabled(listing?.path == nil)
            }
            .padding(.horizontal, 16).padding(.bottom, 8)

            if let pending = newFolderName {
                HStack(spacing: 6) {
                    UdhaField(placeholder: "folder-name", text: Binding(
                        get: { pending }, set: { newFolderName = $0 }
                    ), height: 26, mono: true) { commitNewFolder() }
                        .focused($newFolderFocused)
                    Button("Create") { commitNewFolder() }
                        .udhaButton(.primary, height: 26, hPadding: 10)
                        .disabled(pending.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") {
                        newFolderName = nil
                        core.remoteHostClient.clearCreateDirFailure()
                    }
                    .udhaButton(.ghost, height: 26, hPadding: 10)
                }
                .padding(.horizontal, 16).padding(.bottom, 8)
            }

            if let why = core.remoteHostClient.createDirFailure {
                Text(why)
                    .font(UdhaTheme.text(11.5, .regular))
                    .foregroundStyle(UdhaTheme.red)
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }
            HRule(color: UdhaTheme.rule)

            // Entries.
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let error = listing?.error {
                        Text(error).font(UdhaTheme.text(12, .regular)).foregroundStyle(UdhaTheme.red)
                            .padding(16)
                    } else if listing == nil {
                        Text("Loading…").font(UdhaTheme.text(12, .regular)).foregroundStyle(UdhaTheme.faint)
                            .padding(16)
                    } else if listing!.entries.isEmpty {
                        Text("No subfolders.").font(UdhaTheme.text(12, .regular)).foregroundStyle(UdhaTheme.faint)
                            .padding(16)
                    } else {
                        ForEach(listing!.entries) { entry in
                            Button { request(entry.path) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: entry.isRepo ? "shippingbox" : "folder")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(entry.isRepo ? UdhaTheme.redInk : UdhaTheme.muted)
                                        .frame(width: 14)
                                    Text(entry.name).font(UdhaTheme.text(12.5, .regular)).foregroundStyle(UdhaTheme.ink)
                                        .lineLimit(1)
                                    Spacer()
                                    if entry.isRepo { Mono("repo", size: 9, color: UdhaTheme.faint) }
                                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(UdhaTheme.faint)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .hoverBackground(base: .clear, hover: UdhaTheme.rowHover)
                            .overlay(alignment: .bottom) { HRule(color: UdhaTheme.ruleFaint) }
                        }
                    }
                }
            }
            .frame(minHeight: 260, maxHeight: 360)

            HRule()
            HStack(spacing: 8) {
                Text("Choose selects the folder shown above.")
                    .font(UdhaTheme.text(11, .regular)).foregroundStyle(UdhaTheme.faint)
                Spacer()
                Button("Cancel") { isPresented = false }
                    .udhaButton(.ghost, height: 28, hPadding: 12)
                Button("Choose") {
                    if let path = listing?.path, !path.isEmpty { directory = path }
                    isPresented = false
                }
                .udhaButton(.primary, height: 28, hPadding: 16)
                .disabled((listing?.path ?? "").isEmpty || listing?.error != nil)
            }
            .padding(12)
        }
        .frame(width: 520)
        .background(UdhaTheme.paper)
        .onAppear {
            // Start where the field points (a host path), else the host's home.
            request(directory.isEmpty ? "" : directory)
        }
    }

    private func request(_ path: String) {
        requestedPath = path
        core.remoteHostClient.listDirectory(path.isEmpty ? nil : path, showHidden: showHidden)
    }

    /// Ask the host to make the folder and, on success, walk into it — the host
    /// answers `create_directory` with a listing of the new folder, so the
    /// browser is already there and Choose picks it.
    private func commitNewFolder() {
        let name = (newFolderName ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let parent = listing?.path else { return }
        core.remoteHostClient.createDirectory(in: parent, name: name, showHidden: showHidden)
        newFolderName = nil
    }
}
