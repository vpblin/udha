import Foundation
import Observation

/// Loads, persists, and manages the library of agents. Agents live as `.md`
/// files in `~/Library/Application Support/Udha.AI/Agents/` so they can be
/// hand-edited, version-controlled, or synced. Built-in agents ship in the app
/// bundle and are copied into that directory on first run (and re-seeded if a
/// built-in file goes missing) so the user always starts with a working set.
@MainActor
@Observable
final class AgentStore {
    private(set) var agents: [Agent] = []

    /// Slugs of agents shipped in the app bundle as seed `.md` resources.
    /// Add a new entry here when you add a built-in `Agents/<slug>.md`.
    static let builtInSlugs: [String] = ["security-audit"]

    private var directoryURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Udha.AI", isDirectory: true)
            .appendingPathComponent("Agents", isDirectory: true)
    }

    func load() {
        ensureDirectory()
        seedBuiltInsIfMissing()
        reload()
    }

    /// The directory agents are read from / written to, for "Reveal in Finder".
    var agentsDirectory: URL { directoryURL }

    func reload() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            agents = []
            return
        }
        var loaded: [Agent] = []
        for url in entries where url.pathExtension.lowercased() == "md" {
            let slug = url.deletingPathExtension().lastPathComponent
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            loaded.append(Agent.parse(
                slug: slug,
                contents: contents,
                isBuiltIn: Self.builtInSlugs.contains(slug)
            ))
        }
        agents = loaded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func agent(slug: String) -> Agent? {
        agents.first { $0.slug == slug }
    }

    /// Write an agent to disk and refresh. Returns the (possibly slug-adjusted)
    /// agent that was persisted.
    @discardableResult
    func save(_ agent: Agent) -> Agent {
        ensureDirectory()
        var toSave = agent
        if toSave.slug.isEmpty {
            toSave.slug = uniqueSlug(for: toSave.name)
        }
        let url = directoryURL.appendingPathComponent("\(toSave.slug).md")
        do {
            try toSave.serialized().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.app.error("AgentStore.save failed for \(toSave.slug): \(error.localizedDescription)")
        }
        reload()
        return toSave
    }

    /// Create a brand-new agent with a unique slug and persist a stub.
    @discardableResult
    func create(name: String) -> Agent {
        let slug = uniqueSlug(for: name)
        let agent = Agent(
            slug: slug,
            name: name.isEmpty ? Agent.titleCase(slug) : name,
            description: "",
            icon: Agent.defaultIcon,
            prompt: "",
            isBuiltIn: false
        )
        return save(agent)
    }

    func delete(_ agent: Agent) {
        let url = directoryURL.appendingPathComponent("\(agent.slug).md")
        try? FileManager.default.removeItem(at: url)
        reload()
    }

    // MARK: - Private

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    /// Copy any built-in seed `.md` that isn't already present on disk. This
    /// runs every launch, so deleting a built-in restores it next start (a
    /// deliberate floor of always-available agents); user-created agents are
    /// never touched.
    private func seedBuiltInsIfMissing() {
        for slug in Self.builtInSlugs {
            let dest = directoryURL.appendingPathComponent("\(slug).md")
            guard !FileManager.default.fileExists(atPath: dest.path) else { continue }
            guard let src = Bundle.main.url(forResource: slug, withExtension: "md") else {
                Log.app.error("AgentStore: built-in seed \(slug).md not found in bundle")
                continue
            }
            do {
                try FileManager.default.copyItem(at: src, to: dest)
                Log.app.info("AgentStore: seeded built-in agent \(slug)")
            } catch {
                Log.app.error("AgentStore: failed to seed \(slug): \(error.localizedDescription)")
            }
        }
    }

    private func uniqueSlug(for name: String) -> String {
        let base = Agent.slugify(name)
        let existing = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path))?
                .filter { $0.lowercased().hasSuffix(".md") }
                .map { ($0 as NSString).deletingPathExtension } ?? []
        )
        if !existing.contains(base) { return base }
        var n = 2
        while existing.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }
}
