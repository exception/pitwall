import AppKit
import QuartzCore

/// Listens on the app socket for `pitwall` CLI, hook and MCP requests.
final class ControlServer {
    weak var controller: CanvasController?
    private var source: DispatchSourceRead?
    private var fd: Int32 = -1
    private var socketInode: ino_t = 0

    /// True if a live Pitwall answers on the app socket.
    static func anotherInstanceIsRunning() -> Bool {
        let path = PitwallPaths.appSocket.path
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let res = try? UnixSocket.roundTrip(path, ControlRequest(cmd: "app.ping", tileID: nil, boardID: nil, args: nil),
                                            as: ControlResponse.self, timeout: 1.5)
        return res?.ok == true
    }

    private var watchdog: Timer?
    private static var awake: NSObjectProtocol?
    private static var awakeUntil = Date.distantPast

    /// Keeps timers precise for a while even when Pitwall isn't frontmost
    /// (App Nap otherwise coalesces them, making scripted typing and camera
    /// moves stutter in recordings).
    static func stayResponsive(for seconds: TimeInterval) {
        awakeUntil = max(awakeUntil, Date().addingTimeInterval(seconds))
        if awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Scripted UI")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.1) {
            guard Date() >= awakeUntil, let a = awake else { return }
            ProcessInfo.processInfo.endActivity(a)
            awake = nil
        }
    }

    func start() {
        listen()
        // If the socket file disappears or goes dead (e.g. removed by another
        // process), take it back so hooks keep reaching this app.
        watchdog = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            var st = stat()
            let path = PitwallPaths.appSocket.path
            let ours = stat(path, &st) == 0 && st.st_ino == self.socketInode
            if ours { return }
            DispatchQueue.global().async {
                if Self.anotherInstanceIsRunning() { return }
                DispatchQueue.main.async { NSLog("pitwall: control socket lost; re-listening"); self.relisten() }
            }
        }
    }

    private func relisten() {
        source?.cancel()
        source = nil
        if fd >= 0 { close(fd); fd = -1 }
        listen()
    }

    private func listen() {
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
        watchdog?.invalidate()
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
        if req.cmd == "app.ping" {
            res = ok(.string(String(getpid())))
        } else if req.cmd == "agent.permission" {
            res = handlePermission(req)
        } else if req.cmd == "search" {
            var tiles: [(Board, Tile)] = []
            DispatchQueue.main.sync { tiles = Store.shared.boards.flatMap { b in b.tiles.filter(\.isTerminalBacked).map { (b, $0) } } }
            let hits = CanvasController.searchTerminals(req.args?["query"] ?? "", tiles: tiles, limit: Int(req.args?["limit"] ?? "") ?? 50)
            res = ok(.array(hits.map { h in .object(["board": .string(h.boardName), "tile_id": .string(h.tileID), "tile": .string(h.tileName),
                                                     "line": .string(String(h.line + 1)), "text": .string(h.text)]) }))
        } else {
            DispatchQueue.main.sync { res = self.handle(req) }
        }
        UnixSocket.writeAll(c, Wire.line(res))
    }

    /// A Claude Code permission request: register it on the main thread, then
    /// wait here (off-main) until the user decides in Pitwall.
    private func handlePermission(_ req: ControlRequest) -> ControlResponse {
        guard let raw = req.tileID else { return ok() }
        let args = req.args ?? [:]
        var pending: ApprovalCenter.Pending?
        var tile = raw
        DispatchQueue.main.sync {
            guard let ctl = self.controller, let id = ctl.resolveHookTile(raw, args: args), ctl.store.findTile(id) != nil else { return }
            tile = id
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
        if let v = t.watchCommand { o["command"] = .string(v) }
        if let v = t.prRef { o["pr"] = .string(v) }
        if t.keepAlive == true { o["server"] = .bool(true) }
        if let v = t.background, !v.isEmpty { o["background"] = .string(v.joined(separator: ",")) }
        if let f = t.frameGroupID { o["frame_id"] = .string(f) }
        o["frame"] = .string([t.frame.minX, t.frame.minY, t.frame.width, t.frame.height].map { String(Int($0)) }.joined(separator: ","))
        return .object(o)
    }

    private func handle(_ req: ControlRequest) -> ControlResponse {
        guard let ctl = controller else { return fail("app not ready") }
        let args = req.args ?? [:]
        let from = args["from"]
        let store = ctl.store
        // Place new tiles next to the tile that asked, on its board.
        func near(_ id: String?) -> CGPoint? {
            guard let id, let (b, t) = store.findTile(id) else { return nil }
            return CanvasController.freeSpot(in: b, size: CanvasController.defaultSize(.terminal), near: CGPoint(x: t.frame.maxX + 44, y: t.frame.minY))
        }
        /// The asking tile's board (nil for the plain CLI: the current board).
        func callerBoard(_ id: String?) -> String? { id.flatMap { store.findTile($0)?.board.id } }
        /// Agents never move the user's view: their tiles land on their own
        /// board, without flying the camera or taking focus.
        func onCallerBoard<T>(_ body: () -> T) -> T { ctl.creating(on: callerBoard(from), quiet: from != nil, body) }
        /// The board a request acts on: the caller's, else the current one.
        var actBoard: Board { callerBoard(from).flatMap { store.board($0) } ?? ctl.board }
        func isAgentCaller(_ id: String?) -> Bool {
            guard let id, let t = store.findTile(id)?.tile else { return false }
            return Portals.isAgent(t, hooked: ctl.hookedTiles)
        }

        switch req.cmd {
        case "tile.list":
            let b: Board
            if let q = args["board"], !q.isEmpty {
                switch Portals.board(q, in: store.boards) {
                case .success(let x): b = x
                case .failure(let e): return fail(e.message)
                }
            } else {
                b = req.boardID.flatMap { store.board($0) } ?? store.current
            }
            return ok(.array(b.tiles.map(describe)))

        case "board.list":
            let mine = callerBoard(from)
            return ok(.array(store.boards.map { b in
                var o: [String: JSONValue] = [
                    "id": .string(b.id), "name": .string(b.name),
                    "current": .bool(b.id == store.currentBoardID), "yours": .bool(b.id == mine),
                    "agents": .number(Double(b.tiles.filter { Portals.isAgent($0, hooked: ctl.hookedTiles) }.count)),
                    "portals": .number(Double(store.portals.filter { $0.a.boardID == b.id || $0.b.boardID == b.id }.count)),
                ]
                if let r = b.root { o["root"] = .string(r) }
                let v = b.id == store.currentBoardID ? ctl.canvas.viewport : b.viewport
                o["viewport"] = .string("\(Int(v.origin.x)),\(Int(v.origin.y)),\(String(format: "%.3f", v.zoom))")
                if b.id == store.currentBoardID, let f = ctl.focusedTileID { o["focused"] = .string(f) }
                return .object(o)
            }))

        case "tile.new":
            let cmd = args["command"]
            var at = near(from)
            if let fid = args["frame"] {
                let b = actBoard
                if b.id == store.currentBoardID && from == nil { ctl.pendingPlacement = (nil, fid, Date().addingTimeInterval(5)); at = nil }
                else if b.frames.contains(where: { $0.id == fid }) { at = ctl.creating(on: b.id, quiet: true) { ctl.spot(in: fid, size: CanvasController.defaultSize(.terminal)) } }
            }
            let id = onCallerBoard { ctl.newTerminal(cwd: args["cwd"], command: cmd, at: at, name: args["title"]) }
            if let from { ctl.addLink(from: from, to: id, kind: .spawned) }
            return ok(.string(id))

        case "agent.new":
            let agent = AgentKind(rawValue: args["agent"] ?? "claude") ?? .claude
            if let n = Int(args["count"] ?? ""), n > 1 {
                let ids = onCallerBoard { ctl.fanOut(task: args["task"] ?? "", repo: args["cwd"], agent: agent, count: min(n, 5)) }
                return ok(.string(ids.joined(separator: ",")))
            }
            let id = onCallerBoard {
                ctl.newAgent(task: args["task"] ?? "", repo: args["cwd"], worktree: args["worktree"] == "1",
                             agent: agent, at: near(from), parent: from)
            }
            return ok(.string(id))

        case "tile.diff":
            let id: String?
            if let from { id = onCallerBoard { ctl.newDiff(for: from) } } else {
                guard let dir = args["cwd"], Git.toplevel(dir) != nil else { return fail("not a git repository") }
                id = ctl.newDiff(at: nil, repo: dir)
            }
            return ok(.string(id ?? ""))

        case "link.add":
            guard let a = req.tileID, let b = args["to"], let ta = store.findTile(a), let tb = store.findTile(b) else {
                return fail("both tiles must exist")
            }
            guard ta.board.id == tb.board.id else {
                return fail("those tiles are on different boards; connect them with a portal: pitwall portal \(tb.board.name) --to \(b) (agents: open_portal)")
            }
            ctl.addLink(from: a, to: b)
            if args["handoff"] == "1", let l = store.findTile(a)?.board.links.first(where: { $0.from == a && $0.to == b }) {
                ctl.toggleHandoff(l.id)
            }
            return ok()

        case "tile.watch":
            guard let cmd = args["command"], !cmd.isEmpty else { return fail("command required") }
            let id = onCallerBoard { ctl.newWatch(command: cmd, cwd: args["cwd"], at: near(from), from: from, autoSend: args["autosend"] == "1") }
            return ok(.string(id))

        case "tile.wait":
            let cwd = args["cwd"] ?? from.flatMap { store.findTile($0)?.tile.cwd }
            let repo = (args["pr"]?.isEmpty == false) ? cwd.flatMap(Git.githubRepo) : nil
            guard let spec = CanvasController.waitSpec(run: args["run"], pr: args["pr"], command: args["command"], repo: repo) else {
                return fail("give one of: run (a GitHub Actions run id or URL), pr (number or URL), or command")
            }
            let id = onCallerBoard {
                spec.runID.map { ctl.newRunWait(runID: $0, repo: spec.runRepo, note: args["then"], cwd: cwd, from: from) }
                    ?? ctl.newWait(spec, note: args["then"], cwd: cwd, from: from)
            }
            let wake = from == nil ? "" : " When it finishes (success or failure) Pitwall will send you the result as a new message."
            let how = spec.runID == nil ? " (`\(spec.command)`)" : " (a live Run tile)"
            return ok(.string("Waiting on \(spec.label) in tile \(id)\(how).\(wake) End your turn now instead of polling; don't run gh run watch, sleep or polling loops yourself."))

        case "watch.exit":
            guard let id = req.tileID ?? from, store.findTile(id) != nil else { return ok() }
            ctl.watchExited(id, code: Int(args["code"] ?? "") ?? 1)
            return ok()

        case "rc.start":
            return ok(.string(onCallerBoard { ctl.startRemoteControl(cwd: args["cwd"], worktree: args["worktree"] == "1", at: near(from)) }))

        case "tile.server":
            guard let cmd = args["command"], !cmd.isEmpty else { return fail("command required") }
            return ok(.string(onCallerBoard { ctl.newServer(command: cmd, cwd: args["cwd"], at: near(from), from: from) }))

        case "view":
            Self.stayResponsive(for: (Double(args["duration"] ?? "") ?? 0.32) + 2)
            guard let x = Double(args["x"] ?? ""), let y = Double(args["y"] ?? ""), let z = Double(args["zoom"] ?? "") else { return fail("view <x> <y> <zoom>") }
            ctl.canvas.animate(to: Viewport(origin: CGPoint(x: x, y: y), zoom: CGFloat(z)), duration: Double(args["duration"] ?? "") ?? 0.32)
            return ok()

        case "ui":
            // Drives the interface the way a person would (demos, video, tests).
            guard let model = ctl.model else { return fail("no window") }
            let text = args["text"] ?? ""
            Self.stayResponsive(for: Double(text.count) * 0.045 + 3)
            func type(_ set: @escaping (String) -> Void, then: (() -> Void)? = nil) {
                // One steady timer with no tolerance. (Scheduling every key up
                // front with asyncAfter drifts: GCD's leeway grows with the delay.)
                let chars = Array(text)
                var i = 0
                let timer = Timer(timeInterval: 0.045, repeats: true) { t in
                    i += 1
                    set(String(chars[0..<min(i, chars.count)]))
                    if i >= chars.count {
                        t.invalidate()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { then?() }
                    }
                }
                timer.tolerance = 0
                set("")
                if chars.isEmpty { then?(); return }
                RunLoop.main.add(timer, forMode: .common)
            }
            switch args["action"] ?? "" {
            case "dispatch":
                model.focusDispatch()
                type({ model.dispatchText = $0 }, then: { model.dispatch() })
            case "type":   // dispatch-bar typing without submitting (perf checks)
                model.focusDispatch()
                type({ model.dispatchText = $0 })
            case "search":
                model.searchOpen = true
                model.search.query = ""
                type({ model.search.query = $0 })
            case "inbox": model.inboxOpen = true
            case "approve":
                guard let p = ApprovalCenter.shared.pending.first else { return fail("nothing to approve") }
                ApprovalCenter.shared.decide(p.id, .allow)
            case "close":
                model.inboxOpen = false
                model.searchOpen = false
                model.pickerPoint = nil
            case "sidebar": model.sidebarVisible = text != "hide"
            case "appearance": Prefs.shared.appearance = text
            case "devmode": Prefs.shared.devMode = text != "off"
            case "fullscreen": ctl.toggleFullScreen(text.isEmpty ? nil : text)
            case "snapshot":
                // Renders the window in-process (no screen-recording permission
                // needed). Metal-backed terminals may come out blank.
                guard !text.isEmpty, let v = ctl.canvas.window?.contentView,
                      let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return fail("ui snapshot <path.png>") }
                v.cacheDisplay(in: v.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]),
                      (try? png.write(to: URL(fileURLWithPath: text))) != nil else { return fail("couldn't write \(text)") }
                return ok(.string(text))
            case "click":
                // Tests: a synthetic click at a point in a tile's content (points at
                // 100%, from its top-left; negative y is the header), delivered
                // through this window only.
                let p = text.split(separator: " ").map(String.init)
                guard p.count == 3, let tv = ctl.tileViews[p[0]], let x = Double(p[1]), let y = Double(p[2]),
                      let w = ctl.canvas.window else { return fail("ui click <tile> <x> <y>") }
                let c = tv.content
                let zoom = c.bounds.width > 0 ? c.bounds.width / max(tv.tile.frame.width, 1) : 1
                let local = CGPoint(x: x * zoom, y: c.isFlipped ? y * zoom : c.bounds.height - y * zoom)
                let loc = c.convert(local, to: nil)
                // Header buttons (negative y): press them directly. A synthetic
                // mouse-down would sit in the button's tracking loop waiting for
                // a real mouse-up.
                if let v = w.contentView?.hitTest(loc) as? NSButton {   // hitTest takes superview (window) coordinates
                    v.performClick(nil)
                    return ok(.string("button \(v.accessibilityLabel() ?? v.toolTip ?? "")"))
                }
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    guard let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                    w.sendEvent(e)
                }
                return ok(.string("\(loc.x),\(loc.y)"))
            case "press":
                // Tests: press a visible button in a tile by its accessibility label.
                let p = text.split(separator: " ", maxSplits: 1).map(String.init)
                guard p.count == 2, let tv = ctl.tileViews[p[0]] else { return fail("ui press <tile> <label>") }
                func find(_ v: NSView) -> NSButton? {
                    if let b = v as? NSButton, !b.isHiddenOrHasHiddenAncestor, b.accessibilityLabel() == p[1] { return b }
                    for s in v.subviews { if let b = find(s) { return b } }
                    return nil
                }
                guard let b = find(tv) else { return fail("no button \"\(p[1])\" in \(p[0])") }
                b.performClick(nil)
            default: return fail("ui dispatch|search|inbox|approve|close|sidebar|appearance|devmode|fullscreen|snapshot|click|press")
            }
            return ok()

        case "board.new":
            guard let name = args["name"], !name.isEmpty else { return fail("name required") }
            // An agent adding a board doesn't take the user there.
            let prev = store.currentBoardID
            let b = store.addBoard(name: name, root: args["root"], switchTo: false)
            if from == nil { store.currentBoardID = prev; ctl.switchBoard(b.id) } else { ctl.model?.objectWillChange.send() }
            return ok(.string(b.id))

        case "board.switch":
            guard let q = args["name"], let b = store.boards.first(where: { $0.id == q || $0.name.caseInsensitiveCompare(q) == .orderedSame }) else {
                return fail("no such board")
            }
            ctl.switchBoard(b.id)
            return ok(.string(b.id))

        case "frame.new":
            let ids = (args["tiles"] ?? "").split(separator: ",").map(String.init).filter { store.findTile($0) != nil }
            let owners = Set(ids.compactMap { store.findTile($0)?.board.id })
            guard owners.count <= 1 else { return fail("tiles are on different boards") }
            let bid = owners.first ?? callerBoard(from)
            let fid = ctl.creating(on: bid, quiet: from != nil) { ctl.newFrame(around: ids.isEmpty ? nil : ids, prompt: false) }
            let owner = store.boards.first { $0.frames.contains { $0.id == fid } }?.id
            if let t = args["title"], !t.isEmpty, let owner {
                store.update(owner) { b in if let i = b.frames.firstIndex(where: { $0.id == fid }) { b.frames[i].title = t } }
                ctl.reconcile()
            }
            return ok(.string(fid))

        case "frame.list":
            let b = actBoard
            return ok(.array(b.frames.map { f in
                .object(["id": .string(f.id), "title": .string(f.title), "collapsed": .bool(f.collapsed),
                         "frame": .string([f.frame.minX, f.frame.minY, f.frame.width, f.frame.height].map { String(Int($0)) }.joined(separator: ",")),
                         "members": .string(b.members(of: f.id).map(\.id).joined(separator: ","))])
            }))

        case "frame.collapse", "frame.expand":
            guard let id = args["id"], store.boards.contains(where: { $0.frames.contains { $0.id == id } }) else { return fail("no such frame") }
            ctl.setCollapsed(id, req.cmd == "frame.collapse")
            return ok()

        case "tile.move":
            guard let id = req.tileID, let t = store.findTile(id)?.tile, let x = Double(args["x"] ?? ""), let y = Double(args["y"] ?? "") else {
                return fail("tile.move <id> x y")
            }
            ctl.moveTile(id, to: CGRect(origin: CGPoint(x: x, y: y), size: t.frame.size), persist: true)
            return ok()

        case "layout.save":
            guard let name = args["name"], !name.isEmpty else { return fail("name required") }
            return ok(.string(onCallerBoard { ctl.saveLayout(name: name).id }))

        case "layout.restore":
            guard let name = args["name"], let l = actBoard.layouts?.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id == name }) else {
                return fail("no layout named \(args["name"] ?? "")")
            }
            onCallerBoard { ctl.restoreLayout(l.id) }
            return ok()

        case "layout.list":
            return ok(.array((actBoard.layouts ?? []).map { .object(["id": .string($0.id), "name": .string($0.name), "tiles": .string(String($0.tiles.count))]) }))

        case "search":
            // The scan happens off-main below; this just snapshots the tiles.
            return fail("internal")

        case "tile.pr":
            let repo = args["cwd"] ?? from.flatMap { store.findTile($0)?.tile.cwd } ?? ctl.defaultCwd
            guard let id = onCallerBoard({ ctl.newPR(repo: repo, ref: args["ref"].flatMap { $0.isEmpty ? nil : $0 }, from: from) }) else { return fail("not a git repository: \(repo)") }
            if let from, store.findTile(from)?.tile.kind == .agent { ctl.addLink(from: id, to: from) }
            if args["explain"] == "1", let b = store.findTile(id)?.board, b.id != store.currentBoardID {
                return ok(.string("\(id) (on board \(b.name); it starts checking CI when that board is opened. For a background CI wait use wait_for pr)"))
            }
            return ok(.string(id))

        case "tile.open":
            guard let target = args["target"], !target.isEmpty else { return fail("target required") }
            guard let id = onCallerBoard({ ctl.open(target: target, at: near(from)) }) else { return fail("couldn't open \(target)") }
            if let from { ctl.addLink(from: from, to: id, kind: .spawned) }
            return ok(.string(id))

        case "tile.close":
            guard let id = req.tileID, store.findTile(id) != nil else { return fail("no such tile") }
            // A shell tile running `pitwall tile close` is the user, not an agent.
            ctl.closeTile(id, by: isAgentCaller(from) && from != id ? .agent(from!) : .user)
            return ok()

        case "tile.focus":
            guard let id = req.tileID, let (b, _) = store.findTile(id) else { return fail("no such tile") }
            // The one command that moves the view: it asks to show a tile.
            if b.id != store.currentBoardID { ctl.switchBoard(b.id) }
            ctl.flyTo(tileID: id, fill: false)
            return ok()

        case "tile.read":
            guard let id = req.tileID, let t = store.findTile(id)?.tile else { return fail("no such tile") }
            guard let sid = t.sessionID, t.isTerminalBacked else { return fail("\(t.displayName) is not a terminal") }
            let bytes = Int(args["bytes"] ?? "") ?? 16000
            guard let text = Sessions.scrollback(sid, bytes: bytes) else { return fail("session not running") }
            return ok(.string(Sessions.plain(text)))

        case "tile.send":
            guard let id = req.tileID else { return fail("tile id required") }
            guard let s = ctl.surface(for: id) else {
                // Not on screen: type it into the session directly.
                if let err = ctl.typeInto(id, chunks: Sessions.textChunks(args["text"] ?? "")) { return fail(err) }
                return ok()
            }
            // Text is pasted; line breaks become Return key presses.
            let text = (args["text"] ?? "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            let parts = text.components(separatedBy: "\n")
            for (i, part) in parts.enumerated() {
                if i < parts.count - 1 { s.submit(part) } else if !part.isEmpty { s.sendText(part) }
            }
            return ok()

        case "tile.key":
            guard let id = req.tileID else { return fail("tile id required") }
            guard let s = ctl.surface(for: id) else {
                var bytes = Data()
                for k in (args["keys"] ?? "").split(separator: " ") {
                    guard let b = Sessions.keyBytes[k.lowercased()] else { return fail("unknown key \(k); use up/down/left/right/return/escape/tab/space") }
                    bytes += Data(b.utf8)
                }
                if let err = ctl.typeInto(id, chunks: [(bytes, 50_000)]) { return fail(err) }
                return ok()
            }
            for k in (args["keys"] ?? "").split(separator: " ") {
                guard s.press(key: String(k)) else { return fail("unknown key \(k); use up/down/left/right/return/escape/tab/space") }
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
            guard let raw = req.tileID ?? from, let id = ctl.resolveHookTile(raw, args: args), store.findTile(id) != nil else { return ok() }
            store.updateTile(id) { t in
                if let c = Double(args["cost"] ?? "") { t.costUSD = c }
                if let p = Double(args["context_pct"] ?? "") { t.contextPct = Int(p) }
                if let m = args["model"], !m.isEmpty { t.model = m }
            }
            ctl.reconcileIfVisible(id)
            return ok()

        case "agent.hook":
            guard let raw = req.tileID, let id = ctl.resolveHookTile(raw, args: args) else { return ok() }
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
            let peers = Portals.peers(of: id, boards: store.boards, portals: store.portals).map { p -> JSONValue in
                var d = describe(p.tile)
                if case .object(var o) = d {
                    o["relation"] = .string("portal")
                    o["board"] = .string(p.board.name)
                    o["board_id"] = .string(p.board.id)
                    o["portal_id"] = .string(p.portal.id)
                    d = .object(o)
                }
                return d
            }
            return ok(.array(list + peers))

        case "link.send":
            guard let from, let to = req.tileID else { return fail("tile_id required") }
            switch ctl.sendMessage(from: from, to: to, text: args["text"] ?? "") {
            case .failure(let e): return fail(e.message)
            case .success(let d): return ok(.string(d.text))
            }

        case "portal.open":
            guard let src = from ?? args["source"] else { return fail("run this inside a Pitwall tile") }
            guard let q = args["board"], !q.isEmpty else { return fail("board required") }
            let agent = AgentKind(rawValue: args["agent"] ?? "claude") ?? .claude
            // Anything through the socket is an agent: the Settings toggle and the rate limit apply.
            switch ctl.openPortal(from: src, toBoard: q, task: args["task"], existing: args["to"].flatMap { $0.isEmpty ? nil : $0 },
                                  worktree: args["worktree"] != "0", agent: agent, by: .agent) {
            case .failure(let e): return fail(e.message)
            case .success(let r):
                var o: [String: JSONValue] = [
                    "portal_id": .string(r.portal.id), "tile_id": .string(r.tile.id), "tile_name": .string(r.tile.displayName),
                    "board_id": .string(r.board.id), "board": .string(r.board.name), "created": .bool(r.created),
                    "task_sent": .bool(r.delivery != nil),
                ]
                if let c = store.findTile(r.tile.id)?.tile.cwd { o["cwd"] = .string(c) }
                if let br = store.findTile(r.tile.id)?.tile.branch { o["branch"] = .string(br) }
                if let d = r.delivery { o["delivery"] = .string(d.text) }
                return ok(.object(o))
            }

        case "portal.list":
            guard let src = from ?? args["source"] else { return fail("run this inside a Pitwall tile") }
            return ok(.array(Portals.peers(of: src, boards: store.boards, portals: store.portals).map { p in
                var o: [String: JSONValue] = [
                    "portal_id": .string(p.portal.id), "tile_id": .string(p.tile.id), "tile_name": .string(p.tile.displayName),
                    "board": .string(p.board.name), "board_id": .string(p.board.id), "state": .string(p.tile.state.rawValue),
                ]
                if let c = p.tile.cwd { o["cwd"] = .string(c) }
                if let b = p.tile.branch { o["branch"] = .string(b) }
                return .object(o)
            }))

        case "portal.close":
            guard let src = from ?? args["source"] else { return fail("run this inside a Pitwall tile") }
            let p: Portal
            if let pid = args["portal"], !pid.isEmpty {
                guard let x = store.portal(pid), x.involves(src) else { return fail("no portal \(pid)") }
                p = x
            } else if let to = args["to"], !to.isEmpty {
                let pair: Set<String> = [src, to]
                guard let x = store.portals.first(where: { $0.key == pair }) else { return fail("no portal between this tile and \(to)") }
                p = x
            } else {
                return fail("give portal or to")
            }
            ctl.closePortal(p.id, by: isAgentCaller(src) ? .agent(src) : .user)
            return ok(.string("closed"))

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
