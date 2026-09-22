import SwiftUI
import AVKit
import AppKit

/// The Videos section: the live recorder while one is running, otherwise one
/// recording — its masters, its burned-in caption track, and what to do with it.
struct VideosPane: View {
    let core: AppCore
    @Bindable var shell: UdhaShellModel

    /// Local to the pane, not the shell model: it is cleared the moment it is
    /// used and must never be persisted anywhere.
    @State private var publishPassword: String = ""

    /// Caption edits in flight, keyed by cue. Held here rather than written
    /// through on every keystroke: saving means rewriting captions.json *and*
    /// the derived VTT, and the point of the editor is to fix a line and then
    /// re-render once.
    /// Reveal is per recording and never sticky — it resets with the selection
    /// so a password is not left sitting on screen.
    @State private var revealedPasswordID: UUID?

    @State private var captionDrafts: [UUID: String] = [:]
    @State private var captionsRecordingID: UUID?
    @State private var savingCaptions = false
    /// Bumped after a re-render so the player picks the new file up — the URL
    /// is unchanged, and `AVPlayer` would otherwise keep showing the old one.
    @State private var playerGeneration = 0

    private var recording: Recording? {
        guard let id = shell.selectedRecordingID else { return core.recordings.store.recordings.first }
        return core.recordings.store.recording(withID: id) ?? core.recordings.store.recordings.first
    }

    var body: some View {
        Group {
            if let remaining = core.recordings.countdown {
                countdownView(remaining)
            } else if let live = core.recordings.live, shell.selectedRecordingID == nil || shell.selectedRecordingID == live.recording.id {
                liveView(live)
            } else if let recording {
                detail(recording)
            } else {
                UdhaEmptyState(
                    title: "No videos yet",
                    text: "Record a screen demo with your camera and mic. Udha renders a wide and a vertical master from the same take, with the transcript burned into the frames so the captions survive a re-upload anywhere.",
                    action: ("Record screen", "record.circle", { shell.recordTargetOpen = true })
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $shell.recordTargetOpen) {
            RecordTargetSheet(core: core, shell: shell)
        }
    }

    // MARK: - Pre-roll

    /// The window between hitting record and capture starting. Mirrors the
    /// block on the desktop rather than replacing it — you may well be looking
    /// at the screen you are about to record, not at this one.
    private func countdownView(_ remaining: Int) -> some View {
        VStack(spacing: 16) {
            Text("Starting in")
                .font(UdhaTheme.text(12, .semibold))
                .foregroundStyle(UdhaTheme.badInk)
            Text("\(remaining)")
                .font(UdhaTheme.mono(96, weight: .bold))
                .foregroundStyle(UdhaTheme.label)
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy(duration: 0.2), value: remaining)
            Text("Get set — the guides on screen are what each master will keep.")
                .font(UdhaTheme.text(12.5, .regular))
                .foregroundStyle(UdhaTheme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Live

    private func liveView(_ live: LiveRecording) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UdhaTheme.cardGap) {
                HStack(alignment: .center, spacing: 16) {
                    Pulsing(active: live.engine.state != .paused, period: 1.6) {
                        Circle().fill(live.engine.state == .paused ? UdhaTheme.warn : UdhaTheme.bad).frame(width: 9, height: 9)
                    }
                    Text(live.engine.state == .paused ? "Paused" : "Recording")
                        .font(UdhaTheme.text(12, .semibold))
                        .foregroundStyle(live.engine.state == .paused ? UdhaTheme.warnInk : UdhaTheme.badInk)
                    // The clock is derived from `Date()`, so nothing in the engine
                    // changes as it advances and observation has nothing to
                    // invalidate — the timeline is what makes it tick.
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(UdhaFormat.clock(live.engine.activeDuration))
                            .font(UdhaTheme.mono(30, weight: .semibold))
                            .foregroundStyle(UdhaTheme.label)
                    }
                    Spacer(minLength: 8)
                    Text(streamSummary(live))
                        .font(UdhaTheme.text(12.5, .regular))
                        .foregroundStyle(UdhaTheme.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .udhaCard(fill: UdhaTheme.badTint)

                if let session = live.engine.cameraPreviewSession {
                    CameraFramingPreview(
                        session: session,
                        guides: core.recordings.cameraCropGuides(cameraOnly: live.recording.isCameraOnly)
                    )
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: 720, maxHeight: 420)
                    .udhaRounded(UdhaTheme.cardRadius)
                    .udhaCard()
                }

                VStack(alignment: .leading, spacing: 14) {
                    RecordingDeviceControls(core: core, liveTake: true)
                    HStack(spacing: 8) {
                        if live.engine.state == .paused {
                            Button { core.recordings.resume(); shell.say("Recording resumed") } label: {
                                UdhaLabel(title: "Resume", icon: "play.fill")
                            }
                            .udhaButton(.primary, height: 28, hPadding: 12)
                        } else {
                            Button { core.recordings.pause(); shell.say("Recording paused") } label: {
                                UdhaLabel(title: "Pause", icon: "pause.fill")
                            }
                            .udhaButton(.ghost, height: 28, hPadding: 12)
                        }
                        Button {
                            Task {
                                await core.recordings.stop()
                                shell.say("Rendering both masters…")
                            }
                        } label: {
                            UdhaLabel(title: "Stop and render", icon: "stop.fill")
                        }
                        .udhaButton(.danger, height: 28, hPadding: 12)
                        Spacer()
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .udhaCard()

                // Degradation is surfaced while it can still be fixed, rather than
                // discovered in the finished file.
                if live.engine.cameraUnavailable || live.engine.micUnavailable {
                    VStack(alignment: .leading, spacing: 4) {
                        if live.engine.cameraUnavailable {
                            Text("No camera — recording screen only. The bubble will be missing.")
                        }
                        if live.engine.micUnavailable {
                            Text("No microphone — there will be no narration and no captions.")
                        }
                    }
                    .font(UdhaTheme.text(12, .medium))
                    .foregroundStyle(UdhaTheme.warnInk)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .udhaCard(fill: UdhaTheme.warnTint)
                }
            }
            .padding(.horizontal, UdhaTheme.contentInset)
            .padding(.top, 18)
            .padding(.bottom, 26)
        }
        .udhaScroll()
    }

    private func streamSummary(_ live: LiveRecording) -> String {
        var parts = live.recording.isCameraOnly ? [] : ["Screen"]
        if !live.engine.cameraUnavailable { parts.append("camera") }
        if !live.engine.micUnavailable { parts.append("mic") }
        if !live.engine.systemAudioUnavailable { parts.append("system audio") }
        return parts.joined(separator: " + ")
    }

    // MARK: - Detail

    private func detail(_ recording: Recording) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UdhaTheme.cardGap) {
                header(recording)
                player(recording)
                share(recording)
                actions(recording)
                transcript(recording)
            }
            .padding(.horizontal, UdhaTheme.contentInset)
            .padding(.top, 18)
            .padding(.bottom, 26)
        }
        .udhaScroll()
    }

    private func header(_ recording: Recording) -> some View {
        let available = recording.renderedOrientations
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    UdhaEditableTitle(text: recording.title) { name in
                        var updated = recording
                        updated.title = name
                        core.recordings.store.save(updated)
                        shell.say("Renamed to \(name)")
                        if updated.isPublished {
                            Task { await core.recordings.syncTitle(updated) }
                        }
                    }
                    .padding(.leading, -6)
                    Text(metaLine(recording))
                        .font(UdhaTheme.text(11.5, .regular))
                        .foregroundStyle(UdhaTheme.secondary)
                    if let reason = recording.failureReason {
                        Text(reason)
                            .font(UdhaTheme.text(12, .medium))
                            .foregroundStyle(UdhaTheme.badInk)
                    }
                    if recording.titleSyncPending {
                        HStack(spacing: 8) {
                            UdhaPill("share page still says “\(recording.syncedTitle ?? "the old title")”",
                                     fg: UdhaTheme.warnInk, bg: UdhaTheme.warnTint)
                                .lineLimit(1)
                            Button("Push title") {
                                shell.say("Pushing the title to the share page")
                                Task { await core.recordings.syncTitle(recording) }
                            }
                            .udhaButton(.ghost, height: 22, hPadding: 9)
                        }
                    }
                }
                Spacer(minLength: 12)
                if available.count > 1 {
                    UdhaSegmented(
                        options: available.map {
                            (value: $0, label: $0 == .landscape ? "Wide 16:9" : "Vertical 9:16")
                        },
                        selection: $shell.videoOrientation
                    )
                }
            }
            if recording.isJoined { provenance(recording) }
        }
    }

    private func metaLine(_ recording: Recording) -> String {
        var parts = [UdhaFormat.clock(recording.durationSeconds), UdhaFormat.stamp(recording.createdAt)]
        if recording.isJoined { parts.append("joined from \(recording.joinedFromIDs.count)") }
        if let captions = core.recordings.store.loadCaptions(for: recording), !captions.isEmpty {
            parts.append("\(captions.cues.count) captions")
        }
        if recording.hasCamera { parts.append("camera") }
        if recording.hasMic { parts.append("mic") }
        if recording.hasSystemAudio { parts.append("system audio") }
        return parts.joined(separator: " · ")
    }

    /// What this video was made of, and the way back out.
    ///
    /// The titles come from the join rather than from the sources, so this row
    /// still reads correctly after one of them has been renamed or deleted —
    /// which is exactly when you most want to know what went into it.
    private func provenance(_ recording: Recording) -> some View {
        HStack(spacing: 12) {
            UdhaTag("Joined", fg: UdhaTheme.accentInk, bg: UdhaTheme.accentTint)
            Text(recording.joinedFromTitles.joined(separator: "  →  "))
                .font(UdhaTheme.text(12.5, .medium))
                .foregroundStyle(UdhaTheme.label)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button {
                core.recordings.undoJoin(recording)
                shell.selectedRecordingID = nil
                shell.say("Join undone · the originals were never touched")
            } label: {
                UdhaLabel(title: "Undo join", icon: "arrow.uturn.backward")
            }
            .udhaButton(.ghost, height: 24, hPadding: 10)
            .disabled(core.recordings.processingIDs.contains(recording.id))
            .help("Deletes this joined video. The originals it was made from are untouched.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .udhaCard(radius: 10)
    }

    @ViewBuilder
    private func player(_ recording: Recording) -> some View {
        let available = recording.renderedOrientations
        if available.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(processingCopy(recording))
                    .font(UdhaTheme.text(13, .regular))
                    .foregroundStyle(UdhaTheme.secondary)
                if let fraction = core.recordings.renderProgress[recording.id] {
                    UdhaBar(fraction: fraction, height: 5)
                        .frame(maxWidth: 320)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .udhaCard()
        } else {
            let orientation = available.contains(shell.videoOrientation) ? shell.videoOrientation : available[0]
            let url = core.recordings.store.masterURL(for: recording, orientation: orientation)
            MasterPlayerView(url: url)
                .id("\(url.path)#\(playerGeneration)")
                .frame(height: orientation == .landscape ? 380 : 560)
                .frame(maxWidth: .infinity)
                .background(Color(hex: 0x111113))
                .udhaRounded(UdhaTheme.cardRadius)
                .udhaCard(fill: Color(hex: 0x111113))
        }
    }

    private func processingCopy(_ recording: Recording) -> String {
        guard core.recordings.processingIDs.contains(recording.id) else {
            return "No master has been rendered yet."
        }
        return recording.isJoined
            ? "Joining \(recording.joinedFromIDs.count) videos…"
            : "Rendering the masters…"
    }

    /// Publish, or the link if it is already out there.
    @ViewBuilder
    private func share(_ recording: Recording) -> some View {
        let uploading = core.recordings.publishProgress[recording.id]
        VStack(alignment: .leading, spacing: 10) {
            if let url = core.recordings.shareURL(for: recording) {
                HStack(spacing: 10) {
                    Text("Share")
                        .font(UdhaTheme.text(11, .semibold))
                        .foregroundStyle(UdhaTheme.secondary)
                    Text(url.absoluteString)
                        .font(UdhaTheme.mono(11.5, weight: .medium))
                        .foregroundStyle(UdhaTheme.accent)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if recording.isPasswordProtected {
                        UdhaPill("Password", size: 10, height: 18)
                    }
                    Spacer(minLength: 8)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        shell.say("Link copied")
                    } label: {
                        Text("Copy link")
                    }
                    .udhaButton(.primary, height: 26, hPadding: 11)
                    Button { NSWorkspace.shared.open(url) } label: {
                        Text("Open")
                    }
                    .udhaButton(.ghost, height: 26, hPadding: 11)
                }
                if recording.isPasswordProtected {
                    passwordRow(recording)
                }
            } else if let uploading {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Uploading to Cloudflare Stream… \(Int(uploading * 100))%")
                        .font(UdhaTheme.text(12.5, .medium))
                        .foregroundStyle(UdhaTheme.label)
                    UdhaBar(fraction: uploading, height: 5)
                        .frame(maxWidth: 320)
                }
            } else if recording.isPublished {
                // Uploaded, but there is no origin to build a link out of.
                Text("This recording is published, but no share link origin is set — add one under Settings → Advanced → Share link base to see its link here.")
                    .font(UdhaTheme.text(12.5, .regular))
                    .foregroundStyle(UdhaTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if recording.renderedOrientations.isEmpty {
                Text("Render this recording before publishing it.")
                    .font(UdhaTheme.text(12.5, .regular))
                    .foregroundStyle(UdhaTheme.secondary)
            } else if !core.recordings.canPublish {
                // No default backend ships with the app: publishing is off
                // until you point it at one you run.
                Text("Publishing is off — Udha has no share backend of its own. Point Settings → Advanced → Video share backend at your own upload API to turn it on.")
                    .font(UdhaTheme.text(12.5, .regular))
                    .foregroundStyle(UdhaTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text("Share")
                            .font(UdhaTheme.text(11, .semibold))
                            .foregroundStyle(UdhaTheme.secondary)
                        Text("Uploads both masters and gives you one link — the page picks wide or vertical to match the viewer's screen.")
                            .font(UdhaTheme.text(12, .regular))
                            .foregroundStyle(UdhaTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        UdhaField(placeholder: "Password (optional)", text: $publishPassword, height: 28)
                            .frame(maxWidth: 220)
                        Button {
                            let password = publishPassword
                            publishPassword = ""
                            Task {
                                if let url = await core.recordings.publish(recording, password: password.isEmpty ? nil : password) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                                    shell.say("Published · link copied")
                                } else {
                                    shell.say("Publish failed")
                                }
                            }
                        } label: {
                            UdhaLabel(title: "Publish", icon: "arrow.up.circle")
                        }
                        .udhaButton(.primary, height: 28, hPadding: 12)
                        Spacer()
                    }
                    if !publishPassword.isEmpty {
                        Text("The server only keeps a hash of this, so Udha saves a copy in your Keychain — you can read it back here after publishing.")
                            .font(UdhaTheme.text(11, .regular))
                            .foregroundStyle(UdhaTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let failure = core.recordings.publishError[recording.id] {
                Text(failure)
                    .font(UdhaTheme.text(12, .medium))
                    .foregroundStyle(UdhaTheme.badInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .udhaCard()
    }

    /// What the link asks for, on demand.
    ///
    /// Read from the Keychain rather than from the recording's metadata: the
    /// server keeps only a hash, and a password that cannot be looked up is a
    /// link you eventually cannot share.
    @ViewBuilder
    private func passwordRow(_ recording: Recording) -> some View {
        let stored = core.recordings.sharePassword(for: recording)
        let revealed = revealedPasswordID == recording.id
        HStack(spacing: 10) {
            Text("Password")
                .font(UdhaTheme.text(11, .semibold))
                .foregroundStyle(UdhaTheme.secondary)
            if let stored {
                Text(revealed ? stored : String(repeating: "•", count: max(6, min(stored.count, 16))))
                    .font(UdhaTheme.mono(12, weight: .medium))
                    .foregroundStyle(UdhaTheme.label)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button(revealed ? "Hide" : "Show") {
                    revealedPasswordID = revealed ? nil : recording.id
                }
                .udhaButton(.bare, height: 24, hPadding: 9)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(stored, forType: .string)
                    shell.say("Password copied")
                } label: {
                    UdhaLabel(title: "Copy", icon: "doc.on.doc")
                }
                .udhaButton(.ghost, height: 24, hPadding: 10)
            } else {
                // Published before Udha kept copies, or from another Mac. Said
                // plainly rather than shown as an empty field.
                Text("Not saved on this Mac — republish to set one you can read back.")
                    .font(UdhaTheme.text(12, .regular))
                    .foregroundStyle(UdhaTheme.secondary)
                Spacer(minLength: 8)
            }
        }
    }

    private func actions(_ recording: Recording) -> some View {
        HStack(spacing: 8) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([core.recordings.store.folderURL(for: recording)])
            } label: {
                Text("Reveal in Finder")
            }
            .udhaButton(.ghost, height: 28, hPadding: 12)

            Button {
                Task {
                    await core.recordings.retryProcessing(recording)
                    playerGeneration += 1
                }
                shell.say(recording.isJoined
                          ? "Re-joining \(recording.title)"
                          : "Re-rendering \(recording.title)")
            } label: {
                Text(rerenderTitle(recording))
            }
            .udhaButton(.ghost, height: 28, hPadding: 12)
            .disabled(core.recordings.processingIDs.contains(recording.id))

            Spacer()

            Button {
                core.recordings.delete(recording)
                shell.selectedRecordingID = nil
                shell.say("Deleted \(recording.title)")
            } label: {
                Text("Delete…")
            }
            .udhaButton(.danger, height: 28, hPadding: 12)
        }
    }

    /// A joined video has no raw files of its own, so the button that redoes it
    /// says what it will actually do — join the sources again, not compose.
    private func rerenderTitle(_ recording: Recording) -> String {
        if recording.isJoined { return recording.renderedOrientations.isEmpty ? "Join" : "Re-join" }
        return recording.renderedOrientations.isEmpty ? "Render" : "Re-render"
    }

    @ViewBuilder
    private func transcript(_ recording: Recording) -> some View {
        let track = core.recordings.store.loadCaptions(for: recording)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Captions")
                    .font(UdhaTheme.text(15, .semibold))
                    .tracking(-0.15)
                    .foregroundStyle(UdhaTheme.label)
                if let track {
                    Text("\(track.cues.count)")
                        .font(UdhaTheme.text(11.5, .regular))
                        .monospacedDigit()
                        .foregroundStyle(UdhaTheme.secondary)
                }
                Spacer()
                if !captionDrafts.isEmpty {
                    Button("Revert") { captionDrafts = [:] }
                        .udhaButton(.bare, height: 24, hPadding: 9)
                    Button {
                        saveCaptions(recording, track: track, thenRender: false)
                    } label: {
                        UdhaLabel(title: "Save", icon: "checkmark")
                    }
                    .udhaButton(.ghost, height: 24, hPadding: 10)
                    // Not offered for a joined video, and the button is gone
                    // rather than disabled: re-joining rebuilds the picture
                    // from the sources' masters, whose captions were burned in
                    // before this edit existed.
                    if !recording.isJoined {
                        Button {
                            saveCaptions(recording, track: track, thenRender: true)
                        } label: {
                            UdhaLabel(title: "Save and re-render", icon: "arrow.clockwise")
                        }
                        .udhaButton(.primary, height: 24, hPadding: 11)
                        .disabled(savingCaptions || core.recordings.processingIDs.contains(recording.id))
                    }
                }
                if track != nil {
                    UdhaSelect(
                        options: CaptionPunctuation.allCases.map { (value: $0, label: $0.label) },
                        selection: punctuationBinding(track),
                        minWidth: 150
                    )
                    UdhaSelect(
                        options: [(value: "", label: "As spoken")]
                            + LocalTranslator.languages.map { (value: $0, label: "In \($0)") },
                        selection: Binding(
                            get: { core.config.config.recordings.captionTranslateTo },
                            set: { value in core.config.mutate { $0.recordings.captionTranslateTo = value } }
                        ),
                        minWidth: 140
                    )
                }
            }
            .padding(.horizontal, 4)
            translatedCaptions(recording, track: track)
            if let track, !track.isEmpty {
                Text(recording.isJoined
                     ? "Carried over from the \(recording.joinedFromIDs.count) videos this was joined from — nothing was re-transcribed. Editing here changes the track a share link serves, not the words burned into the picture: for those, fix the caption on the original, re-render it, and join again."
                     : "Burned into both masters. Fix a line here, then re-render — the raw files are kept, so it costs a render and no second transcription.")
                    .font(UdhaTheme.text(11.5, .regular))
                    .foregroundStyle(UdhaTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                VStack(spacing: 0) {
                    ForEach(Array(track.cues.enumerated()), id: \.element.id) { index, cue in
                        HStack(alignment: .center, spacing: 14) {
                            Mono(UdhaFormat.clock(cue.start), size: 11, color: UdhaTheme.tertiary)
                                .frame(width: 44, alignment: .leading)
                            TextField("—", text: Binding(
                                get: { captionDrafts[cue.id] ?? cue.text },
                                set: { value in
                                    // Dropped again once it matches the saved
                                    // line, so the Save buttons disappear when
                                    // an edit is undone.
                                    if value == cue.text {
                                        captionDrafts.removeValue(forKey: cue.id)
                                    } else {
                                        captionDrafts[cue.id] = value
                                    }
                                }
                            ))
                            .textFieldStyle(.plain)
                            .font(UdhaTheme.text(13, .regular))
                            .foregroundStyle(UdhaTheme.label)
                            if captionDrafts[cue.id] != nil {
                                Circle().fill(UdhaTheme.accent).frame(width: 6, height: 6)
                            }
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 34)
                        .hoverBackground(base: .clear, hover: UdhaTheme.fill, radius: 0)
                        .overlay(alignment: .top) { if index > 0 { HRule(color: UdhaTheme.hairline) } }
                    }
                }
                .udhaCard()
                .udhaRounded(UdhaTheme.cardRadius)
            } else if !core.recordings.hasElevenLabsKey {
                Text("No ElevenLabs key, so this recording was rendered without captions. Add one in Settings → Keys and re-render.")
                    .font(UdhaTheme.text(12.5, .regular))
                    .foregroundStyle(UdhaTheme.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .udhaCard()
            } else {
                Text("No captions — nothing audible was transcribed from this recording.")
                    .font(UdhaTheme.text(12.5, .regular))
                    .foregroundStyle(UdhaTheme.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .udhaCard()
            }
        }
        // Drafts belong to one recording. Selecting another must not carry a
        // half-finished edit across to a different transcript.
        .task(id: recording.id) {
            if captionsRecordingID != recording.id {
                captionsRecordingID = recording.id
                captionDrafts = [:]
                revealedPasswordID = nil
            }
        }
    }

    /// The track in the chosen language, under the spoken one. Read-only —
    /// fix the spoken line and translate again — and burned only by a
    /// render, so the words can be read before a render is spent on them.
    @ViewBuilder
    private func translatedCaptions(_ recording: Recording, track: CaptionTrack?) -> some View {
        let language = core.config.config.recordings.captionTranslateTo
        if let track, !track.isEmpty, !language.isEmpty {
            let translated = core.recordings.store.loadCaptions(for: recording, language: language)
            let busy = core.recordings.processingIDs.contains(recording.id)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("In \(language)")
                        .font(UdhaTheme.text(13, .semibold))
                        .foregroundStyle(UdhaTheme.label)
                    if let translated {
                        Text("\(translated.cues.count)")
                            .font(UdhaTheme.text(11.5, .regular))
                            .monospacedDigit()
                            .foregroundStyle(UdhaTheme.secondary)
                    }
                    if recording.captionLanguage == language {
                        UdhaPill("burned in", fg: UdhaTheme.goodInk, bg: UdhaTheme.goodTint)
                    } else if translated != nil {
                        UdhaPill("not burned yet · re-render", fg: UdhaTheme.warnInk, bg: UdhaTheme.warnTint)
                    }
                    Spacer()
                    if busy {
                        HStack(spacing: 5) {
                            WorkingDots()
                            Text("on the box")
                                .font(UdhaTheme.text(11, .regular))
                                .foregroundStyle(UdhaTheme.tertiary)
                        }
                    }
                    Button {
                        shell.say("Translating captions to \(language) on the box")
                        Task {
                            await core.recordings.translateCaptions(recording, to: language)
                            playerGeneration += 1
                        }
                    } label: {
                        UdhaLabel(title: translated == nil ? "Translate" : "Translate again", icon: "character.bubble")
                    }
                    .udhaButton(translated == nil ? .primary : .ghost, height: 24, hPadding: 10)
                    .disabled(busy)
                }
                .padding(.horizontal, 4)
                if let translated, !translated.isEmpty {
                    Text("Translated on your own GPU from the spoken track, sentence by sentence, then re-cut on the same pauses. Re-render to burn it in; a share link then serves this track too.")
                        .font(UdhaTheme.text(11.5, .regular))
                        .foregroundStyle(UdhaTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                    VStack(spacing: 0) {
                        ForEach(Array(translated.cues.enumerated()), id: \.element.id) { index, cue in
                            HStack(alignment: .center, spacing: 14) {
                                Mono(UdhaFormat.clock(cue.start), size: 11, color: UdhaTheme.tertiary)
                                    .frame(width: 44, alignment: .leading)
                                Text(cue.text)
                                    .font(UdhaTheme.text(13, .regular))
                                    .foregroundStyle(UdhaTheme.accentInk)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 34)
                            .overlay(alignment: .top) { if index > 0 { HRule(color: UdhaTheme.hairline) } }
                        }
                    }
                    .udhaCard()
                    .udhaRounded(UdhaTheme.cardRadius)
                } else if !busy {
                    Text("Nothing translated yet. Translate to read it here first, or just re-render — the render translates on its own.")
                        .font(UdhaTheme.text(11.5, .regular))
                        .foregroundStyle(UdhaTheme.secondary)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.top, 6)
        }
    }

    /// Sets the punctuation level for future transcriptions, and applies it to
    /// the cues on screen right now as edits.
    ///
    /// Applied as *drafts* rather than written straight through, so the change
    /// is something you look at and then save — and so it goes out the same
    /// door as a hand edit, re-rendering only when you ask. Choosing a gentler
    /// level cannot put punctuation back that was never stored, so it only
    /// changes what the next transcription does.
    private func punctuationBinding(_ track: CaptionTrack?) -> Binding<CaptionPunctuation> {
        Binding(
            get: { core.config.config.recordings.captionPunctuation },
            set: { level in
                core.config.mutate { $0.recordings.captionPunctuation = level }
                guard let track, level != .full else { return }
                for cue in track.cues {
                    let current = captionDrafts[cue.id] ?? cue.text
                    let stripped = level.apply(toLine: current)
                    if stripped == cue.text {
                        captionDrafts.removeValue(forKey: cue.id)
                    } else if stripped != current {
                        captionDrafts[cue.id] = stripped
                    }
                }
            }
        )
    }

    /// Writes the edited cues back to captions.json (and the derived VTT), then
    /// optionally re-renders both masters from the raw files.
    private func saveCaptions(_ recording: Recording, track: CaptionTrack?, thenRender: Bool) {
        guard var track, !captionDrafts.isEmpty else { return }
        for index in track.cues.indices {
            if let draft = captionDrafts[track.cues[index].id] {
                track.cues[index].setText(draft)
            }
        }
        // Nothing left to say is a deleted cue, not an empty caption flashing
        // on screen.
        track.cues.removeAll { $0.words.isEmpty }
        core.recordings.store.writeCaptions(track, for: recording)
        captionDrafts = [:]
        savingCaptions = true
        shell.say(thenRender ? "Captions saved · re-rendering" : "Captions saved")
        Task {
            if thenRender {
                await core.recordings.retryProcessing(recording)
                playerGeneration += 1
            }
            savingCaptions = false
        }
    }
}

// MARK: - Player

/// AppKit's `AVPlayerView`, wrapped.
///
/// Deliberately **not** SwiftUI's `AVKit.VideoPlayer`. That one aborts the
/// process on this build: `_AVKit_SwiftUI` fails inside
/// `_swift_initClassMetadataImpl` → `getSuperclassMetadata` → `swift::fatalError`,
/// and because SwiftUI realises view-type metadata eagerly it took the app down
/// about seven seconds after launch — before the Videos section was ever
/// opened, which made it look like an unrelated startup crash.
///
/// `AVPlayerView` is the AppKit control and avoids that generic-metadata path
/// entirely. It also gives native scrubbing and full-screen for free.
struct MasterPlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        // Only swap when the file actually changed — reassigning the player
        // restarts playback from zero.
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            view.player = AVPlayer(url: url)
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

// MARK: - Framing preview

/// The camera feed with the crop guides drawn over it — what the wide master
/// keeps, and what the vertical one keeps.
///
/// The point is to answer "am I still in shot" *before* the render rather than
/// after it. The camera column of the wide master is a tall narrow slot that
/// keeps roughly the middle third of a 16:9 frame, so a presenter sitting
/// slightly off-centre is fine in the vertical cut and half out of frame in the
/// wide one, with nothing on screen to say so until the file exists.
///
/// The picture is letterboxed rather than cropped to the view, because a guide
/// drawn over an already-cropped preview would be measuring the wrong frame.
struct CameraFramingPreview: View {
    let session: AVCaptureSession?
    var guides: [CompositorLayout.CropGuide] = []
    var showsLabels: Bool = true

    /// Camera sessions are pinned to `.hd1280x720`, so the incoming frame is
    /// 16:9. Stated once here rather than measured off the preview layer, which
    /// would mean pushing layout state back into SwiftUI every frame.
    private static let sourceAspect: CGFloat = 16.0 / 9.0

    var body: some View {
        GeometryReader { geo in
            let video = CompositorLayout.aspectFit(
                CGSize(width: Self.sourceAspect, height: 1),
                into: CGRect(origin: .zero, size: geo.size)
            )
            ZStack {
                Rectangle().fill(Color(hex: 0x111113))
                CameraPreviewView(session: session, fills: false)
                ForEach(Array(guides.enumerated()), id: \.offset) { index, guide in
                    guideRect(guide, index: index, in: video)
                }
            }
        }
    }

    private func guideRect(_ guide: CompositorLayout.CropGuide, index: Int, in video: CGRect) -> some View {
        let rect = CompositorLayout.cropRegion(of: video, aspect: guide.aspect)
        return Rectangle()
            .strokeBorder(UdhaTheme.bad, lineWidth: index == 0 ? 2 : 1.5)
            .frame(width: rect.width, height: rect.height)
            .overlay(alignment: .topLeading) {
                // Stepped down per guide: both camera crops are full height, so
                // their labels would otherwise print on the same line.
                if showsLabels, rect.width > 96 {
                    Text(guide.label)
                        .font(UdhaTheme.mono(9, weight: .bold))
                        .tracking(0.7)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(UdhaTheme.bad)
                        .padding(.top, CGFloat(index) * 18 + 2)
                        .padding(.leading, 2)
                }
            }
            .position(x: rect.midX, y: rect.midY)
    }
}

// MARK: - Device controls

/// The camera and microphone pickers, in the recorder itself rather than three
/// clicks deep in Settings — choosing which mic a demo is narrated with is part
/// of setting up the take, not a preference.
///
/// `liveTake` is true while a recording is running. The Off entries disappear
/// then: the output file's tracks are laid down when the take starts, and a
/// track cannot be added to a movie that is already being written, so on/off
/// applies to the next recording while a *swap* applies immediately.
struct RecordingDeviceControls: View {
    let core: AppCore
    var liveTake: Bool
    /// Stacked in the narrow column beside the record sheet's self-view; side
    /// by side in the pane, which has the width for it.
    var stacked: Bool = false

    @State private var cameras: [DeviceOption] = []
    @State private var mics: [DeviceOption] = []

    struct DeviceOption: Hashable {
        let uid: String
        let name: String
    }

    /// Distinct from "" (system default) and from any real device's UID.
    private static let offValue = "udha.device.off"
    private static let defaultValue = ""

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 8) {
                    picker(title: "Camera", options: cameraOptions, selection: cameraSelection)
                    picker(title: "Mic", options: micOptions, selection: micSelection)
                }
            } else {
                HStack(spacing: 14) {
                    picker(title: "Camera", options: cameraOptions, selection: cameraSelection)
                    picker(title: "Mic", options: micOptions, selection: micSelection)
                    Spacer(minLength: 0)
                }
            }
        }
        .onAppear(perform: refresh)
        // Devices come and go — a headset is plugged in, an iPhone wanders off
        // the desk. The list is rebuilt whenever the app comes forward rather
        // than being read once and going stale.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func picker(title: String, options: [(value: String, label: String)], selection: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Eyebrow(title)
                .frame(width: stacked ? 52 : nil, alignment: .leading)
            UdhaSelect(options: options, selection: selection, minWidth: stacked ? 194 : 210)
        }
    }

    private func refresh() {
        cameras = CameraCaptureSource.availableCameras().map { DeviceOption(uid: $0.uid, name: $0.name) }
        mics = CameraCaptureSource.availableMicrophones().map { DeviceOption(uid: $0.uid, name: $0.name) }
    }

    // MARK: Options

    private var cameraOptions: [(value: String, label: String)] {
        var options: [(value: String, label: String)] = []
        if !liveTake { options.append((Self.offValue, "Off — screen only")) }
        options.append((Self.defaultValue, defaultLabel(cameras.first?.name)))
        options.append(contentsOf: cameras.map { ($0.uid, $0.name) })
        return options
    }

    private var micOptions: [(value: String, label: String)] {
        var options: [(value: String, label: String)] = []
        if !liveTake { options.append((Self.offValue, "Off — no narration")) }
        let resolved = CameraCaptureSource.microphoneName(forUID: core.config.config.effectiveRecordingMicUID)
        options.append((Self.defaultValue, defaultLabel(resolved)))
        options.append(contentsOf: mics.map { ($0.uid, $0.name) })
        return options
    }

    /// Names the device the fallback actually lands on. "System default" on its
    /// own is the one label that can be wrong without looking wrong.
    private func defaultLabel(_ resolved: String?) -> String {
        guard let resolved, !resolved.isEmpty else { return "System default" }
        return "System default · \(resolved)"
    }

    // MARK: Bindings

    private var cameraSelection: Binding<String> {
        Binding(
            get: {
                let cfg = core.config.config.recordings
                return cfg.includeCamera ? cfg.cameraDeviceUID : Self.offValue
            },
            set: { value in
                core.config.mutate { cfg in
                    if value == Self.offValue {
                        cfg.recordings.includeCamera = false
                    } else {
                        cfg.recordings.includeCamera = true
                        cfg.recordings.cameraDeviceUID = value
                    }
                }
                core.recordings.reloadLocalDevices()
            }
        )
    }

    private var micSelection: Binding<String> {
        Binding(
            get: {
                let cfg = core.config.config.recordings
                return cfg.includeMic ? cfg.micDeviceUID : Self.offValue
            },
            set: { value in
                core.config.mutate { cfg in
                    if value == Self.offValue {
                        cfg.recordings.includeMic = false
                    } else {
                        cfg.recordings.includeMic = true
                        cfg.recordings.micDeviceUID = value
                    }
                }
                core.recordings.reloadLocalDevices()
            }
        )
    }
}

// MARK: - Target picker

/// "What do you want to record?" — a display or a single window.
///
/// This sheet is also where the Screen Recording permission is requested,
/// because listing targets is the first thing that touches ScreenCaptureKit.
struct RecordTargetSheet: View {
    let core: AppCore
    @Bindable var shell: UdhaShellModel

    @State private var targets: [ScreenCaptureCandidate] = []
    @State private var loading = true
    /// Picking a row no longer starts the take. It arms it: the guides land on
    /// that screen and become draggable, and recording waits for the button —
    /// which is the only moment there is to choose *which part* of a 32:9
    /// display ends up in the frame.
    @State private var selected: ScreenCaptureCandidate?
    /// Armed for a take with no screen in it at all — just the camera, filling
    /// the frame. Mutually exclusive with a screen selection.
    @State private var cameraOnly = false
    /// A preview-only session, live only while this sheet is up. See
    /// `CameraPreviewController` for why it is never left running.
    @State private var preview = CameraPreviewController()

    private var displays: [ScreenCaptureCandidate] {
        targets.filter { if case .display = $0.target { return true } else { return false } }
    }
    private var windows: [ScreenCaptureCandidate] {
        targets.filter { if case .window = $0.target { return true } else { return false } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Record")
                    .font(UdhaTheme.text(16, .bold))
                    .foregroundStyle(UdhaTheme.label)
                Spacer()
                Button { shell.recordTargetOpen = false } label: { Text("Cancel") }
                    .udhaButton(.bare, height: 26, hPadding: 8)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            HRule()

            cameraStrip

            HRule()

            if loading {
                progressBody("Looking for screens and windows…")
            } else if targets.isEmpty {
                permissionBody
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        sectionHeader("No screen")
                        cameraOnlyRow
                        if !displays.isEmpty {
                            sectionHeader("Screens")
                            ForEach(displays) { targetRow($0) }
                        }
                        if !windows.isEmpty {
                            sectionHeader("Windows")
                            ForEach(windows) { targetRow($0) }
                        }
                    }
                }
                .frame(maxHeight: 340)

                HRule()
                startBar
            }
        }
        .frame(width: 520)
        .background(UdhaTheme.canvas)
        .task {
            targets = await core.recordings.availableTargets()
            loading = false
        }
        // Keyed on the chosen camera, so switching device in the picker
        // restarts the preview on the new one.
        .task(id: previewKey) {
            if core.config.config.recordings.includeCamera {
                let uid = core.config.config.recordings.cameraDeviceUID
                await preview.start(uid: uid.isEmpty ? nil : uid, access: core.cameraAccess)
            } else {
                preview.stop()
            }
        }
        .onDisappear {
            preview.stop()
            CaptureBorderController.shared.clearPreview()
        }
    }

    private var previewKey: String {
        let cfg = core.config.config.recordings
        return cfg.includeCamera ? "on:\(cfg.cameraDeviceUID)" : "off"
    }

    /// Frame yourself before you hit record, and pick what the take is narrated
    /// with — the two things you cannot fix afterwards.
    private var cameraStrip: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Rectangle().fill(Color(hex: 0x111113))
                if core.config.config.recordings.includeCamera {
                    if preview.session != nil {
                        CameraFramingPreview(
                            session: preview.session,
                            guides: core.recordings.cameraCropGuides(cameraOnly: cameraOnly),
                            showsLabels: cameraOnly
                        )
                    } else if preview.isStarting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(preview.failure ?? "No camera")
                            .font(UdhaTheme.text(10.5, .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                    }
                } else {
                    Text("Camera off")
                        .font(UdhaTheme.text(10.5, .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .frame(width: 208, height: 117)
            .udhaRounded(8)

            VStack(alignment: .leading, spacing: 10) {
                RecordingDeviceControls(core: core, liveTake: false, stacked: true)
                HStack(spacing: 8) {
                    Eyebrow("Start")
                        .frame(width: 52, alignment: .leading)
                    UdhaSelect(
                        options: [
                            (0, "Straight away"),
                            (3, "After 3 · 2 · 1"),
                            (5, "After a 5s count"),
                        ],
                        selection: core.config.binding(\.recordings.countdownSeconds),
                        minWidth: 194
                    )
                }
                Text("System audio is captured too, and the count begins as soon as you pick a screen or window below.")
                    .font(UdhaTheme.text(11, .regular))
                    .foregroundStyle(UdhaTheme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// Recording yourself and nothing else — a piece to camera.
    private var cameraOnlyRow: some View {
        Button {
            cameraOnly = true
            selected = nil
            CaptureBorderController.shared.clearPreview()
        } label: {
            HStack(spacing: 10) {
                StateMark(
                    color: cameraOnly ? UdhaTheme.accent : UdhaTheme.separator,
                    filled: cameraOnly,
                    pulses: false
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text("Just my camera")
                        .font(UdhaTheme.text(13, .semibold))
                        .foregroundStyle(UdhaTheme.ink)
                    Text("Camera and mic only — the picture is you, full frame.")
                        .font(UdhaTheme.text(11, .regular))
                        .foregroundStyle(UdhaTheme.muted)
                }
                Spacer(minLength: 8)
                Mono("1280×720", size: 10)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverBackground(base: .clear, hover: UdhaTheme.fill, radius: 0)
        .overlay(alignment: .bottom) { HRule(color: UdhaTheme.hairline) }
    }

    private var startBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if cameraOnly {
                    Text("Just my camera")
                        .font(UdhaTheme.text(12.5, .semibold))
                        .foregroundStyle(UdhaTheme.ink)
                    Text("No screen, and no system audio — it rides on the screen stream.")
                        .font(UdhaTheme.text(11, .regular))
                        .foregroundStyle(UdhaTheme.faint)
                } else if let selected {
                    Text(selected.name)
                        .font(UdhaTheme.text(12.5, .semibold))
                        .foregroundStyle(UdhaTheme.ink)
                        .lineLimit(1)
                    Text("Drag the red guides on screen to choose the part that gets recorded.")
                        .font(UdhaTheme.text(11, .regular))
                        .foregroundStyle(UdhaTheme.faint)
                } else {
                    Text("Pick a screen or window above.")
                        .font(UdhaTheme.text(12, .regular))
                        .foregroundStyle(UdhaTheme.muted)
                }
            }
            Spacer(minLength: 8)
            Button {
                start()
            } label: {
                UdhaLabel(title: "Start recording", icon: "record.circle")
            }
            .udhaButton(.primary, height: 32, hPadding: 14)
            .disabled(selected == nil && !cameraOnly)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func start() {
        guard cameraOnly || selected != nil else { return }
        let candidate = selected
        let label = cameraOnly ? "camera" : (candidate?.name ?? "screen")
        shell.recordTargetOpen = false
        shell.selectedRecordingID = nil
        Task {
            // Released before the capture session opens, and awaited: handing
            // the same camera to two sessions is how a Continuity device ends
            // up serving neither.
            await preview.stopAndWait()
            await core.recordings.start(target: cameraOnly ? nil : candidate?.target)
            if let live = core.recordings.live {
                shell.selectedRecordingID = live.recording.id
                shell.say("Recording \(label)")
            } else {
                shell.say("Could not start recording")
            }
        }
    }

    private func progressBody(_ message: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(message)
                .font(UdhaTheme.text(12.5, .regular))
                .foregroundStyle(UdhaTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
    }

    /// An empty list means the grant is missing, not that the Mac has no
    /// screens — and a fresh grant does not apply until Udha relaunches, so
    /// this says so rather than letting the retry silently fail.
    private var permissionBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Udha needs Screen Recording access")
                .font(UdhaTheme.text(14, .extraBold))
                .foregroundStyle(UdhaTheme.ink)
            Text("Enable Udha under Privacy & Security → Screen & System Audio Recording. macOS only applies a new grant to a freshly launched app, so Udha has to restart afterwards.")
                .font(UdhaTheme.text(12.5, .regular))
                .foregroundStyle(UdhaTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { core.screenRecordingAccess.openScreenRecordingSettings() } label: {
                    UdhaLabel(title: "Open Settings", icon: "gearshape")
                }
                .udhaButton(.primary, height: 28, hPadding: 12)
                Button {
                    loading = true
                    Task {
                        targets = await core.recordings.availableTargets()
                        loading = false
                    }
                } label: {
                    UdhaLabel(title: "Check again", icon: "arrow.clockwise")
                }
                .udhaButton(.ghost, height: 28, hPadding: 12)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Eyebrow(title)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private func targetRow(_ candidate: ScreenCaptureCandidate) -> some View {
        let isSelected = selected?.target == candidate.target
        return Button {
            selected = candidate
            cameraOnly = false
            CaptureBorderController.shared.showPreview(
                candidate.target, guides: core.recordings.screenCropGuides, adjustable: true
            )
        } label: {
            HStack(spacing: 10) {
                StateMark(
                    color: isSelected ? UdhaTheme.accent : UdhaTheme.separator,
                    filled: isSelected,
                    pulses: false
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.name)
                        .font(UdhaTheme.text(13, .semibold))
                        .foregroundStyle(UdhaTheme.ink)
                        .lineLimit(1)
                    if let app = candidate.applicationName {
                        Text(app)
                            .font(UdhaTheme.text(11, .regular))
                            .foregroundStyle(UdhaTheme.muted)
                    }
                }
                Spacer(minLength: 8)
                Mono("\(candidate.width)×\(candidate.height)", size: 10)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverBackground(base: .clear, hover: UdhaTheme.fill, radius: 0)
        .overlay(alignment: .bottom) { HRule(color: UdhaTheme.hairline) }
        // Outline the actual screen or window under the pointer — the only way
        // to tell "Screen 2" from "Screen 3" without guessing.
        // Hover answers "which one is this?" — but only until a target is
        // armed, after which the guides belong to the selection and are being
        // dragged into place.
        .onHover { inside in
            guard selected == nil, !cameraOnly else { return }
            if inside {
                CaptureBorderController.shared.showPreview(
                    candidate.target, guides: core.recordings.screenCropGuides
                )
            } else {
                CaptureBorderController.shared.clearPreview()
            }
        }
    }
}
