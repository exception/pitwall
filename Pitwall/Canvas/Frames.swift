import AppKit

// MARK: - Frames: membership, placement, resize, collapse
//
// A tile belongs to at most one frame (Tile.frameGroupID). Tiles created at a
// point inside a frame, or next to a tile that's in one, join it; dragging a
// tile in or out changes membership. Frames grow to fit their tiles, can be
// resized by their edges (never smaller than their tiles), and collapse to a
// title strip that still shows who needs you.

extension CanvasController {

    static let framePad: CGFloat = 24

    /// The innermost expanded frame whose body contains a world point.
    func frame(at p: CGPoint) -> FrameGroup? {
        board.frames.filter { !$0.collapsed && $0.frame.contains(p) && p.y > $0.frame.minY + FrameGroup.headerHeight - 12 }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// Where a new tile goes and which frame it joins.
    /// Called by addTile; `at` is the caller's requested origin, if any.
    func placement(for size: CGSize, at: CGPoint?) -> (origin: CGPoint, frameID: String?) {
        if at == nil, let pp = pendingPlacement, pp.expires > Date() {
            pendingPlacement = nil
            if let fid = pp.frameID, let f = board.frames.first(where: { $0.id == fid }) {
                if f.collapsed { setCollapsed(fid, false) }
                if let pt = pp.point, f.frame.contains(pt) { return (CanvasView.snap(pt), fid) }
                return (spot(in: fid, size: size), fid)
            }
            if let pt = pp.point { return (CanvasView.snap(pt), nil) }
        }
        if at == nil { pendingPlacement = nil }
        if let at {
            return (CanvasView.snap(at), frame(at: at)?.id)
        }
        // Next to the focused tile: join its frame.
        if let f = focusedTileID.flatMap({ board.tile($0) }), let fid = f.frameGroupID,
           let fr = board.frames.first(where: { $0.id == fid }), !fr.collapsed {
            return (spot(in: fid, size: size), fid)
        }
        return (freeSpot(size: size), nil)
    }

    /// A free spot inside a frame (left-to-right, top-to-bottom), or just to
    /// the right of its tiles; the frame grows to fit afterwards.
    func spot(in frameID: String, size: CGSize) -> CGPoint {
        guard let f = board.frames.first(where: { $0.id == frameID }) else { return freeSpot(size: size) }
        let others = board.tiles.filter { $0.kind != .subagent }.map { $0.frame.insetBy(dx: -20, dy: -20) }
        let pad = Self.framePad
        let area = CGRect(x: f.frame.minX + pad, y: f.frame.minY + FrameGroup.headerHeight,
                          width: f.frame.width - pad * 2, height: f.frame.height - FrameGroup.headerHeight - pad)
        var y = area.minY
        while y + size.height <= area.maxY {
            var x = area.minX
            while x + size.width <= area.maxX {
                let r = CGRect(x: x, y: y, width: size.width, height: size.height)
                if !others.contains(where: { $0.intersects(r) }) { return CanvasView.snap(r.origin) }
                x += 22
            }
            y += 22
        }
        let members = board.members(of: frameID).map(\.frame)
        let right = members.map(\.maxX).max() ?? area.minX - 44
        return freeSpot(size: size, near: CGPoint(x: right + 44, y: area.minY))
    }

    /// Grows a frame so it contains all its tiles (never shrinks it).
    func fitFrame(_ id: String) {
        guard let f = board.frames.first(where: { $0.id == id }) else { return }
        let members = board.members(of: id)
        guard let first = members.first else { return }
        let u = members.reduce(first.frame) { $0.union($1.frame) }
        let needed = CGRect(x: u.minX - Self.framePad, y: u.minY - FrameGroup.headerHeight,
                            width: u.width + Self.framePad * 2, height: u.height + FrameGroup.headerHeight + Self.framePad)
        let grown = CanvasView.snap(f.frame.union(needed))
        if grown != f.frame {
            store.update { b in
                if let i = b.frames.firstIndex(where: { $0.id == id }) { b.frames[i].frame = grown }
                // Inside means member: loose tiles the frame now covers join it.
                for j in b.tiles.indices where b.tiles[j].frameGroupID == nil && b.tiles[j].kind != .subagent && grown.contains(b.tiles[j].frame) {
                    b.tiles[j].frameGroupID = id
                }
            }
        }
    }

    /// The smallest a frame may be resized to: around its tiles.
    func minimumRect(of id: String) -> CGRect? {
        let members = board.members(of: id)
        guard let first = members.first else { return nil }
        let u = members.reduce(first.frame) { $0.union($1.frame) }
        return CGRect(x: u.minX - Self.framePad, y: u.minY - FrameGroup.headerHeight,
                      width: u.width + Self.framePad * 2, height: u.height + FrameGroup.headerHeight + Self.framePad)
    }

    /// After a tile is dropped: join the frame under its center, or leave.
    func updateMembership(_ tileID: String) {
        guard let t = board.tile(tileID), t.kind != .subagent else { return }
        let center = CGPoint(x: t.frame.midX, y: t.frame.minY + 20)
        let target = frame(at: center)?.id
        if t.frameGroupID != target {
            store.updateTile(tileID) { $0.frameGroupID = target }
        }
        if let target { fitFrame(target) }
        highlightDropFrame(nil)
        reconcile()
    }

    /// While dragging a tile: highlight the frame it would land in.
    func highlightDropFrame(_ tileID: String?) {
        var target: String?
        if let id = tileID, let t = board.tile(id) {
            target = frame(at: CGPoint(x: t.frame.midX, y: t.frame.minY + 20))?.id
        }
        for (id, v) in frameViews { v.dropTarget = id == target }
    }

    // MARK: Collapse

    func setCollapsed(_ id: String, _ collapsed: Bool) {
        store.update { b in if let i = b.frames.firstIndex(where: { $0.id == id }) { b.frames[i].collapsed = collapsed } }
        if collapsed, let f = focusedTileID, board.tile(f)?.frameGroupID == id { clearFocus() }
        reconcile()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Prefs.shared.motion ? 0.18 : 0
            ctx.allowsImplicitAnimation = true
            layoutAll(live: false)
        }
    }

    func toggleCollapsed(_ id: String) {
        guard let f = board.frames.first(where: { $0.id == id }) else { return }
        setCollapsed(id, !f.collapsed)
    }

    /// Hidden because its frame (or its parent's frame) is collapsed.
    func isCollapsedAway(_ t: Tile, in b: Board) -> Bool {
        let collapsed = Set(b.frames.filter(\.collapsed).map(\.id))
        if collapsed.isEmpty { return false }
        if let f = t.frameGroupID, collapsed.contains(f) { return true }
        if t.kind == .subagent, let parent = b.links.first(where: { $0.to == t.id && $0.kind == .spawned })?.from,
           let p = b.tile(parent), let pf = p.frameGroupID { return collapsed.contains(pf) }
        return false
    }

    /// Expands the frame a tile is in, if it's collapsed (before flying to it).
    func revealTile(_ id: String) {
        guard let t = board.tile(id) else { return }
        var fid = t.frameGroupID
        if t.kind == .subagent, let parent = board.links.first(where: { $0.to == id && $0.kind == .spawned })?.from {
            fid = board.tile(parent)?.frameGroupID
        }
        if let fid, board.frames.first(where: { $0.id == fid })?.collapsed == true { setCollapsed(fid, false) }
    }

    /// What a frame's title strip shows about its tiles.
    func summary(of id: String) -> FrameGroupView.Summary {
        let members = board.members(of: id).filter { $0.kind != .subagent }
        let agents = members.filter { $0.kind == .agent }.count
        var parts: [String] = []
        if agents > 0 { parts.append("\(agents) agent\(agents == 1 ? "" : "s")") }
        let others = members.count - agents
        if others > 0 { parts.append("\(others) tile\(others == 1 ? "" : "s")") }
        let waiting = members.filter { $0.state == .waiting }.count
        let errors = members.filter { $0.state == .error }.count
        if waiting > 0 { parts.append("\(waiting) need\(waiting == 1 ? "s" : "") you") }
        if errors > 0 { parts.append("\(errors) failing") }
        return .init(text: parts.joined(separator: " · "),
                     states: members.sorted { $0.state.priority < $1.state.priority }.prefix(12).map(\.state),
                     attention: waiting > 0)
    }

    // MARK: Frame actions

    func zoomToFrame(_ id: String) {
        guard let f = board.frames.first(where: { $0.id == id }) else { return }
        let insets = model?.canvasInsets ?? NSEdgeInsets(top: 80, left: 300, bottom: 140, right: 40)
        canvas.animate(to: canvas.viewport(fitting: f.visibleFrame.insetBy(dx: -24, dy: -24), maxZoom: 1, insets: insets))
    }

    /// "New agent here": the next tile the dispatch bar creates goes in this frame.
    func newAgentInFrame(_ id: String) {
        pendingPlacement = (nil, id, Date().addingTimeInterval(120))
        model?.focusDispatch()
    }

    func newTerminalInFrame(_ id: String) {
        pendingPlacement = (nil, id, Date().addingTimeInterval(5))
        _ = newTerminal()
    }

    /// Arranges a frame's tiles in a grid inside it.
    func tidyFrame(_ id: String) {
        guard let f = board.frames.first(where: { $0.id == id }) else { return }
        let tiles = board.members(of: id).filter { $0.kind != .subagent }
            .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
        guard !tiles.isEmpty else { return }
        let cols = max(1, Int(Double(tiles.count).squareRoot().rounded(.up)))
        let origin = CGPoint(x: f.frame.minX + Self.framePad, y: f.frame.minY + FrameGroup.headerHeight)
        var x = origin.x, y = origin.y, rowH: CGFloat = 0
        var frames: [String: CGRect] = [:]
        for (i, t) in tiles.enumerated() {
            if i > 0 && i % cols == 0 { x = origin.x; y += rowH + 44; rowH = 0 }
            frames[t.id] = CGRect(origin: CanvasView.snap(CGPoint(x: x, y: y)), size: t.frame.size)
            x += t.frame.width + 44
            rowH = max(rowH, t.frame.height)
        }
        store.update { b in for i in b.tiles.indices { if let r = frames[b.tiles[i].id] { b.tiles[i].frame = r } } }
        // Shrink-wrap: tidy is the one action allowed to make a frame smaller.
        if let m = minimumRect(of: id) {
            store.update { b in if let i = b.frames.firstIndex(where: { $0.id == id }) { b.frames[i].frame = CanvasView.snap(m) } }
        }
        reconcile()
        layoutSubagents()
        animateLayout()
    }

    func closeTilesInFrame(_ id: String) {
        let ids = board.members(of: id).filter { $0.kind != .subagent }.map(\.id)
        guard !ids.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Close \(ids.count) tile\(ids.count == 1 ? "" : "s") in this frame?"
        alert.informativeText = "Terminals and agents in them will be stopped."
        alert.addButton(withTitle: "Close Tiles")
        alert.addButton(withTitle: "Cancel")
        guard let w = canvas.window else { return }
        alert.beginSheetModal(for: w) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            for t in ids { self?.closeTile(t) }
        }
    }

    func deleteFrame(_ id: String) {
        store.update { b in
            b.frames.removeAll { $0.id == id }
            for i in b.tiles.indices where b.tiles[i].frameGroupID == id { b.tiles[i].frameGroupID = nil }
        }
        reconcile()
    }

    /// Resizing by an edge or corner; clamped around the frame's tiles.
    func resizeFrame(_ id: String, to rect: CGRect, persist: Bool) {
        var r = rect
        r.size.width = max(r.width, 320)
        r.size.height = max(r.height, 160)
        if let m = minimumRect(of: id) {
            let minX = min(r.minX, m.minX), minY = min(r.minY, m.minY)
            let maxX = max(r.maxX, m.maxX), maxY = max(r.maxY, m.maxY)
            r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        r = CanvasView.snap(r)
        store.update { b in if let i = b.frames.firstIndex(where: { $0.id == id }) { b.frames[i].frame = r } }
        if let v = frameViews[id], let f = board.frames.first(where: { $0.id == id }) {
            v.update(f)
            v.frame = canvas.toView(f.visibleFrame)
            v.apply(zoom: canvas.viewport.zoom)
        }
        if persist { reconcile() }
    }
}
