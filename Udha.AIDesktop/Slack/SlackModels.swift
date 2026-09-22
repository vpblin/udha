import Foundation

enum SlackConversationKind: String, Sendable {
    case im           // DM
    case mpim         // group DM
    case channel      // public channel
    case privateGroup // private channel (legacy "group")
}

struct SlackNewMessage: Sendable, Hashable {
    let workspaceID: String
    let workspaceName: String
    let channelID: String
    let channelLabel: String        // resolved: other user's name for IM, channel name otherwise
    let kind: SlackConversationKind
    let senderUserID: String
    let senderName: String          // resolved
    let text: String                // raw text (Slack markup)
    let ts: String
    let mentionsSelf: Bool
    let threadTs: String?
}

// MARK: - Slack API response envelopes (camelCase via .convertFromSnakeCase)

struct SlackAuthTestResponse: Decodable, Sendable {
    let ok: Bool
    let error: String?
    let team: String?
    let teamId: String?
    let user: String?
    let userId: String?
    let url: String?
}

struct SlackPageMeta: Decodable, Sendable {
    let nextCursor: String?
}

struct SlackConversation: Decodable, Sendable {
    let id: String
    let name: String?
    let isIm: Bool?
    let isMpim: Bool?
    let isChannel: Bool?
    let isGroup: Bool?
    let isPrivate: Bool?
    let isArchived: Bool?
    let user: String?   // IM partner
}

struct SlackConversationsListResponse: Decodable, Sendable {
    let ok: Bool
    let error: String?
    let channels: [SlackConversation]?
    let responseMetadata: SlackPageMeta?
}

struct SlackRawMessage: Decodable, Sendable {
    let ts: String
    let type: String?
    let subtype: String?
    let user: String?
    let botId: String?
    let text: String?
    let threadTs: String?
}

struct SlackHistoryResponse: Decodable, Sendable {
    let ok: Bool
    let error: String?
    let messages: [SlackRawMessage]?
    let hasMore: Bool?
    let responseMetadata: SlackPageMeta?
}

struct SlackUserProfileBlock: Decodable, Sendable {
    let displayName: String?
    let realName: String?
    let firstName: String?
}

struct SlackUserProfile: Decodable, Sendable {
    let id: String
    let name: String?
    let realName: String?
    let profile: SlackUserProfileBlock?
}

struct SlackUserInfoResponse: Decodable, Sendable {
    let ok: Bool
    let error: String?
    let user: SlackUserProfile?
}

struct SlackUsersListResponse: Decodable, Sendable {
    let ok: Bool
    let error: String?
    let members: [SlackUserProfile]?
    let responseMetadata: SlackPageMeta?
}

struct SlackOpenedChannel: Decodable, Sendable {
    let id: String
}

struct SlackConversationsOpenResponse: Decodable, Sendable {
    let ok: Bool
    let error: String?
    let channel: SlackOpenedChannel?
}

struct SlackPostMessageResponse: Decodable, Sendable {
    let ok: Bool
    let error: String?
    let needed: String?
    let provided: String?
    let ts: String?
    let channel: String?
}
