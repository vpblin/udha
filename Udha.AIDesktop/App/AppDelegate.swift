import AppKit
import SwiftUI
@preconcurrency import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var appCore: AppCore?
    private var overlayController: EdgeOverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let core = bootstrapCore()
        // Apply the saved appearance (light / dark / system) and accent before
        // any view is built, so the first frame is already the right one.
        UdhaTheme.bootstrap(config: core.config.config)
        // Install the overlay BEFORE core.start(). start() runs restoreSessions()
        // synchronously, which can be slow (per-session tmux + Apple Events work);
        // gating the overlay behind it meant a slow/stuck restore left the user
        // with no overlay at all. The overlay only needs config + stateStore and
        // populates reactively as sessions come up.
        installOverlay(core: core)
        core.start()
        runMeetingSelfTestIfRequested(core: core)
        runRecordingSelfTestIfRequested(core: core)
        runMachinesSelfTestIfRequested(core: core)
        runCalendarSelfTestIfRequested(core: core)
        openRequestedSection()
        openNewSessionSheetIfRequested()
        runRecordingReprocessIfRequested(core: core)
    }

    /// Re-renders the most recent recording from its raw files, driven by
    /// `open Udha.AIDesktop.app --args -UDHARecordingReprocess YES`.
    ///
    /// This is the payoff of compositing after capture rather than during it:
    /// layout and caption styling can be iterated on without recording
    /// anything again, and because `captions.json` persists it costs no second
    /// transcription call either.
    private func runRecordingReprocessIfRequested(core: AppCore) {
        guard UserDefaults.standard.bool(forKey: "UDHARecordingReprocess") else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let recording = core.recordings.store.recordings.first else {
                Log.recording.error("REPROCESS: no recordings on disk")
                return
            }
            Log.recording.info("REPROCESS: re-rendering \(recording.folderName)")
            await core.recordings.retryProcessing(recording)
            let updated = core.recordings.store.recording(withID: recording.id)
            Log.recording.info("REPROCESS: done — stage=\(String(describing: updated?.stage)) rendered=\(updated?.renderedOrientations.map(\.rawValue).joined(separator: "+") ?? "none")")
        }
    }

    /// Headless end-to-end test of the video capture pipeline, driven by
    /// `open Udha.AIDesktop.app --args -UDHARecordingSelfTest <seconds>`.
    /// Records the main display for the given duration, then logs a SELFTEST
    /// summary (engine state, degradation flags, and the size/duration of each
    /// raw file). The meeting analogue above exists for the same reason: the
    /// pipeline has to be verifiable without clicking through the UI.
    private func runRecordingSelfTestIfRequested(core: AppCore) {
        let seconds = UserDefaults.standard.integer(forKey: "UDHARecordingSelfTest")
        guard seconds > 0 else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            Log.recording.info("SELFTEST: starting \(seconds)s recording self-test")

            let targets = await core.recordings.availableTargets()
            // `-UDHARecordingSelfTestWindow <substring>` records a window
            // instead of a display. Worth its own path: a window capture goes
            // through an entirely different SCK filter, and the failure that
            // produced a wholly black movie only ever showed up on that one.
            let wantedWindow = UserDefaults.standard.string(forKey: "UDHARecordingSelfTestWindow")
            let match: ScreenCaptureCandidate? = {
                if let wantedWindow, !wantedWindow.isEmpty {
                    return targets.first {
                        if case .window = $0.target {
                            // Title or owning app — "Terminal" is the app, while
                            // the title is whatever the shell put there.
                            return $0.name.localizedCaseInsensitiveContains(wantedWindow)
                                || ($0.applicationName?.localizedCaseInsensitiveContains(wantedWindow) ?? false)
                        }
                        return false
                    }
                }
                return targets.first {
                    if case .display = $0.target { return true }
                    return false
                }
            }()
            guard let display = match else {
                let access = core.screenRecordingAccess
                Log.recording.error("SELFTEST: no display target — screen access status=\(String(describing: access.status)) needsRelaunch=\(access.needsRelaunchAfterGrant)")
                return
            }
            Log.recording.info("SELFTEST: target=\(display.name) \(display.width)x\(display.height)")

            await core.recordings.start(target: display.target)
            guard let live = core.recordings.live else {
                Log.recording.error("SELFTEST: no live recording after start")
                return
            }
            Log.recording.info("SELFTEST: engine state=\(String(describing: live.engine.state)) cameraUnavailable=\(live.engine.cameraUnavailable)")

            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            let recording = live.recording
            Log.recording.info("SELFTEST: state=\(String(describing: live.engine.state)) active=\(Int(live.engine.activeDuration))s cameraUnavailable=\(live.engine.cameraUnavailable)")
            await core.recordings.stop()

            let store = core.recordings.store
            for (label, url) in [("screen", store.screenURL(for: recording)), ("camera", store.cameraURL(for: recording))] {
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.intValue ?? 0
                if size == 0 {
                    Log.recording.info("SELFTEST: \(label) — no file")
                    continue
                }
                let asset = AVURLAsset(url: url)
                let duration = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? -1
                let tracks = (try? await asset.load(.tracks)) ?? []
                let kinds = tracks.map { $0.mediaType == .video ? "video" : "audio" }.joined(separator: "+")
                Log.recording.info("SELFTEST: \(label) — \(size / 1024)KB, \(String(format: "%.2f", duration))s, tracks=[\(kinds)]")
            }
            Log.recording.info("SELFTEST: done")
        }
    }

    /// Headless end-to-end test of the meeting pipeline, driven by
    /// `open Udha.AIDesktop.app --args -UDHAMeetingSelfTest <seconds>`.
    /// Records a standard meeting for the given duration, then logs a
    /// SELFTEST summary (segment counts per stream + first lines) and stops.
    /// Exists so the pipeline can be verified without clicking through the UI.
    private func runMeetingSelfTestIfRequested(core: AppCore) {
        let seconds = UserDefaults.standard.integer(forKey: "UDHAMeetingSelfTest")
        guard seconds > 0 else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            Log.meeting.info("SELFTEST: starting \(seconds)s meeting self-test")
            await core.meetings.start(mode: .standard)
            guard let live = core.meetings.live else {
                Log.meeting.error("SELFTEST: no live meeting after start")
                return
            }
            Log.meeting.info("SELFTEST: recorder state=\(String(describing: live.recorder.state)) systemAudioUnavailable=\(live.recorder.systemAudioUnavailable) micUnavailable=\(live.recorder.micUnavailable)")
            // Put the live pane on screen so the run can be screenshotted.
            NotificationCenter.default.post(name: .udhaRequestMeetings, object: nil)
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            let segments = live.recorder.transcript.segments
            let micCount = segments.filter { $0.source == .mic }.count
            let systemCount = segments.filter { $0.source == .system }.count
            Log.meeting.info("SELFTEST: \(segments.count) segments (mic \(micCount), system \(systemCount)) sysUnavailable=\(live.recorder.systemAudioUnavailable) micUnavailable=\(live.recorder.micUnavailable) sttHealthy=\(live.recorder.sttHealthy)")
            for segment in segments.prefix(12) {
                Log.meeting.info("SELFTEST seg [\(segment.speaker) @\(Int(segment.startTime))s] \(segment.text.prefix(90))")
            }
            await core.meetings.stop()
            Log.meeting.info("SELFTEST: done")
        }
    }

    /// `open Udha.AIDesktop.app --args -UDHAOpenSection machines` puts the
    /// window on one section at launch. A test affordance: a pane that is never
    /// shown is a pane that has never been proven to render, and the sections
    /// are otherwise only reachable by clicking.
    private func openRequestedSection() {
        guard let raw = UserDefaults.standard.string(forKey: "UDHAOpenSection"),
              let section = UdhaSection(rawValue: raw) else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            Log.app.info("opening section \(section.rawValue) from -UDHAOpenSection")
            NotificationCenter.default.post(name: .udhaOpenSection, object: section)
        }
    }

    /// `open Udha.AIDesktop.app --args -UDHANewSessionSheet 1` opens the New
    /// Session sheet at launch, for the same reason as the section flag: the
    /// sheet is otherwise only reachable by clicking, so a screenshot of it is
    /// the only proof its pickers render.
    private func openNewSessionSheetIfRequested() {
        guard UserDefaults.standard.bool(forKey: "UDHANewSessionSheet") else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            Log.app.info("opening the New Session sheet from -UDHANewSessionSheet")
            NotificationCenter.default.post(name: .udhaRequestNewSession, object: nil)
        }
    }

    /// Headless check of the Machines section, driven by
    /// `open Udha.AIDesktop.app --args -UDHAMachinesSelfTest <seconds>`.
    /// Turns the monitor on (which the pane normally does on appear), waits,
    /// then logs one SELFTEST line per machine. Exists because the numbers this
    /// section shows come from four different places — /proc on a box, Mach on
    /// this Mac, the relay, and the tailnet — and "it renders" is not evidence
    /// that any of them arrived.
    private func runMachinesSelfTestIfRequested(core: AppCore) {
        let seconds = UserDefaults.standard.integer(forKey: "UDHAMachinesSelfTest")
        guard seconds > 0 else { return }
        Task { @MainActor in
            core.machines.addViewer("selftest")
            Log.app.info("SELFTEST machines: sampling for \(seconds)s")
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            for machine in MachineDirectory.summaries(core: core) {
                Log.app.info("SELFTEST machine \(machine.name): online=\(machine.online) connected=\(machine.connected) rtt=\(machine.latency) state=\(machine.stateLabel)")
                if let stats = machine.stats {
                    Log.app.info("SELFTEST   \(stats.os) · \(stats.cpuModel) · up \(UdhaFormat.uptime(stats.uptimeSeconds))")
                    Log.app.info("SELFTEST   cpu=\(UdhaFormat.percent(stats.cpuPercent)) mem=\(UdhaFormat.bytes(stats.memoryUsed))/\(UdhaFormat.bytes(stats.memoryTotal)) disk=\(UdhaFormat.bytes(stats.diskUsed))/\(UdhaFormat.bytes(stats.diskTotal)) [\(stats.diskDevice)]")
                    Log.app.info("SELFTEST   gpu=\(stats.gpu.map { "\($0.name) \(UdhaFormat.percent($0.utilPercent)) \(UdhaFormat.celsius($0.celsius))" } ?? "none") docker=\(stats.docker.map { "\($0.running) running" } ?? "none")")
                    Log.app.info("SELFTEST   temps=\(stats.temperatures.prefix(4).map { "\($0.label) \(Int($0.celsius))C" }.joined(separator: ", "))")
                    Log.app.info("SELFTEST   net=\(stats.net.map { "\($0.interface) ↓\(UdhaFormat.rate($0.rxBytesPerSec)) ↑\(UdhaFormat.rate($0.txBytesPerSec))" } ?? "none") tools=\(stats.tools.map { "\($0.name) \($0.version)" }.joined(separator: ", "))")
                    Log.app.info("SELFTEST   relay=\(stats.relay.map { "\($0.instanceID) seq=\($0.deltaSeq) caps=\($0.capabilities.joined(separator: "+"))" } ?? "none") sessions=\(machine.sessions.count)")
                } else {
                    Log.app.info("SELFTEST   no stats — \(machine.statsNote ?? "no reason given")")
                }
                if let link = machine.link {
                    Log.app.info("SELFTEST   tailscale \(link.address) \(link.route) handshake \(UdhaFormat.agoText(link.lastHandshake))")
                } else {
                    Log.app.info("SELFTEST   tailscale: \(core.machines.tailscaleNote ?? "no entry")")
                }
            }
            Log.app.info("SELFTEST machines: done")
            core.machines.removeViewer("selftest")
        }
    }

    /// `open Udha.AIDesktop.app --args -UDHACalendarSelfTest 1`: ask for
    /// calendar access if needed, match every recording that has no event,
    /// and log one SELFTEST line per recording — title, calendar, who. The
    /// only way to prove the matcher picks the right event out of several
    /// calendars without sitting through a meeting.
    private func runCalendarSelfTestIfRequested(core: AppCore) {
        guard UserDefaults.standard.bool(forKey: "UDHACalendarSelfTest") else { return }
        Task { @MainActor in
            core.meetingCalendar.check()
            Log.app.info("SELFTEST calendar: access \(String(describing: core.meetingCalendar.status))")
            if core.meetingCalendar.status != .ok {
                let ok = await core.meetingCalendar.requestAccess()
                Log.app.info("SELFTEST calendar: request → \(ok) (\(String(describing: core.meetingCalendar.status)))")
                guard ok else { return }
            }
            await core.meetings.backfillCalendar()
            for m in core.meetings.store.meetings.prefix(40) {
                let cal = m.calendarEvent.map { "\($0.calendarTitle) · \($0.attendees.prefix(4).joined(separator: ", "))" } ?? "no event"
                Log.app.info("SELFTEST calendar \(m.folderName): “\(m.title)” ← \(cal)")
            }
            Log.app.info("SELFTEST calendar: done")
        }
    }

    /// Lazily construct the AppCore once and cache it — callable from any entry point.
    @discardableResult
    func bootstrapCore() -> AppCore {
        if let c = appCore { return c }
        let c = AppCore()
        appCore = c
        return c
    }

    func installOverlay(core: AppCore) {
        Log.app.info("installOverlay: creating EdgeOverlayController")
        overlayController = EdgeOverlayController(core: core)
        if core.config.config.overlay.hideMainWindowOnLaunch {
            // Defer until after the initial WindowGroup has created its window.
            DispatchQueue.main.async { [weak self] in self?.hideMainWindows() }
        }
    }

    private func hideMainWindows() {
        // Miniaturize instead of orderOut — SwiftUI disposes ordered-out WindowGroup windows,
        // and we still need the window around so the gear/plus buttons can reveal it later.
        for window in mainContentWindows() {
            window.miniaturize(nil)
        }
    }

    /// Bring any existing main window forward. If none exists, returns without creating one —
    /// the Window scene + openWindow path is used for initial creation instead.
    func revealMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let candidates = mainContentWindows(includeMiniaturized: true)
        if let window = candidates.first {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func mainContentWindows(includeMiniaturized: Bool = false) -> [NSWindow] {
        NSApp.windows.filter { window in
            guard !(window is EdgeOverlayPanel) else { return false }
            let cls = String(describing: type(of: window))
            if cls.contains("MenuBarExtra") { return false }
            if cls.contains("StatusBar") { return false }
            if cls.contains("Popover") { return false }
            if cls.contains("Menu") && !cls.contains("Window") { return false }
            if includeMiniaturized && window.isMiniaturized { return true }
            return window.frame.width >= 400 && window.frame.height >= 300
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Called when the user clicks the app's Dock icon while it is already
    /// running. We use this to bring the overlay back if it was minimized.
    /// Returning `true` lets AppKit also do its default reopen behavior
    /// (deminiaturize/foreground the main window) when no window is visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        overlayController?.reveal()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        appCore?.shutdown()
    }
}
