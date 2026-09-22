import SwiftUI
import Observation

/// The six things the sidebar can be showing.
enum UdhaSection: String, CaseIterable, Identifiable {
    case sessions, meetings, agents, inbox, videos, machines
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sessions: return "Sessions"
        case .meetings: return "Meetings"
        case .agents:   return "Agents"
        case .inbox:    return "Inbox"
        case .videos:   return "Videos"
        case .machines: return "Machines"
        }
    }
}

enum MeetingDetailTab: String, CaseIterable { case notes, transcript, diagram }
enum LiveMeetingTab: String, CaseIterable { case ask, transcript, items, diagram }

/// All the window's transient UI state in one observable object.
///
/// Kept out of `AppCore` on purpose: none of this is app state, it's *view*
/// state — which pane is showing, what's typed in the palette, which settings
/// section is open. AppCore owns things that outlive the window.
@MainActor
@Observable
final class UdhaShellModel {
    // Navigation
    var section: UdhaSection = .sessions
    var selectedSessionID: UUID?
    /// Set by the board's "Rename" context item to ask the detail pane to start
    /// editing the selected session's title. The pane clears it once it has.
    var renameSelectedSession = false
    /// Sessions ⇧- or ⌘-clicked on the board, for a bulk hand-off. Separate
    /// from `selectedSessionID`, which still says what the detail pane shows.
    var sessionMulti: Set<UUID> = []
    var selectedMeetingID: UUID?
    var selectedAgentSlug: String?
    var selectedThreadID: String?
    var selectedRecordingID: UUID?
    /// Which machine the Machines section is showing. Nil = this Mac.
    var selectedMachine: String?
    /// False until the section has chosen a machine once, so the first visit can
    /// land on the box that actually runs the work rather than on this Mac.
    var machinePicked = false

    // Meeting panes
    var meetingTab: MeetingDetailTab = .notes
    var liveTab: LiveMeetingTab = .transcript
    /// True while the Meetings section should show the live recorder rather
    /// than a stored meeting.
    var showingLive: Bool = false

    // Videos
    /// Which master the detail pane is previewing. Both are rendered from one
    /// recording, so this is a view choice, not a property of the recording.
    var videoOrientation: RecordingOrientation = .landscape
    /// The "what do you want to record?" sheet.
    var recordTargetOpen = false

    // Joining
    /// Videos ticked for a join. Deliberately separate from
    /// `selectedRecordingID`, which still says which one the detail pane is
    /// showing — ticking a second video should not navigate away from the
    /// first.
    var joinSelection: Set<UUID> = []
    /// Play order inside the join sheet. Seeded from the list order when the
    /// sheet opens, then owned by the sheet.
    var joinOrder: [UUID] = []
    var joinName: String = ""
    var joinSheetOpen = false

    // Command palette
    var paletteOpen = false
    var paletteQuery = ""
    var paletteCursor = 0

    // Settings modal
    var settingsOpen = false
    var settingsSection: String = "overview"
    var settingsQuery = ""

    // Sheets
    var newSessionOpen = false
    /// Where the next New Session sheet should start: "New session here" on a
    /// folder sets the machine and the folder before opening it. Consumed by
    /// the sheet's prefill, so an ordinary ⌘N never inherits it.
    struct NewSessionSeed: Equatable {
        var host: String?
        var folderID: UUID?
    }
    var newSessionSeed: NewSessionSeed?
    /// ⌘K's "New folder" — the board owns the rename flow, so the request is
    /// handed to it rather than performed here.
    struct NewFolderRequest: Equatable {
        let id = UUID()
        var host: String?
    }
    var newFolderRequest: NewFolderRequest?
    var agentEditorSlug: String?      // nil = closed
    var newAgentPending = false
    var debugPanelOpen = false
    var firstRunOpen = false

    // Status line
    var status: String = "Watching sessions · hooks + pane reader, no LLM"
    /// Set when the status line is reporting the result of a command, so it can
    /// render in red for a beat.
    var statusIsAction = false

    // MARK: - Status

    func say(_ message: String, action: Bool = true) {
        status = message
        statusIsAction = action
    }

    // MARK: - Navigation helpers

    func go(_ section: UdhaSection) {
        self.section = section
        if section != .meetings { showingLive = false }
    }

    func openLive() {
        section = .meetings
        showingLive = true
    }

    func select(recording id: UUID) {
        section = .videos
        selectedRecordingID = id
    }

    // MARK: - Join selection

    func toggleJoin(_ id: UUID) {
        if joinSelection.contains(id) {
            joinSelection.remove(id)
        } else {
            joinSelection.insert(id)
        }
    }

    func clearJoinSelection() {
        joinSelection = []
    }

    /// Opens the confirm sheet. `order` is the list order of the ticked
    /// videos — newest first is what the sidebar shows, but a join reads as a
    /// sequence, so the sheet is seeded oldest first.
    func openJoinSheet(order: [UUID], name: String) {
        joinOrder = order
        joinName = name
        joinSheetOpen = true
    }

    func select(machine host: String?) {
        section = .machines
        selectedMachine = host
        machinePicked = true
    }

    func select(session id: UUID) {
        section = .sessions
        selectedSessionID = id
        sessionMulti = []
    }

    func openSettings(section: String? = nil) {
        if let section { settingsSection = section; settingsQuery = "" }
        settingsOpen = true
        paletteOpen = false
    }

    func togglePalette() {
        paletteOpen.toggle()
        paletteQuery = ""
        paletteCursor = 0
    }

    func openPalette() {
        paletteOpen = true
        paletteQuery = ""
        paletteCursor = 0
    }
}
