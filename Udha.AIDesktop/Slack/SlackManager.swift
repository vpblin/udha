import Foundation
import Observation

enum SlackWorkspaceStatus: Equatable, Sendable {
    case idle
    case polling
    case tokenMissing
    case error(String)
}

enum SlackAddWorkspaceError: Error, LocalizedError {
    case invalidToken(String)
    case alreadyAdded
    case tokenStoreFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidToken(let msg): return "Slack token rejected: \(msg)"
        case .alreadyAdded: return "Workspace already connected"
        case .tokenStoreFailed(let msg): return "Could not save token: \(msg)"
        }
    }
}

enum SlackSendError: Error, LocalizedError {
    case noWorkspaces
    case workspaceNotFound(String)
    case workspaceAmbiguous([String])
    case tokenMissing(String)
    case recipientNotFound(String)
    case api(String)

    var errorDescription: String? {
        switch self {
        case .noWorkspaces: return "No Slack workspaces connected."
        case .workspaceNotFound(let hint): return "No workspace matching '\(hint)'."
        case .workspaceAmbiguous(let names): return "Multiple workspaces match — specify one: \(names.joined(separator: ", "))."
        case .tokenMissing(let name): return "Token missing for \(name) — reconnect the workspace."
        case .recipientNotFound(let r): return "Couldn't find '\(r)' in that workspace."
        case .api(let msg): return "Slack send failed: \(msg)."
        }
    }
}

struct SlackSendResult: Sendable {
    let workspaceName: String
    let channelID: String
    let recipientLabel: String
    let ts: String
}

struct SlackFetchedMessage: Sendable {
    let workspaceName: String
    let channelLabel: String
    let senderName: String
    let text: String
    let ts: String
}

@MainActor
@Observable
final class SlackManager {
    static let requiredReadScopes: Set<String> = [
        "channels:history", "groups:history", "im:history", "mpim:history", "users:read",
    ]
    static let requiredSendScopes: Set<String> = [
        "chat:write", "im:write",
    ]
    static var allRequiredScopes: Set<String> {
        requiredReadScopes.union(requiredSendScopes)
    }

    let config: ConfigStore
    let keychain: KeychainStore

    private(set) var status: [String: SlackWorkspaceStatus] = [:]
    private(set) var lastRecaps: [String] = []    // rolling UI preview
    private(set) var missingScopes: [String: Set<String>] = [:]  // teamID -> missing

    /// Per-thread history behind the Inbox section. The poller is forward-only,
    /// so this is what Udha has seen while running, not a Slack mirror.
    let inbox = SlackInbox()

    private var pollers: [String: SlackPoller] = [:]

    init(
        config: ConfigStore,
        keychain: KeychainStore
    ) {
        self.config = config
        self.keychain = keychain
    }

    // MARK: - Lifecycle

    func start() {
        inbox.load()
        inbox.applyWorkspaceDomains(config.config.slack.workspaces)
        for ws in config.config.slack.workspaces where ws.enabled {
            startPoller(for: ws)
        }
    }

    func stop() {
        for (id, poller) in pollers {
            Task { await poller.stop() }
            status[id] = .idle
        }
        pollers.removeAll()
    }

    func refreshPollers() {
        let enabled = Set(config.config.slack.workspaces.filter(\.enabled).map(\.id))
        for id in pollers.keys where !enabled.contains(id) {
            if let p = pollers[id] { Task { await p.stop() } }
            pollers[id] = nil
            status[id] = .idle
        }
        for ws in config.config.slack.workspaces where ws.enabled {
            if pollers[ws.id] == nil { startPoller(for: ws) }
        }
    }

    // MARK: - Workspace CRUD

    func addWorkspace(userToken: String) async throws -> SlackWorkspaceRecord {
        let trimmed = userToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = SlackAPIClient(token: trimmed)
        let auth: SlackAuthTestResponse
        do {
            auth = try await client.authTest()
        } catch {
            throw SlackAddWorkspaceError.invalidToken(error.localizedDescription)
        }
        guard auth.ok, let teamId = auth.teamId, let userId = auth.userId else {
            throw SlackAddWorkspaceError.invalidToken(auth.error ?? "auth.test not ok")
        }
        if config.config.slack.workspaces.contains(where: { $0.teamID == teamId }) {
            throw SlackAddWorkspaceError.alreadyAdded
        }

        let domain = auth.url.flatMap { URL(string: $0)?.host } ?? ""
        let record = SlackWorkspaceRecord(
            teamID: teamId,
            teamName: auth.team ?? "Slack",
            teamDomain: domain,
            userID: userId,
            userName: auth.user ?? "you"
        )
        do {
            try keychain.set(trimmed, account: record.keychainAccount)
        } catch {
            throw SlackAddWorkspaceError.tokenStoreFailed(error.localizedDescription)
        }
        config.mutate { $0.slack.workspaces.append(record) }
        await refreshMissingScopes(for: record, client: client)
        startPoller(for: record)
        return record
    }

    /// Pulls the token's granted scopes and stores any missing ones so the UI
    /// can warn and the user knows to reinstall their Slack app.
    func refreshMissingScopes(for ws: SlackWorkspaceRecord, client: SlackAPIClient? = nil) async {
        let c: SlackAPIClient
        if let client {
            c = client
        } else if let token = keychain.get(account: ws.keychainAccount) {
            c = SlackAPIClient(token: token)
        } else {
            return
        }
        do {
            let granted = try await c.fetchGrantedScopes()
            let missing = Self.allRequiredScopes.subtracting(granted)
            missingScopes[ws.teamID] = missing
            if !missing.isEmpty {
                Log.slack.error("[\(ws.teamName)] missing OAuth scopes: \(missing.sorted().joined(separator: ", "))")
            }
        } catch {
            Log.slack.error("[\(ws.teamName)] could not fetch scopes: \(error.localizedDescription)")
        }
    }

    func removeWorkspace(teamID: String) {
        if let poller = pollers.removeValue(forKey: teamID) {
            Task { await poller.stop() }
        }
        status[teamID] = .idle
        if let ws = config.config.slack.workspaces.first(where: { $0.teamID == teamID }) {
            keychain.delete(account: ws.keychainAccount)
        }
        config.mutate { $0.slack.workspaces.removeAll { $0.teamID == teamID } }
    }

    func setEnabled(teamID: String, enabled: Bool) {
        config.mutate { cfg in
            if let idx = cfg.slack.workspaces.firstIndex(where: { $0.teamID == teamID }) {
                cfg.slack.workspaces[idx].enabled = enabled
            }
        }
        refreshPollers()
    }

    // MARK: - Polling

    private func startPoller(for ws: SlackWorkspaceRecord) {
        guard let token = keychain.get(account: ws.keychainAccount) else {
            status[ws.id] = .tokenMissing
            Log.slack.error("no token in keychain for workspace \(ws.teamName)")
            return
        }
        let client = SlackAPIClient(token: token)
        let settings = config.config.slack
        let includeChannels = settings.announceMentions || settings.announceAllChannelMessages
        let announceAll = settings.announceAllChannelMessages
        let id = ws.teamID

        let poller = SlackPoller(
            workspaceID: ws.teamID,
            workspaceName: ws.teamName,
            selfUserID: ws.userID,
            client: client,
            intervalSec: settings.pollIntervalSec,
            includeChannels: includeChannels,
            announceAllInChannels: announceAll
        ) { [weak self] batch in
            await self?.handleNewMessages(batch, workspaceID: id)
        }
        pollers[ws.id] = poller
        status[ws.id] = .polling
        Task { await poller.start() }
        Log.slack.info("poller started for \(ws.teamName)")
    }

    private func handleNewMessages(_ messages: [SlackNewMessage], workspaceID: String) async {
        for m in messages { speakPlain(m) }
        inbox.applyWorkspaceDomains(config.config.slack.workspaces)
    }

    private func speakPlain(_ message: SlackNewMessage) {
        let line: String
        switch message.kind {
        case .im:
            line = "\(message.senderName) sent a DM in \(message.workspaceName)."
        case .mpim:
            line = "\(message.senderName) messaged \(message.channelLabel)."
        case .channel, .privateGroup:
            line = "\(message.senderName) mentioned you in \(message.channelLabel)."
        }
        recordRecap(line)
        // Udha used to speak this and stamp the row with whether it managed to.
        // With the voice feature gone there is nothing to narrate, so the row
        // records only that it arrived.
        inbox.ingest(message, disposition: "received \(Self.hhmm(fromSlackTS: message.ts))")
    }

    private static func hhmm(fromSlackTS ts: String) -> String {
        let secs = Double(ts.split(separator: ".").first.map(String.init) ?? ts) ?? 0
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        return f.string(from: Date(timeIntervalSince1970: secs))
    }

    /// Reply into a thread the Inbox is showing, and record the sent message
    /// so the conversation reads as a conversation.
    func reply(to thread: SlackThread, text: String, byVoice: Bool = false) async throws {
        guard let token = keychain.get(account: "slack_token_\(thread.workspaceID)") else {
            throw SlackSendError.tokenMissing(thread.workspaceName)
        }
        let client = SlackAPIClient(token: token)
        let resp: SlackPostMessageResponse
        do {
            resp = try await client.chatPostMessage(channel: thread.channelID, text: text)
        } catch {
            throw SlackSendError.api(error.localizedDescription)
        }
        guard resp.ok, let ts = resp.ts else {
            throw SlackSendError.api(resp.error ?? "chat.postMessage failed")
        }
        inbox.recordOutgoing(threadID: thread.id, text: text, ts: ts, byVoice: byVoice)
    }

    private func recordRecap(_ line: String) {
        lastRecaps.append(line)
        if lastRecaps.count > 20 { lastRecaps.removeFirst(lastRecaps.count - 20) }
    }

    // MARK: - Sending

    func sendMessage(workspaceHint: String?, recipient: String, text: String) async throws -> SlackSendResult {
        let ws = try resolveWorkspace(hint: workspaceHint)
        guard let token = keychain.get(account: ws.keychainAccount) else {
            Log.slack.error("[\(ws.teamName)] send aborted — no token in keychain")
            throw SlackSendError.tokenMissing(ws.teamName)
        }
        let client = SlackAPIClient(token: token)
        let (channelID, recipientLabel) = try await resolveRecipient(client: client, input: recipient)
        Log.slack.info("[\(ws.teamName)] attempting send to \(recipientLabel) channel=\(channelID) textLen=\(text.count)")
        let resp: SlackPostMessageResponse
        do {
            resp = try await client.chatPostMessage(channel: channelID, text: text)
        } catch {
            Log.slack.error("[\(ws.teamName)] chat.postMessage transport error: \(error.localizedDescription)")
            throw SlackSendError.api(error.localizedDescription)
        }
        guard resp.ok, let ts = resp.ts else {
            let raw = resp.error ?? "unknown error"
            let detail: String
            if raw == "missing_scope", let needed = resp.needed {
                detail = "missing_scope (needed: \(needed))"
                Log.slack.error("[\(ws.teamName)] chat.postMessage rejected: missing_scope needed=\(needed) provided=\(resp.provided ?? "?") channel=\(channelID) recipient=\(recipientLabel)")
            } else {
                detail = raw
                Log.slack.error("[\(ws.teamName)] chat.postMessage rejected: \(raw) channel=\(channelID) recipient=\(recipientLabel)")
            }
            throw SlackSendError.api(detail)
        }
        Log.slack.info("[\(ws.teamName)] sent to \(recipientLabel) (\(channelID)) ts=\(ts)")
        return SlackSendResult(
            workspaceName: ws.teamName,
            channelID: channelID,
            recipientLabel: recipientLabel,
            ts: ts
        )
    }

    private func resolveWorkspace(hint: String?) throws -> SlackWorkspaceRecord {
        let enabled = config.config.slack.workspaces.filter(\.enabled)
        guard !enabled.isEmpty else { throw SlackSendError.noWorkspaces }
        let raw = hint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty {
            if enabled.count == 1 { return enabled[0] }
            throw SlackSendError.workspaceAmbiguous(enabled.map(\.teamName))
        }
        let q = raw.lowercased()
        let matches = enabled.filter {
            $0.teamName.lowercased().contains(q)
                || $0.teamDomain.lowercased().contains(q)
                || $0.teamID.lowercased() == q
        }
        if matches.count == 1 { return matches[0] }
        if matches.isEmpty { throw SlackSendError.workspaceNotFound(raw) }
        throw SlackSendError.workspaceAmbiguous(matches.map(\.teamName))
    }

    private func resolveRecipient(
        client: SlackAPIClient,
        input: String
    ) async throws -> (channelID: String, label: String) {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // Raw channel-ish ID: C/D/G followed by alphanumerics
        if let first = s.first, "CDG".contains(first),
           s.count >= 9, s.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber }) {
            return (s, s)
        }

        // Raw user ID — open DM
        if let first = s.first, first == "U",
           s.count >= 9, s.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber }) {
            let opened = try await open(client: client, userIDs: s)
            return (opened, s)
        }

        // Channel by name (#name or plain "name" that matches a channel)
        if s.hasPrefix("#") {
            let name = String(s.dropFirst()).lowercased()
            if let id = try await findChannelID(client: client, lowerName: name) {
                return (id, "#" + name)
            }
            throw SlackSendError.recipientNotFound(s)
        }

        // Email → lookupByEmail-style via users.list scan (users.lookupByEmail requires users:read.email)
        // We scan users.list for an email match as a best effort.
        if s.contains("@") {
            if let u = try await findUser(client: client, query: s) {
                let opened = try await open(client: client, userIDs: u.id)
                return (opened, displayName(u))
            }
            throw SlackSendError.recipientNotFound(s)
        }

        // Name (display / real / handle)
        if let u = try await findUser(client: client, query: s) {
            let opened = try await open(client: client, userIDs: u.id)
            return (opened, displayName(u))
        }

        // Last resort: try as a channel name without #
        if let id = try await findChannelID(client: client, lowerName: s.lowercased()) {
            return (id, "#" + s)
        }

        throw SlackSendError.recipientNotFound(s)
    }

    private func open(client: SlackAPIClient, userIDs: String) async throws -> String {
        let resp: SlackConversationsOpenResponse
        do {
            resp = try await client.conversationsOpen(users: userIDs)
        } catch {
            throw SlackSendError.api(error.localizedDescription)
        }
        guard resp.ok, let id = resp.channel?.id else {
            throw SlackSendError.api(resp.error ?? "conversations.open failed")
        }
        return id
    }

    private func findChannelID(client: SlackAPIClient, lowerName: String) async throws -> String? {
        var cursor: String? = nil
        let types = ["public_channel", "private_channel"]
        repeat {
            let page: SlackConversationsListResponse
            do {
                page = try await client.usersConversations(types: types, cursor: cursor)
            } catch {
                throw SlackSendError.api(error.localizedDescription)
            }
            guard page.ok else { throw SlackSendError.api(page.error ?? "users.conversations failed") }
            if let hit = (page.channels ?? []).first(where: { ($0.name ?? "").lowercased() == lowerName }) {
                return hit.id
            }
            cursor = page.responseMetadata?.nextCursor
        } while !(cursor?.isEmpty ?? true)
        return nil
    }

    private func findUser(client: SlackAPIClient, query: String) async throws -> SlackUserProfile? {
        let q = query.lowercased()
        var cursor: String? = nil
        repeat {
            let page: SlackUsersListResponse
            do {
                page = try await client.usersList(cursor: cursor)
            } catch {
                throw SlackSendError.api(error.localizedDescription)
            }
            guard page.ok else { throw SlackSendError.api(page.error ?? "users.list failed") }
            for u in page.members ?? [] {
                let name = (u.name ?? "").lowercased()
                let real = (u.realName ?? "").lowercased()
                let disp = (u.profile?.displayName ?? "").lowercased()
                let realProfile = (u.profile?.realName ?? "").lowercased()
                let first = (u.profile?.firstName ?? "").lowercased()
                if name == q || real == q || disp == q || realProfile == q || first == q {
                    return u
                }
                // fuzzy: contains
                if !q.isEmpty, (name.contains(q) || real.contains(q) || disp.contains(q) || realProfile.contains(q)) {
                    return u
                }
            }
            cursor = page.responseMetadata?.nextCursor
        } while !(cursor?.isEmpty ?? true)
        return nil
    }

    private func displayName(_ u: SlackUserProfile) -> String {
        if let s = u.profile?.displayName, !s.isEmpty { return s }
        if let s = u.profile?.realName, !s.isEmpty { return s }
        if let s = u.realName, !s.isEmpty { return s }
        return u.name ?? u.id
    }

    // MARK: - On-demand message fetching

    /// Fetch recent DMs from a specific person across enabled workspaces (or a specific one).
    /// Queries Slack live — does not depend on the poller's in-memory cursor buffer.
    func fetchFromPerson(
        workspaceHint: String?,
        userQuery: String,
        sinceMinutes: Int,
        limit: Int
    ) async -> [SlackFetchedMessage] {
        let targets = resolveTargetWorkspaces(hint: workspaceHint)
        let cutoff = Date().timeIntervalSince1970 - Double(max(sinceMinutes, 1) * 60)
        let oldest = String(format: "%.6f", cutoff)

        var all: [SlackFetchedMessage] = []
        for ws in targets {
            guard let token = keychain.get(account: ws.keychainAccount) else { continue }
            let client = SlackAPIClient(token: token)
            do {
                guard let user = try await findUser(client: client, query: userQuery) else { continue }
                guard let imID = try await findExistingIM(client: client, userID: user.id) else { continue }
                let hist = try await client.conversationsHistory(channel: imID, oldest: oldest, limit: max(1, min(100, limit)))
                guard hist.ok else { continue }
                let msgs = (hist.messages ?? []).sorted { $0.ts < $1.ts }
                let senderName = displayName(user)
                for m in msgs {
                    if let sub = m.subtype, !["thread_broadcast", "file_share"].contains(sub) { continue }
                    guard m.botId == nil else { continue }
                    guard m.user == user.id else { continue }    // only THEIR messages, not yours
                    let text = (m.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    all.append(SlackFetchedMessage(
                        workspaceName: ws.teamName,
                        channelLabel: "DM",
                        senderName: senderName,
                        text: text,
                        ts: m.ts
                    ))
                }
            } catch {
                Log.slack.error("[\(ws.teamName)] fetchFromPerson('\(userQuery)'): \(error.localizedDescription)")
                continue
            }
        }
        return Array(all.suffix(limit))
    }

    /// Fetch recent messages in a channel across enabled workspaces (or a specific one).
    func fetchFromChannel(
        workspaceHint: String?,
        channelQuery: String,
        sinceMinutes: Int,
        limit: Int
    ) async -> [SlackFetchedMessage] {
        let targets = resolveTargetWorkspaces(hint: workspaceHint)
        let cutoff = Date().timeIntervalSince1970 - Double(max(sinceMinutes, 1) * 60)
        let oldest = String(format: "%.6f", cutoff)
        let name = channelQuery.hasPrefix("#")
            ? String(channelQuery.dropFirst()).lowercased()
            : channelQuery.lowercased()

        var all: [SlackFetchedMessage] = []
        for ws in targets {
            guard let token = keychain.get(account: ws.keychainAccount) else { continue }
            let client = SlackAPIClient(token: token)
            do {
                guard let channelID = try await findChannelID(client: client, lowerName: name) else { continue }
                let hist = try await client.conversationsHistory(channel: channelID, oldest: oldest, limit: max(1, min(100, limit)))
                guard hist.ok else { continue }
                let msgs = (hist.messages ?? []).sorted { $0.ts < $1.ts }
                for m in msgs {
                    if let sub = m.subtype, !["thread_broadcast", "file_share"].contains(sub) { continue }
                    guard m.botId == nil else { continue }
                    guard let sender = m.user else { continue }
                    let text = (m.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let senderName = await resolveNameLive(client: client, userID: sender)
                    all.append(SlackFetchedMessage(
                        workspaceName: ws.teamName,
                        channelLabel: "#" + name,
                        senderName: senderName,
                        text: text,
                        ts: m.ts
                    ))
                }
            } catch {
                Log.slack.error("[\(ws.teamName)] fetchFromChannel('\(channelQuery)'): \(error.localizedDescription)")
                continue
            }
        }
        return Array(all.suffix(limit))
    }

    private func resolveTargetWorkspaces(hint: String?) -> [SlackWorkspaceRecord] {
        let enabled = config.config.slack.workspaces.filter(\.enabled)
        guard let raw = hint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return enabled }
        let q = raw.lowercased()
        let matches = enabled.filter {
            $0.teamName.lowercased().contains(q)
                || $0.teamDomain.lowercased().contains(q)
                || $0.teamID.lowercased() == q
        }
        return matches.isEmpty ? enabled : matches
    }

    private func findExistingIM(client: SlackAPIClient, userID: String) async throws -> String? {
        var cursor: String? = nil
        repeat {
            let page = try await client.usersConversations(types: ["im"], cursor: cursor)
            guard page.ok else { return nil }
            if let hit = (page.channels ?? []).first(where: { $0.user == userID }) {
                return hit.id
            }
            cursor = page.responseMetadata?.nextCursor
        } while !(cursor?.isEmpty ?? true)
        return nil
    }

    private func resolveNameLive(client: SlackAPIClient, userID: String) async -> String {
        do {
            let resp = try await client.usersInfo(user: userID)
            if let u = resp.user { return displayName(u) }
        } catch {}
        return "someone"
    }
}
