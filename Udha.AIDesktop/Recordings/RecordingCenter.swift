import Foundation
import Observation

/// One recording in progress: its metadata and the engine capturing it.
@MainActor
@Observable
final class LiveRecording {
    var recording: Recording
    let engine: RecordingEngine

    init(recording: Recording, engine: RecordingEngine) {
        self.recording = recording
        self.engine = engine
    }
}

/// Lifecycle owner tying the store and the capture engine together. Enforces
/// one live recording at a time, the way `MeetingCenter` does for calls.
///
/// Capture never depends on the network: no API key is read on this path, and
/// a recording that is never published is still a finished local file.
@MainActor
@Observable
final class RecordingCenter {
    let store: RecordingStore
    let screenAccess: ScreenRecordingAccess
    let cameraAccess: CameraAccess

    private let config: ConfigStore
    private let keychain: KeychainStore
    private let transcriber: RecordingTranscriber
    private let compositor = RecordingCompositor()
    private let publisher: RecordingPublisher

    private(set) var live: LiveRecording?
    /// Recordings currently being transcribed or rendered, so the UI can show
    /// progress without the store having to poll.
    private(set) var processingIDs: Set<UUID> = []
    /// 0…1 per recording being rendered, for the progress bar.
    private(set) var renderProgress: [UUID: Double] = [:]

    var hasElevenLabsKey: Bool { keychain.has(.elevenLabsAPIKey) }

    init(store: RecordingStore, config: ConfigStore, keychain: KeychainStore,
         screenAccess: ScreenRecordingAccess, cameraAccess: CameraAccess,
         auth0: Auth0Client) {
        self.store = store
        self.config = config
        self.keychain = keychain
        self.screenAccess = screenAccess
        self.cameraAccess = cameraAccess
        self.transcriber = RecordingTranscriber(
            stt: ElevenLabsSTTClient(keychain: keychain, config: config),
            config: config
        )
        self.publisher = RecordingPublisher(auth0: auth0, config: config)
    }

    // MARK: - Publishing

    /// 0…1 per recording being uploaded.
    private(set) var publishProgress: [UUID: Double] = [:]
    private(set) var publishError: [UUID: String] = [:]

    var isPublishing: Bool { !publishProgress.isEmpty }

    /// Uploads the rendered masters and records the resulting share link.
    ///
    /// Only rendered orientations are sent — a recording whose portrait render
    /// failed still publishes as a wide-only share rather than refusing.
    @discardableResult
    func publish(_ recording: Recording, password: String?) async -> URL? {
        guard publishProgress[recording.id] == nil else { return nil }
        var masters: [RecordingOrientation: URL] = [:]
        for orientation in recording.renderedOrientations {
            let url = store.masterURL(for: recording, orientation: orientation)
            if FileManager.default.fileExists(atPath: url.path) {
                masters[orientation] = url
            }
        }
        guard !masters.isEmpty else {
            publishError[recording.id] = "Nothing has been rendered for this recording yet."
            return nil
        }

        publishProgress[recording.id] = 0
        publishError[recording.id] = nil
        defer { publishProgress[recording.id] = nil }

        // The VTT that matches the picture: the burned language when there
        // is one, else the spoken track.
        let burnedVTT = recording.captionLanguage.isEmpty ? nil
            : try? String(contentsOf: store.captionsVTTURL(for: recording, language: recording.captionLanguage), encoding: .utf8)
        let vtt = burnedVTT ?? (try? String(contentsOf: store.captionsVTTURL(for: recording), encoding: .utf8))
        let id = recording.id
        do {
            let result = try await publisher.publish(
                recording: recording,
                masters: masters,
                captionsVTT: vtt,
                password: password,
                onProgress: { [weak self] fraction in
                    Task { @MainActor in self?.publishProgress[id] = fraction }
                }
            )
            storeSharePassword(password, for: id)
            var updated = store.recording(withID: id) ?? recording
            updated.slug = result.slug
            updated.publishedAt = Date()
            updated.isPasswordProtected = !(password ?? "").isEmpty
            updated.streamUIDLandscape = masters[.landscape] != nil ? result.slug : nil
            // What the register call carried — the snapshot's title, not the
            // store's, which may have moved on during the upload.
            updated.syncedTitle = recording.title
            store.save(updated)
            // The title that reached the server was read off the snapshot this
            // call started with, and an upload takes tens of seconds. Renaming
            // inside that window used to be lost in both directions at once:
            // the register carried the old name, and `syncTitle` skipped the
            // rename because the recording was not published *yet*. Push it now
            // that it is — the store's copy is the one that is right.
            if updated.title != recording.title {
                Log.recording.info("RecordingCenter: title changed during publish — syncing “\(updated.title)”")
                await syncTitle(updated)
            }
            return result.url
        } catch {
            publishError[id] = error.localizedDescription
            Log.recording.error("RecordingCenter: publish failed for \(recording.folderName): \(error.localizedDescription)")
            return nil
        }
    }

    /// Pushes a rename to the share service so the public page shows the new
    /// title. Best-effort: the local rename has already been saved, and a
    /// failure here (offline, signed out) should not undo or block it.
    func syncTitle(_ recording: Recording) async {
        guard let slug = recording.slug, recording.isPublished else { return }
        do {
            try await publisher.rename(slug: slug, title: recording.title)
            // Confirm against the store's current row, not the snapshot: a
            // second rename may have landed while this one was in flight, and
            // stamping the old title over it would hide that it is pending.
            if var current = store.recording(withID: recording.id) {
                current.syncedTitle = recording.title
                store.save(current)
            }
            Log.recording.info("RecordingCenter: share page now titled “\(recording.title)” (\(slug.prefix(8)))")
        } catch {
            Log.recording.error("RecordingCenter: title sync failed for \(recording.folderName): \(error.localizedDescription) — will retry at next launch")
        }
    }

    /// Every published recording whose title the share service has not
    /// confirmed gets pushed again. Run once at launch (after the bridge sign-in
    /// has had a moment) and from the pane's retry. Sequential and quiet: a
    /// signed-out Mac logs one line per recording and moves on.
    func syncPendingTitles() async {
        let pending = store.recordings.filter(\.titleSyncPending)
        guard !pending.isEmpty else { return }
        Log.recording.info("RecordingCenter: \(pending.count) published title(s) not yet on the share page — syncing")
        for recording in pending {
            await syncTitle(recording)
        }
    }

    // MARK: - Share passwords

    /// Share passwords live in the Keychain, one item per recording.
    ///
    /// The server only ever stores a hash, so it genuinely cannot tell you what
    /// you chose — which made a password you set last week unrecoverable, and
    /// the link with it. Keeping a copy is a deliberate trade: a share-link
    /// password is not an account credential, and it goes in the Keychain
    /// rather than into `recording.json`, so it is encrypted at rest and never
    /// travels with the recording folder.
    private static func sharePasswordAccount(_ id: UUID) -> String {
        "recording_share_password.\(id.uuidString)"
    }

    /// What this recording's link asks for, if it was published from this Mac.
    func sharePassword(for recording: Recording) -> String? {
        keychain.get(account: Self.sharePasswordAccount(recording.id))
    }

    private func storeSharePassword(_ password: String?, for id: UUID) {
        let account = Self.sharePasswordAccount(id)
        guard let password, !password.isEmpty else {
            // Republished without one: the old password is no longer what the
            // link asks for, so keeping it would be worse than forgetting it.
            keychain.delete(account: account)
            return
        }
        do {
            try keychain.set(password, account: account)
        } catch {
            Log.recording.error("RecordingCenter: could not store the share password: \(error.localizedDescription)")
        }
    }

    /// Removes the recording and anything held for it outside its folder.
    func delete(_ recording: Recording) {
        keychain.delete(account: Self.sharePasswordAccount(recording.id))
        store.delete(recording)
    }

    /// The public link for an already-published recording, or nil when no
    /// share origin is configured.
    ///
    /// The empty base has to be caught here rather than left to `URL(string:)`:
    /// `URL(string: "/v/abc")` is *not* nil, it is a perfectly valid relative
    /// URL, so without this guard an unconfigured install would show "/v/abc"
    /// as the share link and copy that to the pasteboard.
    func shareURL(for recording: Recording) -> URL? {
        guard let slug = recording.slug else { return nil }
        let base = config.config.recordings.shareLinkBaseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        guard let url = URL(string: "\(base.hasSuffix("/") ? String(base.dropLast()) : base)/v/\(slug)"),
              url.scheme != nil, url.host != nil else { return nil }
        return url
    }

    /// Whether `shareLinkBaseURL` is set at all — what the Videos pane asks
    /// before promising a published recording a link.
    var hasShareLinkOrigin: Bool {
        !config.config.recordings.shareLinkBaseURL
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether a recording can be uploaded at all: publishing needs a share
    /// backend, and there is no default one.
    var canPublish: Bool {
        !config.config.recordings.shareAPIBaseURL
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True from the moment a take starts being set up until it is torn down.
    ///
    /// `.starting` counts: the camera and microphone are opened during it, and
    /// that is exactly the window in which a phantom meeting used to appear.
    var isRecording: Bool {
        guard let live else { return false }
        switch live.engine.state {
        case .starting, .recording, .paused, .stopping: return true
        case .idle, .finished, .failed: return false
        }
    }

    /// Swap camera or microphone while a take is running.
    func reloadLocalDevices() {
        live?.engine.reloadLocalDevices()
    }

    private var lastRecordingEndedAt: Date?

    /// True while recording, and for a short window afterwards.
    ///
    /// The tail matters: the meeting auto-detector reads the HAL, and the HAL
    /// keeps reporting the microphone as in use for a moment after the capture
    /// session is torn down. Gating purely on `isRecording` left a gap of tens
    /// of milliseconds in which a phantom meeting started the instant a screen
    /// recording stopped — measured at 56ms in a self-test run. This is not a
    /// permanent suppression: once the window lapses, a genuine call still
    /// auto-starts on the detector's next tick.
    var isRecordingOrSettling: Bool {
        if isRecording { return true }
        guard let lastRecordingEndedAt else { return false }
        return Date().timeIntervalSince(lastRecordingEndedAt) < Self.settlingWindow
    }

    /// A minute, not the 15 seconds this started as. 15 was measured against
    /// the HAL's own lag and covered it — but not the far longer tail of a
    /// Continuity Camera, which keeps the paired iPhone's microphone device
    /// alive for tens of seconds after the session closes. Observed in the log
    /// as a meeting auto-starting 24s after a screen recording stopped.
    private static let settlingWindow: TimeInterval = 60

    /// The crop shapes the masters will keep, for the desktop guides.
    var screenCropGuides: [CompositorLayout.CropGuide] {
        CompositorLayout.screenCropGuides(
            config: config.config.recordings,
            hasCamera: config.config.recordings.includeCamera
        )
    }

    /// The crop shapes the camera panel will keep, for the self-view guides.
    func cameraCropGuides(cameraOnly: Bool = false) -> [CompositorLayout.CropGuide] {
        guard cameraOnly || config.config.recordings.includeCamera else { return [] }
        return CompositorLayout.cameraCropGuides(
            config: config.config.recordings, hasScreen: !cameraOnly
        )
    }

    // MARK: - Targets

    /// Displays and windows available to record. Returns empty rather than
    /// throwing when screen access is off — the caller shows the permission
    /// row instead of an error.
    ///
    /// Access is requested *here*, not at record time, because this is the
    /// first thing that touches ScreenCaptureKit: `SCShareableContent` throws
    /// "the user declined TCCs" on an unauthorized process rather than raising
    /// the prompt itself. Asking at the picker also matches where the meeting
    /// recorder asks — at the moment the user reaches for the feature.
    func availableTargets(requestingAccess: Bool = true) async -> [ScreenCaptureCandidate] {
        if requestingAccess {
            let granted = await screenAccess.requestAccess()
            if !granted {
                Log.recording.error("RecordingCenter: screen recording access unavailable (status=\(String(describing: screenAccess.status)))")
                return []
            }
        }
        do {
            return try await ScreenCaptureSource.availableTargets()
        } catch {
            Log.recording.error("RecordingCenter: cannot list capture targets: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Start / stop

    /// Seconds left on the pre-roll, for the UI to echo. Nil when not counting.
    private(set) var countdown: Int?

    /// `target == nil` records the camera alone.
    func start(target: ScreenCaptureTarget?) async {
        guard live == nil, countdown == nil else { return }

        // Before the folder is created and before anything is opened: a
        // recording that is cancelled during the pre-roll should leave nothing
        // behind at all.
        let preRoll = config.config.recordings.countdownSeconds
        if preRoll > 0 {
            await CaptureBorderController.shared.runCountdown(
                from: preRoll, on: target, guides: target == nil ? [] : screenCropGuides,
                tick: { [weak self] remaining in self?.countdown = remaining }
            )
            countdown = nil
        }

        var recording = store.create()
        // Whatever the guides were dragged to. Stored on the recording rather
        // than read at render time, so re-rendering next month reproduces the
        // framing you chose today.
        let crop = CaptureBorderController.shared.cropCentre
        recording.screenCropX = crop.x
        recording.screenCropY = crop.y
        recording.screenCropScale = CaptureBorderController.shared.cropScale
        recording.isCameraOnly = target == nil
        store.save(recording)
        let engine = RecordingEngine(
            screenURL: store.screenURL(for: recording),
            cameraURL: store.cameraURL(for: recording),
            config: config,
            screenAccess: screenAccess,
            cameraAccess: cameraAccess
        )
        let liveRecording = LiveRecording(recording: recording, engine: engine)
        live = liveRecording

        // Up before the stream is built, so the capture filter can exclude it.
        // Nothing to outline when there is no screen in the take.
        if let target {
            CaptureBorderController.shared.showRecording(target, guides: screenCropGuides)
        }
        await engine.start(target: target)

        if case .failed(let reason) = engine.state {
            // Nothing usable was captured, so the folder is a ghost — remove it
            // rather than leaving an empty entry the user has to tidy up.
            Log.recording.error("RecordingCenter: start failed: \(reason)")
            CaptureBorderController.shared.hideRecording()
            store.delete(liveRecording.recording)
            live = nil
            // The devices were opened before the failure, so the same
            // post-recording settling applies as on the clean path.
            lastRecordingEndedAt = Date()
            return
        }
        Log.recording.info("RecordingCenter: recording into \(recording.folderName)")
    }

    func pause() {
        live?.engine.pause()
    }

    func resume() {
        live?.engine.resume()
    }

    func stop() async {
        guard let liveRecording = live else { return }
        CaptureBorderController.shared.hideRecording()
        let result = await liveRecording.engine.stop()
        lastRecordingEndedAt = Date()

        var recording = liveRecording.recording
        recording.endedAt = Date()
        recording.durationSeconds = result.duration
        recording.hasCamera = result.hasCamera
        recording.hasMic = result.hasMic
        recording.hasSystemAudio = result.hasSystemAudio

        // Caught here rather than three steps later in the compositor. A take
        // with no picture is dead on arrival, and saying so at stop is the
        // difference between "that recording failed" and "nothing works".
        // Whichever stream *is* the picture has to have produced something.
        let hasPicture = recording.isCameraOnly ? result.hasCamera : result.hasScreenVideo
        guard hasPicture else {
            recording.stage = .failed
            recording.failureReason = recording.isCameraOnly
                ? "No camera video was captured. Check that no other app is holding the camera."
                : "No screen video was captured. macOS may have revoked Screen Recording — check Privacy & Security, then restart Udha."
            store.save(recording)
            live = nil
            Log.recording.error("RecordingCenter: \(recording.folderName) captured no picture")
            return
        }

        recording.stage = .needsProcessing
        store.save(recording)
        live = nil
        Log.recording.info("RecordingCenter: finished \(recording.folderName) — \(Int(result.duration))s")

        await process(recording)
    }

    // MARK: - Processing

    /// Transcribe, then render both masters.
    ///
    /// The order is not incidental: captions are burned into the frames, and
    /// you cannot burn text into frames that are already encoded. So a network
    /// call sits in the middle of an otherwise entirely local pipeline.
    ///
    /// Transcription failing is therefore explicitly *not* fatal — the masters
    /// still render, just without captions, and `retryProcessing` can redo them
    /// later from the same raw files. Losing the render because Scribe was down
    /// would be a much worse trade than shipping an uncaptioned video.
    func process(_ recording: Recording) async {
        guard !processingIDs.contains(recording.id) else { return }
        processingIDs.insert(recording.id)
        defer {
            processingIDs.remove(recording.id)
            renderProgress[recording.id] = nil
        }

        var current = recording
        let cfg = config.config.recordings
        let screenURL = store.screenURL(for: current)
        let cameraURL = store.cameraURL(for: current)

        // MARK: Captions
        var captions = store.loadCaptions(for: current)
        if captions == nil, cfg.burnCaptions, hasElevenLabsKey {
            current.stage = .transcribing
            current.failureReason = nil
            store.save(current)
            do {
                let track = try await transcriber.transcribe(
                    screenURL: screenURL,
                    cameraURL: cameraURL,
                    languageCode: cfg.captionLanguageCode.isEmpty ? nil : cfg.captionLanguageCode,
                    maxWords: cfg.captionMaxWords,
                    punctuation: cfg.captionPunctuation
                )
                store.writeCaptions(track, for: current)
                captions = track
            } catch {
                Log.recording.error("RecordingCenter: transcription failed for \(current.folderName): \(error.localizedDescription) — rendering without captions")
            }
        } else if captions == nil, cfg.burnCaptions {
            Log.recording.info("RecordingCenter: no ElevenLabs key — rendering \(current.folderName) without captions")
        }

        // MARK: Translation
        // The spoken track keeps the measured timings; what gets burned may be
        // another language. Cached per language beside the original, so a
        // re-render is a render and nothing else.
        var burn = captions
        current.captionLanguage = ""
        let language = cfg.captionTranslateTo
        if let captions, !captions.isEmpty, !language.isEmpty {
            if let cached = store.loadCaptions(for: current, language: language) {
                burn = cached
                current.captionLanguage = language
            } else {
                current.stage = .transcribing
                store.save(current)
                do {
                    let translated = try await translatedCaptions(captions, to: language)
                    store.writeCaptions(translated, for: current, language: language)
                    burn = translated
                    current.captionLanguage = language
                } catch {
                    Log.recording.error("RecordingCenter: caption translation to \(language) failed for \(current.folderName): \(error.localizedDescription) — burning the spoken captions")
                }
            }
        }

        // MARK: Masters
        current.stage = .composing
        store.save(current)

        var rendered: [RecordingOrientation] = []
        var lastFailure: String?
        var wanted: [RecordingOrientation] = []
        if cfg.renderLandscape { wanted.append(.landscape) }
        if cfg.renderPortrait { wanted.append(.portrait) }

        for (index, orientation) in wanted.enumerated() {
            let outputURL = store.masterURL(for: current, orientation: orientation)
            do {
                // Everything the progress closure reads is captured by value up
                // front. It escapes onto the compositor's actor, so closing over
                // the mutable `rendered` array to derive the same numbers would
                // be a cross-actor read of a value this loop is still mutating.
                let id = current.id
                let span = 1.0 / Double(max(1, wanted.count))
                let base = Double(index) * span
                try await compositor.render(
                    screenURL: screenURL,
                    cameraURL: cameraURL,
                    captions: burn,
                    orientation: orientation,
                    outputURL: outputURL,
                    config: cfg,
                    screenCrop: CGPoint(x: current.screenCropX, y: current.screenCropY),
                    screenCropScale: current.screenCropScale,
                    onProgress: { [weak self] fraction in
                        Task { @MainActor in
                            self?.renderProgress[id] = base + fraction * span
                        }
                    }
                )
                rendered.append(orientation)
            } catch {
                lastFailure = error.localizedDescription
                Log.recording.error("RecordingCenter: \(orientation.rawValue) render failed for \(current.folderName): \(error.localizedDescription)")
            }
        }

        current.renderedOrientations = rendered
        if rendered.isEmpty {
            current.stage = .failed
            current.failureReason = lastFailure ?? "Rendering produced no output."
        } else {
            current.stage = .ready
            current.failureReason = lastFailure
        }
        store.save(current)
        Log.recording.info("RecordingCenter: processed \(current.folderName) → \(rendered.map(\.rawValue).joined(separator: "+")) captions=\(burn?.cues.count ?? 0)\(current.captionLanguage.isEmpty ? "" : " in \(current.captionLanguage)")")
    }

    /// The spoken track in another language, from the box's own model.
    func translatedCaptions(_ track: CaptionTrack, to language: String) async throws -> CaptionTrack {
        let cfg = config.config
        var options = CaptionBuilder.Options()
        options.maxWords = cfg.recordings.captionMaxWords
        options.punctuation = cfg.recordings.captionPunctuation
        let translated = try await CaptionTranslator.translate(
            track, to: language, using: LocalTranslator(config: cfg.localModel), options: options
        )
        Log.recording.info("RecordingCenter: \(track.cues.count) cues → \(translated.cues.count) in \(language)")
        return translated
    }

    /// Translate (or re-translate) a finished recording's captions without
    /// rendering — what the Captions card's "Translate" button does, so the
    /// result can be read before a render is spent on it.
    func translateCaptions(_ recording: Recording, to language: String) async {
        guard !language.isEmpty, let track = store.loadCaptions(for: recording), !track.isEmpty else { return }
        guard !processingIDs.contains(recording.id) else { return }
        processingIDs.insert(recording.id)
        defer { processingIDs.remove(recording.id) }
        do {
            let translated = try await translatedCaptions(track, to: language)
            store.writeCaptions(translated, for: recording, language: language)
        } catch {
            Log.recording.error("RecordingCenter: caption translation to \(language) failed for \(recording.folderName): \(error.localizedDescription)")
        }
    }

    /// Re-runs the pipeline. Used by the "needs processing" row the crash sweep
    /// leaves behind, and after a failed render.
    ///
    /// A joined video has no raw files of its own, so for one of those this
    /// means joining its sources again rather than composing from nothing —
    /// without the fork, "Re-render" would quietly destroy a perfectly good
    /// joined master.
    func retryProcessing(_ recording: Recording) async {
        if recording.isJoined {
            await rejoin(recording)
        } else {
            await process(recording)
        }
    }

    // MARK: - Joining

    /// Concatenates finished recordings, in the order given, into one new one.
    ///
    /// The sources are read and never touched — which is what makes "Undo
    /// join" a delete rather than a restore, and what the sheet means by
    /// "originals are kept".
    @discardableResult
    func join(_ clips: [Recording], title: String) async -> Recording? {
        guard clips.count >= 2 else { return nil }

        var joined = store.create(folderSuffix: "joined")
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        joined.title = trimmed.isEmpty ? Self.defaultJoinTitle(for: clips) : trimmed
        joined.joinedFromIDs = clips.map(\.id)
        joined.joinedFromTitles = clips.map(\.title)
        // Whatever any source had, the join has somewhere in it.
        joined.hasCamera = clips.contains(where: \.hasCamera)
        joined.hasMic = clips.contains(where: \.hasMic)
        joined.hasSystemAudio = clips.contains(where: \.hasSystemAudio)
        // Replaced with the concatenated file's real length once it exists;
        // this is what the row shows in the meantime.
        joined.durationSeconds = clips.reduce(0) { $0 + $1.durationSeconds }
        joined.endedAt = Date()
        joined.stage = .composing
        store.save(joined)

        await runJoin(joined, clips: clips, regenerateCaptions: true)
        return store.recording(withID: joined.id)
    }

    /// Rebuilds a joined video from its sources.
    func rejoin(_ recording: Recording) async {
        let clips = recording.joinedFromIDs.compactMap { store.recording(withID: $0) }
        guard clips.count == recording.joinedFromIDs.count, clips.count >= 2 else {
            // Deliberately does not touch `stage`: the master that is already
            // on disk is still fine and still playable, and marking a working
            // video failed because it can no longer be *rebuilt* would be a
            // worse lie than saying nothing.
            var updated = recording
            updated.failureReason = "One of the videos this was joined from has been deleted, so it can't be rebuilt. The joined file itself is untouched."
            store.save(updated)
            Log.recording.error("RecordingCenter: cannot rejoin \(recording.folderName) — a source is missing")
            return
        }
        var updated = recording
        updated.stage = .composing
        updated.failureReason = nil
        store.save(updated)
        // Only fill the caption track in if there isn't one. Regenerating it
        // from the sources would silently throw away any line edited here since
        // the join — and unlike the picture, that track is not reproducible
        // from the sources once it has been touched.
        await runJoin(updated, clips: clips,
                      regenerateCaptions: store.loadCaptions(for: updated) == nil)
    }

    /// Removes a joined video. The sources were never modified, so undoing is a
    /// delete — there is nothing to put back.
    func undoJoin(_ recording: Recording) {
        guard recording.isJoined else { return }
        delete(recording)
    }

    static func defaultJoinTitle(for clips: [Recording]) -> String {
        guard let first = clips.first else { return "Joined video" }
        return "\(first.title) + \(clips.count - 1)"
    }

    /// Which masters can be produced for this set: only an orientation every
    /// source actually has on disk. Joining a wide-only take with a
    /// both-masters one gives a wide-only result rather than a vertical master
    /// with a hole in the middle of it.
    func joinableOrientations(for clips: [Recording]) -> [RecordingOrientation] {
        guard clips.count >= 2 else { return [] }
        return RecordingOrientation.allCases.filter { orientation in
            clips.allSatisfy { clip in
                clip.renderedOrientations.contains(orientation)
                    && FileManager.default.fileExists(
                        atPath: store.masterURL(for: clip, orientation: orientation).path)
            }
        }
    }

    private func runJoin(_ recording: Recording, clips: [Recording], regenerateCaptions: Bool) async {
        guard !processingIDs.contains(recording.id) else { return }
        processingIDs.insert(recording.id)
        defer {
            processingIDs.remove(recording.id)
            renderProgress[recording.id] = nil
        }

        var current = recording
        let orientations = joinableOrientations(for: clips)
        guard !orientations.isEmpty else {
            current.stage = .failed
            current.failureReason = clips.contains(where: { $0.renderedOrientations.isEmpty })
                ? "Every video has to be rendered before it can be joined."
                : "These videos have no master in common — one is wide-only and the other vertical-only."
            store.save(current)
            Log.recording.error("RecordingCenter: nothing to join for \(current.folderName)")
            return
        }

        let joiner = RecordingJoiner()
        let id = current.id
        let frameRate = config.config.recordings.frameRate
        var rendered: [RecordingOrientation] = []
        var lastFailure: String?

        for (index, orientation) in orientations.enumerated() {
            // Captured by value before the closure escapes onto the joiner, for
            // the same reason `process` does it: deriving these inside the
            // closure would read a variable this loop is still mutating.
            let span = 1.0 / Double(orientations.count)
            let base = Double(index) * span
            let sources = clips.map {
                RecordingJoiner.Clip(title: $0.title, url: store.masterURL(for: $0, orientation: orientation))
            }
            do {
                try await joiner.join(
                    clips: sources,
                    orientation: orientation,
                    outputURL: store.masterURL(for: current, orientation: orientation),
                    frameRate: frameRate,
                    onProgress: { [weak self] fraction in
                        Task { @MainActor in self?.renderProgress[id] = base + fraction * span }
                    }
                )
                rendered.append(orientation)
            } catch {
                lastFailure = error.localizedDescription
                Log.recording.error("RecordingCenter: \(orientation.rawValue) join failed for \(current.folderName): \(error.localizedDescription)")
            }
        }

        // Captions, and the honest duration, both come from the file that was
        // actually written rather than from the sources' stored metadata.
        if let orientation = rendered.first {
            let urls = clips.map { store.masterURL(for: $0, orientation: orientation) }
            let lengths = await RecordingJoiner.durations(of: urls)
            if regenerateCaptions {
                let merged = RecordingJoiner.mergeCaptions(
                    clips.map { store.loadCaptions(for: $0) },
                    offsets: RecordingJoiner.offsets(from: lengths)
                )
                if !merged.isEmpty { store.writeCaptions(merged, for: current) }
                // The sources' burned language carries over with their
                // translated tracks, when every clip has one.
                let language = clips.first?.captionLanguage ?? ""
                if !language.isEmpty, clips.allSatisfy({ $0.captionLanguage == language }) {
                    let tracks = clips.map { store.loadCaptions(for: $0, language: language) }
                    if tracks.allSatisfy({ $0 != nil }) {
                        let mergedTranslated = RecordingJoiner.mergeCaptions(tracks, offsets: RecordingJoiner.offsets(from: lengths))
                        if !mergedTranslated.isEmpty { store.writeCaptions(mergedTranslated, for: current, language: language) }
                        current.captionLanguage = language
                    }
                }
            }
            let total = lengths.reduce(0, +)
            if total > 0 { current.durationSeconds = total }
        }

        current.renderedOrientations = rendered
        if rendered.isEmpty {
            current.stage = .failed
            current.failureReason = lastFailure ?? "Joining produced no output."
        } else {
            current.stage = .ready
            current.failureReason = lastFailure
        }
        store.save(current)
        Log.recording.info("RecordingCenter: joined \(clips.count) into \(current.folderName) → \(rendered.map(\.rawValue).joined(separator: "+"))")
    }

    /// Synchronous quit path, called from `applicationWillTerminate`. The
    /// fragmented .mov files stay playable without a final moov atom, and the
    /// metadata is stamped so the next launch's crash sweep finds a recording
    /// that needs processing rather than a ghost stuck in `.capturing`.
    func emergencyStop() {
        guard let liveRecording = live else { return }
        CaptureBorderController.shared.hideRecording()
        let duration = liveRecording.engine.activeDuration
        liveRecording.engine.abort()
        lastRecordingEndedAt = Date()

        var recording = liveRecording.recording
        recording.endedAt = Date()
        recording.durationSeconds = duration
        recording.stage = .needsProcessing
        store.save(recording)
        live = nil
        Log.recording.info("RecordingCenter: emergency stop for \(recording.folderName)")
    }
}
