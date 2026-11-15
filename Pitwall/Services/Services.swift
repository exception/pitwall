import Foundation

// MARK: - Git

enum Git {
    /// Runs git synchronously; returns stdout or nil on failure.
    @discardableResult
    static func run(_ args: [String], in dir: String, timeout: TimeInterval = 8) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func toplevel(_ dir: String) -> String? {
        run(["rev-parse", "--show-toplevel"], in: dir)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The top of the linked worktree `dir` is in, or nil when `dir` is in a
    /// main checkout (or not in a repo at all).
    static func linkedWorktree(_ dir: String) -> String? {
        guard let out = run(["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir"], in: dir) else { return nil }
        let l = out.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard l.count == 3 else { return nil }
        let gitDir = URL(fileURLWithPath: l[1]).standardizedFileURL.path
        let common = URL(fileURLWithPath: l[2]).standardizedFileURL.path
        return gitDir == common ? nil : l[0]
    }

    static func branch(_ dir: String) -> String? {
        guard let b = run(["rev-parse", "--abbrev-ref", "HEAD"], in: dir)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !b.isEmpty else { return nil }
        return b == "HEAD" ? (run(["rev-parse", "--short", "HEAD"], in: dir)?.trimmingCharacters(in: .whitespacesAndNewlines)) : b
    }

    /// The branch's fork point from the default branch, so stats show the whole
    /// feature, not just uncommitted changes. Falls back to HEAD.
    static func baseRef(_ dir: String) -> String? {
        for cand in ["origin/HEAD", "origin/main", "origin/master", "main", "master"] {
            if let mb = run(["merge-base", "HEAD", cand], in: dir)?.trimmingCharacters(in: .whitespacesAndNewlines), !mb.isEmpty {
                let head = run(["rev-parse", "HEAD"], in: dir)?.trimmingCharacters(in: .whitespacesAndNewlines)
                // On the default branch itself, compare to HEAD (uncommitted only).
                if mb == head { return "HEAD" }
                return mb
            }
        }
        return "HEAD"
    }

    static func diffStat(_ dir: String) -> (Int, Int)? {
        let base = baseRef(dir) ?? "HEAD"
        guard let out = run(["diff", "--numstat", base], in: dir) else { return nil }
        var a = 0, d = 0
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            if parts.count >= 2 { a += Int(parts[0]) ?? 0; d += Int(parts[1]) ?? 0 }
        }
        return (a, d)
    }

    /// Creates `<repo>/.worktrees/<name>` on a new branch. Returns its path.
    static func addWorktree(repo: String, name: String) -> Result<String, Error> {
        let safe = name.lowercased().replacingOccurrences(of: "[^a-z0-9._/-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-/"))
        let dirName = safe.replacingOccurrences(of: "/", with: "-")
        let path = (repo as NSString).appendingPathComponent(".worktrees/\(dirName)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", repo, "worktree", "add", "-b", safe, path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return .failure(error) }
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return .failure(NSError(domain: "git", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: msg]))
        }
        // Keep worktrees out of `git status` of the main checkout.
        let exclude = (repo as NSString).appendingPathComponent(".git/info/exclude")
        if let s = try? String(contentsOfFile: exclude, encoding: .utf8), !s.contains(".worktrees") {
            try? (s + (s.hasSuffix("\n") ? "" : "\n") + ".worktrees/\n").write(toFile: exclude, atomically: true, encoding: .utf8)
        }
        return .success(path)
    }

    static func removeWorktree(repo: String, path: String) {
        run(["worktree", "remove", "--force", path], in: repo)
    }
}

// MARK: - Session daemon client

enum Sessions {
    static var helperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/pitwall").path
    }

    static func ensureDaemon() {
        DaemonLauncher.ensureRunning(helper: helperPath)
    }

    static func list() -> [SessionInfo] {
        (try? UnixSocket.roundTrip(PitwallPaths.daemonSocket.path, DaemonRequest(op: .list), as: DaemonResponse.self))?.sessions ?? []
    }

    static func kill(_ id: String) {
        _ = try? UnixSocket.roundTrip(PitwallPaths.daemonSocket.path, DaemonRequest(op: .kill, id: id), as: DaemonResponse.self)
    }

    static func scrollback(_ id: String, bytes: Int) -> String? {
        (try? UnixSocket.roundTrip(PitwallPaths.daemonSocket.path, DaemonRequest(op: .scrollback, id: id, maxBytes: bytes),
                                   as: DaemonResponse.self))?.text
    }

    /// Types a prompt into a session no tile is showing (its board isn't
    /// open) and presses Return: attaches at the session's own size, sends
    /// the text as a bracketed paste, then detaches. Works with any daemon
    /// version, since it only uses `attach` and input frames.
    static func submit(_ id: String, text: String, done: ((Bool) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let info = list().first { $0.id == id }
            guard let info, info.alive, !info.attached,
                  let fd = try? UnixSocket.connect(PitwallPaths.daemonSocket.path) else {
                DispatchQueue.main.async { done?(false) }; return
            }
            defer { close(fd) }
            let req = DaemonRequest(op: .attach, id: id, cols: info.cols ?? 120, rows: info.rows ?? 40)
            guard UnixSocket.writeAll(fd, Wire.line(req)),
                  let (line, _) = UnixSocket.readLine(fd),
                  let res = try? Wire.decoder.decode(DaemonResponse.self, from: line), res.ok, res.created != true else {
                DispatchQueue.main.async { done?(false) }; return
            }
            func frame(_ s: String) -> Data {
                let p = Data(s.utf8)
                var d = Data([FrameKind.input.rawValue])
                withUnsafeBytes(of: UInt32(p.count).bigEndian) { d.append(contentsOf: $0) }
                return d + p
            }
            _ = UnixSocket.writeAll(fd, frame("\u{1B}[200~" + text + "\u{1B}[201~"))
            usleep(300_000)
            let ok = UnixSocket.writeAll(fd, frame("\r"))
            usleep(200_000)
            DispatchQueue.main.async { done?(ok) }
        }
    }

    /// Strips ANSI escape sequences and carriage-return overwrites.
    static func plain(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\u{1B}\\[[0-9;?<>=]*[ -/]*[@-~]", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "\u{1B}[()][0-9A-Za-z]", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "\u{1B}[=>78]", with: "", options: .regularExpression)
        let lines = out.components(separatedBy: "\n").map { line -> String in
            // Keep what survives the last carriage return (progress redraws).
            line.components(separatedBy: "\r").last(where: { !$0.isEmpty }) ?? ""
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Claude Code integration

/// Pitwall launches agents with `--settings` (hooks) and `--mcp-config`
/// (canvas tools) files it owns, so the user's own config is never touched.
enum ClaudeIntegration {
    static let hookEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification",
                             "Stop", "SubagentStart", "SubagentStop", "SessionEnd", "PermissionRequest"]

    static var settingsFile: URL { PitwallPaths.support.appendingPathComponent("claude-settings.json") }
    static var mcpFile: URL { PitwallPaths.support.appendingPathComponent("claude-mcp.json") }

    static func writeFiles() {
        let helper = Sessions.helperPath
        var hooks: [String: Any] = [:]
        for e in hookEvents {
            // Permission requests wait for the user to answer in Pitwall.
            let timeout = e == "PermissionRequest" ? 600 : 5
            hooks[e] = [["hooks": [["type": "command", "command": "\(shellQuote(helper)) hook \(e)", "timeout": timeout]]]]
        }
        let settings: [String: Any] = [
            "hooks": hooks,
            // Reports usage to Pitwall, then runs the user's own status line.
            "statusLine": ["type": "command", "command": "\(shellQuote(helper)) statusline", "padding": 0],
        ]
        let mcp: [String: Any] = ["mcpServers": ["pitwall": ["type": "stdio", "command": helper, "args": ["mcp"]]]]
        for (obj, url) in [(settings, settingsFile), (mcp, mcpFile)] {
            if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
                try? d.write(to: url, options: .atomic)
            }
        }
    }

    /// Shell command that starts Claude Code wired into Pitwall.
    static func command(task: String?, images: [URL] = []) -> String {
        var cmd = "claude --settings \(shellQuote(settingsFile.path))"
        for dir in Set(images.map { $0.deletingLastPathComponent().path }).sorted() { cmd += " --add-dir " + shellQuote(dir) }
        cmd += " --mcp-config \(shellQuote(mcpFile.path))"
        let prompt = prompt(task: task ?? "", images: images)
        // `--mcp-config` takes several files, so end options before the task.
        if !prompt.isEmpty { cmd += " -- " + shellQuote(prompt) }
        return cmd
    }

    /// The task with attached image paths appended, so the agent reads them.
    static func prompt(task: String, images: [URL]) -> String {
        guard !images.isEmpty else { return task }
        let list = images.map { "- " + $0.path }.joined(separator: "\n")
        let head = images.count == 1 ? "Attached image (read it before starting):" : "Attached images (read them before starting):"
        return (task.isEmpty ? "" : task + "\n\n") + head + "\n" + list
    }

    /// Short auto-name from a task: first few meaningful words, capitalized.
    static func name(fromTask task: String) -> String {
        let words = task.replacingOccurrences(of: "\n", with: " ").split(separator: " ").prefix(6)
        var s = words.joined(separator: " ")
        if s.count > 42 { s = String(s.prefix(40)) + "…" }
        return s.prefix(1).uppercased() + s.dropFirst()
    }
}
