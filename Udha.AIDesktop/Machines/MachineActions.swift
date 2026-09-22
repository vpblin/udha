import Foundation
import AppKit

/// The few things the Machines section does to a machine rather than read from
/// it. Kept apart from the view so the pane stays about layout.
@MainActor
enum MachineActions {

    /// A Terminal window on that machine. For a remote box that is an SSH
    /// session, which works from anywhere because the host name is also its
    /// Tailscale name — the same assumption session handoff already relies on.
    static func openTerminal(host: String?) {
        let command = host.map { "ssh \($0)" } ?? ""
        let script = """
        tell application "Terminal"
          activate
          do script "\(command)"
        end tell
        """
        run(script)
    }

    /// Attach a Terminal to one tmux session on a remote box.
    static func attach(host: String, tmuxName: String) {
        let script = """
        tell application "Terminal"
          activate
          do script "ssh -t \(host) tmux attach -t \(tmuxName)"
        end tell
        """
        run(script)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([FileLogger.shared.fileURL])
    }

    private static func run(_ script: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            Log.app.error("machines: osascript failed — \(error.localizedDescription)")
        }
    }
}
