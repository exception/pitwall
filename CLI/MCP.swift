import Foundation

/// A small MCP server (stdio, newline-delimited JSON-RPC) exposing the canvas
/// to agents: they can open tiles, read other terminals, and report status.
final class MCPServer {
    struct Tool {
        let name: String
        let description: String
        let schema: [String: Any]
        let handler: ([String: Any]) throws -> String
    }

    private lazy var tools: [Tool] = [
        Tool(name: "list_tiles",
             description: "List the tiles on the Pitwall canvas board this agent runs in: id, kind, title, cwd, agent status, branch.",
             schema: ["type": "object", "properties": [:]]) { _ in
            try self.call("tile.list")
        },
        Tool(name: "open_terminal",
             description: "Open a new terminal tile next to this one. Optionally run a command in it (for example a dev server, a test watcher, or another agent).",
             schema: ["type": "object", "properties": [
                "cwd": ["type": "string", "description": "Working directory (absolute). Defaults to this tile's directory."],
                "command": ["type": "string", "description": "Shell command to run in the new tile."],
                "title": ["type": "string", "description": "Tile title."],
             ]]) { a in
            var args: [String: String] = [:]
            for k in ["cwd", "command", "title"] { if let v = a[k] as? String { args[k] = v } }
            if args["cwd"] == nil { args["cwd"] = FileManager.default.currentDirectoryPath }
            return try self.call("tile.new", args: args)
        },
        Tool(name: "open",
             description: "Open a file (markdown, code, image), a folder, or a URL (e.g. a localhost dev server) as a tile on the canvas.",
             schema: ["type": "object", "properties": [
                "target": ["type": "string", "description": "Absolute file path, or http(s) URL."],
             ], "required": ["target"]]) { a in
            try self.call("tile.open", args: ["target": a["target"] as? String ?? ""])
        },
        Tool(name: "read_tile",
             description: "Read the recent output of another terminal tile (e.g. to check a dev server's logs or another agent's progress).",
             schema: ["type": "object", "properties": [
                "tile_id": ["type": "string"],
                "bytes": ["type": "integer", "description": "How many trailing bytes to read (default 16000)."],
             ], "required": ["tile_id"]]) { a in
            try self.call("tile.read", tile: a["tile_id"] as? String,
                          args: ["bytes": String(a["bytes"] as? Int ?? 16000), "plain": "1"])
        },
        Tool(name: "set_status",
             description: "Report this agent's status on its tile so the user sees it at a glance. state: working | waiting | done | error | idle.",
             schema: ["type": "object", "properties": [
                "state": ["type": "string", "enum": ["working", "waiting", "done", "error", "idle"]],
                "message": ["type": "string", "description": "Short summary shown on the tile."],
             ], "required": ["state"]]) { a in
            try self.call("agent.status", args: ["state": a["state"] as? String ?? "idle",
                                                 "message": a["message"] as? String ?? ""])
        },
        Tool(name: "list_links",
             description: "List the tiles this agent is connected to on the canvas (its parent, the agents it spawned, and tiles the user linked by hand). Linked agents can message each other.",
             schema: ["type": "object", "properties": [:]]) { _ in
            try self.call("link.list")
        },
        Tool(name: "send_message",
             description: "Send a message to a connected tile's agent. If it is idle it receives the message as a new prompt; if it is busy it receives it as soon as it finishes its current turn. Use list_links to find tile ids.",
             schema: ["type": "object", "properties": [
                "tile_id": ["type": "string", "description": "A linked tile id."],
                "text": ["type": "string"],
             ], "required": ["tile_id", "text"]]) { a in
            try self.call("link.send", tile: a["tile_id"] as? String, args: ["text": a["text"] as? String ?? ""])
        },
        Tool(name: "read_messages",
             description: "Read (and clear) messages other linked agents have sent to this agent.",
             schema: ["type": "object", "properties": [:]]) { _ in
            try self.call("link.inbox")
        },
        Tool(name: "close_tile",
             description: "Close a tile on the canvas.",
             schema: ["type": "object", "properties": ["tile_id": ["type": "string"]], "required": ["tile_id"]]) { a in
            try self.call("tile.close", tile: a["tile_id"] as? String)
        },
    ]

    private func call(_ cmd: String, tile: String? = nil, args: [String: String] = [:]) throws -> String {
        let res = try Control.send(cmd, tile: tile, args: args)
        if !res.ok { throw NSError(domain: "pitwall", code: 1, userInfo: [NSLocalizedDescriptionKey: res.error ?? "failed"]) }
        guard let r = res.result else { return "ok" }
        if let s = r.stringValue { return s }
        return String(decoding: (try? Wire.encoder.encode(r)) ?? Data(), as: UTF8.self)
    }

    func run() -> Never {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let id = msg["id"]
            let method = msg["method"] as? String ?? ""
            let params = msg["params"] as? [String: Any] ?? [:]
            guard id != nil else { continue } // notification
            switch method {
            case "initialize":
                respond(id, result: [
                    "protocolVersion": (params["protocolVersion"] as? String) ?? "2025-06-18",
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "pitwall", "version": "0.1.0"],
                    "instructions": "Pitwall is the infinite canvas this agent's terminal lives on. Use set_status to keep the user informed, open to show files or dev servers, and open_terminal to start helpers.",
                ])
            case "ping":
                respond(id, result: [:])
            case "tools/list":
                respond(id, result: ["tools": tools.map {
                    ["name": $0.name, "description": $0.description, "inputSchema": $0.schema]
                }])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let args = params["arguments"] as? [String: Any] ?? [:]
                guard let tool = tools.first(where: { $0.name == name }) else {
                    respond(id, error: (-32602, "unknown tool \(name)")); continue
                }
                do {
                    let text = try tool.handler(args)
                    respond(id, result: ["content": [["type": "text", "text": text]]])
                } catch {
                    respond(id, result: ["content": [["type": "text", "text": "\(error.localizedDescription)"]], "isError": true])
                }
            default:
                respond(id, error: (-32601, "method not found"))
            }
        }
        exit(0)
    }

    private func respond(_ id: Any?, result: [String: Any]? = nil, error: (Int, String)? = nil) {
        var obj: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull()]
        if let result { obj["result"] = result }
        if let error { obj["error"] = ["code": error.0, "message": error.1] }
        if let d = try? JSONSerialization.data(withJSONObject: obj) {
            FileHandle.standardOutput.write(d)
            FileHandle.standardOutput.write(Data([0x0A]))
        }
    }
}
