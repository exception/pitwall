import AppKit

// MARK: - Portals: agents on different boards, connected
//
// A portal joins two agent tiles on different boards (usually two repos of
// one project). Either end can message the other with send_message. Opening
// one never moves the user's view: the end on screen animates, a toast offers
// Jump, and both tiles get a badge that jumps to the other side.

/// Who closed a portal (or one of its tiles), for the right notifications.
enum PortalCloser: Equatable {
    case user
    case agent(String)
    case auto
    case boardRemoved(String)
}

/// One portal as seen from one of its tiles.
struct PortalBadge: Equatable {
    let portalID: String
    let otherTile: String
    let otherName: String
    let boardID: String
    let boardName: String
    let colorIndex: Int
    var color: NSColor { Theme.boardColors[colorIndex % Theme.boardColors.count] }
}

extension CanvasController {

    struct PortalOpened {
        let portal: Portal
        let tile: Tile
        let board: Board
        let created: Bool
        let delivery: Delivery?
    }

    // MARK: Open

    /// Opens a portal from agent `src` to another board: a new agent there on
    /// `task` (in a new worktree), or the `existing` agent on that board.
    func openPortal(from src: String, toBoard query: String, task: String?, existing: String? = nil,
                    worktree: Bool = true, agent: AgentKind = .claude, by: OpenedBy) -> Result<PortalOpened, PortalError> {
        let plan: Portals.Plan
        switch Portals.validate(source: src, board: query, task: task, existing: existing, by: by,
                                boards: store.boards, portals: store.portals, hooked: hookedTiles,
                                agentPortalsEnabled: Prefs.shared.agentPortals, recentOpens: portalLog[src] ?? []) {
        case .failure(let e): return .failure(e)
        case .success(let p): plan = p
        }
        var result: PortalOpened
        switch plan {
        case let .spawn(source, sourceBoard, target, task):
            let size = Self.defaultSize(.agent)
            let at = Self.freeSpot(in: target, size: size, near: Portals.spotStart(on: target, viewSize: canvas.bounds.size, size: size))
            let dir = target.root ?? NSHomeDirectory()
            var cwd = dir
            var branch: String?
            if worktree, Git.toplevel(dir) != nil, let wt = makeWorktree(task: task, in: dir) { cwd = wt.path; branch = wt.branch }
            let prompt = agent == .claude
                ? Portals.agentPrompt(source: source, sourceBoard: sourceBoard, target: target, cwd: cwd, branch: branch, task: task) : task
            let id = creating(on: target.id, quiet: true) {
                newAgent(task: task, repo: cwd, worktree: false, agent: agent, at: at, prompt: prompt)
            }
            if let branch { store.updateTile(id) { $0.branch = branch; $0.worktree = cwd } }
            let p = Portal(a: PortalEnd(boardID: sourceBoard.id, tileID: source.id), b: PortalEnd(boardID: target.id, tileID: id),
                           openedBy: by.rawValue, task: task)
            store.addPortal(p)
            guard let far = store.findTile(id)?.tile else { return .failure(PortalError("couldn't create the agent")) }
            result = PortalOpened(portal: p, tile: far, board: target, created: true, delivery: nil)
        case let .connect(source, sourceBoard, target, tile, task, existingPortal):
            var p = existingPortal ?? Portal(a: PortalEnd(boardID: sourceBoard.id, tileID: source.id),
                                             b: PortalEnd(boardID: target.id, tileID: tile.id), openedBy: by.rawValue, task: task)
            let created = existingPortal == nil
            if created { p = store.addPortal(p).portal }
            var delivery: Delivery?
            if let task {
                switch sendMessage(from: source.id, to: tile.id, text: Portals.connectMessage(task: task, source: source, sourceBoard: sourceBoard)) {
                case .success(let d): delivery = d
                case .failure: delivery = nil
                }
            }
            result = PortalOpened(portal: p, tile: tile, board: target, created: created, delivery: delivery)
        }
        if by == .agent && result.created { portalLog[src] = (portalLog[src] ?? []).filter { Date().timeIntervalSince($0) < Portals.rateWindow } + [Date()] }
        if result.created || result.delivery != nil { portalFeedback(result, from: src) }
        reconcile()
        return .success(result)
    }

    /// The end on screen animates; a toast offers Jump. The view never moves.
    private func portalFeedback(_ r: PortalOpened, from src: String) {
        guard let (sb, s) = store.findTile(src) else { return }
        // The agent's auto-name is its task, so say each thing once.
        let task = r.created ? r.portal.task : nil
        let what = task.map { r.tile.name == nil ? "New agent: \($0)" : "\(r.tile.displayName): \($0)" }
            ?? (r.created ? "Connected to \(r.tile.displayName)" : "Task sent to \(r.tile.displayName)")
        if sb.id == board.id {
            reconcile()
            tileView(src)?.portalOpened()
            model?.toast(.init(kind: .info, title: "Portal open to \(r.board.name)", body: what,
                               tileID: r.tile.id, portalID: r.portal.id))
        } else if r.board.id == board.id {
            reconcile()
            tileView(r.tile.id)?.portalArrived()
            model?.toast(.init(kind: .info, title: "Portal from \(s.displayName) (\(sb.name))", body: r.portal.task ?? "Connected",
                               tileID: src, portalID: r.portal.id))
        } else {
            model?.toast(.init(kind: .info, title: "Portal: \(sb.name) → \(r.board.name)", body: "\(s.displayName) · \(what)",
                               tileID: r.tile.id, portalID: r.portal.id))
        }
        model?.objectWillChange.send()
    }

    // MARK: Close

    /// Closes a portal. `closing`: the tile whose closing caused it, if any.
    func closePortal(_ id: String, by closer: PortalCloser, closing: String? = nil) {
        guard let p = store.portal(id) else { return }
        store.removePortals { $0.id == id }
        let ends = [p.a.tileID, p.b.tileID]
        for survivor in ends where survivor != closing {
            guard let (sb, st) = store.findTile(survivor), let other = p.other(survivor) else { continue }
            let otherInfo = store.findTile(other.tileID)
            let otherName = otherInfo?.tile.displayName ?? other.tileID
            let otherBoard = otherInfo?.board.name ?? store.board(other.boardID)?.name ?? "another board"
            // Tell a busy agent at its next turn end; never wake an idle one.
            let isActor: Bool = { if case .agent(let x) = closer { return x == survivor }; return false }()
            if Portals.isAgent(st, hooked: hookedTiles), st.state == .working || st.state == .waiting, !isActor {
                store.inbox[survivor, default: []].append(AgentMessage(from: other.tileID, fromName: "Pitwall",
                    text: "The portal to \"\(otherName)\" on board \"\(otherBoard)\" closed. You can no longer message it.", noReply: true))
            }
            // Toast unless the user did it themselves.
            switch closer {
            case .user, .boardRemoved: break
            case .agent(let x):
                let actor = store.findTile(x)?.tile.displayName ?? x
                let title = closing == nil ? "\(actor) closed its portal" : "\(otherName) on \(otherBoard) was closed by \(actor)"
                if !isActor { model?.toast(.init(kind: .info, title: title, body: "Portal to \(st.displayName) closed.", tileID: survivor)) }
            case .auto:
                model?.toast(.init(kind: .info, title: "\(otherName) on \(otherBoard) ended", body: "Portal to \(st.displayName) closed.", tileID: survivor))
            }
            if sb.id == board.id { tileView(survivor)?.portalBadges = portalBadges(for: survivor) }
            else { pendingCollapse[survivor] = Date() }
        }
        portalSeen = portalSeen.filter { !ends.contains($0.key) }
        reconcile()
        model?.objectWillChange.send()
    }

    /// Removing a board closes its portals first (sessions keep running).
    func removeBoard(_ id: String) {
        for p in store.portals where p.a.boardID == id || p.b.boardID == id { closePortal(p.id, by: .boardRemoved(id)) }
        store.removeBoard(id)
        reconcile()
    }

    // MARK: Messages through a portal

    /// Bookkeeping and animation for a message crossing a portal.
    func portalTransit(_ p: Portal, from: String, to: String) {
        store.updatePortal(p.id) { $0.lastActivity = Date(); $0.lastSender = from }
        if let fb = store.findTile(from)?.board, fb.id == board.id { tileView(from)?.portalPulse(outbound: true); tileView(from)?.portalActive = true }
        if let tb = store.findTile(to)?.board, tb.id == board.id {
            portalSeen[to] = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.tileView(to)?.portalPulse(outbound: false) }
            tileView(to)?.portalActive = true
        }
        // The spin winds down 10 s after the last message.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.2) { [weak self] in self?.refreshPortalChrome(boardChanged: false) }
    }

    // MARK: Badges and the ring

    func portalBadges(for tileID: String) -> [PortalBadge] {
        Portals.peers(of: tileID, boards: store.boards, portals: store.portals)
            .sorted { ($0.portal.lastActivity ?? $0.portal.createdAt) > ($1.portal.lastActivity ?? $1.portal.createdAt) }
            .map { PortalBadge(portalID: $0.portal.id, otherTile: $0.tile.id, otherName: $0.tile.displayName,
                               boardID: $0.board.id, boardName: $0.board.name, colorIndex: $0.board.colorIndex) }
    }

    /// Sets badges and spin on the views; on a board change, plays messages
    /// that arrived while it was hidden, and portals that closed meanwhile.
    func refreshPortalChrome(boardChanged: Bool) {
        let now = Date()
        for (id, v) in tileViews {
            let badges = portalBadges(for: id)
            v.portalBadges = badges
            guard !badges.isEmpty else {
                if boardChanged, let at = pendingCollapse.removeValue(forKey: id), now.timeIntervalSince(at) < 60 {
                    v.flashReceive(color: Theme.text3)
                }
                continue
            }
            let mine = store.portals(of: id)
            let recent = mine.contains { ($0.lastActivity.map { now.timeIntervalSince($0) < 10 }) ?? false }
            let working = mine.contains { p in
                [p.a.tileID, p.b.tileID].contains { store.findTile($0)?.tile.state == .working }
            }
            v.portalActive = recent || working
            if boardChanged {
                // Something came through while this board was hidden.
                for p in mine {
                    guard let at = p.lastActivity, now.timeIntervalSince(at) < 15, p.lastSender != id,
                          (portalSeen[id] ?? .distantPast) < at else { continue }
                    portalSeen[id] = at
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak v] in v?.portalPulse(outbound: false) }
                    break
                }
            }
        }
    }

    func portalBadgeClicked(_ tileID: String, from button: NSView) {
        let badges = portalBadges(for: tileID)
        guard !badges.isEmpty else { return }
        if badges.count == 1 { jumpThroughPortal(badges[0].portalID, from: tileID); return }
        let m = NSMenu()
        for b in badges {
            let item = MenuAction("\(b.boardName) · \(b.otherName)") { [weak self] in self?.jumpThroughPortal(b.portalID, from: tileID) }
            item.image = Theme.swatch(b.colorIndex)
            m.addItem(item)
        }
        m.addItem(.separator())
        let close = NSMenuItem(title: "Close portal", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for b in badges { sub.addItem(MenuAction("\(b.otherName) (\(b.boardName))") { [weak self] in self?.closePortal(b.portalID, by: .user) }) }
        close.submenu = sub
        m.addItem(close)
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    }

    // MARK: Jump

    /// Goes to the other end of a portal: a quick zoom into the ring, the
    /// board switch, then the far tile bursts out of its ring.
    func jumpThroughPortal(_ portalID: String, from tileID: String) {
        guard let p = store.portal(portalID), let far = p.other(tileID), let (farBoard, _) = store.findTile(far.tileID) else { return }
        let color = Theme.boardColors[farBoard.colorIndex % Theme.boardColors.count]
        let src = board
        let saved = canvas.viewport
        let arrive = { [weak self] in
            guard let self else { return }
            self.canvas.cancelCamera()
            self.switchBoard(farBoard.id)
            DispatchQueue.main.async { self.portalArrive(at: far.tileID) }
        }
        if farBoard.id == src.id {
            flyTo(tileID: far.tileID, fill: false)
            tileView(far.tileID)?.portalArrived()
            return
        }
        guard Prefs.shared.motion, let v = tileView(tileID), store.findTile(tileID)?.board.id == src.id else { arrive(); return }
        let ring = v.ringCenter
        let world = canvas.toWorld(ring)
        let factor = min(1.6, CanvasView.maxZoom / max(saved.zoom, 0.01))
        var target = saved
        target.zoom = saved.zoom * factor
        target.origin = CGPoint(x: world.x - ring.x / target.zoom, y: world.y - ring.y / target.zoom)
        PortalIris.play(in: canvas.effectsView, at: canvas.effectsView.convert(ring, from: canvas), color: color,
                        zoom: saved.zoom, opening: true, duration: 0.22)
        canvas.animate(to: target, duration: 0.22, persist: false) { [weak self] in
            guard let self else { return }
            // Leave the source board exactly as it was.
            self.canvas.cancelCamera()
            self.canvas.setViewport(saved, persist: false)
            self.store.update(src.id) { $0.viewport = saved }
            arrive()
        }
    }

    /// Flies to the far tile and plays the arrival out of its ring.
    private func portalArrive(at tileID: String) {
        guard let t = board.tile(tileID) else { return }
        let insets = model?.canvasInsets ?? NSEdgeInsets(top: 80, left: 300, bottom: 140, right: 40)
        let target = canvas.viewport(fitting: t.frame.insetBy(dx: -24, dy: -24),
                                     maxZoom: min(1, max(canvas.viewport.zoom, 0.6)), insets: insets)
        // The ring's spot once the camera lands (works before the view exists).
        let corner = CGPoint(x: t.frame.maxX, y: t.frame.minY)
        let landed = CGPoint(x: (corner.x - target.origin.x) * target.zoom, y: (corner.y - target.origin.y) * target.zoom)
        let color = portalBadges(for: tileID).first?.color ?? Theme.blue
        flyTo(tileID: tileID, fill: false)
        PortalIris.play(in: canvas.effectsView, at: canvas.effectsView.convert(landed, from: canvas), color: color,
                        zoom: target.zoom, opening: false, duration: 0.32)
        DispatchQueue.main.asyncAfter(deadline: .now() + (Prefs.shared.motion ? 0.25 : 0)) { [weak self] in
            self?.tileView(tileID)?.portalArrived()
        }
    }

    // MARK: Menu

    /// "Open portal to ▸" plus jump/close items for a tile's context menu.
    func addPortalItems(to m: NSMenu, for t: Tile) {
        guard Portals.isAgent(t, hooked: hookedTiles) else { return }
        let others = store.boards.filter { $0.id != board.id }
        if !others.isEmpty {
            let open = NSMenuItem(title: "Open portal to", action: nil, keyEquivalent: "")
            let boards = NSMenu()
            for b in others {
                let item = NSMenuItem(title: b.name, action: nil, keyEquivalent: "")
                item.image = Theme.swatch(b.colorIndex)
                let sub = NSMenu()
                sub.addItem(MenuAction("New agent…") { [weak self] in self?.promptPortalTask(from: t.id, to: b) })
                let agents = b.tiles.filter { Portals.isAgent($0, hooked: hookedTiles) }
                if !agents.isEmpty { sub.addItem(.separator()) }
                for a in agents {
                    let pair: Set<String> = [t.id, a.id]
                    let existing = store.portals.first { $0.key == pair }
                    let ai = MenuAction(a.displayName) { [weak self] in
                        guard let self else { return }
                        if let existing { self.closePortal(existing.id, by: .user); return }
                        if case .failure(let e) = self.openPortal(from: t.id, toBoard: b.id, task: nil, existing: a.id, by: .user) {
                            self.model?.toast(.init(kind: .error, title: "Couldn't open portal", body: e.message, tileID: t.id))
                        }
                    }
                    ai.state = existing == nil ? .off : .on
                    ai.toolTip = existing == nil ? "Connect to this agent" : "Connected: choose to close the portal"
                    ai.image = Self.stateDot(a.state)
                    sub.addItem(ai)
                }
                item.submenu = sub
                boards.addItem(item)
            }
            open.submenu = boards
            m.addItem(open)
        }
        let badges = portalBadges(for: t.id)
        guard !badges.isEmpty else { return }
        m.addItem(.separator())
        for b in badges {
            m.addItem(MenuAction("Jump to \(b.otherName) (\(b.boardName))") { [weak self] in self?.jumpThroughPortal(b.portalID, from: t.id) })
        }
        for b in badges {
            m.addItem(MenuAction("Close portal to \(b.otherName)") { [weak self] in self?.closePortal(b.portalID, by: .user) })
        }
    }

    private func promptPortalTask(from src: String, to b: Board) {
        promptText(title: "New agent on \(b.name)", value: "", button: "Open Portal") { [weak self] task in
            guard let self else { return }
            let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty else { return }
            if case .failure(let e) = self.openPortal(from: src, toBoard: b.id, task: task, by: .user) {
                self.model?.toast(.init(kind: .error, title: "Couldn't open portal", body: e.message, tileID: src))
            }
        }
    }

    static func stateDot(_ s: AgentState) -> NSImage {
        let img = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
            Theme.color(for: s).setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        return img
    }
}
