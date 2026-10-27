import AppKit
import Foundation

/// Hours worked, per client, for the Time section.
///
/// Three inputs, all kept in `~/Library/Application Support/Udha.AI/Time/`
/// so history outlives Claude's 30-day transcript cleanup and survives a box
/// being off: the prompts typed on every machine (`prompts.jsonl`, this Mac's
/// read from its transcripts, each box's asked for over the bridge), one line
/// per active minute on this Mac (`activity-<yyyy-MM>.jsonl`), and the
/// recorded meetings (read live from the meeting store).
@MainActor
@Observable
final class TimeTracker {
    /// Every week counted so far, keyed by its Monday. A week being
    /// recounted keeps showing its last result.
    private(set) var weeks: [Date: TimeWeek] = [:]
    /// This week — what the sidebar badge and the title bar read.
    var week: TimeWeek? { weeks[Self.weekStart(containing: Date())] }
    func week(starting start: Date) -> TimeWeek? { weeks[start] }
    private(set) var isComputing = false
    private(set) var lastRefresh: Date?
    /// Boxes whose agent can't report prompts yet (built before this feature).
    private(set) var hostsWithoutActivity: [String] = []

    @ObservationIgnored private let config: ConfigStore
    @ObservationIgnored private let meetings: MeetingCenter
    @ObservationIgnored private let remoteHosts: RemoteHostDirectory
    @ObservationIgnored private let scanner = PromptActivityScanner()
    @ObservationIgnored private var prompts = Set<PromptEvent>()
    @ObservationIgnored private var activity: [ActivityMinute] = []
    @ObservationIgnored private var sampler: Timer?
    @ObservationIgnored private var seenRemoteAt: [String: Date] = [:]
    @ObservationIgnored private var recount: Task<Void, Never>?

    private let directory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Udha.AI/Time", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init(config: ConfigStore, meetings: MeetingCenter, remoteHosts: RemoteHostDirectory) {
        self.config = config
        self.meetings = meetings
        self.remoteHosts = remoteHosts
        loadLog()
    }

    func start() {
        sampler?.invalidate()
        sampler = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleMinute() }
        }
    }

    // MARK: - Week

    static func weekStart(containing date: Date, calendar: Calendar = .current) -> Date {
        var cal = calendar
        cal.firstWeekday = 2  // Monday
        return cal.dateInterval(of: .weekOfYear, for: date)?.start ?? cal.startOfDay(for: date)
    }

    /// Re-read every source and recompute `start`'s week. Asks each box for
    /// its prompts first and recomputes again when they arrive.
    func refresh(weekStarting start: Date) {
        let since = start.addingTimeInterval(-86_400)
        hostsWithoutActivity = []
        for host in remoteHosts.connectedHosts {
            guard let client = remoteHosts.client(for: host) else { continue }
            if client.hostActivitySupported { client.requestActivity(since: since) }
            else { hostsWithoutActivity.append(host) }
        }
        compute(start)
        // Box replies land asynchronously — a box still reading its
        // transcripts for the first time can take half a minute. Recount
        // whenever one arrives, for up to a minute.
        // A newer refresh (another week picked) cancels this one, or its
        // recount would land over the week now on screen.
        recount?.cancel()
        recount = Task { @MainActor [weak self] in
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                guard let self, self.hasNewRemote() else { continue }
                self.compute(start)
            }
        }
    }

    private func hasNewRemote() -> Bool {
        remoteHosts.connectedHosts.contains { host in
            guard let at = remoteHosts.client(for: host)?.hostPromptsAt else { return false }
            return at != seenRemoteAt[host]
        }
    }

    private func compute(_ start: Date) {
        absorbRemote()
        isComputing = true
        let scanner = scanner
        let since = start.addingTimeInterval(-86_400)
        let cfg = config.config.timeTracking
        let meetingRows = meetings.store.meetings.compactMap { m -> TimeMeeting? in
            guard let end = m.endedAt else { return nil }
            return TimeMeeting(start: m.createdAt, end: end, title: m.title, summary: m.summary,
                               calendarAccount: m.calendarEvent?.account ?? "")
        }
        let activityRows = activity
        let known = prompts
        Task.detached(priority: .utility) { [weak self] in
            let local = scanner.events(since: since).map { e -> PromptEvent in
                var e = e; e.host = "mac"; return e
            }
            let all = known.union(local)
            let week = TimeRollup.week(starting: start, prompts: Array(all), meetings: meetingRows,
                                       activity: activityRows, config: cfg)
            await MainActor.run {
                guard let self else { return }
                self.persist(local)
                self.weeks[start] = week
                self.isComputing = false
                self.lastRefresh = Date()
            }
        }
    }

    private func absorbRemote() {
        var fresh: [PromptEvent] = []
        for host in remoteHosts.connectedHosts {
            guard let client = remoteHosts.client(for: host), let at = client.hostPromptsAt,
                  at != seenRemoteAt[host] else { continue }
            seenRemoteAt[host] = at
            fresh += client.hostPrompts
        }
        persist(fresh)
    }

    // MARK: - Mac activity

    private func sampleMinute() {
        let cfg = config.config.timeTracking
        guard cfg.captureMacActivity, SystemInputState.idleSeconds() < 90 else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let name = front?.localizedName ?? "?"
        let bundle = front?.bundleIdentifier ?? ""
        if cfg.excludedApps.contains(where: { $0 == name || $0 == bundle }) { return }
        let minute = ActivityMinute(at: Date(), app: name)
        activity.append(minute)
        append(["t": minute.at.timeIntervalSince1970, "a": name], to: activityFile(for: minute.at))
    }

    private func activityFile(for date: Date) -> URL {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"
        return directory.appendingPathComponent("activity-\(f.string(from: date)).jsonl")
    }

    // MARK: - Log

    private var promptsFile: URL { directory.appendingPathComponent("prompts.jsonl") }

    private func persist(_ events: [PromptEvent]) {
        let new = events.filter { !prompts.contains($0) }
        guard !new.isEmpty else { return }
        prompts.formUnion(new)
        var text = ""
        for e in new {
            var w = e.wire; w["h"] = e.host
            if let data = try? JSONSerialization.data(withJSONObject: w),
               let line = String(data: data, encoding: .utf8) { text += line + "\n" }
        }
        appendRaw(text, to: promptsFile)
    }

    private func append(_ object: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let line = String(data: data, encoding: .utf8) else { return }
        appendRaw(line + "\n", to: url)
    }

    private func appendRaw(_ text: String, to url: URL) {
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    private func loadLog() {
        if let text = try? String(contentsOf: promptsFile, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let e = PromptEvent(wire: obj, host: obj["h"] as? String ?? "") else { continue }
                prompts.insert(e)
            }
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.lastPathComponent.hasPrefix("activity-") {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let t = obj["t"] as? Double else { continue }
                activity.append(ActivityMinute(at: Date(timeIntervalSince1970: t), app: obj["a"] as? String ?? "?"))
            }
        }
    }
}
