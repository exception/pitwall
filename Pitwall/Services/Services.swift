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

    /// "owner/repo" of the GitHub `origin` remote, so gh can be pointed at the
    /// repo (-R) without needing to run inside a checkout.
    static func githubRepo(_ dir: String) -> String? {
        guard let url = run(["remote", "get-url", "origin"], in: dir)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let r = url.range(of: #"github\.com[:/]([^/\s]+/[^/\s]+?)(\.git)?/?$"#, options: .regularExpression) else { return nil }
        var s = String(url[r]).dropFirst("github.com".count + 1)
        if s.hasSuffix("/") { s = s.dropLast() }
        if s.hasSuffix(".git") { s = s.dropLast(4) }
        return String(s)
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

    /// The daemon's sessions, or nil when it couldn't be reached (so callers
    /// can tell "nothing running" from "didn't hear back").
    static func listResult(timeout: TimeInterval = 30) -> [SessionInfo]? {
        (try? UnixSocket.roundTrip(PitwallPaths.daemonSocket.path, DaemonRequest(op: .list), as: DaemonResponse.self, timeout: timeout))?.sessions
    }

    /// Rough grid for a session started without a surface. The first surface
    /// that attaches resizes it to the real size.
    static func headlessSize(for t: Tile) -> (cols: Int, rows: Int) {
        let fs = max(CGFloat(Prefs.shared.fontSize), 8)
        let size = t.frame.size == .zero ? CanvasController.defaultSize(t.kind) : t.frame.size
        let cols = Int((size.width - 24) / (fs * 0.6))
        let rows = Int((size.height - Theme.headerHeight - 16) / (fs * 1.3))
        return (min(max(cols, 40), 300), min(max(rows, 10), 120))
    }

    /// The env a surface's attach client would forward, minus what only a
    /// real Ghostty surface sets (Pitwall runs Ghostty with
    /// `shell-integration = none`; the daemon does its own zsh integration).
    static func headlessEnv(tileID: String, boardID: String, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env: [String: String] = [
            PitwallEnv.tileID: tileID,
            PitwallEnv.boardID: boardID,
            PitwallEnv.appSocket: PitwallPaths.appSocket.path,
            PitwallEnv.helper: helperPath,
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "ghostty",
        ]
        let terminfo = Bundle.main.resourceURL?.appendingPathComponent("terminfo").path
        if !Prefs.shared.compatTerm, let terminfo, FileManager.default.fileExists(atPath: terminfo) {
            env["TERM"] = "xterm-ghostty"
            env["TERMINFO"] = terminfo
        } else {
            env["TERM"] = "xterm-256color"
        }
        if let r = GhosttyRuntime.resourcesDir { env["GHOSTTY_RESOURCES_DIR"] = r }
        for k in ["LANG", "LC_ALL", "LC_CTYPE"] { if let v = base[k], !v.isEmpty { env[k] = v } }
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env
    }

    static func headlessRequest(for t: Tile, boardID: String, size: (cols: Int, rows: Int)) -> DaemonRequest {
        DaemonRequest(op: .attach, id: t.sessionID ?? t.id, cwd: t.cwd, script: AgentKind.launchCommand(for: t).flatMap { $0.isEmpty ? nil : $0 },
                      env: headlessEnv(tileID: t.id, boardID: boardID), cols: size.cols, rows: size.rows)
    }

    /// Starts a tile's session without a terminal on screen (its board isn't
    /// open): one attach round trip, which creates the session, then detach.
    /// Call on main, right after the tile is stored and only when it has no
    /// view, so no surface can attach in between.
    @discardableResult
    static func startHeadless(_ t: Tile, boardID: String) -> Bool {
        ensureDaemon()
        let req = headlessRequest(for: t, boardID: boardID, size: headlessSize(for: t))
        let res = try? UnixSocket.roundTrip(PitwallPaths.daemonSocket.path, req, as: DaemonResponse.self, timeout: 2)
        return res?.ok == true
    }

    /// Types into a session no tile is showing: attaches at the session's
    /// own size, writes each chunk as input (pausing after it), then detaches.
    /// Only uses `attach` and input frames, so it works with any daemon.
    static func sendInput(_ id: String, chunks: [(Data, UInt32)], done: ((Bool) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let info = list().first { $0.id == id }
            guard let info, info.alive, !info.attached,
                  let fd = try? UnixSocket.connect(PitwallPaths.daemonSocket.path) else {
                DispatchQueue.main.async { done?(false) }; return
            }
            defer { close(fd) }
            let req = DaemonRequest(op: .attach, id: id, cols: info.cols ?? 120, rows: info.rows ?? 40)
            // `created` means it was gone and we just spawned an empty shell: don't type into that.
            guard UnixSocket.writeAll(fd, Wire.line(req)),
                  let (line, _) = UnixSocket.readLine(fd),
                  let res = try? Wire.decoder.decode(DaemonResponse.self, from: line), res.ok, res.created != true else {
                DispatchQueue.main.async { done?(false) }; return
            }
            var ok = true
            for (bytes, pause) in chunks {
                var d = Data([FrameKind.input.rawValue])
                withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { d.append(contentsOf: $0) }
                ok = UnixSocket.writeAll(fd, d + bytes) && ok
                if pause > 0 { usleep(pause) }
            }
            DispatchQueue.main.async { done?(ok) }
        }
    }

    static func paste(_ s: String) -> Data { Data(("\u{1B}[200~" + s + "\u{1B}[201~").utf8) }

    /// Types a prompt into a session no tile is showing and presses Return.
    static func submit(_ id: String, text: String, done: ((Bool) -> Void)? = nil) {
        sendInput(id, chunks: [(paste(text), 300_000), (Data("\r".utf8), 200_000)], done: done)
    }

    /// `tile send` text as chunks, like the surface does it: every line but
    /// the last is pasted then Return; the last is pasted without Return.
    static func textChunks(_ text: String) -> [(Data, UInt32)] {
        let t = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let parts = t.components(separatedBy: "\n")
        var out: [(Data, UInt32)] = []
        for (i, part) in parts.enumerated() {
            if i < parts.count - 1 {
                if !part.isEmpty { out.append((paste(part), 100_000)) }
                out.append((Data("\r".utf8), 100_000))
            } else if !part.isEmpty {
                out.append((paste(part), 50_000))
            }
        }
        return out
    }

    /// Bytes for `TerminalSurfaceView.namedKeys` (arrows in normal cursor
    /// mode; apps with DECCKM on expect ESC O A, but Claude Code takes both).
    static let keyBytes: [String: String] = [
        "return": "\r", "enter": "\r", "escape": "\u{1B}", "esc": "\u{1B}", "tab": "\t", "space": " ",
        "up": "\u{1B}[A", "down": "\u{1B}[B", "right": "\u{1B}[C", "left": "\u{1B}[D",
    ]

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

    /// Shell command that reopens a conversation without sending a prompt.
    /// Unknown conversation: Claude's picker (`--continue` could grab another
    /// tile's, when they share a folder). No transcript (nothing was said, or
    /// it was deleted): a new one, since `--resume` would exit with an error.
    static func resumeCommand(launchedWith original: String?, session: String?, transcript: String?) -> String {
        var cmd = command(task: nil)
        // Our own command line: keep its options (image folders), drop the task.
        if let original, original.hasPrefix("claude --settings "), let options = original.components(separatedBy: " -- ").first {
            cmd = options
        }
        guard let session else { return cmd + " --resume" }
        if let transcript, !FileManager.default.fileExists(atPath: transcript) { return cmd }
        return cmd + " --resume " + shellQuote(session)
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
