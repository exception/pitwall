import Foundation

/// A skill or slash command a new Claude Code agent can start with, offered
/// when the dispatch bar's text starts with `/`.
struct SlashCommand: Identifiable, Hashable {
    enum Source: Hashable {
        case project, user, plugin(String), builtIn

        var label: String {
            switch self {
            case .project: return "project"
            case .user: return "user"
            case .plugin(let p): return p
            case .builtIn: return "built-in"
            }
        }

        var order: Int {
            switch self {
            case .project: return 0
            case .user: return 1
            case .plugin: return 2
            case .builtIn: return 3
            }
        }
    }

    /// Without the leading slash, e.g. `pr-review` or `Notion:find`.
    let name: String
    let description: String
    var argumentHint: String?
    let source: Source
    var id: String { name }
}

/// Finds the skills and commands Claude Code would load for a folder: the
/// project's `.claude/` (and its parents'), the user's `~/.claude/`, and
/// every enabled plugin, the same places `claude` itself looks.
enum SlashCommands {
    /// Built-ins worth starting a fresh session with.
    static let builtIns: [SlashCommand] = [
        .init(name: "init", description: "Write a CLAUDE.md that documents this codebase", source: .builtIn),
        .init(name: "code-review", description: "Review the current diff for correctness bugs", argumentHint: "[level] [target]", source: .builtIn),
        .init(name: "security-review", description: "Security review of the pending changes on this branch", source: .builtIn),
        .init(name: "simplify", description: "Clean up the changed code for reuse and simplicity", source: .builtIn),
    ]

    static func load(repo: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [SlashCommand] {
        let claudeHome = home.appendingPathComponent(".claude", isDirectory: true)
        var out: [SlashCommand] = []

        // Project: the folder and each parent up to (not including) home.
        var projectDirs: [URL] = []
        if let repo {
            var dir = URL(fileURLWithPath: repo, isDirectory: true).standardizedFileURL
            while dir.path != home.standardizedFileURL.path && dir.path != "/" {
                projectDirs.append(dir.appendingPathComponent(".claude", isDirectory: true))
                dir = dir.deletingLastPathComponent()
            }
        }
        for d in projectDirs {
            out += skills(in: d.appendingPathComponent("skills"), source: .project)
            out += commands(in: d.appendingPathComponent("commands"), source: .project)
        }

        out += skills(in: claudeHome.appendingPathComponent("skills"), source: .user)
        out += commands(in: claudeHome.appendingPathComponent("commands"), source: .user)

        for (namespace, root) in enabledPlugins(claudeHome: claudeHome, projectDirs: projectDirs) {
            out += skills(in: root.appendingPathComponent("skills"), source: .plugin(namespace), namespace: namespace)
            out += commands(in: root.appendingPathComponent("commands"), source: .plugin(namespace), namespace: namespace)
        }

        out += builtIns

        // The first definition of a name wins (project shadows user, and so on).
        var seen = Set<String>()
        return out.filter { seen.insert($0.name.lowercased()).inserted }
    }

    /// Commands matching what's typed after the `/`: name prefixes first, then
    /// a prefix of the part after a plugin's `:`, then anywhere in the name,
    /// then the description.
    static func matches(_ query: String, in all: [SlashCommand]) -> [SlashCommand] {
        let q = query.lowercased()
        func rank(_ c: SlashCommand) -> Int? {
            let n = c.name.lowercased()
            if q.isEmpty || n.hasPrefix(q) { return 0 }
            if n.split(separator: ":").dropFirst().contains(where: { $0.hasPrefix(q) }) { return 1 }
            if n.contains(q) { return 2 }
            if c.description.lowercased().contains(q) { return 3 }
            return nil
        }
        return all.compactMap { c in rank(c).map { (c, $0) } }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                if a.0.source.order != b.0.source.order { return a.0.source.order < b.0.source.order }
                return a.0.name.localizedCaseInsensitiveCompare(b.0.name) == .orderedAscending
            }
            .map(\.0)
    }

    // MARK: Scanning

    /// `skills/<name>/SKILL.md`.
    static func skills(in dir: URL, source: SlashCommand.Source, namespace: String? = nil) -> [SlashCommand] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return [] }
        return entries.compactMap { entry in
            let file = entry.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let meta = frontmatter(text)
            if meta["user-invocable"]?.lowercased() == "false" { return nil }
            let base = meta["name"].flatMap { $0.isEmpty ? nil : $0 } ?? entry.lastPathComponent
            return SlashCommand(name: namespace.map { "\($0):\(base)" } ?? base,
                                description: meta["description"] ?? firstLine(of: text),
                                argumentHint: meta["argument-hint"],
                                source: source)
        }
    }

    /// `commands/**/*.md`. In a plugin a subfolder adds a namespace
    /// (`Notion:tasks:build`); for project and user commands it only groups.
    static func commands(in dir: URL, source: SlashCommand.Source, namespace: String? = nil) -> [SlashCommand] {
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return [] }
        var out: [SlashCommand] = []
        let rootCount = dir.standardizedFileURL.pathComponents.count
        for case let file as URL in walker where file.pathExtension == "md" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let meta = frontmatter(text)
            if meta["user-invocable"]?.lowercased() == "false" { continue }
            let base = file.deletingPathExtension().lastPathComponent
            let name: String
            if let namespace {
                let folders = file.standardizedFileURL.deletingLastPathComponent().pathComponents.dropFirst(rootCount)
                name = ([namespace] + folders + [base]).joined(separator: ":")
            } else {
                name = base
            }
            out.append(SlashCommand(name: name, description: meta["description"] ?? firstLine(of: text),
                                    argumentHint: meta["argument-hint"], source: source))
        }
        return out
    }

    /// Enabled plugins as (namespace, install folder). `enabledPlugins` from
    /// the user's settings, then the project's and its local overrides.
    static func enabledPlugins(claudeHome: URL, projectDirs: [URL]) -> [(String, URL)] {
        var enabled: [String: Bool] = [:]
        let settings = [claudeHome.appendingPathComponent("settings.json")]
            + projectDirs.reversed().flatMap { [$0.appendingPathComponent("settings.json"), $0.appendingPathComponent("settings.local.json")] }
        for file in settings {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let plugins = json["enabledPlugins"] as? [String: Any] else { continue }
            for (k, v) in plugins { if let b = v as? Bool { enabled[k] = b } }
        }
        guard let data = try? Data(contentsOf: claudeHome.appendingPathComponent("plugins/installed_plugins.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let installed = json["plugins"] as? [String: Any] else { return [] }
        let fm = FileManager.default
        var out: [(String, URL)] = []
        for key in installed.keys.sorted() where enabled[key] == true {
            let installs = (installed[key] as? [[String: Any]]) ?? []
            guard let path = installs.compactMap({ $0["installPath"] as? String }).first(where: { fm.fileExists(atPath: $0) }) else { continue }
            let root = URL(fileURLWithPath: path, isDirectory: true)
            var namespace = String(key.split(separator: "@").first ?? Substring(key))
            if let m = try? Data(contentsOf: root.appendingPathComponent(".claude-plugin/plugin.json")),
               let manifest = try? JSONSerialization.jsonObject(with: m) as? [String: Any],
               let n = manifest["name"] as? String, !n.isEmpty {
                namespace = n
            }
            out.append((namespace, root))
        }
        return out
    }

    // MARK: Frontmatter

    /// The flat `key: value` pairs of a Markdown file's YAML frontmatter,
    /// including folded (`>`) and literal (`|`) blocks and quoted strings.
    /// Multi-line values are joined into one line.
    static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var out: [String: String] = [:]
        var key: String?
        var block: [String] = []
        func flush() {
            if let k = key, !block.isEmpty { out[k] = block.joined(separator: " ") }
            key = nil; block = []
        }
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            if key != nil, line.first == " " || line.first == "\t" || line.isEmpty {
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { block.append(t) }
                continue
            }
            flush()
            guard let colon = line.firstIndex(of: ":"), line.first != " " else { continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces)
            var v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if v.hasPrefix(">") || v.hasPrefix("|") || v.isEmpty {
                key = k  // a block, or a value continued on indented lines
                continue
            }
            if v.count >= 2, let q = v.first, q == "\"" || q == "'", v.last == q { v = String(v.dropFirst().dropLast()) }
            out[k] = v
        }
        flush()
        return out
    }

    private static func firstLine(of text: String) -> String {
        var body = Substring(text)
        if text.hasPrefix("---"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) {
            body = text[end.upperBound...]
        }
        let line = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty && !$0.hasPrefix("#") } ?? ""
        return line.count > 120 ? String(line.prefix(118)) + "…" : line
    }
}

/// Skills and commands for the dispatch bar's folder, loaded off the main
/// thread and refreshed whenever the menu opens (they're plain files the user
/// may have just added).
final class SlashCatalog: ObservableObject {
    @Published private(set) var commands: [SlashCommand] = []
    private var loadedRepo: String??
    private var loadedAt = Date.distantPast
    private let queue = DispatchQueue(label: "pitwall.slash-catalog", qos: .userInitiated)

    func refresh(repo: String?) {
        if loadedRepo == .some(repo) && Date().timeIntervalSince(loadedAt) < 5 { return }
        loadedRepo = .some(repo)
        loadedAt = Date()
        queue.async { [weak self] in
            let found = SlashCommands.load(repo: repo)
            DispatchQueue.main.async {
                guard let self, self.loadedRepo == .some(repo) else { return }
                self.commands = found
            }
        }
    }
}
