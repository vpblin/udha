import Foundation
import Observation

/// The live LLM loop for a recording in progress. Every N seconds it sends
/// the full transcript plus the current state to Claude (cheap model) and
/// replaces the state wholesale with the revised version — no diff grammar,
/// self-healing (a bad tick is repaired by the next one), and stable slug ids
/// keep SwiftUI animating the diagram instead of rebuilding it.
///
/// A failed tick is dropped (state unchanged, quiet error chip, loop
/// continues). Recording never depends on this loop working.
@MainActor
@Observable
final class MeetingIntelligence {
    private(set) var actionItems: [ActionItem] = []
    private(set) var processModel = ProcessModel()
    private(set) var isUpdating = false
    private(set) var lastError: String?
    private(set) var callCount = 0

    /// Fired after each successful tick so the owner can persist state.
    var onStateChanged: (() -> Void)?

    private let claude: ClaudeClient
    private let config: ConfigStore
    private let keychain: KeychainStore
    private(set) var mode: MeetingMode
    private weak var recorder: MeetingRecorder?
    private var loopTask: Task<Void, Never>?
    private var lastSentCount = 0

    /// Belt-and-braces transcript cap (~2.5h of talk) so a marathon call stays
    /// inside the live model's context window.
    private let transcriptTailCap = 300_000

    init(claude: ClaudeClient, config: ConfigStore, keychain: KeychainStore, mode: MeetingMode, recorder: MeetingRecorder) {
        self.claude = claude
        self.config = config
        self.keychain = keychain
        self.mode = mode
        self.recorder = recorder
    }

    func startLoop() {
        guard loopTask == nil else { return }
        loopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                var interval = self?.config.config.meetings.liveUpdateIntervalSec ?? 60
                // On the local model a tick is 30–80 s of the box's GPU, the
                // same GPU the live translation queues behind; every minute
                // would starve it. Five minutes keeps the items fresh enough.
                if let m = self?.config.config.meetings, m.notesProvider == .local
                    || (m.fallbackToLocal && !(self?.keychain.has(.anthropicAPIKey) ?? false)) {
                    interval = max(interval, 300)
                }
                try? await Task.sleep(nanoseconds: UInt64(max(30, min(300, interval))) * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.tickIfNeeded()
            }
        }
    }

    func stopLoop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Mid-meeting switch into process mapping (auto-recorded meetings start
    /// standard). The next tick sends the whole transcript so far, so the
    /// diagram catches up on everything already discussed. Forces a prompt
    /// re-send (`lastSentCount = 0` would double-bill; just letting the next
    /// tick run is enough since the transcript block re-caches).
    func setMode(_ newMode: MeetingMode) {
        mode = newMode
    }

    /// UI checkbox toggles during the call.
    func setDone(_ id: UUID, done: Bool) {
        guard let idx = actionItems.firstIndex(where: { $0.id == id }) else { return }
        actionItems[idx].done = done
        onStateChanged?()
    }

    private func tickIfNeeded() async {
        let cfg = config.config.meetings
        guard cfg.liveUpdatesEnabled else { return }
        guard ClaudeClient.hasNotesModel(keychain: keychain, config: config) else { return }
        guard !isUpdating else { return }
        guard callCount < cfg.maxLiveCallsPerMeeting else {
            if callCount == cfg.maxLiveCallsPerMeeting {
                Log.meeting.info("MeetingIntelligence: live-call cap (\(cfg.maxLiveCallsPerMeeting)) reached — loop idle")
                callCount += 1
            }
            return
        }
        guard let recorder, recorder.state == .recording || recorder.state == .paused else { return }
        let segments = recorder.transcript.segments
        guard segments.count > lastSentCount else { return }

        isUpdating = true
        defer { isUpdating = false }

        var transcriptText = recorder.transcript.renderText()
        if transcriptText.count > transcriptTailCap {
            transcriptText = "[earlier transcript truncated]\n" + String(transcriptText.suffix(transcriptTailCap))
        }
        let stateJSON = Self.encodeState(actionItems: actionItems, process: mode == .processMapping ? processModel : nil)

        do {
            let (payload, _) = try await claude.structured(
                LiveTickPayload.self,
                model: cfg.liveModel,
                maxTokens: 4000,
                system: [PromptBlock(text: MeetingPrompts.liveSystem(mode: mode), cached: true)],
                user: [
                    PromptBlock(text: "<transcript>\n\(transcriptText)\n</transcript>", cached: true),
                    PromptBlock(text: "<current_state>\n\(stateJSON)\n</current_state>"),
                    PromptBlock(text: "Return the revised state."),
                ],
                schema: MeetingPrompts.liveSchema(mode: mode)
            )
            actionItems = ActionItemPayload.merge(payload.action_items)
            if mode == .processMapping, let process = payload.process {
                processModel = process.toModel()
            }
            lastSentCount = segments.count
            callCount += 1
            lastError = nil
            onStateChanged?()
        } catch ClaudeError.noAPIKey {
            // Quiet: the missing-key banner covers this; retry next tick.
        } catch {
            lastError = error.localizedDescription
            Log.meeting.error("MeetingIntelligence: tick failed: \(error.localizedDescription)")
        }
    }

    static func encodeState(actionItems: [ActionItem], process: ProcessModel?) -> String {
        struct WireItem: Encodable {
            let id: String
            let text: String
            let owner: String?
            let done: Bool
        }
        struct WireState: Encodable {
            let action_items: [WireItem]
            let process: ProcessModel?
        }
        let state = WireState(
            action_items: actionItems.map {
                WireItem(id: $0.id.uuidString, text: $0.text, owner: $0.owner, done: $0.done)
            },
            process: process
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(state)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
