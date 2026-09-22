import Foundation
#if canImport(EventKit)
import EventKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Names recordings after the Apple Calendar event they overlap.
///
/// Why Calendar.app and not a calendar API: this Mac's Calendar already syncs
/// every account the user has (several Google Workspace orgs, iCloud,
/// Hotmail), so one local EventKit read covers all of them with no sign-in of
/// its own and no per-org token to keep apart. The calendar an event lives in
/// is named after the account address, which is what tells the orgs apart.
///
/// The reading is done here and reduced to a plain `CalendarEventRef`
/// (Foundation-only, shared with the Linux agent) before it touches a
/// `Meeting`. Access is asked for at the first recording, or from Settings —
/// never at launch; `check()` only reads the current grant.
@MainActor
@Observable
final class MeetingCalendar {
    enum Status: Equatable { case unknown, notDetermined, ok, denied }

    private(set) var status: Status = .unknown

    #if canImport(EventKit)
    /// One store for the app's lifetime — creating them is expensive and each
    /// re-reads the calendar database.
    nonisolated private let store = EKEventStore()
    #endif

    // MARK: - Access

    func check() {
        #if canImport(EventKit)
        apply(EKEventStore.authorizationStatus(for: .event))
        #else
        status = .denied
        #endif
    }

    /// Shows the system prompt if it has never been answered. Returns whether
    /// events can be read afterwards.
    @discardableResult
    func requestAccess() async -> Bool {
        #if canImport(EventKit)
        do {
            let granted = try await store.requestFullAccessToEvents()
            apply(EKEventStore.authorizationStatus(for: .event))
            if !granted { Log.meeting.info("MeetingCalendar: calendar access declined") }
            return granted
        } catch {
            Log.meeting.error("MeetingCalendar: access request failed: \(error.localizedDescription)")
            check()
            return status == .ok
        }
        #else
        return false
        #endif
    }

    func openCalendarSettings() {
        #if canImport(AppKit)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    #if canImport(EventKit)
    private func apply(_ s: EKAuthorizationStatus) {
        switch s {
        case .fullAccess: status = .ok
        case .notDetermined: status = .notDetermined
        case .denied, .restricted, .writeOnly: status = .denied
        @unknown default: status = .unknown
        }
    }
    #endif

    // MARK: - Matching

    /// The event a recording most plausibly is. `recordingEnd` is nil while
    /// the meeting is still running, in which case a typical 45-minute call is
    /// assumed. Runs off the main actor — the query walks every calendar.
    nonisolated func match(recordingStart: Date, recordingEnd: Date?) async -> CalendarEventRef? {
        #if canImport(EventKit)
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let end = recordingEnd ?? recordingStart.addingTimeInterval(45 * 60)
        let events = fetch(from: recordingStart.addingTimeInterval(-3 * 3600), to: end.addingTimeInterval(3 * 3600))
        return Self.best(among: events, recordingStart: recordingStart, recordingEnd: end)
        #else
        return nil
        #endif
    }

    /// One wide read for the launch backfill, so fifty meetings cost one
    /// query, not fifty.
    nonisolated func matches(for meetings: [Meeting]) async -> [UUID: CalendarEventRef] {
        #if canImport(EventKit)
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess,
              let first = meetings.map(\.createdAt).min(),
              let last = meetings.map { $0.endedAt ?? $0.createdAt }.max() else { return [:] }
        let events = fetch(from: first.addingTimeInterval(-3 * 3600), to: last.addingTimeInterval(3 * 3600))
        var out: [UUID: CalendarEventRef] = [:]
        for m in meetings {
            let end = m.endedAt ?? m.createdAt.addingTimeInterval(45 * 60)
            if let ref = Self.best(among: events, recordingStart: m.createdAt, recordingEnd: end) {
                out[m.id] = ref
            }
        }
        return out
        #else
        return [:]
        #endif
    }

    #if canImport(EventKit)
    nonisolated private func fetch(from: Date, to: Date) -> [EKEvent] {
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate)
    }

    /// Scores every candidate against the recording window and keeps the
    /// best. The window is padded so a recording started a few minutes early,
    /// or a call joined late, still lines up.
    ///
    /// Ties are common — two standing calls at 11:00 in two calendars — and
    /// are broken by what the user did with the invite: accepted beats
    /// unanswered, a required seat beats an optional one, and a meeting with
    /// a call link beats a reminder-shaped event with none.
    nonisolated private static func best(among events: [EKEvent], recordingStart: Date, recordingEnd: Date) -> CalendarEventRef? {
        let windowStart = recordingStart.addingTimeInterval(-15 * 60)
        let windowEnd = recordingEnd.addingTimeInterval(5 * 60)
        var bestScore = -Double.infinity
        var best: EKEvent?
        for e in events {
            guard !e.isAllDay, e.status != .canceled,
                  let s = e.startDate, let f = e.endDate,
                  s < windowEnd, f > windowStart else { continue }
            if isNoise(e.calendar) { continue }
            let me = e.attendees?.first { $0.isCurrentUser }
            if me?.participantStatus == .declined { continue }
            // Nobody invited and no call link is a reminder or a focus block,
            // not a meeting; naming a recording after it is worse than the
            // placeholder ("Timesheets reminder" was a real one).
            let attendees = e.attendees ?? []
            let link = conferenceURL(of: e)
            if attendees.isEmpty && link == nil { continue }

            let overlap = min(f, recordingEnd).timeIntervalSince(max(s, recordingStart))
            var score = max(overlap, 0)
            score -= abs(s.timeIntervalSince(recordingStart)) / 4
            if !attendees.isEmpty { score += 900 }
            if link != nil { score += 600 }
            switch me?.participantStatus {
            case .accepted: score += 500
            case .tentative: score += 100
            default: break
            }
            if me?.participantRole == .optional { score -= 300 }
            if e.organizer?.isCurrentUser == true { score += 200 }
            if score > bestScore { bestScore = score; best = e }
        }
        return best.map(ref(for:))
    }

    nonisolated private static func isNoise(_ cal: EKCalendar) -> Bool {
        if cal.type == .birthday { return true }
        let t = cal.title.lowercased()
        return t.contains("holiday") || t.contains("birthday") || t == "siri suggestions" || t == "scheduled reminders"
    }

    nonisolated private static func ref(for e: EKEvent) -> CalendarEventRef {
        let others = (e.attendees ?? []).filter { !$0.isCurrentUser }.map(displayName)
        return CalendarEventRef(
            eventIdentifier: e.eventIdentifier ?? "",
            title: e.title.trimmingCharacters(in: .whitespacesAndNewlines),
            calendarTitle: e.calendar.title,
            account: e.calendar.source?.title ?? "",
            organizer: e.organizer.map(displayName),
            attendees: others,
            start: e.startDate,
            end: e.endDate,
            conferenceURL: conferenceURL(of: e),
            location: e.location?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    nonisolated private static func displayName(_ p: EKParticipant) -> String {
        if let n = p.name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty, !n.contains("@") { return n }
        let raw = p.url.absoluteString
        return raw.hasPrefix("mailto:") ? String(raw.dropFirst(7)) : raw
    }

    nonisolated private static let conferenceHosts = [
        "meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com",
        "whereby.com", "webex.com", "around.co", "meet.jit.si",
    ]

    /// The event's URL when it is a call link, else the first call link in
    /// the location or notes (Google puts Meet in `url`; Zoom invites bury it
    /// in the description).
    nonisolated private static func conferenceURL(of e: EKEvent) -> String? {
        if let u = e.url?.absoluteString, conferenceHosts.contains(where: { u.contains($0) }) { return u }
        for text in [e.location, e.notes].compactMap({ $0 }) {
            guard let range = text.range(of: #"https?://[^\s<>"']+"#, options: .regularExpression) else { continue }
            var rest = text[...]
            var r: Range<String.Index>? = range
            while let found = r {
                let u = String(text[found])
                if conferenceHosts.contains(where: { u.contains($0) }) { return u }
                rest = text[found.upperBound...]
                r = rest.range(of: #"https?://[^\s<>"']+"#, options: .regularExpression)
            }
        }
        return nil
    }
    #endif
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
