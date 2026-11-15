import AppKit
import GhosttyKit
import UserNotifications

/// Glue between the Store (model), the CanvasView and the tile views. Also the
/// agent-status state machine (hooks + terminal signals) and link messaging.
final class CanvasController: NSObject {
    let store = Store.shared
    let canvas: CanvasView
    weak var model: AppModel?

    private(set) var tileViews: [String: TileView] = [:]
    var frameViews: [String: FrameGroupView] = [:]
    private var renderedBoardID: String?
    private(set) var focusedTileID: String?
    private var tickTimer: Timer?
    private var pollTimer: Timer?
    /// Tiles where Claude Code hooks are active (precise status available).
    var hookedTiles = Set<String>()

    var board: Board { store.current }

    init(canvas: CanvasView) {
        self.canvas = canvas
        super.init()
        canvas.controller = self
        tickTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.tileViews.values.forEach { $0.tick() }
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.poll() }
    }

    // MARK: Rendering

    /// Brings views in line with the current board.
    func reconcile() {
        let b = board
        if renderedBoardID != b.id {
            // Switching boards: tear down views (sessions keep running in the daemon).
            for (_, v) in tileViews { v.content.willClose(); v.removeFromSuperview() }
            tileViews.removeAll()
            frameViews.values.forEach { $0.removeFromSuperview() }
            frameViews.removeAll()
            renderedBoardID = b.id
            focusedTileID = nil
            canvas.setViewport(b.viewport, persist: false)
        }
        let ids = Set(b.tiles.map(\.id))
        for (id, v) in tileViews where !ids.contains(id) {
            v.content.willClose()
            v.removeFromSuperview()
            tileViews[id] = nil
        }
        for t in b.tiles.sorted(by: { $0.z < $1.z }) {
            if let v = tileViews[t.id] {
                if v.tile != t { v.update(tile: t) }
            } else {
                let v = TileView(tile: t, content: makeContent(for: t))
                v.canvas = canvas
                tileViews[t.id] = v
                canvas.tilesLayer.addSubview(v)
            }
        }
        // z-order
        let ordered = b.tiles.sorted { $0.z < $1.z }.compactMap { tileViews[$0.id] }
        if canvas.tilesLayer.subviews != ordered as [NSView] {
            canvas.tilesLayer.subviews = ordered
        }
        // frames
        let fids = Set(b.frames.map(\.id))
        for (id, v) in frameViews where !fids.contains(id) { v.removeFromSuperview(); frameViews[id] = nil }
        for f in b.frames {
            if let v = frameViews[f.id] { v.update(f) } else {
                let v = FrameGroupView(group: f)
                v.canvas = canvas
                frameViews[f.id] = v
                canvas.framesLayer.addSubview(v)
            }
            frameViews[f.id]?.summary = summary(of: f.id)
        }
        layoutAll(live: false)
        updateAttentionBadge()
    }

    func layoutAll(live: Bool) {
        let z = canvas.viewport.zoom
        let visible = canvas.bounds.insetBy(dx: -200, dy: -200)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let full = fullScreenTileID
        for t in board.tiles {
            guard let v = tileViews[t.id] else { continue }
            if let full {
                // One tile fills the window at 100%; everything else steps aside.
                if t.id == full {
                    v.frame = fullScreenRect
                    v.isHidden = false
                    v.apply(zoom: 1, live: false)
                } else {
                    v.isHidden = true
                    v.content.setVisible(false)
                }
                continue
            }
            let r = canvas.toView(t.frame)
            let onScreen = r.intersects(visible) && !isCollapsedAway(t, in: board)
            v.frame = r
            v.isHidden = !onScreen
            v.apply(zoom: z, live: live)
        }
        canvas.linksView.isHidden = full != nil
        canvas.framesLayer.isHidden = full != nil
        for f in board.frames {
            guard let v = frameViews[f.id] else { continue }
            v.frame = canvas.toView(f.visibleFrame)
            v.apply(zoom: z)
        }
        CATransaction.commit()
        canvas.linksView.refresh()
        model?.zoom = z
    }

    func tileView(_ id: String) -> TileView? { tileViews[id] }

    /// Re-renders tile headers after a preference that affects them changes.
    func refreshTileChrome() { tileViews.values.forEach { $0.tick() } }

    func tileID(at viewPoint: CGPoint) -> String? {
        board.tiles.sorted { $0.z > $1.z }.first { !isCollapsedAway($0, in: board) && canvas.toView($0.frame).contains(viewPoint) }?.id
    }

    func viewportChanged(_ v: Viewport) {
        store.update { $0.viewport = v }
    }

    // MARK: Content

    private func makeContent(for t: Tile) -> TileContent {
        switch t.kind {
        case .terminal, .agent, .logs:
            Sessions.ensureDaemon()
            let sessionID = t.sessionID ?? t.id
            var cmd = "\(shellQuote(Sessions.helperPath)) attach --id \(sessionID)"
            if let cwd = t.cwd { cmd += " --cwd \(shellQuote(cwd))" }
            if let c = t.command, !c.isEmpty { cmd += " --sh \(shellQuote(c))" }
            let env = [
                PitwallEnv.tileID: t.id,
                PitwallEnv.boardID: board.id,
                PitwallEnv.appSocket: PitwallPaths.appSocket.path,
                PitwallEnv.helper: Sessions.helperPath,
            ]
            let surface = TerminalSurfaceView(launch: .init(command: cmd, workingDirectory: t.cwd, env: env), zoom: 1)
            let session = TerminalSession(tileID: t.id, controller: self)
            surface.delegate = session
            sessions[t.id] = session
            return TerminalTileContent(surface: surface)
        case .browser:
            let b = BrowserTileContent(url: t.target ?? "http://localhost:3000")
            let id = t.id
            b.onURLChange = { [weak self] u in self?.store.updateTile(id) { $0.target = u } }
            return b
        case .note:
            return TextFileTileContent(path: t.target ?? "", markdown: true)
        case .code:
            return TextFileTileContent(path: t.target ?? "", markdown: false)
        case .image:
            return ImageTileContent(path: t.target ?? "")
        case .diff:
            let d = DiffTileContent(repo: t.target ?? t.cwd ?? NSHomeDirectory())
            let id = t.id
            d.onOpenPR = { [weak self] in self?.openPR(diffTile: id) }
            return d
        case .subagent:
            return SubagentTileContent()
        case .pr:
            return PRTileContent(tileID: t.id, repo: t.target ?? t.cwd ?? NSHomeDirectory(), ref: t.prRef, controller: self)
        case .compare:
            let c = CompareTileContent(tileIDs: (t.target ?? "").split(separator: ",").map(String.init))
            c.controller = self
            return c
        }
    }

    private var sessions: [String: TerminalSession] = [:]

    func surface(for tileID: String) -> TerminalSurfaceView? {
        (tileViews[tileID]?.content as? TerminalTileContent)?.surface
    }

    // MARK: Creating tiles

    static func defaultSize(_ k: TileKind) -> CGSize {
        switch k {
        case .terminal, .logs: return CGSize(width: 682, height: 462)
        case .agent: return CGSize(width: 726, height: 506)
        case .browser: return CGSize(width: 770, height: 528)
        case .note: return CGSize(width: 528, height: 638)
        case .code: return CGSize(width: 616, height: 528)
        case .image: return CGSize(width: 396, height: 308)
        case .diff: return CGSize(width: 682, height: 638)
        case .subagent: return CGSize(width: 286, height: 110)
        case .compare: return CGSize(width: 726, height: 330)
        case .pr: return CGSize(width: 528, height: 572)
        }
    }

    /// Finds a free spot: next to the focused tile, else the visible center.
    func freeSpot(size: CGSize, near: CGPoint? = nil) -> CGPoint {
        var p: CGPoint
        if let near { p = near }
        else if let f = focusedTileID.flatMap({ board.tile($0) }) { p = CGPoint(x: f.frame.maxX + 44, y: f.frame.minY) }
        else {
            let v = canvas.visibleWorldRect
            p = CGPoint(x: v.midX - size.width / 2, y: v.midY - size.height / 2 - 40)
        }
        let others = board.tiles.map { $0.frame.insetBy(dx: -20, dy: -20) }
        var r = CGRect(origin: p, size: size)
        var tries = 0
        while others.contains(where: { $0.intersects(r) }) && tries < 60 {
            r.origin.x += 44
            if tries % 12 == 11 { r.origin.x = p.x; r.origin.y += 88 }
            tries += 1
        }
        return CanvasView.snap(r.origin)
    }

    @discardableResult
    func addTile(_ t: Tile, at: CGPoint? = nil, focus: Bool = true, fly: Bool = true) -> String {
        var t = t
        let size = t.frame.size == .zero ? Self.defaultSize(t.kind) : t.frame.size
        let place = placement(for: size, at: at)
        t.frame = CGRect(origin: place.origin, size: size)
        t.frameGroupID = place.frameID
        t.z = board.maxZ + 1
        store.update { $0.tiles.append(t) }
        if let fid = place.frameID { fitFrame(fid) }
        reconcile()
        if focus { self.focus(tileID: t.id, makeFirstResponder: true) }
        if fly, !canvas.visibleWorldRect.insetBy(dx: 40, dy: 40).contains(t.frame) { flyTo(tileID: t.id, fill: false) }
        return t.id
    }

    func newTerminal(cwd: String? = nil, command: String? = nil, at: CGPoint? = nil, name: String? = nil, kind: TileKind = .terminal) -> String {
        var t = Tile(kind: kind, frame: .zero)
        t.cwd = cwd ?? defaultCwd
        t.command = command
        t.name = name
        t.sessionID = t.id
        return addTile(t, at: at)
    }

    var defaultCwd: String {
        if let f = focusedTileID.flatMap({ board.tile($0) }), let c = f.cwd { return c }
        return board.root ?? NSHomeDirectory()
    }

    /// Starts a Claude Code agent on a task, optionally in a new worktree.
    @discardableResult
    func newAgent(task: String, repo: String?, worktree: Bool, agent: AgentKind, at: CGPoint? = nil, parent: String? = nil, name: String? = nil) -> String {
        var cwd = repo ?? defaultCwd
        var branch: String?
        if worktree, let top = Git.toplevel(cwd) {
            let slug = ClaudeIntegration.name(fromTask: task).lowercased()
                .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let words = slug.split(separator: "-").prefix(4).joined(separator: "-")
            let name = "pw/" + String(words.prefix(28)) + "-" + String(UUID().uuidString.prefix(4)).lowercased()
            switch Git.addWorktree(repo: top, name: name) {
            case .success(let p): cwd = p; branch = name
            case .failure(let e): model?.toast(.init(kind: .error, title: "Couldn't create worktree", body: e.localizedDescription))
            }
        }
        var t = Tile(kind: .agent, frame: .zero)
        t.cwd = cwd
        t.sessionID = t.id
        t.task = task.isEmpty ? nil : task
        t.autoName = task.isEmpty ? agent.title : ClaudeIntegration.name(fromTask: task)
        t.name = name
        t.worktree = branch == nil ? nil : cwd
        t.branch = branch
        t.command = agent.command(task: task)
        if !task.isEmpty { t.state = .working; t.stateSince = Date() }
        if agent == .claude { hookedTiles.insert(t.id) }
        let id = addTile(t, at: at)
        if let parent { addLink(from: parent, to: id, kind: .spawned) }
        return id
    }

    /// Opens a path or URL as the right kind of tile.
    @discardableResult
    func open(target: String, at: CGPoint? = nil) -> String? {
        if target.hasPrefix("http://") || target.hasPrefix("https://") || target.hasPrefix("localhost") {
            var t = Tile(kind: .browser, frame: .zero)
            t.target = target
            return addTile(t, at: at)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target, isDirectory: &isDir) else {
            model?.toast(.init(kind: .error, title: "Not found", body: target))
            return nil
        }
        if isDir.boolValue { return newTerminal(cwd: target, at: at) }
        let ext = (target as NSString).pathExtension.lowercased()
        var t: Tile
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "svg", "pdf"].contains(ext) { t = Tile(kind: .image, frame: .zero) }
        else if ["md", "markdown", "mdx", "txt"].contains(ext) { t = Tile(kind: .note, frame: .zero) }
        else { t = Tile(kind: .code, frame: .zero) }
        t.target = target
        t.cwd = (target as NSString).deletingLastPathComponent
        return addTile(t, at: at)
    }

    func newNote(at: CGPoint? = nil) {
        let dir = board.root ?? NSHomeDirectory()
        var name = "Untitled.md"
        var i = 2
        while FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(name)) { name = "Untitled \(i).md"; i += 1 }
        let path = (dir as NSString).appendingPathComponent(name)
        try? "# \n".write(toFile: path, atomically: true, encoding: .utf8)
        open(target: path, at: at)
    }

    func newDiff(for tileID: String? = nil, at: CGPoint? = nil, repo: String? = nil) {
        let src = repo == nil ? (tileID ?? focusedTileID).flatMap { board.tile($0) } : nil
        let dir = repo ?? src?.worktree ?? src?.cwd ?? defaultCwd
        guard let top = Git.toplevel(dir) else {
            model?.toast(.init(kind: .error, title: "Not a git repository", body: dir)); return
        }
        var t = Tile(kind: .diff, frame: .zero)
        t.target = top
        t.cwd = top
        t.branch = Git.branch(top)
        t.autoName = "Diff · " + (t.branch ?? (top as NSString).lastPathComponent)
        var near: CGPoint?
        if let s = src { near = CGPoint(x: s.frame.maxX + 44, y: s.frame.minY) }
        let id = addTile(t, at: at ?? near.map { freeSpot(size: Self.defaultSize(.diff), near: $0) })
        if let s = src { addLink(from: s.id, to: id, kind: .spawned) }
    }

    /// Asks for a command, then opens a watch tile running it.
    func promptWatch(at: CGPoint? = nil) {
        prompt(title: "Watch a command", value: Self.suggestedWatch(in: defaultCwd), button: "Watch") { [weak self] cmd in
            guard let self, !cmd.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            self.newWatch(command: cmd, at: at)
        }
    }

    /// A sensible default: the project's test script.
    static func suggestedWatch(in dir: String) -> String {
        let fm = FileManager.default
        func has(_ f: String) -> Bool { fm.fileExists(atPath: (dir as NSString).appendingPathComponent(f)) }
        if has("package.json") { return has("pnpm-lock.yaml") ? "pnpm test" : (has("bun.lockb") || has("bun.lock") ? "bun test" : "npm test") }
        if has("Cargo.toml") { return "cargo test" }
        if has("go.mod") { return "go test ./..." }
        if has("pyproject.toml") || has("pytest.ini") { return "pytest" }
        if has("Package.swift") { return "swift test" }
        return ""
    }

    func newFrame(around ids: [String]? = nil, prompt askName: Bool = true) {
        let tiles = (ids ?? focusedTileID.map { [$0] } ?? []).compactMap { board.tile($0) }
        var rect: CGRect
        if tiles.isEmpty {
            let v = canvas.visibleWorldRect
            rect = CGRect(x: v.midX - 400, y: v.midY - 300, width: 800, height: 600)
        } else {
            rect = tiles.map(\.frame).reduce(tiles[0].frame) { $0.union($1) }.insetBy(dx: -24, dy: -24)
            rect.origin.y -= 44; rect.size.height += 44
        }
        var f = FrameGroup(title: "New frame", frame: CanvasView.snap(rect))
        f.colorIndex = board.frames.count
        let members = Set(tiles.map(\.id))
        store.update { b in
            b.frames.append(f)
            for i in b.tiles.indices where members.contains(b.tiles[i].id) { b.tiles[i].frameGroupID = f.id }
        }
        reconcile()
        if askName { renameFrame(f.id) }
    }

    // MARK: Moving, closing, focus

    func moveTile(_ id: String, to frame: CGRect, persist: Bool) {
        if persist { store.update { b in if let i = b.tiles.firstIndex(where: { $0.id == id }) { b.tiles[i].frame = frame } } }
        else {
            // Fast path while dragging: no save.
            store.update { b in if let i = b.tiles.firstIndex(where: { $0.id == id }) { b.tiles[i].frame = frame } }
        }
        if let v = tileViews[id], let t = board.tile(id) {
            v.update(tile: t)
            v.frame = canvas.toView(frame)
            v.apply(zoom: canvas.viewport.zoom, live: !persist)
        }
        canvas.linksView.refresh()
        if persist { updateMembership(id) } else { highlightDropFrame(id) }
    }

    func moveFrame(_ id: String, to origin: CGPoint, persist: Bool) {
        guard let f = board.frames.first(where: { $0.id == id }) else { return }
        let dx = origin.x - f.frame.minX, dy = origin.y - f.frame.minY
        guard dx != 0 || dy != 0 || persist else { return }
        let inside = board.members(of: id).map(\.id)
        store.update { b in
            if let i = b.frames.firstIndex(where: { $0.id == id }) { b.frames[i].frame.origin = origin }
            for j in b.tiles.indices where inside.contains(b.tiles[j].id) {
                b.tiles[j].frame.origin.x += dx; b.tiles[j].frame.origin.y += dy
            }
        }
        layoutSubagents()
        reconcile()
        frameViews[id]?.update(board.frames.first { $0.id == id }!)
    }

    func closeTile(_ id: String) {
        guard let t = board.tile(id) else { return }
        if fullScreenTileID == id { fullScreenTileID = nil; model?.fullScreen = false }
        if t.isTerminalBacked, let sid = t.sessionID { Sessions.kill(sid) }
        sessions[id] = nil
        hookedTiles.remove(id)
        store.update { b in
            b.tiles.removeAll { $0.id == id }
            // Sub-agents go with their parent.
            let kids = b.links.filter { $0.from == id && $0.kind == .spawned }.map(\.to)
            b.tiles.removeAll { kids.contains($0.id) && $0.kind == .subagent }
            let remaining = Set(b.tiles.map(\.id))
            b.links.removeAll { l in l.from == id || l.to == id || !remaining.contains(l.to) || !remaining.contains(l.from) }
        }
        store.inbox[id] = nil
        if focusedTileID == id { focusedTileID = nil; model?.focusedTileID = nil }
        reconcile()
    }

    func focus(tileID: String, makeFirstResponder: Bool) {
        guard board.tile(tileID) != nil else { return }
        if focusedTileID != tileID {
            focusedTileID.flatMap { tileViews[$0] }?.isFocusedTile = false
            focusedTileID = tileID
            tileViews[tileID]?.isFocusedTile = true
            model?.focusedTileID = tileID
            if let t = board.tile(tileID), t.z < board.maxZ {
                let z = board.maxZ + 1
                store.update { b in if let i = b.tiles.firstIndex(where: { $0.id == tileID }) { b.tiles[i].z = z } }
                reconcile()
            }
            // Looking at a finished agent acknowledges it.
            if let t = board.tile(tileID), t.state == .done { setState(tileID, .idle, message: t.statusMessage) }
        }
        if makeFirstResponder, let target = tileViews[tileID]?.content.focusTarget, !(tileViews[tileID]?.showsCard ?? true) {
            canvas.window?.makeFirstResponder(target)
        }
    }

    func clearFocus() {
        focusedTileID.flatMap { tileViews[$0] }?.isFocusedTile = false
        focusedTileID = nil
        model?.focusedTileID = nil
    }

    /// Center stage: fly to the tile and fit it, never above 100% so the
    /// terminal font stays at its normal size.
    func flyTo(tileID: String, fill: Bool) {
        revealTile(tileID)
        guard let t = board.tile(tileID) else { return }
        if fullScreenTileID != nil && fullScreenTileID != tileID { exitFullScreen() }
        let insets = model?.canvasInsets ?? NSEdgeInsets(top: 80, left: 300, bottom: 140, right: 40)
        var target = canvas.viewport(fitting: t.frame.insetBy(dx: -24, dy: -24), maxZoom: 1, insets: insets)
        if !fill {
            // Just bring it into view without zooming in further than now.
            target = canvas.viewport(fitting: t.frame.insetBy(dx: -24, dy: -24),
                                     maxZoom: min(1, max(canvas.viewport.zoom, 0.6)), insets: insets)
        }
        canvas.animate(to: target)
        focus(tileID: tileID, makeFirstResponder: true)
    }

    // MARK: Full screen

    private(set) var fullScreenTileID: String?

    func toggleFullScreen(_ id: String? = nil) {
        if let cur = fullScreenTileID, id == nil || id == cur { exitFullScreen(); return }
        guard let id = id ?? focusedTileID, board.tile(id) != nil else { return }
        if fullScreenTileID != nil { exitFullScreen() }
        fullScreenTileID = id
        tileViews[id]?.isFullScreen = true
        model?.fullScreen = true
        focus(tileID: id, makeFirstResponder: true)
        animateLayout()
    }

    func exitFullScreen() {
        guard let id = fullScreenTileID else { return }
        fullScreenTileID = nil
        tileViews[id]?.isFullScreen = false
        model?.fullScreen = false
        animateLayout()
        focus(tileID: id, makeFirstResponder: true)
    }

    /// The rect a full-screen tile fills: the canvas area beside the sidebar.
    private var fullScreenRect: CGRect {
        let left: CGFloat = (model?.sidebarVisible ?? true) ? 272 : 10
        return CGRect(x: left, y: 34, width: canvas.bounds.width - left - 10, height: canvas.bounds.height - 44)
    }

    func animateLayout() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Prefs.shared.motion ? 0.2 : 0
            ctx.allowsImplicitAnimation = true
            layoutAll(live: false)
        }
    }

    func zoomToFit() {
        // What's actually drawn: visible tiles plus frames (collapsed ones as their strip).
        let rects = board.tiles.filter { !isCollapsedAway($0, in: board) }.map(\.frame) + board.frames.map(\.visibleFrame)
        guard let first = rects.first else { return }
        let all = rects.reduce(first) { $0.union($1) }
        let insets = model?.canvasInsets ?? NSEdgeInsets(top: 80, left: 300, bottom: 140, right: 40)
        canvas.animate(to: canvas.viewport(fitting: all.insetBy(dx: -40, dy: -40), maxZoom: 1, insets: insets))
    }

    func setZoom(_ z: CGFloat) {
        canvas.zoom(by: z / canvas.viewport.zoom, around: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), live: true)
    }

    /// ⌘J: jump to the next tile (on any board) that needs the user.
    func nextAttention() {
        var all: [(Board, Tile)] = []
        for b in store.boards { for t in b.tiles where t.state.needsAttention || t.state == .done { all.append((b, t)) } }
        all.sort { ($0.1.state.priority, $0.1.stateSince) < ($1.1.state.priority, $1.1.stateSince) }
        guard let (b, t) = all.first(where: { $0.1.id != focusedTileID }) ?? all.first else { return }
        if b.id != board.id { switchBoard(b.id) }
        flyTo(tileID: t.id, fill: false)
    }

    func switchBoard(_ id: String) {
        guard id != store.currentBoardID else { return }
        if fullScreenTileID != nil { exitFullScreen() }
        store.currentBoardID = id
        store.scheduleSave()
        reconcile()
    }

    /// Snap all tiles into a tidy grid (the "mosaic" layout command).
    func tidy() {
        let tiles = board.tiles.filter { $0.kind != .subagent }.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
        guard !tiles.isEmpty else { return }
        let cols = max(1, Int(Double(tiles.count).squareRoot().rounded(.up)))
        let origin = tiles.map(\.frame.origin).reduce(CGPoint(x: CGFloat.infinity, y: .infinity)) { CGPoint(x: min($0.x, $1.x), y: min($0.y, $1.y)) }
        var x = origin.x, y = origin.y, rowH: CGFloat = 0
        var frames: [String: CGRect] = [:]
        for (i, t) in tiles.enumerated() {
            if i > 0 && i % cols == 0 { x = origin.x; y += rowH + 44; rowH = 0 }
            frames[t.id] = CGRect(origin: CanvasView.snap(CGPoint(x: x, y: y)), size: t.frame.size)
            x += t.frame.width + 44
            rowH = max(rowH, t.frame.height)
        }
        store.update { b in for i in b.tiles.indices { if let f = frames[b.tiles[i].id] { b.tiles[i].frame = f } } }
        reconcile()
        layoutSubagents()
        zoomToFit()
    }

    // MARK: Rename

    func renameTile(_ id: String) {
        guard let t = board.tile(id) else { return }
        prompt(title: "Rename tile", value: t.displayName) { [weak self] s in
            self?.store.updateTile(id) { $0.name = s.isEmpty ? nil : s }
            self?.reconcile()
        }
    }

    func renameFrame(_ id: String) {
        guard let f = board.frames.first(where: { $0.id == id }) else { return }
        prompt(title: "Name this frame", value: f.title) { [weak self] s in
            self?.store.update { b in if let i = b.frames.firstIndex(where: { $0.id == id }) { b.frames[i].title = s.isEmpty ? "Frame" : s } }
            self?.reconcile()
        }
    }

    func promptText(title: String, value: String, button: String, done: @escaping (String) -> Void) {
        prompt(title: title, value: value, button: button, done: done)
    }

    private func prompt(title: String, value: String, button: String = "Save", done: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if let w = canvas.window {
            alert.beginSheetModal(for: w) { r in if r == .alertFirstButtonReturn { done(field.stringValue) } }
        }
    }

    // MARK: Menus

    func contextMenu(for id: String) -> NSMenu? {
        guard let t = board.tile(id) else { return nil }
        let m = NSMenu()
        m.addItem(MenuAction("Rename…") { [weak self] in self?.renameTile(id) })
        m.addItem(MenuAction("Focus") { [weak self] in self?.flyTo(tileID: id, fill: true) })
        if t.isTerminalBacked || t.kind == .diff {
            m.addItem(MenuAction("Show diff") { [weak self] in self?.newDiff(for: id) })
        }
        m.addItem(MenuAction("Put in a frame") { [weak self] in self?.newFrame(around: [id]) })
        if t.isTerminalBacked {
            m.addItem(MenuAction("Restart session") { [weak self] in self?.restartSession(id) })
        }
        if t.kind == .logs, t.watchCommand != nil {
            m.addItem(MenuAction(t.keepAlive == true ? "Restart server" : "Run again") { [weak self] in self?.rerunWatch(id) })
            if t.keepAlive == true {
                m.addItem(MenuAction("Stop server") { [weak self] in self?.stopServer(id) })
            } else if t.state != .working {
                m.addItem(MenuAction("Keep running (restart on exit)") { [weak self] in
                    self?.store.updateTile(id) { $0.keepAlive = true }
                    self?.rerunWatch(id)
                })
            }
        }
        if t.kind == .logs || t.kind == .pr {
            m.addItem(MenuAction(t.kind == .pr ? "Send failures to agent" : "Send output to agent") { [weak self] in
                guard let self else { return }
                if t.kind == .pr, let info = (self.tileView(id)?.content as? PRTileContent)?.info { self.sendPRFailures(id, info) }
                else { self.sendFailure(id) }
            })
            let auto = MenuAction("Send failures automatically") { [weak self] in self?.toggleAutoSend(id) }
            auto.state = t.autoSend == true ? .on : .off
            m.addItem(auto)
        }
        if t.kind == .agent || t.kind == .diff {
            m.addItem(MenuAction("Follow pull request") { [weak self] in
                guard let self, let dir = t.worktree ?? t.target ?? t.cwd, let pr = self.newPR(repo: dir, from: id) else { return }
                if t.kind == .agent { self.addLink(from: pr, to: id) }
            })
        }
        if t.kind == .agent {
            m.addItem(MenuAction("Review with a new agent") { [weak self] in self?.startReview(of: id) })
        }
        let links = board.links.filter { $0.from == id || $0.to == id }
        if !links.isEmpty {
            m.addItem(.separator())
            for l in links where l.from == id {
                let name = board.tile(l.to)?.displayName ?? l.to
                let item = MenuAction("Hand off to \(name) when done") { [weak self] in self?.toggleHandoff(l.id) }
                item.state = l.isHandoff ? .on : .off
                m.addItem(item)
            }
            for l in links {
                let other = l.from == id ? l.to : l.from
                let name = board.tile(other)?.displayName ?? other
                m.addItem(MenuAction("Unlink \(name)") { [weak self] in self?.removeLink(l.id) })
            }
        }
        m.addItem(.separator())
        m.addItem(MenuAction("Close tile") { [weak self] in self?.closeTile(id) })
        return m
    }

    func canvasMenu(at p: CGPoint) -> NSMenu? {
        let w = canvas.toWorld(p)
        let m = NSMenu()
        m.addItem(MenuAction("New agent…") { [weak self] in
            guard let self else { return }
            self.pendingPlacement = (w, self.frame(at: w)?.id, Date().addingTimeInterval(120))
            self.model?.focusDispatch()
        })
        m.addItem(MenuAction("New terminal") { [weak self] in _ = self?.newTerminal(at: w) })
        m.addItem(MenuAction("New note") { [weak self] in self?.newNote(at: w) })
        m.addItem(MenuAction("New browser") { [weak self] in self?.open(target: "http://localhost:3000", at: w) })
        m.addItem(MenuAction("Watch a command…") { [weak self] in self?.promptWatch(at: w) })
        m.addItem(MenuAction("Run dev server…") { [weak self] in self?.promptServer(at: w) })
        m.addItem(MenuAction("Follow pull request") { [weak self] in
            guard let self else { return }
            self.newPR(repo: self.board.root ?? self.defaultCwd, at: w)
        })
        m.addItem(MenuAction("New frame") { [weak self] in self?.newFrame() })
        m.addItem(.separator())
        m.addItem(MenuAction("Tidy up") { [weak self] in self?.tidy() })
        m.addItem(MenuAction("Save layout…") { [weak self] in self?.promptSaveLayout() })
        m.addItem(MenuAction("Zoom to fit") { [weak self] in self?.zoomToFit() })
        return m
    }

    func frameMenu(_ id: String) -> NSMenu {
        let m = NSMenu()
        let collapsed = board.frames.first { $0.id == id }?.collapsed ?? false
        m.addItem(MenuAction("New agent here…") { [weak self] in self?.newAgentInFrame(id) })
        m.addItem(MenuAction("New terminal here") { [weak self] in self?.newTerminalInFrame(id) })
        m.addItem(.separator())
        m.addItem(MenuAction(collapsed ? "Expand" : "Collapse") { [weak self] in self?.toggleCollapsed(id) })
        m.addItem(MenuAction("Zoom to frame") { [weak self] in self?.zoomToFrame(id) })
        m.addItem(MenuAction("Tidy tiles") { [weak self] in self?.tidyFrame(id) })
        m.addItem(MenuAction("Rename…") { [weak self] in self?.renameFrame(id) })
        m.addItem(.separator())
        m.addItem(MenuAction("Close all tiles in frame…") { [weak self] in self?.closeTilesInFrame(id) })
        m.addItem(MenuAction("Delete frame (keep tiles)") { [weak self] in self?.deleteFrame(id) })
        return m
    }

    // MARK: Picker

    func showPicker(at viewPoint: CGPoint) { model?.showPicker(world: canvas.toWorld(viewPoint), view: viewPoint) }
    func dismissPicker() { model?.pickerPoint = nil }

    // MARK: Links & messaging

    func addLink(from: String, to: String, kind: Link.Kind = .manual) {
        guard from != to, !board.links.contains(where: { ($0.from == from && $0.to == to) || ($0.from == to && $0.to == from) }) else { return }
        store.update { $0.links.append(Link(from: from, to: to, kind: kind)) }
        canvas.linksView.refresh()
    }

    func removeLink(_ id: String) {
        store.update { $0.links.removeAll { $0.id == id } }
        canvas.linksView.refresh()
    }

    func linkedTiles(of id: String) -> [(Link, Tile)] {
        guard let (b, _) = store.findTile(id) else { return [] }
        return b.links.compactMap { l in
            let other = l.from == id ? l.to : (l.to == id ? l.from : nil)
            return other.flatMap { b.tile($0) }.map { (l, $0) }
        }
    }

    /// Delivers a message from one tile's agent to a linked tile's agent.
    func sendMessage(from: String, to: String, text: String) -> String? {
        guard let (b, target) = store.findTile(to) else { return "No such tile" }
        guard let link = b.links.first(where: { ($0.from == from && $0.to == to) || ($0.from == to && $0.to == from) }) else {
            return "Those tiles aren't linked. Ask the user to connect them on the canvas."
        }
        guard target.kind == .agent || hookedTiles.contains(to) else { return "\(target.displayName) isn't running an agent." }
        let fromName = store.findTile(from)?.tile.displayName ?? from
        let msg = AgentMessage(from: from, fromName: fromName, text: text)
        store.update(b.id) { bb in if let i = bb.links.firstIndex(where: { $0.id == link.id }) { bb.links[i].lastActivity = Date() } }
        if b.id == board.id { canvas.linksView.pulse(link: link, fromTile: from, text: text) }
        if target.state == .working || target.state == .waiting || surface(for: to) == nil {
            store.inbox[to, default: []].append(msg) // delivered by the Stop hook
        } else {
            surface(for: to)?.submit(Self.format(msg))
            setState(to, .working, message: "Message from \(fromName)")
        }
        return nil
    }

    static func format(_ m: AgentMessage) -> String {
        "[Pitwall message from \"\(m.fromName)\" (tile \(m.from)); reply with the pitwall send_message tool] \(m.text)"
    }

    // MARK: Agent status

    func setState(_ id: String, _ s: AgentState, message: String? = nil) {
        guard let (_, t) = store.findTile(id) else { return }
        let changed = t.state != s
        store.updateTile(id) {
            if changed { $0.stateSince = Date() }
            $0.state = s
            if let message { $0.statusMessage = message }
        }
        if changed && s == .waiting { notifyAttention(id) }
        // It no longer needs you: drop its "needs you" toasts.
        if changed && t.state == .waiting && s != .waiting { model?.toasts.removeAll { $0.tileID == id && $0.kind == .attention } }
        if changed { model?.objectWillChange.send(); updateAttentionBadge() }
        if store.currentBoardID == store.findTile(id)?.board.id { reconcile() }
    }

    private func updateAttentionBadge() {
        let n = store.boards.flatMap(\.tiles).filter { $0.state == .waiting }.count
        NSApp.dockTile.badgeLabel = n > 0 && Prefs.shared.dockBadge ? "\(n)" : nil
        model?.refreshAttention()
    }

    private func notifyAttention(_ id: String) {
        guard let (_, t) = store.findTile(id) else { return }
        let visibleAndFocused = NSApp.isActive && focusedTileID == id
        if visibleAndFocused { return }
        let prefs = Prefs.shared
        if prefs.toasts {
            model?.toast(.init(kind: .attention, title: t.displayName, body: t.statusMessage ?? "Needs your input", tileID: id))
        }
        if prefs.sound { NSSound(named: "Glass")?.play() }
        if !NSApp.isActive && prefs.systemNotifications {
            let c = UNMutableNotificationContent()
            c.title = t.displayName
            c.body = t.statusMessage ?? "Needs your input"
            c.userInfo = ["tile": id]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "pw-\(id)-\(Date().timeIntervalSince1970)", content: c, trigger: nil))
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    /// Claude Code hook events → status. Returns optional hook output JSON.
    func handleHook(tileID: String, args: [String: String]) -> String? {
        guard store.findTile(tileID) != nil else { return nil }
        hookedTiles.insert(tileID)
        screenWaiting.remove(tileID)
        let event = args["event"] ?? ""
        let tool = args["tool_name"] ?? ""
        // Any progress means a pending permission was answered in the terminal.
        if ["PostToolUse", "UserPromptSubmit", "Stop", "SessionEnd"].contains(event) {
            ApprovalCenter.shared.passThrough(tileID: tileID)
        }
        switch event {
        case "UserPromptSubmit":
            if let p = args["prompt"], !p.isEmpty {
                Timelines.shared.add(tileID, p.hasPrefix("[Pitwall message") ? .message : .prompt, p)
            }
        case "PreToolUse":
            if let d = describe(tool: tool, args: args) { Timelines.shared.add(tileID, tool == "Task" || tool == "Agent" ? .subagent : .tool, d) }
        case "Notification":
            if let m = args["message"] { Timelines.shared.add(tileID, .notification, m) }
        case "Stop":
            Timelines.shared.add(tileID, .done, args["last_assistant_message"].map { String($0.prefix(200)) } ?? "Finished its turn")
        default: break
        }
        switch event {
        case "SessionStart":
            store.updateTile(tileID) { if $0.kind == .terminal { $0.kind = .agent } }
            setState(tileID, .idle)
            if let ctx = sharedNotesContext(for: tileID) {
                return Self.hookJSON(["hookSpecificOutput": ["hookEventName": "SessionStart", "additionalContext": ctx]])
            }
        case "UserPromptSubmit":
            let prompt = args["prompt"] ?? ""
            store.updateTile(tileID) { t in
                if t.kind == .terminal { t.kind = .agent }
                if !prompt.isEmpty && !prompt.hasPrefix("[Pitwall message") {
                    t.task = prompt
                    if t.name == nil && (t.autoName == nil || t.autoName == AgentKind.claude.title) { t.autoName = ClaudeIntegration.name(fromTask: prompt) }
                }
            }
            clearFinishedSubagents(of: tileID)
            setState(tileID, .working, message: nil)
            if let ctx = sharedNotesContext(for: tileID) {
                return Self.hookJSON(["hookSpecificOutput": ["hookEventName": "UserPromptSubmit", "additionalContext": ctx]])
            }
        case "PreToolUse":
            if tool == "Task" || tool == "Agent" {
                spawnSubagent(parent: tileID, toolUseID: args["tool_use_id"],
                              description: args["input.description"] ?? "Sub-agent", type: args["input.subagent_type"])
            }
            setState(tileID, .working, message: describe(tool: tool, args: args))
        case "PostToolUse":
            if tool == "Task" || tool == "Agent" { finishSubagent(parent: tileID, toolUseID: args["tool_use_id"]) }
            if store.findTile(tileID)?.tile.state == .waiting { setState(tileID, .working) }
        case "SubagentStop":
            break
        case "Notification":
            let msg = args["message"] ?? "Needs your input"
            // "Waiting for your input" is an idle reminder after a finished
            // turn, not a blocking question: that's Done, not Needs you.
            if args["notification_type"] == "idle_prompt" || msg.localizedCaseInsensitiveContains("waiting for your input") {
                if store.findTile(tileID)?.tile.state != .waiting { setState(tileID, focusedTileID == tileID ? .idle : .done) }
                break
            }
            setState(tileID, .waiting, message: msg)
        case "Stop":
            if var queue = store.inbox[tileID], !queue.isEmpty {
                let m = queue.removeFirst()
                store.inbox[tileID] = queue.isEmpty ? nil : queue
                setState(tileID, .working, message: "Message from \(m.fromName)")
                let out: [String: Any] = ["decision": "block", "reason": Self.format(m)]
                return (try? JSONSerialization.data(withJSONObject: out)).map { String(decoding: $0, as: UTF8.self) }
            }
            let summary = args["last_assistant_message"].map { String($0.prefix(160)) }
            setState(tileID, focusedTileID == tileID && NSApp.isActive ? .idle : .done, message: summary)
            handOff(from: tileID, result: args["last_assistant_message"] ?? "")
        case "SessionEnd":
            setState(tileID, .idle, message: nil)
        default:
            break
        }
        return nil
    }

    static func hookJSON(_ obj: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: obj)).map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: Workflows (stage D)

    /// Recent hand-offs per link, to stop runaway ping-pong between agents.
    private var handoffLog: [String: [Date]] = [:]

    /// Pipeline links: send a finished turn's result downstream.
    func handOff(from tileID: String, result: String) {
        guard let (b, src) = store.findTile(tileID) else { return }
        for link in b.links where link.from == tileID && link.isHandoff {
            let recent = (handoffLog[link.id] ?? []).filter { Date().timeIntervalSince($0) < 600 }
            guard recent.count < 4 else {
                model?.toast(.init(kind: .info, title: "Hand-off paused", body: "\(src.displayName) handed off 4 times in 10 minutes. Check the pipeline.", tileID: tileID))
                continue
            }
            handoffLog[link.id] = recent + [Date()]
            var text = "\(src.displayName) finished its step. Its result:\n\n" + String(result.prefix(4000))
            if let br = src.branch { text += "\n\n(Its work is on branch \(br)\(src.worktree.map { " in \($0)" } ?? "").)" }
            if let err = sendMessage(from: tileID, to: link.to, text: text) {
                model?.toast(.init(kind: .error, title: "Couldn't hand off", body: err, tileID: link.to))
            }
        }
    }

    func toggleHandoff(_ linkID: String) {
        store.update { b in
            if let i = b.links.firstIndex(where: { $0.id == linkID }) {
                b.links[i].handoff = !(b.links[i].handoff ?? false)
                b.links[i].kind = .manual
            }
        }
        canvas.linksView.refresh()
    }

    /// Notes linked to an agent are given to it as context on every prompt.
    func sharedNotesContext(for tileID: String) -> String? {
        let notes = linkedTiles(of: tileID).map(\.1).filter { $0.kind == .note || $0.kind == .code }
        guard !notes.isEmpty else { return nil }
        var out = "Shared notes from Pitwall (linked to you on the canvas; you may edit these files to update them):\n"
        for n in notes {
            guard let path = n.target, let s = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            out += "\n--- \(path) ---\n" + String(s.prefix(6000)) + "\n"
        }
        return out
    }

    /// Starts a reviewer agent on the same checkout, linked to the worker.
    func startReview(of tileID: String) {
        guard let t = board.tile(tileID) else { return }
        let dir = t.worktree ?? t.cwd ?? defaultCwd
        let task = """
        You are reviewing the work of another agent: Pitwall tile \(tileID) ("\(t.displayName)")\(t.branch.map { " on branch \($0)" } ?? ""). \
        Read its changes (git diff against the base branch, plus uncommitted changes). Look for bugs, missing tests, \
        risky changes and anything that doesn't match the task\(t.task.map { " (\"\(String($0.prefix(300)))\")" } ?? ""). \
        Do not edit files yourself. When done, use the pitwall send_message tool to send concise, actionable findings to tile \(tileID).
        """
        let near = CGPoint(x: t.frame.maxX + 66, y: t.frame.minY)
        let id = newAgent(task: task, repo: dir, worktree: false, agent: .claude,
                          at: freeSpot(size: Self.defaultSize(.agent), near: near), name: "Review · " + t.displayName)
        addLink(from: tileID, to: id, kind: .manual)
    }

    /// Fan-out: the same task in N worktrees, framed, with a Compare tile.
    func fanOut(task: String, repo: String?, agent: AgentKind, count: Int) {
        let size = Self.defaultSize(.agent)
        let v = canvas.visibleWorldRect
        var origin = CanvasView.snap(CGPoint(x: v.minX + 120, y: v.minY + 140))
        origin = freeSpot(size: CGSize(width: (size.width + 44) * CGFloat(count), height: size.height + 300), near: origin)
        var ids: [String] = []
        for i in 0..<count {
            let at = CGPoint(x: origin.x + CGFloat(i) * (size.width + 44), y: origin.y)
            ids.append(newAgent(task: task, repo: repo, worktree: true, agent: agent, at: at,
                                name: "Attempt \(i + 1) · " + ClaudeIntegration.name(fromTask: task)))
        }
        var cmp = Tile(kind: .compare, frame: .zero)
        cmp.target = ids.joined(separator: ",")
        cmp.cwd = repo
        cmp.autoName = "Compare attempts"
        cmp.frame.size = CGSize(width: 726, height: 330)
        let cmpID = addTile(cmp, at: CGPoint(x: origin.x, y: origin.y + size.height + 44), focus: false)
        for id in ids { addLink(from: id, to: cmpID, kind: .spawned) }
        var rect = CGRect(x: origin.x - 24, y: origin.y - 68, width: (size.width + 44) * CGFloat(count) - 20, height: size.height + 330 + 44 + 92)
        rect = CanvasView.snap(rect)
        var f = FrameGroup(title: "Fan-out · " + ClaudeIntegration.name(fromTask: task), frame: rect)
        f.colorIndex = board.frames.count
        let members = Set(ids + [cmpID])
        store.update { b in
            b.frames.append(f)
            for i in b.tiles.indices where members.contains(b.tiles[i].id) { b.tiles[i].frameGroupID = f.id }
        }
        fitFrame(f.id)
        reconcile()
        zoomToFit()
    }

    /// Merges a winning attempt into its repo (in a terminal so you see it).
    func pickAttempt(_ tileID: String) {
        guard let t = store.findTile(tileID)?.tile, let branch = t.branch, let wt = t.worktree,
              let top = Git.toplevel((wt as NSString).deletingLastPathComponent + "/../..") ?? Git.toplevel(wt) else { return }
        let alert = NSAlert()
        alert.messageText = "Merge \(branch)?"
        alert.informativeText = "Commits the attempt's changes on its branch and merges it into the checked-out branch of \((top as NSString).lastPathComponent). You'll see every step in a terminal tile."
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let cmd = "git -C \(shellQuote(wt)) add -A && (git -C \(shellQuote(wt)) diff --cached --quiet || git -C \(shellQuote(wt)) commit -m \(shellQuote("Attempt: " + (t.task ?? branch)))) && git merge --no-ff \(shellQuote(branch))"
        _ = newTerminal(cwd: top, command: cmd, name: "Merge " + branch)
    }

    private func describe(tool: String, args: [String: String]) -> String? {
        if let c = args["input.command"] { return "$ " + String(c.prefix(120)) }
        if let f = args["input.file_path"] { return "\(tool) \((f as NSString).lastPathComponent)" }
        if let d = args["input.description"] { return d }
        return tool.isEmpty ? nil : tool
    }

    // MARK: Sub-agents

    private func spawnSubagent(parent: String, toolUseID: String?, description: String, type: String?) {
        guard Prefs.shared.showSubagents, let (b, p) = store.findTile(parent) else { return }
        var t = Tile(kind: .subagent, frame: .zero)
        t.autoName = type.map { "\($0) · \(description)" } ?? description
        t.statusMessage = description
        t.state = .working
        t.sessionID = toolUseID // remember which Task call this is
        t.frame.size = Self.defaultSize(.subagent)
        t.z = b.maxZ + 1
        store.update(b.id) { $0.tiles.append(t); $0.links.append(Link(from: p.id, to: t.id, kind: .spawned)) }
        layoutSubagents()
        if b.id == board.id { reconcile() }
    }

    private func finishSubagent(parent: String, toolUseID: String?) {
        guard let (b, _) = store.findTile(parent) else { return }
        let kids = b.links.filter { $0.from == parent && $0.kind == .spawned }.map(\.to)
        if let k = b.tiles.first(where: { kids.contains($0.id) && $0.kind == .subagent && ($0.sessionID == toolUseID || toolUseID == nil) && $0.state == .working }) {
            setState(k.id, .done)
        }
    }

    private func clearFinishedSubagents(of parent: String) {
        guard let (b, _) = store.findTile(parent) else { return }
        let kids = Set(b.links.filter { $0.from == parent && $0.kind == .spawned }.map(\.to))
        let done = b.tiles.filter { kids.contains($0.id) && $0.kind == .subagent && $0.state != .working }.map(\.id)
        guard !done.isEmpty else { return }
        store.update(b.id) { bb in
            bb.tiles.removeAll { done.contains($0.id) }
            bb.links.removeAll { done.contains($0.to) }
        }
        if b.id == board.id { reconcile() }
    }

    /// Stacks sub-agent chips in a column to the right of their parent.
    func layoutSubagents() {
        for b in store.boards {
            var updates: [String: CGRect] = [:]
            for p in b.tiles where p.kind != .subagent {
                let kids = b.links.filter { $0.from == p.id && $0.kind == .spawned }.compactMap { b.tile($0.to) }.filter { $0.kind == .subagent }
                for (i, k) in kids.enumerated() {
                    let size = Self.defaultSize(.subagent)
                    updates[k.id] = CGRect(x: p.frame.maxX + 66, y: p.frame.minY + CGFloat(i) * (size.height + 22), width: size.width, height: size.height)
                }
            }
            if !updates.isEmpty {
                store.update(b.id) { bb in for i in bb.tiles.indices { if let f = updates[bb.tiles[i].id] { bb.tiles[i].frame = f } } }
            }
        }
    }

    // MARK: Terminal signals (fallback when hooks aren't present)

    func terminalSignal(_ id: String, _ signal: TerminalSession.Signal) {
        let hooked = hookedTiles.contains(id)
        switch signal {
        case .title(let title):
            // Claude Code puts a spinner glyph before the task summary.
            // Drop any leading spinner/status glyphs (they change every frame).
            let cleaned = String(title.drop { !$0.isLetter && !$0.isNumber }).trimmingCharacters(in: .whitespaces)
            store.updateTile(id) { $0.terminalTitle = cleaned }
            if let (_, t) = store.findTile(id), t.kind == .agent, t.name == nil, !cleaned.isEmpty,
               !["claude", "Claude Code", "zsh", "bash"].contains(cleaned) {
                store.updateTile(id) { $0.autoName = cleaned }
            }
            reconcileIfCurrent(id)
        case .pwd(let p):
            store.updateTile(id) { $0.cwd = p }
            refreshGit(id)
        case .notification(_, let body):
            // With hooks, Claude Code's own events are authoritative.
            if hooked { return }
            if body.localizedCaseInsensitiveContains("waiting for your input") {
                if store.findTile(id)?.tile.state != .waiting { setState(id, focusedTileID == id ? .idle : .done) }
                return
            }
            setState(id, .waiting, message: body.isEmpty ? nil : body)
        case .bell:
            if !hooked, let t = store.findTile(id)?.tile, t.kind == .agent, focusedTileID != id { setState(id, .waiting) }
        case .progress(let s):
            guard !hooked else { return }
            if s == GHOSTTY_PROGRESS_STATE_REMOVE {
                if store.findTile(id)?.tile.state == .working { setState(id, focusedTileID == id ? .idle : .done) }
            } else if s == GHOSTTY_PROGRESS_STATE_ERROR {
                setState(id, .error)
            } else {
                setState(id, .working)
            }
        case .commandFinished(let code):
            if !hooked, code > 0, let t = store.findTile(id)?.tile, t.kind == .logs, t.watchCommand == nil { setState(id, .error, message: "exit \(code)") }
        case .exited:
            sessionEnded(id)
        case .focused:
            focus(tileID: id, makeFirstResponder: false)
        }
    }

    /// The terminal's attach client exited. Close the tile only if the
    /// session itself ended (the user typed `exit`); if the session was lost
    /// (daemon gone), keep the tile so it can be restarted.
    private func sessionEnded(_ id: String) {
        guard let t = store.findTile(id)?.tile, let sid = t.sessionID else { closeTile(id); return }
        let info = try? UnixSocket.roundTrip(PitwallPaths.daemonSocket.path, DaemonRequest(op: .info, id: sid), as: DaemonResponse.self)
        if let s = info?.session, !s.alive {
            closeTile(id)
        } else if let s = info?.session, s.alive {
            return // detached by another client; nothing to do
        } else {
            setState(id, .error, message: "Session lost. Right-click → Restart session.")
        }
    }

    /// Recreates a tile's terminal (a fresh session if the old one is gone).
    func restartSession(_ id: String) {
        guard let v = tileViews[id] else { return }
        v.content.willClose()
        v.removeFromSuperview()
        tileViews[id] = nil
        sessions[id] = nil
        setState(id, .idle, message: nil)
        reconcile()
    }

    func reconcileIfVisible(_ id: String) { reconcileIfCurrent(id) }

    // MARK: Permission requests

    func permissionRequested(_ tileID: String, _ p: ApprovalCenter.Pending) {
        Timelines.shared.add(tileID, .permission, p.summary)
        setState(tileID, .waiting, message: "Wants to run: " + p.summary)
    }

    func permissionResolved(_ tileID: String, _ p: ApprovalCenter.Pending, _ d: ApprovalCenter.Decision?) {
        switch d {
        case .allow?, .allowAlways?:
            Timelines.shared.add(tileID, .approved, (d == .allowAlways ? "Always allowed: " : "Allowed: ") + p.summary)
            setState(tileID, .working, message: p.summary)
        case .deny?:
            Timelines.shared.add(tileID, .denied, "Denied: " + p.summary)
            setState(tileID, .working, message: "Denied " + p.summary)
        case nil:
            break
        }
        model?.toasts.removeAll { $0.tileID == tileID }
    }

    private func reconcileIfCurrent(_ id: String) {
        if board.tile(id) != nil { reconcile() }
    }

    // MARK: Polling: git + foreground process

    /// Agent CLIs by process name. Claude Code's native build runs as its
    /// version number (e.g. "2.1.325").
    static func isAgentProcess(_ name: String) -> Bool {
        if ["claude", "codex", "gemini", "aider", "opencode", "amp"].contains(name) { return true }
        return name.range(of: "^\\d+\\.\\d+\\.\\d+$", options: .regularExpression) != nil
    }

    private func poll() {
        let infos = Sessions.list()
        var byID: [String: SessionInfo] = [:]
        for i in infos { byID[i.id] = i }
        for b in store.boards {
            for t in b.tiles where t.isTerminalBacked {
                guard let sid = t.sessionID, let info = byID[sid] else { continue }
                let fg = info.foregroundName ?? ""
                let isAgent = Self.isAgentProcess(fg)
                if isAgent { agentSeen.insert(t.id) }
                if isAgent && t.kind == .terminal {
                    store.updateTile(t.id) { $0.kind = .agent; if $0.autoName == nil { $0.autoName = fg.first?.isNumber == true ? "Claude" : fg.capitalized } }
                }
                if let cwd = info.foregroundCwd, cwd != t.cwd { store.updateTile(t.id) { $0.cwd = cwd } }
                // The agent quit back to the shell: it is no longer working.
                let shells: Set<String> = ["zsh", "bash", "fish", "sh", "nu", "login"]
                // Only once we've seen it running: right after launch the shell
                // is still in front while the agent starts up.
                if t.kind == .agent, shells.contains(fg), agentSeen.contains(t.id), t.state == .working || t.state == .waiting {
                    agentSeen.remove(t.id)
                    setState(t.id, .idle, message: "Agent exited")
                }
            }
        }
        for t in board.tiles where t.isTerminalBacked || t.kind == .diff { refreshGit(t.id) }
        scanScreens(byID: byID)
        layoutSubagents()
        reconcile()
    }

    // MARK: Screen scanning: blocking prompts + image paths

    /// Prompts that block on the user, recognized from the end of the output.
    /// These appear before (or without) hooks, e.g. Claude's folder-trust check.
    static let blockingPrompts: [(pattern: String, message: String)] = [
        ("trust this folder|trust the files in this folder|Quick safety check", "Asking you to trust this folder"),
        ("Do you want to proceed\\?|Do you want to make this edit|Do you want to create|Do you want to allow", "Waiting for your permission"),
        ("Allow command\\?|Approve this command|\\[y/N\\]|\\(y/n\\)", "Waiting for your approval"),
    ]
    private var screenWaiting = Set<String>()
    /// Watch tiles: the failure line currently shown (so it isn't re-reported).
    var watchFailingLine: [String: String] = [:]
    /// PR tiles: comment ids already seen.
    var prSeenComments: [String: Set<String>] = [:]
    /// Dev servers: recent automatic restarts (for crash-loop backoff).
    var serverRestarts: [String: [Date]] = [:]
    /// Where the next new tile goes (set by "New agent here" and the canvas menu).
    /// Agent tiles whose agent process we've seen in the foreground.
    var agentSeen = Set<String>()
    var pendingPlacement: (point: CGPoint?, frameID: String?, expires: Date)?
    private var scanInFlight = Set<String>()

    static let imagePattern = try! NSRegularExpression(
        pattern: "(?:~|/)[^\\s'\"`<>|()\\[\\]]+?\\.(?:png|jpe?g|gif|webp|heic|tiff?)\\b", options: [.caseInsensitive])

    private func scanScreens(byID: [String: SessionInfo]) {
        for b in store.boards {
            for t in b.tiles where t.isTerminalBacked {
                guard let sid = t.sessionID, byID[sid]?.alive == true, !scanInFlight.contains(t.id) else { continue }
                let isWatch = t.kind == .logs
                let watchPrompts = Prefs.shared.detectPrompts && t.kind == .agent && (t.state == .working || screenWaiting.contains(t.id))
                let collectImages = Prefs.shared.imageGallery
                scanInFlight.insert(t.id)
                let id = t.id
                let known = Set(t.images ?? [])
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let raw = Sessions.scrollback(sid, bytes: 48_000) ?? ""
                    let text = Sessions.plain(raw)
                    // Prompts: only the last screenful matters.
                    var prompt: String?
                    if watchPrompts {
                        let tail = String(text.suffix(2500))
                        prompt = Self.blockingPrompts.first { tail.range(of: $0.pattern, options: [.regularExpression, .caseInsensitive]) != nil }?.message
                    }
                    // Images: existing files mentioned anywhere in recent output.
                    var found: [String] = []
                    let ns = text as NSString
                    for m in (collectImages ? Self.imagePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) : []) {
                        var path = ns.substring(with: m.range)
                        path = (path as NSString).expandingTildeInPath
                        if !known.contains(path), !found.contains(path), FileManager.default.fileExists(atPath: path) { found.append(path) }
                    }
                    let watchTail = isWatch ? String(text.suffix(4000)) : nil
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.scanInFlight.remove(id)
                        if let watchTail { self.watchScan(id, tail: watchTail) }
                        guard let cur = self.store.findTile(id)?.tile else { return }
                        if let prompt, cur.state != .waiting {
                            self.screenWaiting.insert(id)
                            self.setState(id, .waiting, message: prompt)
                        } else if prompt == nil, self.screenWaiting.contains(id), cur.state == .waiting {
                            self.screenWaiting.remove(id)
                            self.setState(id, .working, message: nil)
                        }
                        if !found.isEmpty {
                            self.store.updateTile(id) { t in t.images = Array(((t.images ?? []) + found).suffix(40)) }
                            self.reconcileIfCurrent(id)
                        }
                    }
                }
            }
        }
    }

    /// Opens an image from a tile's gallery as a linked image tile.
    func openImage(_ path: String, from tileID: String) {
        guard let src = board.tile(tileID) else { open(target: path); return }
        let near = CGPoint(x: src.frame.maxX + 44, y: src.frame.minY)
        if let id = open(target: path, at: freeSpot(size: Self.defaultSize(.image), near: near)) {
            addLink(from: tileID, to: id, kind: .spawned)
        }
    }

    private var gitInFlight = Set<String>()

    func refreshGit(_ id: String) {
        guard let (_, t) = store.findTile(id), let dir = t.worktree ?? t.cwd, !gitInFlight.contains(id) else { return }
        gitInFlight.insert(id)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let branch = Git.branch(dir)
            let stat = branch == nil ? nil : Git.diffStat(dir)
            DispatchQueue.main.async {
                guard let self else { return }
                self.gitInFlight.remove(id)
                guard let cur = self.store.findTile(id)?.tile else { return }
                if cur.branch != branch || cur.diffAdded != stat?.0 || cur.diffRemoved != stat?.1 {
                    self.store.updateTile(id) { $0.branch = branch; $0.diffAdded = stat?.0; $0.diffRemoved = stat?.1 }
                    self.reconcileIfCurrent(id)
                }
            }
        }
    }

    // MARK: PRs

    private func openPR(diffTile id: String) {
        guard let t = board.tile(id), let repo = t.target else { return }
        let cmd = "git push -u origin HEAD && gh pr create --fill"
        let term = newTerminal(cwd: repo, command: cmd, name: "Open PR")
        addLink(from: id, to: term, kind: .spawned)
        // Follow the PR once it exists; the tile retries until gh finds it.
        if let pr = newPR(repo: repo, from: id), let agent = linkedTiles(of: id).first(where: { $0.1.kind == .agent })?.1.id {
            addLink(from: pr, to: agent)
        }
    }
}

/// Which CLI agent to start from the dispatch bar.
enum AgentKind: String, CaseIterable, Identifiable {
    case claude, codex, shell
    var id: String { rawValue }
    var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .shell: return "Shell command"
        }
    }
    func command(task: String) -> String? {
        switch self {
        case .claude: return ClaudeIntegration.command(task: task)
        case .codex: return task.isEmpty ? "codex" : "codex \(shellQuote(task))"
        case .shell: return task.isEmpty ? nil : task
        }
    }
}

/// Per-terminal delegate translating Ghostty callbacks into controller signals.
final class TerminalSession: TerminalSurfaceDelegate {
    enum Signal {
        case title(String), pwd(String), notification(String, String), bell
        case progress(ghostty_action_progress_report_state_e)
        case commandFinished(Int), exited, focused
    }
    let tileID: String
    weak var controller: CanvasController?

    init(tileID: String, controller: CanvasController) {
        self.tileID = tileID
        self.controller = controller
    }

    func surface(_ view: TerminalSurfaceView, titleChanged title: String) { controller?.terminalSignal(tileID, .title(title)) }
    func surface(_ view: TerminalSurfaceView, pwdChanged pwd: String) { controller?.terminalSignal(tileID, .pwd(pwd)) }
    func surface(_ view: TerminalSurfaceView, notification title: String, body: String) { controller?.terminalSignal(tileID, .notification(title, body)) }
    func surfaceDidRingBell(_ view: TerminalSurfaceView) { controller?.terminalSignal(tileID, .bell) }
    func surface(_ view: TerminalSurfaceView, progress: ghostty_action_progress_report_state_e, percent: Int) { controller?.terminalSignal(tileID, .progress(progress)) }
    func surface(_ view: TerminalSurfaceView, commandFinished exitCode: Int, duration: UInt64) { controller?.terminalSignal(tileID, .commandFinished(exitCode)) }
    func surface(_ view: TerminalSurfaceView, childExited exitCode: Int) { controller?.terminalSignal(tileID, .exited) }
    func surface(_ view: TerminalSurfaceView, openURL url: String) {
        if url.contains("localhost") || url.contains("127.0.0.1") { controller?.open(target: url) }
        else if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
    func surfaceDidRequestClose(_ view: TerminalSurfaceView, processAlive: Bool) { controller?.terminalSignal(tileID, .exited) }
    func surfaceDidFocus(_ view: TerminalSurfaceView) { controller?.terminalSignal(tileID, .focused) }
}

/// NSMenuItem with a closure.
final class MenuAction: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, key: String = "", _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}
