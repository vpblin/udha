import Foundation
import Observation

/// One message inside an inbox thread.
struct SlackInboxMessage: Codable, Identifiable, Hashable {
    var id: String { ts }
    /// Slack's message timestamp — also the stable identity within a channel.
    var ts: String
    var from: String
    var text: String
    var at: Date
    /// True for messages Udha sent on the user's behalf.
    var outgoing: Bool = false
    /// What (if anything) happened to this message audibly: "narrated 9:41",
    /// "sent by voice", "muted — quiet hours". Shown verbatim on the row so the
    /// inbox explains why you did or didn't hear about something.
    var disposition: String? = nil
}

/// A conversation as the Inbox pane shows it: one DM, group DM, or channel in
/// one workspace, with the last N messages Udha has seen.
struct SlackThread: Codable, Identifiable, Hashable {
    /// `T01ABC/D01XYZ` — workspace + channel. Stable across restarts.
    var id: String
    var workspaceID: String
    var workspaceName: String
    var workspaceDomain: String
    var channelID: String
    /// "Ada Lovelace" for a DM, "#retention" for a channel.
    var label: String
    var kindRaw: String
    var messages: [SlackInboxMessage] = []
    var unread: Bool = false
    var lastActivity: Date = Date()

    var kind: SlackConversationKind { SlackConversationKind(rawValue: kindRaw) ?? .channel }

    /// "example.slack.com · DM" — the second line under the thread title.
    var where_: String {
        let host = workspaceDomain.isEmpty ? workspaceName : workspaceDomain
        switch kind {
        case .im:           return "\(host) · DM"
        case .mpim:         return "\(host) · group"
        case .channel:      return "\(host) · \(label)"
        case .privateGroup: return "\(host) · private"
        }
    }

    var preview: String {
        messages.last?.text.replacingOccurrences(of: "\n", with: " ") ?? ""
    }
}

/// Per-thread Slack history for the Inbox section.
///
/// The poller only ever hands us *new* messages, so this is a forward-only
/// record of what Udha has observed while running — not a Slack mirror. It is
/// persisted so restarting the app doesn't blank the inbox, and bounded on both
/// axes (threads and messages per thread) because it lives entirely in memory.
@MainActor
@Observable
final class SlackInbox {
    /// Newest activity first.
    private(set) var threads: [SlackThread] = []

    private let maxThreads = 60
    private let maxMessagesPerThread = 60

    private var saveTask: Task<Void, Never>?

    var unreadCount: Int { threads.filter(\.unread).count }

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Udha.AI", isDirectory: true)
            .appendingPathComponent("slack-inbox.json")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Lifecycle

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            threads = try Self.decoder.decode([SlackThread].self, from: data)
                .sorted { $0.lastActivity > $1.lastActivity }
        } catch {
            Log.slack.error("SlackInbox: unreadable store, starting empty: \(error.localizedDescription)")
        }
    }

    // MARK: - Ingest

    /// Record an inbound message and return the thread it landed in.
    @discardableResult
    func ingest(_ message: SlackNewMessage, disposition: String?) -> SlackThread {
        let id = "\(message.workspaceID)/\(message.channelID)"
        let at = Self.date(fromSlackTS: message.ts)
        let entry = SlackInboxMessage(
            ts: message.ts,
            from: message.senderName,
            text: message.text,
            at: at,
            outgoing: false,
            disposition: disposition
        )

        var thread: SlackThread
        if let idx = threads.firstIndex(where: { $0.id == id }) {
            thread = threads.remove(at: idx)
        } else {
            thread = SlackThread(
                id: id,
                workspaceID: message.workspaceID,
                workspaceName: message.workspaceName,
                workspaceDomain: "",
                channelID: message.channelID,
                label: message.kind == .im ? message.senderName : message.channelLabel,
                kindRaw: message.kind.rawValue
            )
        }
        // Slack can re-deliver a ts across a cursor reset; dedupe on it.
        if !thread.messages.contains(where: { $0.ts == entry.ts }) {
            thread.messages.append(entry)
            if thread.messages.count > maxMessagesPerThread {
                thread.messages.removeFirst(thread.messages.count - maxMessagesPerThread)
            }
        }
        thread.unread = true
        thread.lastActivity = at
        threads.insert(thread, at: 0)
        trim()
        scheduleSave()
        return thread
    }

    /// Record a reply Udha sent, so the thread reads as a conversation.
    func recordOutgoing(threadID: String, text: String, ts: String, byVoice: Bool) {
        guard let idx = threads.firstIndex(where: { $0.id == threadID }) else { return }
        var thread = threads.remove(at: idx)
        thread.messages.append(SlackInboxMessage(
            ts: ts,
            from: "You",
            text: text,
            at: Date(),
            outgoing: true,
            disposition: byVoice ? "sent by voice" : "sent from Udha"
        ))
        if thread.messages.count > maxMessagesPerThread {
            thread.messages.removeFirst(thread.messages.count - maxMessagesPerThread)
        }
        thread.unread = false
        thread.lastActivity = Date()
        threads.insert(thread, at: 0)
        scheduleSave()
    }

    func markRead(_ threadID: String) {
        guard let idx = threads.firstIndex(where: { $0.id == threadID }), threads[idx].unread else { return }
        threads[idx].unread = false
        scheduleSave()
    }

    func markAllRead() {
        guard threads.contains(where: \.unread) else { return }
        for i in threads.indices { threads[i].unread = false }
        scheduleSave()
    }

    func thread(id: String) -> SlackThread? { threads.first { $0.id == id } }

    /// Fill in `workspaceDomain` from config so the "where" line reads as a
    /// real Slack host. Cheap enough to re-run whenever workspaces change.
    func applyWorkspaceDomains(_ workspaces: [SlackWorkspaceRecord]) {
        let byID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.teamID, $0) })
        var changed = false
        for i in threads.indices {
            guard let ws = byID[threads[i].workspaceID] else { continue }
            if threads[i].workspaceDomain != ws.teamDomain {
                threads[i].workspaceDomain = ws.teamDomain
                changed = true
            }
            if threads[i].workspaceName != ws.teamName {
                threads[i].workspaceName = ws.teamName
                changed = true
            }
        }
        if changed { scheduleSave() }
    }

    // MARK: - Private

    private func trim() {
        guard threads.count > maxThreads else { return }
        threads.removeLast(threads.count - maxThreads)
    }

    /// Debounced: a burst of poll results shouldn't produce a write each.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        let url = fileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try Self.encoder.encode(threads)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.slack.error("SlackInbox: save failed: \(error.localizedDescription)")
        }
    }

    /// Slack timestamps are "1724270461.001900" — seconds since epoch.
    private static func date(fromSlackTS ts: String) -> Date {
        guard let secs = Double(ts.split(separator: ".").first.map(String.init) ?? ts) else { return Date() }
        return Date(timeIntervalSince1970: secs)
    }
}
