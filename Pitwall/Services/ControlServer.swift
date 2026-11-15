import Foundation

/// Listens on the app socket for `pitwall` CLI, hook and MCP requests.
final class ControlServer {
    weak var controller: CanvasController?
    private var source: DispatchSourceRead?
    private var fd: Int32 = -1
    private var socketInode: ino_t = 0

    func start() {
        PitwallPaths.ensure()
        do { fd = try UnixSocket.listen(PitwallPaths.appSocket.path) } catch {
            NSLog("pitwall: control socket failed: \(error)")
            return
        }
        var st = stat()
        if stat(PitwallPaths.appSocket.path, &st) == 0 { socketInode = st.st_ino }
        let fd = self.fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        src.setEventHandler { [weak self] in
            let c = accept(fd, nil, nil)
            guard c >= 0 else { return }
            var on: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            Thread.detachNewThread { self?.serve(c) }
        }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        if fd >= 0 { close(fd) }
        // Only remove the socket if it's still ours (a newer instance may
        // already have replaced it).
        var st = stat()
        if stat(PitwallPaths.appSocket.path, &st) == 0, st.st_ino == socketInode {
            unlink(PitwallPaths.appSocket.path)
        }
    }

    private func serve(_ c: Int32) {
        defer { close(c) }
        guard let (line, _) = UnixSocket.readLine(c),
              let req = try? Wire.decoder.decode(ControlRequest.self, from: line) else { return }
        var res = ControlResponse(ok: false, error: "app not ready")
        if req.cmd == "agent.permission" {
            res = handlePermission(req)
        } else {
            DispatchQueue.main.sync { res = self.handle(req) }
        }
        UnixSocket.writeAll(c, Wire.line(res))
    }

    /// A Claude Code permission request: register it on the main thread, then
    /// wait here (off-main) until the user decides in Pitwall.
    private func handlePermission(_ req: ControlRequest) -> ControlResponse {
        guard let tile = req.tileID else { return ok() }
        let args = req.args ?? [:]
        var pending: ApprovalCenter.Pending?
        DispatchQueue.main.sync {
            guard let ctl = self.controller, ctl.store.findTile(tile) != nil else { return }
            pending = ApprovalCenter.shared.register(tileID: tile, args: args)
            ctl.permissionRequested(tile, pending!)
        }
        guard let p = pending else { return ok() }
        let decision = ApprovalCenter.shared.wait(p.id, timeout: 580)
        DispatchQueue.main.async { self.controller?.permissionResolved(tile, p, decision) }
        guard let d = decision else { return ok() } // fall through to Claude's own prompt
        return ok(.object(["hookOutput": .string(ApprovalCenter.hookOutput(d, suggestions: p.suggestions))]))
    }

    private func ok(_ r: JSONValue? = nil) -> ControlResponse { ControlResponse(ok: true, error: nil, result: r) }
    private func fail(_ e: String) -> ControlResponse { ControlResponse(ok: false, error: e, result: nil) }

    private func describe(_ t: Tile) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(t.id), "kind": .string(t.kind.rawValue), "name": .string(t.displayName),
            "state": .string(t.state.rawValue),
        ]
        if let v = t.cwd { o["cwd"] = .string(v) }
        if let v = t.branch { o["branch"] = .string(v) }
        if let v = t.statusMessage { o["message"] = .string(v) }
        if let v = t.target { o["target"] = .string(v) }
        if let v = t.task { o["task"] = .string(String(v.prefix(300))) }
        return .object(o)
    }

    private func handle(_ req: ControlRequest) -> ControlResponse {
        guard let ctl = controller else { return fail("app not ready") }
        let args = req.args ?? [:]
        let from = args["from"]
        let store = ctl.store
        // Place new tiles next to the tile that asked, on its board.
        func near(_ id: String?) -> CGPoint? {
            guard let id, let t = ctl.board.tile(id) else { return nil }
            return ctl.freeSpot(size: CanvasController.defaultSize(.terminal), near: CGPoint(x: t.frame.maxX + 44, y: t.frame.minY))
        }
        func ensureBoard(of id: String?) {
            if let id, let (b, _) = store.findTile(id), b.id != store.currentBoardID { ctl.switchBoard(b.id) }
        }

        switch req.cmd {
        case "tile.list":
            let b = req.boardID.flatMap { store.board($0) } ?? store.current
            return ok(.array(b.tiles.map(describe)))

        case "tile.new":
            ensureBoard(of: from)
            let cmd = args["command"]
            let id = ctl.newTerminal(cwd: args["cwd"], command: cmd, at: near(from), name: args["title"])
            if let from { ctl.addLink(from: from, to: id, kind: .spawned) }
            return ok(.string(id))

        case "agent.new":
            ensureBoard(of: from)
            let agent = AgentKind(rawValue: args["agent"] ?? "claude") ?? .claude
            let before = Set(store.current.tiles.map(\.id))
            ctl.newAgent(task: args["task"] ?? "", repo: args["cwd"], worktree: args["worktree"] == "1",
                         agent: agent, at: near(from), parent: from)
            let id = store.current.tiles.first { !before.contains($0.id) }?.id ?? ""
            return ok(.string(id))

        case "tile.diff":
            ensureBoard(of: from)
            let before = Set(store.current.tiles.map(\.id))
            if let from { ctl.newDiff(for: from) } else {
                guard let dir = args["cwd"], Git.toplevel(dir) != nil else { return fail("not a git repository") }
                ctl.newDiff(at: nil, repo: dir)
            }
            return ok(.string(store.current.tiles.first { !before.contains($0.id) }?.id ?? ""))

        case "remote.pair":
            guard RemoteServer.shared.running else { return fail("Pitwall Remote is off. Turn it on in Settings › Pitwall Remote.") }
            guard let url = RemoteServer.shared.pairingURL() else { return fail("No network address found") }
            return ok(.string(url.absoluteString))

        case "link.add":
            guard let a = req.tileID, let b = args["to"], store.findTile(a) != nil, store.findTile(b) != nil else {
                return fail("both tiles must exist")
            }
            ctl.addLink(from: a, to: b)
            return ok()

        case "tile.open":
            guard let target = args["target"], !target.isEmpty else { return fail("target required") }
            ensureBoard(of: from)
            guard let id = ctl.open(target: target, at: near(from)) else { return fail("couldn't open \(target)") }
            if let from { ctl.addLink(from: from, to: id, kind: .spawned) }
            return ok(.string(id))

        case "tile.close":
            guard let id = req.tileID, store.findTile(id) != nil else { return fail("no such tile") }
            ctl.closeTile(id)
            return ok()

        case "tile.focus":
            guard let id = req.tileID, store.findTile(id) != nil else { return fail("no such tile") }
            ensureBoard(of: id)
            ctl.flyTo(tileID: id, fill: false)
            return ok()

        case "tile.read":
            guard let id = req.tileID, let t = store.findTile(id)?.tile else { return fail("no such tile") }
            guard let sid = t.sessionID, t.isTerminalBacked else { return fail("\(t.displayName) is not a terminal") }
            let bytes = Int(args["bytes"] ?? "") ?? 16000
            guard let text = Sessions.scrollback(sid, bytes: bytes) else { return fail("session not running") }
            return ok(.string(Sessions.plain(text)))

        case "tile.send":
            guard let id = req.tileID, let s = ctl.surface(for: id) else { return fail("no live terminal with that id on this board") }
            // Text is pasted; line breaks become Return key presses.
            let text = (args["text"] ?? "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            let parts = text.components(separatedBy: "\n")
            for (i, part) in parts.enumerated() {
                if i < parts.count - 1 { s.submit(part) } else if !part.isEmpty { s.sendText(part) }
            }
            return ok()

        case "agent.status":
            guard let id = req.tileID, store.findTile(id) != nil else { return fail("run this inside a Pitwall tile") }
            guard let state = AgentState(rawValue: args["state"] ?? "") ?? (args["state"] == "needs-you" ? .waiting : nil) else {
                return fail("state must be one of: working, waiting, done, error, idle")
            }
            let msg = args["message"].flatMap { $0.isEmpty ? nil : $0 }
            ctl.setState(id, state, message: msg)
            return ok()

        case "agent.usage":
            guard let id = req.tileID ?? from, store.findTile(id) != nil else { return ok() }
            store.updateTile(id) { t in
                if let c = Double(args["cost"] ?? "") { t.costUSD = c }
                if let p = Double(args["context_pct"] ?? "") { t.contextPct = Int(p) }
                if let m = args["model"], !m.isEmpty { t.model = m }
            }
            ctl.reconcileIfVisible(id)
            return ok()

        case "agent.hook":
            guard let id = req.tileID else { return ok() }
            if let out = ctl.handleHook(tileID: id, args: args) { return ok(.object(["hookOutput": .string(out)])) }
            return ok()

        case "link.list":
            guard let id = req.tileID ?? from else { return fail("run this inside a Pitwall tile") }
            let list = ctl.linkedTiles(of: id).map { (l, t) -> JSONValue in
                var d = describe(t)
                if case .object(var o) = d {
                    o["relation"] = .string(l.kind == .manual ? "linked" : (l.from == id ? "child" : "parent"))
                    d = .object(o)
                }
                return d
            }
            return ok(.array(list))

        case "link.send":
            guard let from, let to = req.tileID else { return fail("tile_id required") }
            if let err = ctl.sendMessage(from: from, to: to, text: args["text"] ?? "") { return fail(err) }
            return ok(.string("delivered"))

        case "link.inbox":
            guard let id = from ?? req.tileID else { return fail("run this inside a Pitwall tile") }
            let msgs = store.inbox[id] ?? []
            store.inbox[id] = nil
            return ok(.array(msgs.map { .object(["from": .string($0.from), "fromName": .string($0.fromName), "text": .string($0.text)]) }))

        default:
            return fail("unknown command \(req.cmd)")
        }
    }
}
