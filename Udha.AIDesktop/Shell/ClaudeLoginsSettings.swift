import SwiftUI

/// Settings → Claude logins, for one machine: every tree's pool, who each
/// login is signed in as, how full it is, and the buttons that add a login,
/// sign it in, or drop it.
///
/// This Mac edits its own config; a box is edited through the bridge's
/// pool verbs and shows whatever its `accounts` reply says, so the list is
/// always the owning machine's truth. Signing in is the one step no machine
/// can do for you — `claude auth login` prints a URL and waits for a code —
/// so "Sign in" opens a terminal running exactly that, over `ssh -t` for a box.
struct ClaudeLoginsEditor: View {
    let core: AppCore
    /// Nil for this Mac, a host name for a box.
    let host: String?

    /// The name typed into each pool's add field, by tree.
    @State private var newLoginName: [String: String] = [:]
    @State private var newTreePrefix = ""
    @State private var newTreeDir = ""
    @State private var localError: String?
    /// The email typed for a login a box is still making, for its sign-in.
    @State private var pendingEmail: String?

    private var isLocal: Bool { host == nil }

    private var pools: [ClaudeLoginPoolOverview] {
        isLocal ? core.sessionManager.poolOverviews() : core.remoteHostClient.hostAccounts
    }

    private var defaultLogin: ClaudeLoginOverview? {
        isLocal ? core.sessionManager.defaultLoginOverview() : core.remoteHostClient.hostDefaultLogin
    }

    private var failure: String? {
        isLocal ? localError : core.remoteHostClient.loginEditFailure
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let login = defaultLogin {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Everything else")
                        .font(UdhaTheme.text(12, .semibold))
                        .foregroundStyle(UdhaTheme.label)
                    loginRow(login, primary: true, pathPrefix: nil)
                }
                .padding(10)
                .udhaWell()
            }
            ForEach(pools) { pool in poolCard(pool) }
            newTreeCard
            if let failure {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(failure)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Dismiss") {
                        localError = nil
                        core.remoteHostClient.clearLoginEditFailure()
                    }
                    .udhaButton(.bare, height: 22, hPadding: 6)
                }
                .font(UdhaTheme.text(11.5, .medium))
                .foregroundStyle(UdhaTheme.badInk)
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(UdhaTheme.badTint))
            }
            HStack(spacing: 8) {
                Button {
                    if isLocal { core.sessionManager.refreshLoginEmails() }
                    else { core.remoteHostClient.requestAccounts() }
                } label: {
                    UdhaLabel(title: "Refresh", icon: "arrow.clockwise", iconSize: 11)
                }
                .udhaButton(.ghost, height: 24, hPadding: 8)
                .help("Re-read who each dir is signed in as — after a sign-in finished in the terminal")
                Text("Usage is probed every 5 minutes; the Fable cap only comes from that probe.")
                    .font(UdhaTheme.text(11, .regular))
                    .foregroundStyle(UdhaTheme.tertiary)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        // A box that just made a dir for a new login: open its sign-in here,
        // the one step the box cannot do on its own.
        .onChange(of: core.remoteHostClient.loginDirToSignIn) { _, dir in
            guard !isLocal, let dir else { return }
            core.remoteHostClient.clearLoginDirToSignIn()
            signIn(dir, email: pendingEmail)
            pendingEmail = nil
        }
    }

    // MARK: - One tree

    private func poolCard(_ pool: ClaudeLoginPoolOverview) -> some View {
        let primary = pool.members.first?.dir
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(UdhaTheme.accent)
                Mono(UdhaFormat.tildePath(pool.pathPrefix), size: 12)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Button("Remove tree") { removeTree(pool.pathPrefix) }
                    .udhaButton(.bare, height: 22, hPadding: 6)
                    .help("Forget this tree's pool. Nothing on disk is touched; sessions there go back to the default login.")
            }
            ForEach(pool.members) { login in
                loginRow(login, primary: login.dir == primary, pathPrefix: pool.pathPrefix)
            }
            HStack(spacing: 8) {
                TextField("email of the new login, e.g. you@example.com", text: Binding(
                    get: { newLoginName[pool.pathPrefix] ?? "" },
                    set: { newLoginName[pool.pathPrefix] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(UdhaTheme.text(12, .regular))
                .frame(maxWidth: 260)
                .onSubmit { addLogin(to: pool) }
                Button {
                    addLogin(to: pool)
                } label: {
                    UdhaLabel(title: "Add login", icon: "plus", iconSize: 11)
                }
                .udhaButton(.ghost, height: 24, hPadding: 8)
                .disabled((newLoginName[pool.pathPrefix] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Makes ~/.claude-<name> (the part before the @) sharing this tree's settings, skills and transcripts, adds it to the pool, then opens a terminal to sign it in with that email")
            }
            .padding(.top, 2)
        }
        .padding(10)
        .udhaWell()
    }

    /// Email (or the dir's short name), the dir, its headroom, and the
    /// actions that apply: Sign in while nothing is signed in, Remove for an
    /// alternate.
    private func loginRow(_ login: ClaudeLoginOverview, primary: Bool, pathPrefix: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: login.email == nil || login.needsSignIn ? "person.crop.circle.badge.questionmark" : "person.crop.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(login.email == nil || login.needsSignIn ? UdhaTheme.warn : UdhaTheme.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(login.displayName)
                        .font(UdhaTheme.text(12.5, .semibold))
                        .foregroundStyle(UdhaTheme.label)
                        .lineLimit(1)
                    if primary {
                        UdhaPill("primary", fg: UdhaTheme.secondary, bg: UdhaTheme.fill, size: 10, height: 16)
                    }
                    if login.isLimited() {
                        UdhaPill(login.headroom(), fg: UdhaTheme.badInk, bg: UdhaTheme.badTint, size: 10, height: 16)
                    }
                }
                HStack(spacing: 6) {
                    Mono(UdhaFormat.tildePath(login.dir), size: 10.5, color: UdhaTheme.tertiary)
                        .lineLimit(1)
                    Text("·")
                        .foregroundStyle(UdhaTheme.tertiary)
                    Text(login.email == nil ? "not signed in"
                         : login.needsSignIn ? "signed out — token expired, sign in again"
                         : (login.usage?.summary ?? "no reading yet"))
                        .font(UdhaTheme.text(11, .regular))
                        .foregroundStyle(login.email == nil || login.needsSignIn ? UdhaTheme.warnInk : UdhaTheme.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if login.email == nil || login.needsSignIn {
                Button {
                    signIn(login.dir)
                } label: {
                    UdhaLabel(title: "Sign in", icon: "key", iconSize: 11)
                }
                .udhaButton(.primary, height: 24, hPadding: 8)
                .help("Opens a terminal running `claude auth login` for this dir — open the URL it prints, paste the code")
            }
            if !primary, pathPrefix != nil {
                Button("Remove") { removeLogin(login.dir) }
                    .udhaButton(.bare, height: 22, hPadding: 6)
                    .help("Drop this login from the pool. The dir and its sign-in stay on disk.")
            }
        }
        .padding(.vertical, 3)
    }

    private var newTreeCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("New tree")
                .font(UdhaTheme.text(12, .semibold))
                .foregroundStyle(UdhaTheme.label)
            Text("Every session under a folder runs as its own login. Name the folder and the config dir that signs it in; the dir is made by the first sign-in.")
                .font(UdhaTheme.text(11, .regular))
                .foregroundStyle(UdhaTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("folder, e.g. ~/projects/acme", text: $newTreePrefix)
                    .textFieldStyle(.roundedBorder)
                    .font(UdhaTheme.text(12, .regular))
                TextField("config dir, e.g. ~/.claude-acme", text: $newTreeDir)
                    .textFieldStyle(.roundedBorder)
                    .font(UdhaTheme.text(12, .regular))
                Button {
                    addTree()
                } label: {
                    UdhaLabel(title: "Add tree", icon: "plus", iconSize: 11)
                }
                .udhaButton(.ghost, height: 24, hPadding: 8)
                .disabled(newTreePrefix.trimmingCharacters(in: .whitespaces).isEmpty
                          || newTreeDir.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(10)
        .udhaWell()
    }

    // MARK: - Actions

    private func addLogin(to pool: ClaudeLoginPoolOverview) {
        let name = (newLoginName[pool.pathPrefix] ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        // An email is the natural thing to type; it names the dir and
        // pre-fills the sign-in. Kept until the add succeeds, so a refusal
        // leaves what you typed in place.
        let email = name.contains("@") ? name : nil
        if isLocal {
            do {
                let dir = try core.sessionManager.addClaudeLogin(pathPrefix: pool.pathPrefix, name: name)
                newLoginName[pool.pathPrefix] = ""
                signIn(dir, email: email)
            } catch {
                localError = "\(error)"
            }
        } else {
            pendingEmail = email
            newLoginName[pool.pathPrefix] = ""
            core.remoteHostClient.addClaudeLogin(pathPrefix: pool.pathPrefix, name: name)
        }
    }

    private func removeLogin(_ dir: String) {
        if isLocal {
            do { try core.sessionManager.removeClaudeLogin(dir: dir) } catch { localError = "\(error)" }
        } else {
            core.remoteHostClient.removeClaudeLogin(dir: dir)
        }
    }

    private func addTree() {
        let prefix = newTreePrefix.trimmingCharacters(in: .whitespaces)
        let dir = newTreeDir.trimmingCharacters(in: .whitespaces)
        if isLocal {
            do {
                try core.sessionManager.addClaudeTree(pathPrefix: prefix, configDir: dir)
                newTreePrefix = ""; newTreeDir = ""
            } catch {
                localError = "\(error)"
            }
        } else {
            core.remoteHostClient.addClaudeTree(pathPrefix: prefix, configDir: dir)
            newTreePrefix = ""; newTreeDir = ""
        }
    }

    private func removeTree(_ pathPrefix: String) {
        if isLocal {
            do { try core.sessionManager.removeClaudeTree(pathPrefix: pathPrefix) } catch { localError = "\(error)" }
        } else {
            core.remoteHostClient.removeClaudeTree(pathPrefix: pathPrefix)
        }
    }

    private func signIn(_ dir: String, email: String? = nil) {
        core.sessionManager.openTerminal(
            running: SessionManager.signInCommand(configDir: dir, email: email),
            on: host,
            title: "Sign in \(ClaudeAccountPool.shortName(dir))" + (host.map { " · \($0)" } ?? "")
        )
    }
}
