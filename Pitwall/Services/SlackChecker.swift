import Foundation
import Combine

/// Checks Slack for each board whose agent listens there, every few minutes,
/// with a headless, read-only Claude Code session. New asks go to the board
/// agent's inbox.
///
/// A board reaches Slack through Claude's Slack connector (the workspace your
/// claude.ai account is connected to) or through a sign-in of its own, kept in
/// a separate Claude Code config folder so each board can be on a different
/// workspace.
final class SlackChecker: ObservableObject {
    static let shared = SlackChecker()

    weak var controller: CanvasController?
    /// Boards with a check running.
    @Published private(set) var checking: Set<String> = []
    private var timer: Timer?
    private let store = Store.shared
    static let timeout: TimeInterval = 300

    func start(controller: CanvasController) {
        self.controller = controller
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.tick() }
    }

    private func tick() {
        for b in store.boards {
            let s = b.agentConfig.slack
            guard s.enabled else { continue }
            let due = b.agentChecked.map { Date().timeIntervalSince($0) >= Double(max(1, s.everyMinutes)) * 60 } ?? true
            // After a failure, wait the full interval too (from the failure).
            if due { check(boardID: b.id) }
        }
    }

    // MARK: Per-board sign-in

    static func agentDir(_ boardID: String) -> URL {
        PitwallPaths.support.appendingPathComponent("agents/\(boardID)", isDirectory: true)
    }

    static func configDir(_ b: Board) -> String {
        b.agentConfig.slack.configDir ?? agentDir(b.id).appendingPathComponent("claude").path
    }

    /// The board's own Slack MCP entry: Slack's server, signed in through
    /// Slack's app for Claude Code.
    static func mcpFile(_ boardID: String) -> URL {
        let url = agentDir(boardID).appendingPathComponent("slack-mcp.json")
        let json = #"{"mcpServers":{"slack":{"type":"http","url":"https://mcp.slack.com/mcp","oauth":{"clientId":"1601185624273.8899143856786","callbackPort":3118}}}}"#
        try? FileManager.default.createDirectory(at: agentDir(boardID), withIntermediateDirectories: true)
        try? Data(json.utf8).write(to: url, options: .atomic)
        return url
    }

    /// Environment that points Claude Code at the board's own config folder
    /// (and away from the claude.ai connectors).
    static func signInEnv(_ b: Board) -> String {
        "CLAUDE_CONFIG_DIR=\(shellQuote(configDir(b))) ENABLE_CLAUDEAI_MCP_SERVERS=false"
    }

    /// Your own skills (~/.claude/skills), visible from the board's folder.
    static func linkPersonalSkills(configDir: String) {
        let fm = FileManager.default
        let link = (configDir as NSString).appendingPathComponent("skills")
        let target = UserClaude.dir.appendingPathComponent("skills").path
        guard fm.fileExists(atPath: target), (try? fm.destinationOfSymbolicLink(atPath: link)) == nil,
              !fm.fileExists(atPath: link) else { return }
        try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(atPath: link, withDestinationPath: target)
    }

    /// Opens a terminal where the user signs the board in: /login once for
    /// Claude, then /mcp → slack → authenticate, picking the workspace.
    func connect(boardID: String) {
        guard let ctl = controller, let b = store.board(boardID) else { return }
        try? FileManager.default.createDirectory(atPath: Self.configDir(b), withIntermediateDirectories: true)
        Self.linkPersonalSkills(configDir: Self.configDir(b))
        let plugins = UserClaude.enabledPluginDirs().map { " --plugin-dir " + shellQuote($0) }.joined()
        let cmd = "\(Self.signInEnv(b)) claude --strict-mcp-config --mcp-config \(shellQuote(Self.mcpFile(boardID).path))\(plugins)"
        if b.id != store.currentBoardID { ctl.switchBoard(b.id) }
        let id = ctl.newTerminal(cwd: Self.agentDir(boardID).path, command: cmd, name: "Connect Slack · \(b.agentConfig.name)")
        ctl.flyTo(tileID: id, fill: false)
        ctl.model?.toast(.init(kind: .info, title: "Connect Slack for \(b.name)",
                               body: "In the terminal: /login (first time only), then /mcp → slack → Authenticate, and pick the workspace in Slack. Then /exit and press Check now.",
                               tileID: nil))
    }

    // MARK: Checking

    /// The shell command for one check.
    static func command(_ b: Board, since: Date) -> String {
        let s = b.agentConfig.slack
        var env = ""
        var mcp = ""
        if s.connection == .boardSignIn {
            env = signInEnv(b) + " "
            mcp = " --strict-mcp-config --mcp-config \(shellQuote(mcpFile(b.id).path))"
            // The board's own config folder has none of your plugins or
            // skills: bring them along.
            linkPersonalSkills(configDir: configDir(b))
            for dir in UserClaude.enabledPluginDirs() { mcp += " --plugin-dir \(shellQuote(dir))" }
        }
        let model = s.model.trimmingCharacters(in: .whitespaces).isEmpty ? "haiku" : s.model
        return "cd \(shellQuote(agentDir(b.id).path)) && \(env)exec claude -p --model \(shellQuote(model)) --output-format json"
            + " --no-session-persistence --tools Skill\(mcp)"
            + " --allowedTools \(shellQuote(BoardAgent.checkTools(s.connection).joined(separator: " ")))"
            + " --json-schema \(shellQuote(BoardAgent.checkSchema))"
            + " -- \(shellQuote(BoardAgent.checkPrompt(s, since: since, instructions: b.agentConfig.instructions, open: (b.asks ?? []).filter { $0.state == .new && $0.source == "slack" }))) < /dev/null"
    }

    /// Starts a check now. `since` overrides where it looks back to.
    @discardableResult
    func check(boardID: String, since override: Date? = nil) -> Bool {
        guard !checking.contains(boardID), let b = store.board(boardID) else { return false }
        checking.insert(boardID)
        let started = Date()
        let since = override ?? b.agentChecked ?? started.addingTimeInterval(-BoardAgent.firstLookback)
        try? FileManager.default.createDirectory(at: Self.agentDir(boardID), withIntermediateDirectories: true)
        let cmd = Self.command(b, since: since)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let (out, err, status) = Self.run(cmd)
            DispatchQueue.main.async {
                self?.finish(boardID: boardID, started: started, out: out, err: err, status: status)
            }
        }
        return true
    }

    private func finish(boardID: String, started: Date, out: Data, err: String, status: Int32) {
        checking.remove(boardID)
        let result: BoardAgent.CheckResult
        do {
            result = try BoardAgent.parseCheck(out)
        } catch {
            var why = error.localizedDescription
            if status == 15 || status == 9 { why = "the check took longer than \(Int(Self.timeout / 60)) minutes" }
            else if why == "no output", !err.isEmpty { why = String(err.suffix(200)) }
            store.update(boardID) { $0.agentChecked = started; $0.agentCheckError = why }
            return
        }
        let seen = Set(store.board(boardID)?.agentSeen ?? [])
        var filed: [String] = []
        var taken: [AgentAsk] = []
        for (i, ask) in result.asks.enumerated() {
            let fresh = result.keys[i].filter { !seen.contains($0) && !filed.contains($0) }
            guard !fresh.isEmpty else { continue }
            filed += fresh
            // More messages on an open ask: add them to it.
            if let id = result.continues[i], store.board(boardID)?.asks?.contains(where: { $0.id == id && $0.state == .new }) == true {
                store.update(boardID) { b in
                    guard var list = b.asks, let j = list.firstIndex(where: { $0.id == id }) else { return }
                    list[j].text += "\n" + ask.text
                    list[j].count = (list[j].count ?? 1) + fresh.count
                    list[j].at = Date()
                    b.asks = list
                }
                continue
            }
            if controller?.receiveAsk(ask, boardID: boardID, quiet: true).ok == true { taken.append(ask) }
        }
        // One toast per check, not one per message.
        if let b = store.board(boardID), !taken.isEmpty {
            let name = b.agentConfig.name
            controller?.model?.toast(taken.count == 1
                ? .init(kind: .info, title: "\(name): \(taken[0].from) asked", body: String(taken[0].text.prefix(140)))
                : .init(kind: .info, title: "\(name): \(taken.count) new asks", body: taken.map(\.from).uniqued().joined(separator: ", ")))
        }
        store.update(boardID) { b in
            b.agentChecked = started
            b.agentCheckError = nil
            b.agentSeen = Array(((b.agentSeen ?? []) + filed).suffix(BoardAgent.keepSeen))
            // "Coup (coupsa.slack.com)" → "Coup".
            let w = result.workspace.map { $0.components(separatedBy: " (").first ?? $0 }?.trimmingCharacters(in: .whitespaces)
            if let w, !w.isEmpty, b.agent?.slack.workspace != w {
                var c = b.agentConfig
                c.slack.workspace = w
                b.agent = c
            }
        }
    }

    /// Runs a command in a login shell (for the user's PATH), with a timeout.
    private static func run(_ cmd: String) -> (Data, String, Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", cmd]
        var env = ProcessInfo.processInfo.environment
        for k in env.keys where k.hasPrefix("PITWALL_") || k == "CLAUDECODE" { env[k] = nil }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (Data(), error.localizedDescription, -1) }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        var errData = Data()
        let errReader = DispatchQueue(label: "slack-check-err")
        errReader.async { errData = err.fileHandleForReading.readDataToEndOfFile() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        errReader.sync {}
        return (data, String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), p.terminationStatus)
    }
}

private extension Array where Element == String {
    func uniqued() -> [String] { var seen = Set<String>(); return filter { seen.insert($0).inserted } }
}

/// Your normal Claude Code setup, so board sessions get the same skills.
enum UserClaude {
    static var dir: URL {
        if let d = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !d.isEmpty { return URL(fileURLWithPath: d) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
    }

    /// Install folders of the plugins enabled in your user settings.
    static func enabledPluginDirs() -> [String] {
        guard let s = try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("settings.json"))) as? [String: Any],
              let enabled = s["enabledPlugins"] as? [String: Bool],
              let inst = try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("plugins/installed_plugins.json"))) as? [String: Any]
        else { return [] }
        let plugins = inst["plugins"] as? [String: Any] ?? inst
        return enabled.filter(\.value).keys.sorted().compactMap { key in
            let entries = plugins[key] as? [[String: Any]]
            let path = entries?.first(where: { ($0["scope"] as? String) == "user" })?["installPath"] as? String
                ?? entries?.first?["installPath"] as? String
            return path.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        }
    }
}
