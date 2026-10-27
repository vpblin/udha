import Foundation
import Observation

/// Per-recording-folder persistence under ~/Library/Application Support/Udha.AI/Recordings/.
///
/// Folder layout (folder name is human-browsable; the UUID in recording.json is
/// the authoritative identity — renaming a recording edits the title only):
///   yyyyMMdd-HHmmss-recording/
///     recording.json      (store-owned metadata)
///     raw/screen.mov      (engine-owned: screen video + system audio)
///     raw/camera.mov      (engine-owned: camera video + mic audio)
///     captions.json       (editable source of truth, word-level timings)
///     captions.vtt        (derived; what Cloudflare Stream is handed)
///     out/landscape.mp4   (compositor-owned, captions burned in)
///     out/portrait.mp4
///
/// Follows MeetingStore rather than AgentStore: mutations update the in-memory
/// array in place and write only the touched files instead of write-then-rescan.
/// Errors are logged, never thrown (house rule); writes are atomic.
@MainActor
@Observable
final class RecordingStore {
    /// Sorted newest-first.
    private(set) var recordings: [Recording] = []

    private var pendingWrites: [String: Task<Void, Never>] = [:]

    var recordingsDirectory: URL { directoryURL }

    private var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Udha.AI", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    private static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Load

    func load() {
        ensureDirectory()
        reload()
        sweepCrashedRecordings()
    }

    func reload() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil))?
            .filter(\.hasDirectoryPath) ?? []
        var loaded: [Recording] = []
        for folder in folders {
            let metaURL = folder.appendingPathComponent("recording.json")
            guard let data = try? Data(contentsOf: metaURL) else { continue }
            do {
                var recording = try Self.jsonDecoder.decode(Recording.self, from: data)
                recording.folderName = folder.lastPathComponent
                loaded.append(recording)
            } catch {
                Log.recording.error("RecordingStore: skipping undecodable \(folder.lastPathComponent): \(error.localizedDescription)")
            }
        }
        recordings = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    /// A recording still marked `.capturing` at launch died with the app.
    ///
    /// The raw files are usually still playable despite never being finalized,
    /// because the engine sets `movieFragmentInterval` — without that an
    /// unfinalized .mov has no moov atom and is simply garbage. Recoverable
    /// ones drop to `.needsProcessing` so the UI can offer "finish processing";
    /// ones with nothing on disk are marked failed rather than left as ghosts.
    private func sweepCrashedRecordings() {
        for var recording in recordings where recording.stage == .capturing {
            let screen = screenURL(for: recording)
            let attrs = try? FileManager.default.attributesOfItem(atPath: screen.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            let mtime = attrs?[.modificationDate] as? Date

            recording.endedAt = mtime ?? recording.createdAt
            if size > 0 {
                recording.stage = .needsProcessing
                if recording.durationSeconds == 0, let mtime {
                    recording.durationSeconds = max(0, mtime.timeIntervalSince(recording.createdAt))
                }
                Log.recording.info("RecordingStore: recovered crashed recording \(recording.folderName) — needs processing")
            } else {
                recording.stage = .failed
                recording.failureReason = "Recording stopped unexpectedly before any video was written."
                Log.recording.error("RecordingStore: crashed recording \(recording.folderName) has no usable video")
            }
            save(recording)
        }
        // Anything caught mid-render is restartable from the raw files, which
        // are still intact — a half-written master is overwritten, not resumed.
        for var recording in recordings where recording.stage == .transcribing || recording.stage == .composing {
            recording.stage = .needsProcessing
            save(recording)
            Log.recording.info("RecordingStore: re-queued \(recording.folderName) after interrupted processing")
        }
    }

    // MARK: - Create / save / delete

    static func defaultTitle(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return "Recording \(f.string(from: date))"
    }

    /// `folderSuffix` only names the folder — a joined video lands in
    /// `…-joined/` so the library is legible in Finder. Identity is still the
    /// UUID inside recording.json.
    @discardableResult
    func create(folderSuffix: String = "recording") -> Recording {
        ensureDirectory()
        let now = Date()
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let folderName = "\(stamp.string(from: now))-\(folderSuffix)"
        let recording = Recording(
            title: Self.defaultTitle(for: now),
            createdAt: now,
            folderName: folderName
        )
        let folder = directoryURL.appendingPathComponent(folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent("raw", isDirectory: true),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent("out", isDirectory: true),
                withIntermediateDirectories: true
            )
        } catch {
            Log.recording.error("RecordingStore: cannot create \(folderName): \(error.localizedDescription)")
        }
        recordings.insert(recording, at: 0)
        save(recording)
        return recording
    }

    func save(_ recording: Recording) {
        if let idx = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[idx] = recording
        } else {
            recordings.insert(recording, at: 0)
            recordings.sort { $0.createdAt > $1.createdAt }
        }
        let url = folderURL(for: recording).appendingPathComponent("recording.json")
        do {
            let data = try Self.jsonEncoder.encode(recording)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.recording.error("RecordingStore: save failed for \(recording.folderName): \(error.localizedDescription)")
        }
    }

    func saveDebounced(_ recording: Recording) {
        if let idx = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[idx] = recording
        }
        debounced(key: "meta-\(recording.id)") { [weak self] in
            self?.save(recording)
        }
    }

    func delete(_ recording: Recording) {
        try? FileManager.default.removeItem(at: folderURL(for: recording))
        recordings.removeAll { $0.id == recording.id }
    }

    func recording(withID id: UUID) -> Recording? {
        recordings.first { $0.id == id }
    }

    /// True when some joined video was built from this one.
    ///
    /// Derived rather than stored on the source: undoing a join is a delete,
    /// and a flag written into the source would outlive the join that set it.
    func isJoinSource(_ recording: Recording) -> Bool {
        recordings.contains { $0.joinedFromIDs.contains(recording.id) }
    }

    // MARK: - Paths

    func folderURL(for recording: Recording) -> URL {
        directoryURL.appendingPathComponent(recording.folderName, isDirectory: true)
    }

    func screenURL(for recording: Recording) -> URL {
        folderURL(for: recording).appendingPathComponent("raw/screen.mov")
    }

    func cameraURL(for recording: Recording) -> URL {
        folderURL(for: recording).appendingPathComponent("raw/camera.mov")
    }

    func masterURL(for recording: Recording, orientation: RecordingOrientation) -> URL {
        folderURL(for: recording).appendingPathComponent("out/\(orientation.fileName)")
    }

    /// `language` is a name from `LocalTranslator.languages`; nil (or "") is
    /// the spoken track, `captions.json`. A translated track sits beside it
    /// as `captions.<code>.json` + `.vtt`.
    func captionsJSONURL(for recording: Recording, language: String? = nil) -> URL {
        folderURL(for: recording).appendingPathComponent("captions\(Self.suffix(language)).json")
    }

    func captionsVTTURL(for recording: Recording, language: String? = nil) -> URL {
        folderURL(for: recording).appendingPathComponent("captions\(Self.suffix(language)).vtt")
    }

    private static func suffix(_ language: String?) -> String {
        guard let language, !language.isEmpty else { return "" }
        return "." + LocalTranslator.code(for: language)
    }

    // MARK: - Sidecar files

    /// Writing the spoken track drops every translated one: they were
    /// derived from what this replaces, and the next render re-translates.
    func writeCaptions(_ track: CaptionTrack, for recording: Recording, language: String? = nil) {
        do {
            let data = try Self.jsonEncoder.encode(track)
            try data.write(to: captionsJSONURL(for: recording, language: language), options: .atomic)
            let vtt = CaptionTrackVTT.serialize(track)
            try vtt.write(to: captionsVTTURL(for: recording, language: language), atomically: true, encoding: .utf8)
        } catch {
            Log.recording.error("RecordingStore: captions write failed for \(recording.folderName): \(error.localizedDescription)")
        }
        if language == nil || language?.isEmpty == true { removeTranslatedCaptions(for: recording) }
    }

    func loadCaptions(for recording: Recording, language: String? = nil) -> CaptionTrack? {
        guard let data = try? Data(contentsOf: captionsJSONURL(for: recording, language: language)) else { return nil }
        return try? Self.jsonDecoder.decode(CaptionTrack.self, from: data)
    }

    func removeTranslatedCaptions(for recording: Recording) {
        let folder = folderURL(for: recording)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix("captions.") && name != "captions.json" && name != "captions.vtt" {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    // MARK: - Helpers

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func debounced(key: String, _ work: @escaping @MainActor () -> Void) {
        pendingWrites[key]?.cancel()
        pendingWrites[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            work()
            self?.pendingWrites[key] = nil
        }
    }

    /// Drop debounced writes on the quit path. Anything that matters is saved
    /// directly by the recorder's abort() rather than relying on this.
    func flushPendingWrites() {
        for task in pendingWrites.values { task.cancel() }
        pendingWrites = [:]
    }
}
