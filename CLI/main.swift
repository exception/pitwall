import Foundation
import Darwin

let usage = """
pitwall — control Pitwall from the terminal

  pitwall tile list                         List tiles on the current board (JSON)
  pitwall tile new [--cwd DIR] [--title T] [-- CMD...]
                                            Open a terminal tile (optionally running CMD)
  pitwall agent "<task>" [--cwd DIR] [--worktree] [--codex] [--count N]
                                            Start an agent tile on a task
  pitwall diff [DIR]                        Open a live diff tile for a git checkout
  pitwall watch [--cwd DIR] [--auto-send] -- CMD...
                                            Run CMD in a watch tile that turns red when it fails
                                            (--auto-send: failures go to the calling agent)
  pitwall pr [NUMBER|URL] [--cwd DIR]       Follow a pull request (default: this branch's PR)
  pitwall server [--cwd DIR] -- CMD...      Run a dev server that restarts if it crashes
  pitwall search <text|/regex/>             Search every terminal's history (JSON)
  pitwall layout save <name> | <name> | list
                                            Save, restore or list layouts of the current board
  pitwall remote pair                       (WIP) Print a one-time link to pair a phone
  pitwall link <tile> <tile> [--handoff]    Connect two tiles (--handoff: pass results downstream)
  pitwall open <path|url>                   Open a file, folder or URL as a tile
  pitwall tile close <id>                   Close a tile
  pitwall tile focus <id>                   Fly the canvas to a tile
  pitwall tile move <id> <x> <y>            Move a tile (canvas points)
  pitwall tile key <id> <key>...            Press keys in a terminal (up, down, return, escape…)
  pitwall view <x> <y> <zoom> [seconds]     Move the canvas (world point at top-left)
  pitwall ui <action> [text]                Drive the interface (demos): dispatch, search, inbox, approve, close
  pitwall board new <name> [--root DIR] | board switch <name>
  pitwall frame new [--title T] [TILE...]   Put tiles in a new frame
  pitwall frame list | collapse <id> | expand <id>
  pitwall tile read <id> [--bytes N]        Print a tile's recent terminal output
  pitwall tile send <id> <text>             Type text into another terminal tile
  pitwall status <working|waiting|done|error|idle> [message]
                                            Set this tile's agent status
  pitwall notify <message>                  Flag this tile as needing attention
  pitwall mcp                               Run the Pitwall MCP server on stdio
  pitwall sessions                          List daemon sessions (JSON)

Internal:
  pitwall daemon                            Run the session daemon
  pitwall attach --id ID [--cwd DIR] [-- CMD...]
  pitwall hook <ClaudeCodeEvent>            Claude Code hook entry point (reads stdin)
"""

enum Control {
    static var socketPath: String {
        let env = ProcessInfo.processInfo.environment
        guard let inherited = env[PitwallEnv.appSocket] else { return PitwallPaths.appSocket.path }
        // An explicit PITWALL_HOME names the instance: a socket inherited from
        // another one (e.g. a shell inside the real app) must not win.
        if let home = env["PITWALL_HOME"], !home.isEmpty, !inherited.hasPrefix(PitwallPaths.runDir.path) {
            return PitwallPaths.appSocket.path
        }
        return inherited
    }
    static var tileID: String? { ProcessInfo.processInfo.environment[PitwallEnv.tileID] }
    static var boardID: String? { ProcessInfo.processInfo.environment[PitwallEnv.boardID] }

    static func send(_ cmd: String, tile: String? = nil, args: [String: String] = [:], timeout: TimeInterval = 30) throws -> ControlResponse {
        var args = args
        if let me = tileID { args["from"] = me }
        let req = ControlRequest(cmd: cmd, tileID: tile ?? tileID, boardID: boardID, args: args)
        return try UnixSocket.roundTrip(socketPath, req, as: ControlResponse.self, timeout: timeout)
    }

    static func printResult(_ res: ControlResponse) -> Int32 {
        if !res.ok {
            fputs("pitwall: \(res.error ?? "failed")\n", stderr)
            return 1
        }
        if let r = res.result {
            if let s = r.stringValue { print(s) }
            else if let d = try? Wire.encoder.encode(r), let s = String(data: d, encoding: .utf8) { print(s) }
        }
        return 0
    }
}

func runTile(_ args: [String]) -> Int32 {
    guard let sub = args.first else { print(usage); return 2 }
    let rest = Array(args.dropFirst())
    do {
        switch sub {
        case "list", "ls":
            return Control.printResult(try Control.send("tile.list"))
        case "new", "create":
            var a: [String: String] = [:]
            var i = 0
            while i < rest.count {
                switch rest[i] {
                case "--cwd": i += 1; a["cwd"] = rest[safe: i]
                case "--title": i += 1; a["title"] = rest[safe: i]
                case "--frame": i += 1; a["frame"] = rest[safe: i]
                case "--": a["command"] = rest[(i + 1)...].map(shellQuote).joined(separator: " "); i = rest.count
                default: break
                }
                i += 1
            }
            if a["cwd"] == nil { a["cwd"] = FileManager.default.currentDirectoryPath }
            return Control.printResult(try Control.send("tile.new", args: a))
        case "close", "rm":
            guard let id = rest.first else { fputs("tile close <id>\n", stderr); return 2 }
            return Control.printResult(try Control.send("tile.close", tile: id))
        case "key":
            guard rest.count >= 2 else { fputs("tile key <id> <key>... (up down left right return escape tab space)\n", stderr); return 2 }
            return Control.printResult(try Control.send("tile.key", tile: rest[0], args: ["keys": rest.dropFirst().joined(separator: " ")]))
        case "move":
            guard rest.count >= 3 else { fputs("tile move <id> <x> <y>\n", stderr); return 2 }
            return Control.printResult(try Control.send("tile.move", tile: rest[0], args: ["x": rest[1], "y": rest[2]]))
        case "focus":
            guard let id = rest.first else { fputs("tile focus <id>\n", stderr); return 2 }
            return Control.printResult(try Control.send("tile.focus", tile: id))
        case "read":
            guard let id = rest.first else { fputs("tile read <id>\n", stderr); return 2 }
            var a: [String: String] = [:]
            if let i = rest.firstIndex(of: "--bytes"), let n = rest[safe: i + 1] { a["bytes"] = n }
            return Control.printResult(try Control.send("tile.read", tile: id, args: a))
        case "send":
            guard rest.count >= 2 else { fputs("tile send <id> <text>\n", stderr); return 2 }
            return Control.printResult(try Control.send("tile.send", tile: rest[0],
                                                        args: ["text": rest[1...].joined(separator: " ")]))
        default:
            print(usage); return 2
        }
    } catch {
        fputs("pitwall: is the app running? (\(error))\n", stderr)
        return 1
    }
}

/// Claude Code hook entry point. Must never fail the agent.
/// The app may answer with hook output (a Stop "block" carrying a message from
/// a linked tile, or a PermissionRequest decision), printed for Claude Code.
func runHook(_ args: [String]) -> Int32 {
    guard let event = args.first, let tile = Control.tileID else { return 0 }
    // Permission requests wait for the user (Inbox, toast, phone); everything
    // else must return immediately.
    let waits = event == "PermissionRequest"
    alarm(waits ? 590 : 3)
    let input = FileHandle.standardInput.readDataToEndOfFile()
    var a: [String: String] = ["event": event]
    if let obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any] {
        for key in ["message", "tool_name", "session_id", "notification_type", "prompt", "cwd", "transcript_path",
                    "stop_hook_active", "tool_use_id", "agent_id", "agent_type", "last_assistant_message", "permission_mode"] {
            if let v = obj[key] { a[key] = "\(v)" }
        }
        if let ti = obj["tool_input"] as? [String: Any] {
            for key in ["description", "subagent_type", "command", "file_path", "url", "pattern", "prompt", "run_in_background"] {
                if let v = ti[key] { a["input." + key] = "\(v)" }
            }
            if let d = try? JSONSerialization.data(withJSONObject: ti), d.count < 8000 {
                a["tool_input_json"] = String(decoding: d, as: UTF8.self)
            }
        }
        if let sug = obj["permission_suggestions"],
           let d = try? JSONSerialization.data(withJSONObject: sug) { a["permission_suggestions"] = String(decoding: d, as: UTF8.self) }
        if let tr = obj["tool_response"] as? [String: Any] {
            if let agentId = tr["agentId"] { a["response.agentId"] = "\(agentId)" }
            if let status = tr["status"] { a["response.status"] = "\(status)" }
        }
        for key in ["prompt", "last_assistant_message", "input.prompt"] {
            if let v = a[key], v.count > 600 { a[key] = String(v.prefix(600)) }
        }
    }
    if let res = try? Control.send(waits ? "agent.permission" : "agent.hook", tile: tile, args: a, timeout: waits ? 585 : 3), res.ok,
       let out = res.result?["hookOutput"]?.stringValue {
        print(out)
    }
    return 0
}

/// Claude Code statusLine command: report usage to Pitwall, then show the
/// user's own status line (if they have one) so Pitwall doesn't replace it.
func runStatusLine() -> Int32 {
    alarm(4)
    let input = FileHandle.standardInput.readDataToEndOfFile()
    var line = ""
    if let obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any] {
        var a: [String: String] = [:]
        if let cost = obj["cost"] as? [String: Any] {
            if let c = cost["total_cost_usd"] { a["cost"] = "\(c)" }
            if let d = cost["total_duration_ms"] { a["duration_ms"] = "\(d)" }
            if let x = cost["total_lines_added"] { a["lines_added"] = "\(x)" }
            if let x = cost["total_lines_removed"] { a["lines_removed"] = "\(x)" }
        }
        if let cw = obj["context_window"] as? [String: Any] {
            if let p = cw["used_percentage"] { a["context_pct"] = "\(p)" }
            if let t = cw["total_input_tokens"] { a["input_tokens"] = "\(t)" }
            if let t = cw["total_output_tokens"] { a["output_tokens"] = "\(t)" }
        }
        if let m = obj["model"] as? [String: Any], let n = m["display_name"] { a["model"] = "\(n)" }
        if Control.tileID != nil { _ = try? Control.send("agent.usage", args: a, timeout: 1.5) }
        let cost = Double(a["cost"] ?? "") ?? 0
        line = "\(a["model"] ?? "Claude") · $" + String(format: "%.2f", cost) + (a["context_pct"].map { " · \($0)% context" } ?? "")
    }
    // Chain to the user's own statusLine command, if any.
    let userSettings = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
    if let d = try? Data(contentsOf: userSettings),
       let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
       let sl = obj["statusLine"] as? [String: Any], let cmd = sl["command"] as? String, !cmd.isEmpty {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        if (try? p.run()) != nil {
            inPipe.fileHandleForWriting.write(input)
            try? inPipe.fileHandleForWriting.close()
            let out = outPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if !out.isEmpty { FileHandle.standardOutput.write(out); return 0 }
        }
    }
    print(line)
    return 0
}

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"
let rest = Array(args.dropFirst())

switch command {
case "daemon":
    SessionDaemon().run()
case "attach":
    exit(AttachCommand.run(rest))
case "hook":
    exit(runHook(rest))
case "statusline":
    exit(runStatusLine())
case "tile":
    exit(runTile(rest))
case "open":
    guard let target = rest.first else { fputs("open <path|url>\n", stderr); exit(2) }
    var resolved = target
    if !target.contains("://") {
        resolved = URL(fileURLWithPath: target, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL.path
    }
    do { exit(Control.printResult(try Control.send("tile.open", args: ["target": resolved]))) }
    catch { fputs("pitwall: is the app running? (\(error))\n", stderr); exit(1) }
case "agent":
    var a: [String: String] = ["cwd": FileManager.default.currentDirectoryPath]
    var task: [String] = []
    var i = 0
    while i < rest.count {
        switch rest[i] {
        case "--cwd": i += 1; a["cwd"] = rest[safe: i]
        case "--worktree": a["worktree"] = "1"
        case "--codex": a["agent"] = "codex"
        case "--shell": a["agent"] = "shell"
        case "--count": i += 1; a["count"] = rest[safe: i]
        default: task.append(rest[i])
        }
        i += 1
    }
    a["task"] = task.joined(separator: " ")
    do { exit(Control.printResult(try Control.send("agent.new", args: a))) }
    catch { fputs("pitwall: is the app running? (\(error))\n", stderr); exit(1) }
case "watch", "server":
    let cmdName = command
    let isServer = cmdName == "server"
    var a: [String: String] = ["cwd": FileManager.default.currentDirectoryPath]
    var cmd: [String] = []
    var i = 0, rawMode = false
    while i < rest.count {
        if rawMode { cmd.append(rest[i]) }
        else if rest[i] == "--" { rawMode = true }
        else if rest[i] == "--cwd" { i += 1; a["cwd"] = rest[safe: i] }
        else if rest[i] == "--auto-send" { a["autosend"] = "1" }
        else { cmd.append(rest[i]) }
        i += 1
    }
    guard !cmd.isEmpty else { fputs("\(cmdName) [--cwd DIR] -- CMD...\n", stderr); exit(2) }
    a["command"] = cmd.joined(separator: " ")
    do { exit(Control.printResult(try Control.send(isServer ? "tile.server" : "tile.watch", args: a))) }
    catch { fputs("pitwall: is the app running? (\(error))\n", stderr); exit(1) }
case "ui":
    guard let action = rest.first else { fputs("ui dispatch|search <text> | inbox | approve | close | sidebar show|hide | appearance light|dark|system | fullscreen [tile]\n", stderr); exit(2) }
    do { exit(Control.printResult(try Control.send("ui", args: ["action": action, "text": rest.dropFirst().joined(separator: " ")]))) }
    catch { fputs("pitwall: \(error)\n", stderr); exit(1) }
case "view":
    guard rest.count == 3 || rest.count == 4 else { fputs("view <x> <y> <zoom>   (world point at the top-left, zoom 0.1–2)\n", stderr); exit(2) }
    do { exit(Control.printResult(try Control.send("view", args: ["x": rest[0], "y": rest[1], "zoom": rest[2], "duration": rest[safe: 3] ?? "0.32"]))) }
    catch { fputs("pitwall: \(error)\n", stderr); exit(1) }
case "board":
    guard let sub = rest.first, let name = rest[safe: 1] else { fputs("board new <name> [--root DIR] | board switch <name>\n", stderr); exit(2) }
    var a = ["name": name]
    if let i = rest.firstIndex(of: "--root"), let r = rest[safe: i + 1] { a["root"] = URL(fileURLWithPath: r).standardizedFileURL.path }
    do { exit(Control.printResult(try Control.send(sub == "new" ? "board.new" : "board.switch", args: a))) }
    catch { fputs("pitwall: \(error)\n", stderr); exit(1) }
case "frame":
    guard let sub = rest.first else { fputs("frame new|list|collapse|expand\n", stderr); exit(2) }
    do {
        switch sub {
        case "list": exit(Control.printResult(try Control.send("frame.list")))
        case "collapse", "expand":
            guard let id = rest[safe: 1] else { fputs("frame \(sub) <id>\n", stderr); exit(2) }
            exit(Control.printResult(try Control.send("frame.\(sub)", args: ["id": id])))
        case "new":
            var a: [String: String] = [:], ids: [String] = []
            var i = 1
            while i < rest.count {
                if rest[i] == "--title" { i += 1; a["title"] = rest[safe: i] } else { ids.append(rest[i]) }
                i += 1
            }
            a["tiles"] = ids.joined(separator: ",")
            exit(Control.printResult(try Control.send("frame.new", args: a)))
        default: fputs("frame new|list|collapse|expand\n", stderr); exit(2)
        }
    } catch { fputs("pitwall: \(error)\n", stderr); exit(1) }
case "search":
    guard !rest.isEmpty else { fputs("search <text|/regex/>\n", stderr); exit(2) }
    do { exit(Control.printResult(try Control.send("search", args: ["query": rest.joined(separator: " ")], timeout: 60))) }
    catch { fputs("pitwall: \(error)\n", stderr); exit(1) }
case "layout":
    guard let first = rest.first else { fputs("layout save <name> | <name> | list\n", stderr); exit(2) }
    do {
        switch first {
        case "list": exit(Control.printResult(try Control.send("layout.list")))
        case "save": exit(Control.printResult(try Control.send("layout.save", args: ["name": rest.dropFirst().joined(separator: " ")])))
        default: exit(Control.printResult(try Control.send("layout.restore", args: ["name": rest.joined(separator: " ")])))
        }
    } catch { fputs("pitwall: \(error)\n", stderr); exit(1) }
case "watch-exit":
    _ = try? Control.send("watch.exit", args: ["code": rest.first ?? "1"], timeout: 5)
    exit(0)
case "pr":
    var a: [String: String] = ["cwd": FileManager.default.currentDirectoryPath]
    var i = 0
    while i < rest.count {
        if rest[i] == "--cwd" { i += 1; a["cwd"] = rest[safe: i] } else { a["ref"] = rest[i] }
        i += 1
    }
    do { exit(Control.printResult(try Control.send("tile.pr", args: a))) }
    catch { fputs("pitwall: is the app running? (\(error))\n", stderr); exit(1) }
case "diff":
    let dir = rest.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? FileManager.default.currentDirectoryPath
    do { exit(Control.printResult(try Control.send("tile.diff", args: ["cwd": dir]))) }
    catch { fputs("pitwall: \(error)\n", stderr); exit(1) }
case "remote":
    guard rest.first == "pair" else { fputs("remote pair\n", stderr); exit(2) }
    do { exit(Control.printResult(try Control.send("remote.pair"))) }
    catch { fputs("pitwall: \(error)\n", stderr); exit(1) }
case "link":
    let ids = rest.filter { !$0.hasPrefix("--") }
    guard ids.count == 2 else { fputs("link <tile> <tile> [--handoff]\n", stderr); exit(2) }
    do { exit(Control.printResult(try Control.send("link.add", tile: ids[0], args: ["to": ids[1], "handoff": rest.contains("--handoff") ? "1" : "0"]))) }
    catch { fputs("pitwall: \(error)\n", stderr); exit(1) }
case "status":
    guard let state = rest.first else { fputs("status <state> [message]\n", stderr); exit(2) }
    let msg = rest.dropFirst().joined(separator: " ")
    do { exit(Control.printResult(try Control.send("agent.status", args: ["state": state, "message": msg]))) }
    catch { fputs("pitwall: \(error)\n", stderr); exit(1) }
case "notify":
    do { exit(Control.printResult(try Control.send("agent.status", args: ["state": "waiting", "message": rest.joined(separator: " ")]))) }
    catch { fputs("pitwall: \(error)\n", stderr); exit(1) }
case "mcp":
    MCPServer().run()
case "sessions":
    do {
        let res = try UnixSocket.roundTrip(PitwallPaths.daemonSocket.path, DaemonRequest(op: .list), as: DaemonResponse.self)
        let d = try Wire.encoder.encode(res.sessions ?? [])
        print(String(decoding: d, as: UTF8.self))
    } catch { fputs("pitwall: daemon not running (\(error))\n", stderr); exit(1) }
case "help", "--help", "-h":
    print(usage)
default:
    print(usage)
    exit(2)
}
