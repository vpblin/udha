import Foundation

/// A meeting as the tracker sees it: a span, words to match, and the
/// calendar account it came from.
struct TimeMeeting: Sendable {
    var start: Date
    var end: Date
    var title: String
    var summary: String
    var calendarAccount: String
}

/// One active minute on the Mac, and the app in front during it.
struct ActivityMinute: Sendable, Hashable {
    var at: Date
    var app: String
}

/// What a week adds up to. Minutes everywhere; the view formats.
struct TimeWeek: Sendable {
    struct Day: Sendable, Identifiable {
        var id: Date { date }
        var date: Date
        var minutes: Int
        var byClient: [String: Int]
        var first: Date?
        var last: Date?
    }
    struct Client: Sendable, Identifiable {
        var id: String { name }
        var name: String
        var org: String
        var minutes: Int
        var meetingMinutes: Int
        var prompts: Int
    }
    var start: Date
    var days: [Day]
    var clients: [Client]
    var minutes: Int
    var meetingMinutes: Int
    var prompts: Int
    var byOrg: [String: Int]

    static let unassigned = "Unassigned"
}

/// Turns prompts, meetings and Mac activity into minutes per client.
///
/// Minute by minute: a meeting owns its minutes; otherwise a minute is work
/// if it falls inside a stretch of prompts (no gap longer than `gapMinutes`,
/// plus `promptTailMinutes` after the last one) or the Mac was in use, and it
/// goes to the client of the nearest prompt in that stretch. A Mac minute with
/// no prompt or meeting near it goes to a client whose app rule matches, else
/// to Unassigned — it is never guessed.
enum TimeRollup {
    static func week(starting start: Date, prompts rawPrompts: [PromptEvent], meetings: [TimeMeeting],
                     activity: [ActivityMinute], config: TimeTrackingConfig,
                     calendar: Calendar = .current) -> TimeWeek {
        let end = calendar.date(byAdding: .day, value: 7, to: start)!
        let gap = config.gapMinutes * 60
        let tail = config.promptTailMinutes * 60

        // Resumed/forked transcripts and handed-off sessions repeat history;
        // the same second + the same opening words is one prompt.
        let windowStart = start.addingTimeInterval(-gap)
        var inWindow: [PromptEvent] = rawPrompts.filter { (p: PromptEvent) -> Bool in p.at >= windowStart && p.at < end }
        inWindow.sort { (a: PromptEvent, b: PromptEvent) -> Bool in a.at < b.at }
        var seen = Set<String>()
        var prompts: [PromptEvent] = []
        for p in inWindow where seen.insert("\(Int(p.at.timeIntervalSince1970))|\(p.key)").inserted {
            prompts.append(p)
        }
        // A long prompt sent at five or more different times is a loop.
        var keyCounts: [UInt32: Int] = [:]
        for p in prompts where p.key != 0 { keyCounts[p.key, default: 0] += 1 }
        prompts.removeAll { (p: PromptEvent) -> Bool in p.key != 0 && (keyCounts[p.key] ?? 0) >= 5 }

        let promptClients = prompts.map { client(forPrompt: $0, config.clients) }
        let meetingSpans = meetings
            .filter { $0.end > start && $0.start < end && $0.end.timeIntervalSince($0.start) >= 180 }
            .map { ($0, client(forMeeting: $0, config.clients)) }
        var activeMinutes: [Int: String] = [:]
        for m in activity { activeMinutes[Int(m.at.timeIntervalSince1970 / 60)] = m.app }

        var perDay: [Date: (Int, [String: Int], Date?, Date?)] = [:]
        var perClient: [String: (Int, Int)] = [:]     // minutes, meeting minutes
        var total = 0, meetingTotal = 0
        var pi = 0
        var t = start
        while t < end {
            let minuteIndex = Int(t.timeIntervalSince1970 / 60)
            while pi < prompts.count, prompts[pi].at <= t { pi += 1 }
            let previous = pi > 0 ? pi - 1 : nil
            let next = pi < prompts.count ? pi : nil

            var who: String?
            var inMeeting = false
            if let m = meetingSpans.first(where: { $0.0.start <= t && t < $0.0.end }) {
                who = m.1; inMeeting = true
            } else {
                let sincePrev = previous.map { t.timeIntervalSince(prompts[$0].at) }
                let untilNext = next.map { prompts[$0].at.timeIntervalSince(t) }
                let inStretch = (sincePrev.map { $0 <= tail } ?? false)
                    || (sincePrev != nil && untilNext != nil
                        && prompts[next!].at.timeIntervalSince(prompts[previous!].at) <= gap)
                if inStretch, let previous {
                    who = promptClients[previous]
                } else if let app = activeMinutes[minuteIndex] {
                    // Nearest prompt within the gap names the client; else an app rule.
                    if let p = sincePrev, p <= gap, let previous { who = promptClients[previous] }
                    else if let n = untilNext, n <= gap, let next { who = promptClients[next] }
                    else { who = client(forApp: app, config.clients) ?? TimeWeek.unassigned }
                }
            }
            if let who {
                let day = calendar.startOfDay(for: t)
                var d = perDay[day] ?? (0, [:], nil, nil)
                d.0 += 1; d.1[who, default: 0] += 1
                d.2 = d.2 ?? t; d.3 = t.addingTimeInterval(60)
                perDay[day] = d
                var c = perClient[who] ?? (0, 0)
                c.0 += 1; if inMeeting { c.1 += 1; meetingTotal += 1 }
                perClient[who] = c
                total += 1
            }
            t = t.addingTimeInterval(60)
        }

        var orgOf: [String: String] = [:]
        for c in config.clients where orgOf[c.name] == nil { orgOf[c.name] = c.org }
        var promptCount: [String: Int] = [:]
        for (i, p) in prompts.enumerated() where p.at >= start { promptCount[promptClients[i], default: 0] += 1 }
        let clients = perClient.map { name, v in
            TimeWeek.Client(name: name, org: orgOf[name] ?? "—", minutes: v.0, meetingMinutes: v.1,
                            prompts: promptCount[name] ?? 0)
        }.sorted { $0.minutes > $1.minutes }
        var byOrg: [String: Int] = [:]
        for c in clients { byOrg[c.org, default: 0] += c.minutes }

        let days = (0..<7).map { offset -> TimeWeek.Day in
            let date = calendar.date(byAdding: .day, value: offset, to: start)!
            let d = perDay[date] ?? (0, [:], nil, nil)
            return TimeWeek.Day(date: date, minutes: d.0, byClient: d.1, first: d.2, last: d.3)
        }
        return TimeWeek(start: start, days: days, clients: clients, minutes: total,
                        meetingMinutes: meetingTotal, prompts: prompts.filter { $0.at >= start }.count, byOrg: byOrg)
    }

    // MARK: - Rules

    static func client(forPrompt p: PromptEvent, _ rules: [TimeClient]) -> String {
        let haystack = (p.project + " " + p.configDir).lowercased()
        return rules.first { r in (r.folderKeywords ?? []).contains { haystack.contains($0.lowercased()) } }?.name
            ?? TimeWeek.unassigned
    }

    static func client(forMeeting m: TimeMeeting, _ rules: [TimeClient]) -> String {
        let words = (m.title + " " + m.summary).lowercased()
        if let hit = rules.first(where: { r in (r.meetingKeywords ?? []).contains { words.contains($0.lowercased()) } }) {
            return hit.name
        }
        let account = m.calendarAccount.lowercased()
        if !account.isEmpty,
           let hit = rules.first(where: { r in (r.calendarAccounts ?? []).contains { account.contains($0.lowercased()) } }) {
            return hit.name
        }
        return TimeWeek.unassigned
    }

    static func client(forApp app: String, _ rules: [TimeClient]) -> String? {
        let a = app.lowercased()
        return rules.first { r in (r.appKeywords ?? []).contains { a.contains($0.lowercased()) } }?.name
    }
}
