import Foundation
import Darwin

let usage = """
pitwall — control Pitwall from the terminal

  pitwall tile list                         List tiles on the current board (JSON)
  pitwall tile new [--cwd DIR] [--title T] [-- CMD...]
                                            Open a terminal tile (optionally running CMD)
  pitwall agent "<task>" [--cwd DIR] [--worktree] [--codex]
                                            Start an agent tile on a task
  pitwall diff [DIR]                        Open a live diff tile for a git checkout
  pitwall remote pair                       Print a one-time link to pair a phone
  pitwall link <tile> <tile>                Connect two tiles so their agents can talk
  pitwall open <path|url>                   Open a file, folder or URL as a tile
  pitwall tile close <id>                   Close a tile
  pitwall tile focus <id>                   Fly the canvas to a tile
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
        ProcessInfo.processInfo.environment[PitwallEnv.appSocket] ?? PitwallPaths.appSocket.path
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
            for key in ["description", "subagent_type", "command", "file_path", "url", "pattern", "prompt"] {
                if let v = ti[key] { a["input." + key] = "\(v)" }
            }
            if let d = try? JSONSerialization.data(withJSONObject: ti), d.count < 8000 {
                a["tool_input_json"] = String(decoding: d, as: UTF8.self)
            }
        }
        if let sug = obj["permission_suggestions"],
           let d = try? JSONSerialization.data(withJSONObject: sug) { a["permission_suggestions"] = String(decoding: d, as: UTF8.self) }
        if let tr = obj["tool_response"] as? [String: Any], let agentId = tr["agentId"] { a["response.agentId"] = "\(agentId)" }
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
        default: task.append(rest[i])
        }
        i += 1
    }
    a["task"] = task.joined(separator: " ")
    do { exit(Control.printResult(try Control.send("agent.new", args: a))) }
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
    guard rest.count == 2 else { fputs("link <tile> <tile>\n", stderr); exit(2) }
    do { exit(Control.printResult(try Control.send("link.add", tile: rest[0], args: ["to": rest[1]]))) }
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
