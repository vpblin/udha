import Foundation

actor SlackPoller {
    typealias MessageHandler = @Sendable ([SlackNewMessage]) async -> Void

    let workspaceID: String
    let workspaceName: String
    let selfUserID: String
    private let client: SlackAPIClient
    private let handler: MessageHandler

    private var intervalSec: Int
    private var includeChannels: Bool
    private var announceAllInChannels: Bool

    private var lastTsByChannel: [String: String] = [:]
    private var channelLabelCache: [String: (label: String, kind: SlackConversationKind)] = [:]
    private var userNameCache: [String: String] = [:]

    private var runTask: Task<Void, Never>?

    init(
        workspaceID: String,
        workspaceName: String,
        selfUserID: String,
        client: SlackAPIClient,
        intervalSec: Int,
        includeChannels: Bool,
        announceAllInChannels: Bool,
        handler: @escaping MessageHandler
    ) {
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.selfUserID = selfUserID
        self.client = client
        self.intervalSec = intervalSec
        self.includeChannels = includeChannels
        self.announceAllInChannels = announceAllInChannels
        self.handler = handler
    }

    func start() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.initializeCursors()
            while !Task.isCancelled {
                await self.tick()
                let delay = await self.intervalSec
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            }
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
    }

    func updateSettings(intervalSec: Int, includeChannels: Bool, announceAllInChannels: Bool) {
        self.intervalSec = intervalSec
        self.includeChannels = includeChannels
        self.announceAllInChannels = announceAllInChannels
    }

    // MARK: - Polling

    private func initializeCursors() async {
        // Mark "now" as the baseline so existing backlog is never announced.
        let now = String(format: "%.6f", Date().timeIntervalSince1970)
        do {
            for conv in try await fetchAllConversations() {
                if lastTsByChannel[conv.id] == nil {
                    lastTsByChannel[conv.id] = now
                }
            }
            Log.slack.info("[\(workspaceName)] initialized cursors for \(lastTsByChannel.count) conversations")
        } catch {
            Log.slack.error("[\(workspaceName)] initializeCursors: \(error.localizedDescription)")
        }
    }

    private func tick() async {
        do {
            let conversations = try await fetchAllConversations()
            var batch: [SlackNewMessage] = []

            for conv in conversations {
                let kind = classify(conv)
                if !includeChannels, (kind == .channel || kind == .privateGroup) { continue }
                if conv.isArchived == true { continue }

                let oldest = lastTsByChannel[conv.id]
                    ?? String(format: "%.6f", Date().timeIntervalSince1970)
                if lastTsByChannel[conv.id] == nil { lastTsByChannel[conv.id] = oldest }

                let history: SlackHistoryResponse
                do {
                    history = try await client.conversationsHistory(channel: conv.id, oldest: oldest)
                } catch {
                    Log.slack.error("[\(workspaceName)] history \(conv.id): \(error.localizedDescription)")
                    continue
                }
                guard history.ok else {
                    Log.slack.error("[\(workspaceName)] history \(conv.id) not ok: \(history.error ?? "?")")
                    continue
                }
                let messages = history.messages ?? []
                if messages.isEmpty { continue }

                // Messages come newest-first; process oldest-first so emission order is chronological.
                let ordered = messages.sorted { ($0.ts) < ($1.ts) }
                var maxTs = oldest
                for msg in ordered {
                    if msg.ts > maxTs { maxTs = msg.ts }
                    guard let processed = await process(message: msg, conv: conv, kind: kind) else { continue }
                    batch.append(processed)
                }
                lastTsByChannel[conv.id] = maxTs
            }

            if !batch.isEmpty {
                Log.slack.info("[\(workspaceName)] tick: \(batch.count) new messages")
                await handler(batch)
            }
        } catch {
            Log.slack.error("[\(workspaceName)] tick failed: \(error.localizedDescription)")
        }
    }

    private func fetchAllConversations() async throws -> [SlackConversation] {
        var all: [SlackConversation] = []
        var cursor: String? = nil
        let types = ["im", "mpim", "public_channel", "private_channel"]
        repeat {
            let page = try await client.usersConversations(types: types, cursor: cursor)
            guard page.ok else {
                throw SlackAPIError.slack(page.error ?? "users.conversations failed")
            }
            all.append(contentsOf: page.channels ?? [])
            cursor = page.responseMetadata?.nextCursor
        } while !(cursor?.isEmpty ?? true)
        return all
    }

    // MARK: - Message filtering + enrichment

    private func process(
        message: SlackRawMessage,
        conv: SlackConversation,
        kind: SlackConversationKind
    ) async -> SlackNewMessage? {
        // Skip system/bot/own
        if let sub = message.subtype, !Self.allowedSubtypes.contains(sub) { return nil }
        guard message.botId == nil else { return nil }
        guard let sender = message.user, sender != selfUserID else { return nil }
        let text = (message.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let mentionsSelf = text.contains("<@\(selfUserID)>")
            || text.contains("<!here>")
            || text.contains("<!channel>")

        // Channel filter: require mention unless user opted into all-channel announcement
        if kind == .channel || kind == .privateGroup {
            if !announceAllInChannels, !mentionsSelf { return nil }
        }

        let senderName = await resolveUserName(id: sender)
        let (label, _) = await resolveChannelLabel(conv: conv, kind: kind)

        return SlackNewMessage(
            workspaceID: workspaceID,
            workspaceName: workspaceName,
            channelID: conv.id,
            channelLabel: label,
            kind: kind,
            senderUserID: sender,
            senderName: senderName,
            text: text,
            ts: message.ts,
            mentionsSelf: mentionsSelf,
            threadTs: message.threadTs
        )
    }

    private static let allowedSubtypes: Set<String> = ["thread_broadcast", "file_share"]

    private func classify(_ conv: SlackConversation) -> SlackConversationKind {
        if conv.isIm == true { return .im }
        if conv.isMpim == true { return .mpim }
        if conv.isPrivate == true || conv.isGroup == true { return .privateGroup }
        return .channel
    }

    private func resolveUserName(id: String) async -> String {
        if let cached = userNameCache[id] { return cached }
        do {
            let resp = try await client.usersInfo(user: id)
            let profile = resp.user
            let name = Self.nonEmpty(profile?.profile?.displayName)
                ?? Self.nonEmpty(profile?.profile?.realName)
                ?? Self.nonEmpty(profile?.realName)
                ?? Self.nonEmpty(profile?.name)
                ?? "someone"
            userNameCache[id] = name
            return name
        } catch {
            userNameCache[id] = "someone"
            return "someone"
        }
    }

    private func resolveChannelLabel(
        conv: SlackConversation,
        kind: SlackConversationKind
    ) async -> (String, SlackConversationKind) {
        if let cached = channelLabelCache[conv.id] { return (cached.label, cached.kind) }
        let label: String
        switch kind {
        case .im:
            if let partner = conv.user { label = await resolveUserName(id: partner) }
            else { label = "direct message" }
        case .mpim:
            label = Self.nonEmpty(conv.name) ?? "group DM"
        case .channel, .privateGroup:
            label = conv.name.map { "#" + $0 } ?? "channel"
        }
        channelLabelCache[conv.id] = (label, kind)
        return (label, kind)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
