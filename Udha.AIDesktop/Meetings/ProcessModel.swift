import Foundation

/// Swimlane model of a business process, built incrementally by the LLM during
/// a process-mapping call. IDs are human-readable slugs ("write-code"), not
/// UUIDs: the LLM echoes them across full-state revisions, which is what lets
/// SwiftUI diff/animate the growing diagram instead of rebuilding it.
struct ProcessRole: Codable, Hashable, Identifiable {
    var id: String
    var name: String
}

struct ProcessStep: Codable, Hashable, Identifiable {
    var id: String
    var roleID: String
    var title: String
    var detail: String? = nil
}

struct ProcessEdge: Codable, Hashable, Identifiable {
    var from: String
    var to: String
    var label: String? = nil

    var id: String { "\(from)->\(to)" }
}

struct ProcessModel: Codable, Hashable {
    /// Column order, left to right (the LLM orders by first involvement).
    var roles: [ProcessRole] = []
    /// Array order = the process's own sequence (layout tiebreak).
    var steps: [ProcessStep] = []
    var edges: [ProcessEdge] = []

    var isEmpty: Bool { roles.isEmpty && steps.isEmpty }

    /// Drops steps whose role doesn't exist and edges whose endpoints don't —
    /// the LLM occasionally references ids it didn't emit; layout must stay a
    /// total function.
    func sanitized() -> ProcessModel {
        var m = self
        let roleIDs = Set(m.roles.map(\.id))
        m.steps = m.steps.filter { roleIDs.contains($0.roleID) }
        let stepIDs = Set(m.steps.map(\.id))
        m.edges = m.edges.filter { stepIDs.contains($0.from) && stepIDs.contains($0.to) && $0.from != $0.to }
        var seen = Set<String>()
        m.edges = m.edges.filter { seen.insert($0.id).inserted }
        return m
    }

    /// Mermaid flowchart with one subgraph per lane — the shareable text form.
    func mermaidText() -> String {
        func slug(_ s: String) -> String {
            String(s.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        }
        func quote(_ s: String) -> String {
            "\"\(s.replacingOccurrences(of: "\"", with: "'"))\""
        }
        var lines = ["flowchart TD"]
        for role in roles {
            lines.append("  subgraph \(slug(role.id))[\(quote(role.name))]")
            for step in steps where step.roleID == role.id {
                lines.append("    \(slug(step.id))[\(quote(step.title))]")
            }
            lines.append("  end")
        }
        for edge in edges {
            if let label = edge.label, !label.isEmpty {
                lines.append("  \(slug(edge.from)) -- \(quote(label)) --> \(slug(edge.to))")
            } else {
                lines.append("  \(slug(edge.from)) --> \(slug(edge.to))")
            }
        }
        return lines.joined(separator: "\n")
    }
}
