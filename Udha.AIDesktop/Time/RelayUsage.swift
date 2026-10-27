import Foundation

/// The relay's usage report: who uses Udha through it, how long, on which
/// machines, and how many of each *kind* of action — never what anyone typed.
///
/// Only one login ever receives it (the relay's `USAGE_ADMIN_SUB`). For any
/// other login `fetch_usage` gets no reply at all, so the Usage section simply
/// stays empty there.
struct RelayUsageReport: Decodable, Equatable {
    struct Day: Decodable, Equatable, Identifiable {
        let day: String
        let activeUsers: Int
        let clientSeconds: Int
        var id: String { day }

        var date: Date? { Self.parser.date(from: day) }
        private static let parser: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone(identifier: "UTC")
            return f
        }()
    }

    struct Person: Decodable, Equatable, Identifiable {
        let userId: String
        let email: String?
        let name: String?
        let activeDays: Int
        let connects: Int
        let clientSeconds: Int
        let hostSeconds: Int
        let apps: [String: Int]
        let machines: [String: String]
        let actions: [String: Int]
        let firstSeen: Double?
        let lastSeen: Double?
        let onlineNow: Bool
        let machinesOnline: Int
        let sharedWith: [String]

        var id: String { userId }
        var label: String { name ?? email ?? userId }
        var lastSeenDate: Date? { lastSeen.map { Date(timeIntervalSince1970: $0 / 1000) } }
        var appMinutes: Int { clientSeconds / 60 }
        var totalActions: Int { actions.values.reduce(0, +) }
        /// Machine names, most readable first.
        var machineNames: [String] { Array(Set(machines.values)).sorted() }
    }

    let days: Int
    let generatedAt: Double
    let series: [Day]
    let people: [Person]
}
