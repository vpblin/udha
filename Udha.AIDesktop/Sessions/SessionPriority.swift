import Foundation

/// How loudly a session is allowed to interrupt you.
///
/// Lives beside the other session types rather than in `AppConfig` — it is a
/// property of a session, and keeping it here lets the session model compile
/// without dragging in the whole configuration graph.
enum SessionPriority: String, Codable, Hashable {
    case normal
    case high
}
