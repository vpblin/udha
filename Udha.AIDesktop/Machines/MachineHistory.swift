import Foundation
import Observation

/// The recent past of every machine's vitals, so the Machines pane can draw a
/// line instead of a single number.
///
/// `MachineStats` is one instant — the collector reads and forgets. A shape is
/// what tells you whether 68% memory is a plateau or a climb, so each reading
/// that arrives is appended here.
///
/// Two honest limits, both deliberate. The monitor only samples while the
/// Machines section is on screen, so a chart covers *the time you have been
/// watching*, not a rolling hour; `span` reports that measured window rather
/// than a label like "60 m" that would be a lie for the first fifty-nine of
/// them. And nothing is persisted: a relaunch starts the charts empty rather
/// than drawing a gap as if it were flat.
@MainActor
@Observable
final class MachineHistory {

    /// What is tracked per machine. Temperatures are keyed separately, by
    /// sensor label, because which sensors exist differs per box.
    enum Track: String, CaseIterable {
        case cpu, memory, disk, gpu, rtt, sessions
    }

    /// An hour at 5s is 720 points — more than any sparkline can resolve, and
    /// the oldest of them is already older than the window the pane claims.
    private let capacity = 720

    private struct Log {
        var values: [Double] = []
        var stamps: [Date] = []

        mutating func append(_ value: Double, at when: Date, capacity: Int) {
            values.append(value)
            stamps.append(when)
            if values.count > capacity {
                values.removeFirst(values.count - capacity)
                stamps.removeFirst(stamps.count - capacity)
            }
        }
    }

    private var tracks: [String: [Track: Log]] = [:]
    private var temps: [String: [String: Log]] = [:]
    /// The `sampledAt` of the last reading stored per machine, so the same
    /// payload arriving twice (the remote stats are polled, not pushed) is not
    /// counted as two samples and does not stretch the span.
    private var lastSampleAt: [String: Date] = [:]

    // MARK: - Recording

    /// Store one reading. `sessions` comes from the app's own store rather than
    /// the payload, so this Mac's chart is right even before the first collect.
    func record(id: String, stats: MachineStats?, sessions: Int, rttMilliseconds: Double?) {
        guard let stats else { return }
        if let seen = lastSampleAt[id], seen == stats.sampledAt { return }
        lastSampleAt[id] = stats.sampledAt
        let at = stats.sampledAt

        var machine = tracks[id] ?? [:]
        func put(_ track: Track, _ value: Double?) {
            guard let value else { return }
            var log = machine[track] ?? Log()
            log.append(value, at: at, capacity: capacity)
            machine[track] = log
        }
        put(.cpu, stats.cpuPercent)
        put(.memory, stats.memoryPercent)
        put(.disk, stats.diskPercent)
        put(.gpu, stats.gpu?.utilPercent)
        put(.rtt, stats.relay?.rttMilliseconds ?? rttMilliseconds)
        put(.sessions, Double(sessions))
        tracks[id] = machine

        var sensors = temps[id] ?? [:]
        for reading in stats.temperatures {
            var log = sensors[reading.label] ?? Log()
            log.append(reading.celsius, at: at, capacity: capacity)
            sensors[reading.label] = log
        }
        temps[id] = sensors
    }

    /// Drop everything for a machine — used when a box goes offline, so the
    /// line does not resume from an hour ago as though nothing happened.
    func forget(id: String) {
        tracks[id] = nil
        temps[id] = nil
        lastSampleAt[id] = nil
    }

    // MARK: - Reading

    func series(_ id: String, _ track: Track) -> [Double] {
        tracks[id]?[track]?.values ?? []
    }

    func temperature(_ id: String, label: String) -> [Double] {
        temps[id]?[label]?.values ?? []
    }

    /// How much time the samples actually cover, as a label: "4 m", "1 h 12 m",
    /// or "—" when there is not yet a second sample to measure against.
    func span(_ id: String, _ track: Track = .cpu) -> String {
        guard let log = tracks[id]?[track], let first = log.stamps.first, let last = log.stamps.last,
              log.stamps.count > 1 else { return "—" }
        return UdhaFormat.duration(since: first, now: last)
    }

    /// Errors bucketed into the last 24 hours, one point per hour, oldest
    /// first. Read straight from the payload's own timestamps, so unlike the
    /// other series this one is real history even on the first sample.
    static func dropsPerHour(_ errors: [MachineStats.ConnectionError], now: Date = Date()) -> [Double] {
        var buckets = [Double](repeating: 0, count: 24)
        for error in errors {
            let hoursAgo = now.timeIntervalSince(error.at) / 3600
            guard hoursAgo >= 0, hoursAgo < 24 else { continue }
            let index = 23 - Int(hoursAgo)
            buckets[max(0, min(23, index))] += 1
        }
        return buckets
    }
}
