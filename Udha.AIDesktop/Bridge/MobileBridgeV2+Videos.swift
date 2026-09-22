import Foundation

/// Video-library handlers for protocol v2. Mac-only: the headless agent (`UDHA_AGENT`)
/// has no recording library, so these files are simply not part of its build and the
/// matching `case`s in `handleV2Payload` are fenced out.
extension MobileBridge {
    // MARK: - Videos

    /// The recording library, as rows the phone can list.
    ///
    /// Metadata only, deliberately: a master is gigabytes and the relay carries
    /// JSON, so what travels is what the video *is* — plus the public link for
    /// anything already published, which is the one way a phone can actually
    /// watch it.
    func sendVideosFull() {
        guard let center = recordingCenter else {
            relay.sendRelay(["type": "videos_full", "videos": [] as [Any]])
            return
        }
        relay.sendRelay([
            "type": "videos_full",
            "videos": center.store.recordings.map { videoRow($0, center: center) },
        ])
    }

    private func videoRow(_ recording: Recording, center: RecordingCenter) -> [String: Any] {
        var row: [String: Any] = [
            "id": recording.id.uuidString,
            "title": recording.title,
            // Epoch seconds, as everywhere else on this wire.
            "createdAt": recording.createdAt.timeIntervalSince1970,
            "durationSec": recording.durationSeconds,
            "stage": recording.stage.rawValue,
            "hasCamera": recording.hasCamera,
            "hasMic": recording.hasMic,
            "hasSystemAudio": recording.hasSystemAudio,
            "orientations": recording.renderedOrientations.map(\.rawValue),
            "isPasswordProtected": recording.isPasswordProtected,
            // One flag rather than making the client re-derive "don't touch
            // this yet" from a stage plus a set it cannot see.
            "busy": recording.stage == .capturing || center.processingIDs.contains(recording.id),
        ]
        if let reason = recording.failureReason { row["failureReason"] = reason }
        if let published = recording.publishedAt {
            row["publishedAt"] = published.timeIntervalSince1970
        }
        if recording.isPublished, let url = center.shareURL(for: recording) {
            row["shareURL"] = url.absoluteString
        }
        return row
    }

    /// Retitle from the phone. Saved through the store, exactly as the Videos
    /// pane does it, and pushed on to the share service when the video is
    /// published — otherwise the public page would keep the old name and the
    /// rename would only be half true.
    func handleRenameVideo(_ payload: [String: Any], id: UUID?) {
        let title = ((payload["title"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let center = recordingCenter else {
            ack("rename_video", id: id, ok: false, error: "no video library")
            return
        }
        guard let id, var recording = center.store.recording(withID: id) else {
            ack("rename_video", id: id, ok: false, error: "unknown video")
            return
        }
        guard !title.isEmpty else {
            ack("rename_video", id: id, ok: false, error: "empty title")
            return
        }
        recording.title = title
        center.store.save(recording)
        if recording.isPublished {
            Task { @MainActor in await center.syncTitle(recording) }
        }
        logRemote("rename_video", id: id, detail: title)
        ack("rename_video", id: id, ok: true)
        sendVideosFull()
    }

    /// Delete from the phone. Refused while the video is being captured or
    /// rendered: those hold file handles, and the honest answer is "not yet"
    /// rather than a half-deleted folder.
    func handleDeleteVideo(_ payload: [String: Any], id: UUID?) {
        guard let center = recordingCenter else {
            ack("delete_video", id: id, ok: false, error: "no video library")
            return
        }
        guard let id, let recording = center.store.recording(withID: id) else {
            ack("delete_video", id: id, ok: false, error: "unknown video")
            return
        }
        guard recording.stage != .capturing, !center.processingIDs.contains(id) else {
            ack("delete_video", id: id, ok: false, error: "still recording or rendering")
            return
        }
        center.delete(recording)
        logRemote("delete_video", id: id, detail: recording.title)
        ack("delete_video", id: id, ok: true)
        sendVideosFull()
    }
}
