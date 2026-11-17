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
            if let fid = args["frame"] { ctl.pendingPlacement = (nil, fid, Date().addingTimeInterval(5)) }
            let id = ctl.newTerminal(cwd: args["cwd"], command: cmd, at: near(from), name: args["title"])
            if let from { ctl.addLink(from: from, to: id, kind: .spawned) }
            return ok(.string(id))

        case "agent.new":
            ensureBoard(of: from)
            let agent = AgentKind(rawValue: args["agent"] ?? "claude") ?? .claude
            let before = Set(store.current.tiles.map(\.id))
            if let n = Int(args["count"] ?? ""), n > 1 {
                ctl.fanOut(task: args["task"] ?? "", repo: args["cwd"], agent: agent, count: min(n, 5))
                return ok(.string(store.current.tiles.filter { !before.contains($0.id) }.map(\.id).joined(separator: ",")))
            }
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

        case "link.add":
            guard let a = req.tileID, let b = args["to"], store.findTile(a) != nil, store.findTile(b) != nil else {
                return fail("both tiles must exist")
            }
            ctl.addLink(from: a, to: b)
            if args["handoff"] == "1", let l = store.findTile(a)?.board.links.first(where: { $0.from == a && $0.to == b }) {
                ctl.toggleHandoff(l.id)
            }
            return ok()

        case "tile.watch":
            guard let cmd = args["command"], !cmd.isEmpty else { return fail("command required") }
            ensureBoard(of: from)
            let id = ctl.newWatch(command: cmd, cwd: args["cwd"], at: near(from), from: from, autoSend: args["autosend"] == "1")
            return ok(.string(id))

        case "tile.wait":
            let cwd = args["cwd"] ?? from.flatMap { store.findTile($0)?.tile.cwd }
            let repo = (args["pr"]?.isEmpty == false) ? cwd.flatMap(Git.githubRepo) : nil
            guard let spec = CanvasController.waitSpec(run: args["run"], pr: args["pr"], command: args["command"], repo: repo) else {
                return fail("give one of: run (a GitHub Actions run id or URL), pr (number or URL), or command")
            }
            ensureBoard(of: from)
            let id = spec.runID.map { ctl.newRunWait(runID: $0, repo: spec.runRepo, note: args["then"], cwd: cwd, from: from) }
                ?? ctl.newWait(spec, note: args["then"], cwd: cwd, from: from)
            let wake = from == nil ? "" : " When it finishes (success or failure) Pitwall will send you the result as a new message."
            let how = spec.runID == nil ? " (`\(spec.command)`)" : " (a live Run tile)"
            return ok(.string("Waiting on \(spec.label) in tile \(id)\(how).\(wake) End your turn now instead of polling; don't run gh run watch, sleep or polling loops yourself."))

        case "watch.exit":
            guard let id = req.tileID ?? from, store.findTile(id) != nil else { return ok() }
            ctl.watchExited(id, code: Int(args["code"] ?? "") ?? 1)
            return ok()

        case "rc.start":
            ensureBoard(of: from)
            return ok(.string(ctl.startRemoteControl(cwd: args["cwd"], worktree: args["worktree"] == "1", at: near(from))))

        case "tile.server":
            guard let cmd = args["command"], !cmd.isEmpty else { return fail("command required") }
            ensureBoard(of: from)
            return ok(.string(ctl.newServer(command: cmd, cwd: args["cwd"], at: near(from), from: from)))

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
            case "agent": BoardAgentSettingsWindowController.show(boardID: store.current.id)
            case "fullscreen": ctl.toggleFullScreen(text.isEmpty ? nil : text)
            case "snapshot":
                // Renders the window in-process (no screen-recording permission
                // needed). Metal-backed terminals may come out blank.
                // `--key`: the key window instead (e.g. a settings window).
                let keyWindow = text.hasPrefix("--key ")
                let text = keyWindow ? String(text.dropFirst(6)) : text
                guard !text.isEmpty, let v = (keyWindow ? NSApp.keyWindow : ctl.canvas.window)?.contentView,
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
            let b = store.addBoard(name: name, root: args["root"])
            ctl.switchBoard(b.id)
            return ok(.string(b.id))

        case "board.switch":
            guard let q = args["name"], let b = store.boards.first(where: { $0.id == q || $0.name.caseInsensitiveCompare(q) == .orderedSame }) else {
                return fail("no such board")
            }
            ctl.switchBoard(b.id)
            return ok(.string(b.id))

        case "frame.new":
            let ids = (args["tiles"] ?? "").split(separator: ",").map(String.init).filter { store.findTile($0) != nil }
            let before = Set(ctl.board.frames.map(\.id))
            ctl.newFrame(around: ids.isEmpty ? nil : ids, prompt: false)
            guard let f = ctl.board.frames.first(where: { !before.contains($0.id) }) else { return fail("couldn't create frame") }
            if let t = args["title"], !t.isEmpty {
                store.update { b in if let i = b.frames.firstIndex(where: { $0.id == f.id }) { b.frames[i].title = t } }
                ctl.reconcile()
            }
            return ok(.string(f.id))

        case "frame.list":
            return ok(.array(ctl.board.frames.map { f in
                .object(["id": .string(f.id), "title": .string(f.title), "collapsed": .bool(f.collapsed),
                         "frame": .string([f.frame.minX, f.frame.minY, f.frame.width, f.frame.height].map { String(Int($0)) }.joined(separator: ",")),
                         "members": .string(ctl.board.members(of: f.id).map(\.id).joined(separator: ","))])
            }))

        case "frame.collapse", "frame.expand":
            guard let id = args["id"], ctl.board.frames.contains(where: { $0.id == id }) else { return fail("no such frame") }
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
            return ok(.string(ctl.saveLayout(name: name).id))

        case "layout.restore":
            guard let name = args["name"], let l = ctl.board.layouts?.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id == name }) else {
                return fail("no layout named \(args["name"] ?? "")")
            }
            ctl.restoreLayout(l.id)
            return ok()

        case "layout.list":
            return ok(.array((ctl.board.layouts ?? []).map { .object(["id": .string($0.id), "name": .string($0.name), "tiles": .string(String($0.tiles.count))]) }))

        case "search":
            // The scan happens off-main below; this just snapshots the tiles.
            return fail("internal")

        case "tile.pr":
            ensureBoard(of: from)
            let repo = args["cwd"] ?? from.flatMap { store.findTile($0)?.tile.cwd } ?? ctl.defaultCwd
            guard let id = ctl.newPR(repo: repo, ref: args["ref"].flatMap { $0.isEmpty ? nil : $0 }, from: from) else { return fail("not a git repository: \(repo)") }
            if let from, store.findTile(from)?.tile.kind == .agent { ctl.addLink(from: id, to: from) }
            return ok(.string(id))

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

        case "tile.key":
            guard let id = req.tileID, let s = ctl.surface(for: id) else { return fail("no live terminal with that id on this board") }
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

        case "agent.ask":
            // A board by name or id; else the caller's board; else the current one.
            let wanted = args["board"].flatMap { n in store.boards.first { $0.id == n || $0.name.lowercased() == n.lowercased() } }
            if args["board"] != nil, wanted == nil { return fail("no board named \(args["board"]!)") }
            let b = wanted ?? from.flatMap { store.findTile($0)?.board } ?? req.boardID.flatMap { store.board($0) } ?? store.current
            let ask = AgentAsk(source: args["source"] ?? "cli", from: args["from"] ?? NSUserName(),
                               channel: args["channel"], text: args["text"] ?? "", link: args["link"])
            let r = ctl.receiveAsk(ask, boardID: b.id)
            return r.ok ? ok(.string(r.message)) : fail(r.message)

        case "agent.asks":
            let b = args["board"].flatMap { n in store.boards.first { $0.id == n || $0.name.lowercased() == n.lowercased() } } ?? store.current
            return ok(.array((b.asks ?? []).map { a in
                var o: [String: JSONValue] = ["id": .string(a.id), "from": .string(a.from), "text": .string(a.text),
                                              "state": .string(a.state.rawValue), "source": .string(a.source)]
                if let c = a.channel { o["channel"] = .string(c) }
                if let w = a.workerTileID { o["worker"] = .string(w) }
                return .object(o)
            }))

        case "agent.check":
            let b = args["board"].flatMap { n in store.boards.first { $0.id == n || $0.name.lowercased() == n.lowercased() } } ?? store.current
            guard b.agentConfig.slack.enabled else { return fail("\(b.agentConfig.name) isn't listening on Slack on \(b.name)") }
            let since = Double(args["since"] ?? "").map { Date().addingTimeInterval(-$0 * 3600) }
            return SlackChecker.shared.check(boardID: b.id, since: since)
                ? ok(.string("Checking Slack for \(b.name)…")) : fail("a check is already running")

        case "agent.pickup":
            let b = args["board"].flatMap { n in store.boards.first { $0.id == n || $0.name.lowercased() == n.lowercased() } } ?? store.current
            guard let id = args["ask"], let tile = ctl.pickUp(askID: id, boardID: b.id) else { return fail("no new ask with that id") }
            return ok(.string(tile))

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
