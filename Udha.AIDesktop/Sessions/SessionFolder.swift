import Foundation

/// A named group of sessions on one machine. Owned by the machine that
/// supervises those sessions — the Mac for its own, `udha-agent` for a box —
/// exactly like a session's label and its place in the list: persisted in that
/// machine's `AppConfig.sessionFolders`, published on the wire beside the
/// session rows, and edited from anywhere through the bridge's folder verbs.
/// Ids never cross machines; a session handed off to another host lands loose.
struct SessionFolder: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    /// A hidden folder hides every session filed in it. Decoded by hand so a
    /// folder written before the flag existed still loads: synthesized
    /// `Decodable` ignores a default when the key is missing, and
    /// `ConfigStore` can only fill defaults for top-level dictionaries, never
    /// for elements of an array.
    var hidden: Bool = false

    init(id: UUID = UUID(), name: String, hidden: Bool = false) {
        self.id = id
        self.name = name
        self.hidden = hidden
    }

    private enum CodingKeys: String, CodingKey { case id, name, hidden }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    }

    /// Resolve the target index after removal so adjacent downward moves work.
    static func reordered(_ ids: [UUID], moving: UUID, target: UUID, after: Bool) -> [UUID] {
        guard moving != target, ids.contains(moving), ids.contains(target) else { return ids }
        var result = ids.filter { $0 != moving }
        let index = result.firstIndex(of: target)!
        result.insert(moving, at: index + (after ? 1 : 0))
        return result
    }

    // MARK: - Wire

    /// `hidden` rides only when true, the same rule as the session row's.
    var wireValue: [String: Any] {
        var out: [String: Any] = ["id": id.uuidString, "name": name]
        if hidden { out["hidden"] = true }
        return out
    }

    init?(wire r: [String: Any]) {
        guard let s = r["id"] as? String, let id = UUID(uuidString: s),
              let name = r["name"] as? String else { return nil }
        self.init(id: id, name: name, hidden: (r["hidden"] as? Bool) ?? false)
    }
}
