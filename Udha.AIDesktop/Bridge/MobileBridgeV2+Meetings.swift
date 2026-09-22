import Foundation

/// Meeting handlers for protocol v2. Mac-only: the headless agent (`UDHA_AGENT`)
/// has no meeting recorder, so these files are simply not part of its build and the
/// matching `case`s in `handleV2Payload` are fenced out.
extension MobileBridge {
    // MARK: - Meetings

    func sendMeetingsFull() {
        // Re-arm here too: a client can connect long after the Mac started
        // recording, and setting the hook is idempotent.
        mirrorLiveTranscript()
        guard let store = meetingStore else {
            relay.sendRelay(["type": "meetings_full", "meetings": [] as [Any]])
            return
        }
        relay.sendRelay([
            "type": "meetings_full",
            "meetings": store.meetings.map { meetingRow($0, detail: false) },
        ])
    }

    func sendMeetingDetail(_ idString: String?) {
        guard let idString, let uuid = UUID(uuidString: idString),
              let store = meetingStore,
              let meeting = store.meetings.first(where: { $0.id == uuid }) else { return }
        relay.sendRelay([
            "type": "meeting_detail",
            "meeting": meetingRow(meeting, detail: true),
        ])
    }

    private func meetingRow(_ meeting: Meeting, detail: Bool) -> [String: Any] {
        var row: [String: Any] = [
            "id": meeting.id.uuidString,
            "title": meeting.title,
            // Epoch seconds — a date-string format mismatch would silently
            // blank the entire list on the client.
            "createdAt": meeting.createdAt.timeIntervalSince1970,
            "mode": meeting.mode.rawValue,
            "origin": meeting.origin.rawValue,
            "hasAudio": meeting.hasAudio,
            "finalized": meeting.finalized,
        ]
        if let endedAt = meeting.endedAt { row["endedAt"] = endedAt.timeIntervalSince1970 }
        if let cal = meeting.calendarEvent {
            row["calendar"] = [
                "title": cal.title, "org": cal.org, "calendar": cal.calendarTitle,
                "organizer": cal.organizer ?? "", "attendees": cal.attendees,
            ] as [String: Any]
        }
        guard detail, let store = meetingStore else { return row }

        row["summary"] = meeting.summary
        row["userNotes"] = store.loadUserNotes(for: meeting)
        // The polished notes are the thing worth reading after a call — the
        // finalize pass has always produced them, but until now they never
        // left this machine and the phone showed only the two-line blurb.
        row["notesMarkdown"] = store.loadAINotes(for: meeting)
        row["actionItems"] = meeting.actionItems.map { item -> [String: Any] in
            var d: [String: Any] = ["id": item.id.uuidString, "text": item.text, "done": item.done]
            if let owner = item.owner { d["owner"] = owner }
            return d
        }
        // Decisions live inside the AI notes markdown; pull the bulleted lines
        // out of the Decisions section rather than inventing a second store.
        row["decisions"] = MeetingNotes.decisions(from: store.loadAINotes(for: meeting))
        row["transcript"] = store.loadTranscript(for: meeting).map { seg in
            [
                "id": seg.id.uuidString,
                "source": seg.source.rawValue,
                "speaker": seg.speaker,
                "text": seg.text,
                "startTime": seg.startTime,
                "endTime": seg.endTime,
            ] as [String: Any]
        }
        return row
    }

    func handleStartMeeting(_ payload: [String: Any]) {
        guard let center = meetingCenter else { return }
        let mode = MeetingMode(rawValue: (payload["mode"] as? String) ?? "") ?? .standard
        logRemote("start_meeting", id: nil, detail: mode.rawValue)
        Task { @MainActor in
            await center.start(mode: mode)
            self.mirrorLiveTranscript()
            self.sendMeetingsFull()
        }
    }

    /// Streams this Mac's live transcript to the phone as it is recognised.
    ///
    /// The client has always decoded `meeting_live`; nothing ever sent it, so
    /// watching a Mac recording from the phone showed an empty pane with a
    /// running clock.
    @MainActor
    func mirrorLiveTranscript() {
        guard let center = meetingCenter, let live = center.live else { return }
        let id = live.meeting.id.uuidString
        // Weakly: the closure is stored on the transcript, which the recorder
        // owns, which the LiveMeeting owns — capturing `live` strongly would
        // make the live meeting immortal.
        live.recorder.transcript.onAppendRemote = { [weak self, weak live] segments in
            guard let self, let live else { return }
            self.relay.sendRelay([
                "type": "meeting_live",
                "id": id,
                "elapsedSec": Int(live.recorder.activeDuration),
                "segments": segments.map { seg in
                    [
                        "id": seg.id.uuidString,
                        "source": seg.source.rawValue,
                        "speaker": seg.speaker,
                        "text": seg.text,
                        "startTime": seg.startTime,
                        "endTime": seg.endTime,
                    ] as [String: Any]
                },
            ])
        }
    }

    /// A question about the call in progress on this Mac, answered by the same
    /// pipeline the desktop pane uses.
    ///
    /// Only the live meeting: a phone asking about its *own* recording answers
    /// on-device, and a finished host meeting has no ask pipeline yet. Both
    /// used to fall through to `default` and get no reply at all, which left
    /// the phone showing "thinking" indefinitely.
    func handleMeetingAsk(_ payload: [String: Any]) {
        let requestedID = (payload["id"] as? String) ?? ""
        guard let question = payload["question"] as? String,
              !question.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let center = meetingCenter, let live = center.live else {
            relay.sendRelay([
                "type": "meeting_ask_reply",
                "id": requestedID,
                "text": "No meeting is being recorded on this Mac right now.",
            ])
            return
        }
        let id = live.meeting.id.uuidString
        live.ask.onAnswerLanded = { [weak self] turn in
            self?.relay.sendRelay([
                "type": "meeting_ask_reply",
                "id": id,
                "text": turn.cite.isEmpty ? turn.text : "\(turn.text)\n\n— \(turn.cite)",
            ])
        }
        logRemote("meeting_ask", id: nil, detail: question)
        live.ask.ask(question)
    }

    func handleStopMeeting() {
        guard let center = meetingCenter else { return }
        let id = center.live?.meeting.id
        logRemote("stop_meeting", id: nil)
        Task { @MainActor in
            await center.stop()
            self.relay.sendRelay(["type": "meeting_stopped", "id": id?.uuidString ?? ""])
            self.sendMeetingsFull()
        }
    }

    func handleActionItemDone(_ payload: [String: Any]) {
        guard let store = meetingStore,
              let meetingID = (payload["id"] as? String).flatMap(UUID.init(uuidString:)),
              let itemID = (payload["itemId"] as? String).flatMap(UUID.init(uuidString:)),
              var meeting = store.meetings.first(where: { $0.id == meetingID }),
              let index = meeting.actionItems.firstIndex(where: { $0.id == itemID })
        else { return }
        meeting.actionItems[index].done = (payload["done"] as? Bool) ?? false
        store.save(meeting)
    }

    /// Notes typed on a client. Written to the meeting's own user-notes file,
    /// which is deliberately separate from the AI notes — re-running the
    /// summary pass must never overwrite something a human wrote.
    func handleUpdateMeetingNotes(_ payload: [String: Any]) {
        guard let store = meetingStore,
              let id = (payload["id"] as? String).flatMap(UUID.init(uuidString:)),
              let notes = payload["notes"] as? String,
              let meeting = store.meetings.first(where: { $0.id == id }) else { return }
        // Route through the live meeting when it's the one being recorded: its
        // `roughNotes` buffer is what `MeetingCenter.stop()` writes on the way
        // out, so a file-only write here would be overwritten by the desktop's
        // (possibly empty) copy the moment the call ended.
        if let live = meetingCenter?.live, live.meeting.id == meeting.id {
            live.roughNotes = notes
        } else {
            store.writeUserNotes(notes, for: meeting)
        }
        logRemote("update_meeting_notes", id: nil, detail: meeting.title)
        // Echo the stored value so every other paired client converges.
        sendMeetingDetail(id.uuidString)
    }

    /// A meeting recorded on the phone. iOS cannot capture system audio, so it
    /// arrives mic-only and already transcribed on-device; the host's job is
    /// the notes pass, which is the part worth centralising.
    func handlePushLocalMeeting(_ payload: [String: Any]) {
        guard let store = meetingStore, let center = meetingCenter else {
            pushAck(id: nil, ok: false, error: "meetings are not available on this Mac")
            return
        }
        let upload: LocalMeetingUpload
        switch LocalMeetingUpload.parse(payload) {
        case .success(let parsed):
            upload = parsed
        case .failure(let why):
            pushAck(id: nil, ok: false, error: why.message)
            return
        }
        let id = upload.id
        let mode = MeetingMode(rawValue: upload.mode) ?? .standard

        // Idempotent by id: uploads retry, and a retry must update the meeting
        // rather than make another one.
        var meeting: Meeting
        if let existing = store.meetings.first(where: { $0.id == id }) {
            meeting = existing
        } else {
            meeting = store.create(mode: mode)
            meeting.id = id
        }
        meeting.title = upload.title
        meeting.mode = mode
        meeting.origin = .local
        if let created = upload.createdAt { meeting.createdAt = created }
        if let ended = upload.endedAt { meeting.endedAt = ended }
        meeting.hasAudio = upload.hasAudio
        if !upload.actionItems.isEmpty {
            meeting.actionItems = upload.actionItems.map {
                ActionItem(id: $0.id, text: $0.text, owner: $0.owner, done: $0.done)
            }
        }
        meeting.finalized = false
        store.save(meeting)

        // The rough notes typed on the phone, written *before* the finalize
        // pass runs — that pass uses them as the backbone of the polished
        // notes, so arriving after it would defeat the whole point.
        if let userNotes = upload.userNotes {
            store.writeUserNotes(userNotes, for: meeting)
        }

        // Persist the phone's transcript into the meeting folder so the notes
        // pass reads it exactly as it reads a locally recorded one.
        if !upload.transcript.isEmpty {
            let writer = TranscriptJSONLWriter(meetingFolder: store.folderURL(for: meeting))
            writer.append(upload.transcript.map { seg in
                TranscriptSegment(
                    source: TranscriptSource(rawValue: seg.source) ?? .mic,
                    speaker: seg.speaker,
                    text: seg.text,
                    startTime: seg.start,
                    endTime: seg.end
                )
            })
            writer.flushSync()
        }

        logRemote("push_local_meeting", id: nil, detail: upload.title)
        // Ack before the notes pass, not after: the phone needs to stop
        // retrying as soon as the meeting is safely on disk here, and the
        // summary can take a while.
        pushAck(id: id, ok: true, error: nil)
        sendMeetingsFull()

        let stored = meeting
        Task { @MainActor in
            await center.finalize(stored)
            self.sendMeetingsFull()
            self.sendMeetingDetail(stored.id.uuidString)
        }
    }

    /// Confirms receipt of a pushed meeting. Without this the phone has no way
    /// to tell "sent" from "arrived", so its outbox would either re-send on
    /// every reconnect or forget the meeting before the Mac had it.
    private func pushAck(id: UUID?, ok: Bool, error: String?) {
        var payload: [String: Any] = ["type": "push_local_meeting_ack", "ok": ok]
        if let id { payload["id"] = id.uuidString }
        if let error { payload["error"] = error }
        relay.sendRelay(payload)
    }
}
