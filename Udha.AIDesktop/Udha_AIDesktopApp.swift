import SwiftUI

@main
struct Udha_AIDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // One window. Sessions, meetings, agents and the Slack inbox are
        // sections inside it rather than separate scenes — the redesign folded
        // the standalone Meetings window in, and Settings became a modal so it
        // can be searched across every section at once.
        Window("Udha", id: "main") {
            UdhaRootView()
                .environment(delegate.bootstrapCore())
        }
        // A real title bar with a unified (52pt) toolbar: the section's name
        // and hint sit beside the traffic lights, the meeting control and
        // the new-session button live in the toolbar (`UdhaToolbar`).
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { EmptyView() }
            // Both ⌘, and the app menu's Settings… item drive the in-window
            // modal. There is no `Settings` scene to route to any more.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    NotificationCenter.default.post(name: .udhaRequestSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarContent(core: delegate.bootstrapCore())
        } label: {
            let core = delegate.bootstrapCore()
            MenuBarStatusView(inputLock: core.inputLock, stateStore: core.stateStore, meetings: core.meetings)
        }
        .menuBarExtraStyle(.window)
    }
}
