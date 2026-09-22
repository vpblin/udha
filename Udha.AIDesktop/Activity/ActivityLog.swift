import Foundation
import Observation
#if canImport(os)
import os
#endif

enum ActivityEvent: Identifiable, Hashable {
    case sendInput(sessionID: UUID, text: String)
    case approvePrompt(sessionID: UUID, promptText: String)
    case rejectPrompt(sessionID: UUID, promptText: String, reason: String?)
    case mute(scope: String, durationSec: Int)
    case setPriority(sessionID: UUID, level: SessionPriority)
    case scheduleAction(sessionID: UUID, action: String, fireAt: Date, scheduleID: UUID)
    case cancelScheduled(scheduleID: UUID)
    case stateTransition(sessionID: UUID, from: SessionState, to: SessionState)
    /// A session moved to another Claude login (usage limit, or on request).
    case accountRotated(sessionID: UUID, from: String, to: String, reason: String)
    case toolCall(name: String, arguments: String)
    case voiceSpoken(text: String, channel: String)
    case error(description: String)
    case meetingStarted(meetingID: UUID, mode: String)
    case meetingEnded(meetingID: UUID, durationSec: Int)
    case meetingNotesGenerated(meetingID: UUID)
    case meetingLLMError(description: String)
    case meetingSplit(meetingID: UUID, newMeetingID: UUID, atSec: Int)
    /// Several recordings of one call folded into `meetingID`.
    case meetingJoined(meetingID: UUID, absorbed: Int)
    /// An action driven from somewhere other than this Mac — today that means
    /// the phone or iPad over the bridge. Carries its own source rather than
    /// threading a `source` parameter through all sixteen existing cases.
    case remoteAction(sessionID: UUID?, verb: String, detail: String?, source: String)

    var id: UUID {
        switch self {
        case .scheduleAction(_, _, _, let id): return id
        case .cancelScheduled(let id): return id
        default: return UUID()
        }
    }
}

struct ActivityRecord: Identifiable, Hashable {
    let id: UUID = UUID()
    let timestamp: Date = Date()
    let event: ActivityEvent
}

@MainActor
@Observable
final class ActivityLog {
    private(set) var records: [ActivityRecord] = []
    private let maxRecords: Int = 2000

    func record(_ event: ActivityEvent) {
        records.append(ActivityRecord(event: event))
        if records.count > maxRecords {
            records.removeFirst(records.count - maxRecords)
        }
        Log.app.debug("activity: \(String(describing: event))")
    }

    func recent(_ n: Int) -> [ActivityRecord] {
        Array(records.suffix(n))
    }
}
