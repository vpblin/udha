import SwiftUI
import AppKit

/// One Slack conversation: what was said, whether Udha spoke it aloud, and a
/// box to answer from without switching apps.
struct InboxPane: View {
    let core: AppCore
    @Bindable var shell: UdhaShellModel

    @State private var draft = ""
    @State private var sending = false
    @State private var error = ""

    private var thread: SlackThread? {
        guard let id = shell.selectedThreadID else { return core.slack.inbox.threads.first }
        return core.slack.inbox.thread(id: id) ?? core.slack.inbox.threads.first
    }

    var body: some View {
        Group {
            if let thread {
                detail(thread)
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var empty: some View {
        let noWorkspace = core.config.config.slack.workspaces.isEmpty
        let connect: (title: String, icon: String?, run: () -> Void)? = noWorkspace
            ? (title: "Connect a workspace", icon: nil, run: { shell.openSettings(section: "slack") })
            : nil
        return UdhaEmptyState(
            title: noWorkspace ? "Slack isn't connected" : "Nothing in the inbox",
            text: noWorkspace
                ? "Connect a workspace and DMs and mentions arrive here, answerable without leaving the app."
                : "DMs and mentions appear as they arrive. Udha only sees messages sent while it's running.",
            action: connect
        )
    }

    private func detail(_ thread: SlackThread) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(thread.label)
                        .font(UdhaTheme.text(22, .bold))
                        .tracking(-0.3)
                        .foregroundStyle(UdhaTheme.label)
                        .lineLimit(1)
                    Mono(thread.where_, size: 11.5)
                }
                Spacer(minLength: 12)
                Button("Mark all read") { core.slack.inbox.markAllRead() }
                    .udhaButton(.ghost, height: 26)
                    .disabled(core.slack.inbox.unreadCount == 0)
            }
            .padding(.horizontal, UdhaTheme.contentInset)
            .padding(.top, 18)
            .padding(.bottom, 14)
            HRule()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(thread.messages.reversed()) { message in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(message.from)
                                    .font(UdhaTheme.text(12.5, .bold))
                                    .foregroundStyle(message.outgoing ? UdhaTheme.accentInk : UdhaTheme.label)
                                Mono(UdhaFormat.timeOfDay(message.at), size: 10.5, color: UdhaTheme.tertiary)
                                Spacer()
                                if let disposition = message.disposition {
                                    UdhaPill(disposition, size: 10, height: 18)
                                }
                            }
                            Text(message.text)
                                .font(UdhaTheme.text(13, .regular))
                                .lineSpacing(4)
                                .foregroundStyle(UdhaTheme.label)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 15)
                        .padding(.top, 12)
                        .padding(.bottom, 13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .udhaCard(fill: message.outgoing ? UdhaTheme.accentTint : UdhaTheme.card)
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(.horizontal, UdhaTheme.contentInset)
                .padding(.vertical, 14)
            }
            .udhaScroll()

            VStack(alignment: .leading, spacing: 6) {
                if !error.isEmpty {
                    Text(error).font(UdhaTheme.text(11.5, .medium)).foregroundStyle(UdhaTheme.badInk)
                }
                HStack(spacing: 10) {
                    UdhaField(
                        placeholder: "Reply in \(thread.workspaceName)…",
                        text: $draft,
                        height: 32
                    ) { send(thread) }
                    .frame(maxWidth: 700)
                    Button(sending ? "Sending…" : "Send") { send(thread) }
                        .udhaButton(.primary, height: 32, hPadding: 16)
                        .disabled(sending || draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, UdhaTheme.contentInset)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .udhaChrome(.headerView, tint: UdhaTheme.chrome)
            .overlay(alignment: .top) { HRule() }
        }
    }

    private func send(_ thread: SlackThread) {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !sending else { return }
        sending = true
        error = ""
        Task {
            do {
                try await core.slack.reply(to: thread, text: text)
                draft = ""
                shell.say("Sent to \(thread.label)")
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }
}
