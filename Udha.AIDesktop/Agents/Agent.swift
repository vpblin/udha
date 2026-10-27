import Foundation

/// A reusable, named prompt that can be launched against a folder. Agents are
/// stored on disk as plain `.md` files with a small YAML-ish frontmatter block:
///
/// ```
/// ---
/// name: Security Audit
/// description: One-line summary shown in the picker.
/// icon: lock.shield
/// ---
/// <the prompt body — everything after the closing fence>
/// ```
///
/// The filename (minus `.md`) is the stable `slug`; the body is the prompt that
/// gets pasted into a freshly-spawned Claude session once it's up and running.
struct Agent: Identifiable, Hashable {
    /// Filename slug, e.g. `security-audit`. Stable identity across edits.
    var slug: String
    var name: String
    var description: String
    /// SF Symbol name used as the agent's glyph in the UI.
    var icon: String
    /// The full markdown prompt body (everything below the frontmatter).
    var prompt: String
    /// True when this agent was seeded from the app bundle. Built-ins are still
    /// editable — editing just writes a user copy over the seeded file.
    var isBuiltIn: Bool = false

    var id: String { slug }

    static let defaultIcon = "sparkles"

    /// Parse a `.md` file's contents into an Agent. Frontmatter is optional;
    /// when absent we fall back to sensible defaults derived from the slug.
    static func parse(slug: String, contents: String, isBuiltIn: Bool) -> Agent {
        var name = Self.titleCase(slug)
        var description = ""
        var icon = defaultIcon
        var body = contents

        let lines = contents.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            var i = 1
            var meta: [String: String] = [:]
            while i < lines.count {
                let line = lines[i]
                if line.trimmingCharacters(in: .whitespaces) == "---" {
                    i += 1
                    break
                }
                if let colon = line.firstIndex(of: ":") {
                    let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                    let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    meta[key] = value
                }
                i += 1
            }
            if let n = meta["name"], !n.isEmpty { name = n }
            if let d = meta["description"] { description = d }
            if let ic = meta["icon"], !ic.isEmpty { icon = ic }
            body = lines[i...].joined(separator: "\n")
        }

        return Agent(
            slug: slug,
            name: name,
            description: description,
            icon: icon,
            prompt: body.trimmingCharacters(in: .whitespacesAndNewlines),
            isBuiltIn: isBuiltIn
        )
    }

    /// Serialize back to a `.md` file body with frontmatter.
    func serialized() -> String {
        """
        ---
        name: \(name)
        description: \(description)
        icon: \(icon)
        ---
        \(prompt)
        """
    }

    /// `security-audit` → `Security Audit`
    static func titleCase(_ slug: String) -> String {
        slug.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Derive a filesystem-safe slug from a human name.
    static func slugify(_ name: String) -> String {
        let lowered = name.lowercased()
        let mapped = lowered.map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "agent" : collapsed
    }
}
