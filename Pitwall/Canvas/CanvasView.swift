import AppKit

/// The infinite pan/zoom surface. Tiles are subviews laid out in screen
/// points: screen = (world − origin) × zoom.
final class CanvasView: NSView {
    weak var controller: CanvasController?
    private(set) var viewport = Viewport()

    let grid = GridView()
    let framesLayer = FlippedView()
    let linksView = LinksView()
    let tilesLayer = FlippedView()
    /// Above tiles: message bubbles, comet trails and ripples.
    let effectsView = PassthroughView()

    static let minZoom: CGFloat = 0.15
    static let maxZoom: CGFloat = 1.6
    static let gridStep: CGFloat = 22

    private var spaceDown = false
    private var panStart: NSPoint?
    private var originAtPanStart = CGPoint.zero
    private var commitZoomWork: DispatchWorkItem?
    private var liveZoom = false
    private var linkDrag: (from: String, point: CGPoint)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        effectsView.wantsLayer = true
        for v in [grid, framesLayer, linksView, tilesLayer, effectsView] as [NSView] {
            v.autoresizingMask = [.width, .height]
            v.frame = bounds
            addSubview(v)
        }
        grid.canvas = self
        linksView.canvas = self
        registerForDraggedTypes([.fileURL, .URL])
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Coordinates

    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - viewport.origin.x) * viewport.zoom, y: (p.y - viewport.origin.y) * viewport.zoom)
    }

    func toView(_ r: CGRect) -> CGRect {
        CGRect(origin: toView(r.origin), size: CGSize(width: r.width * viewport.zoom, height: r.height * viewport.zoom))
    }

    func toWorld(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x / viewport.zoom + viewport.origin.x, y: p.y / viewport.zoom + viewport.origin.y)
    }

    var visibleWorldRect: CGRect {
        CGRect(origin: viewport.origin, size: CGSize(width: bounds.width / viewport.zoom, height: bounds.height / viewport.zoom))
    }

    static func snap(_ p: CGPoint) -> CGPoint {
        guard Prefs.shared.snapToGrid else { return p }
        let s = gridStep / 2
        return CGPoint(x: (p.x / s).rounded() * s, y: (p.y / s).rounded() * s)
    }

    static func snap(_ r: CGRect) -> CGRect {
        guard Prefs.shared.snapToGrid else { return r }
        return CGRect(origin: snap(r.origin), size: CGSize(width: (r.width / (gridStep / 2)).rounded() * gridStep / 2,
                                                   height: (r.height / (gridStep / 2)).rounded() * gridStep / 2))
    }

    // MARK: Viewport

    func setViewport(_ v: Viewport, live: Bool = false, persist: Bool = true) {
        var v = v
        v.zoom = min(max(v.zoom, Self.minZoom), Self.maxZoom)
        let zoomChanged = v.zoom != viewport.zoom
        viewport = v
        controller?.layoutAll(live: live && zoomChanged)
        grid.needsDisplay = true
        linksView.refresh()
        if persist { controller?.viewportChanged(v) }
    }

    func zoom(by factor: CGFloat, around viewPoint: CGPoint, live: Bool) {
        let before = toWorld(viewPoint)
        var v = viewport
        v.zoom = min(max(v.zoom * factor, Self.minZoom), Self.maxZoom)
        v.origin = CGPoint(x: before.x - viewPoint.x / v.zoom, y: before.y - viewPoint.y / v.zoom)
        setViewport(v, live: live, persist: !live)
        if live { scheduleZoomCommit() }
    }

    /// After live zooming settles, re-render terminals crisply at the new scale.
    private func scheduleZoomCommit(delay: TimeInterval = 0.18) {
        commitZoomWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.controller?.layoutAll(live: false)
            self.controller?.viewportChanged(self.viewport)
        }
        commitZoomWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// Animates the viewport to show `world` rect centered.
    func animate(to target: Viewport, duration: TimeInterval = 0.32) {
        guard Prefs.shared.motion else {
            setViewport(target)
            controller?.layoutAll(live: false)
            return
        }
        let start = viewport
        let t0 = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = min(1, (CACurrentMediaTime() - t0) / duration)
            let e = 1 - pow(1 - t, 3)
            var v = Viewport()
            // Interpolate zoom geometrically for a natural feel.
            v.zoom = start.zoom * pow(target.zoom / start.zoom, e)
            let c0 = CGPoint(x: start.origin.x + self.bounds.width / 2 / start.zoom, y: start.origin.y + self.bounds.height / 2 / start.zoom)
            let c1 = CGPoint(x: target.origin.x + self.bounds.width / 2 / target.zoom, y: target.origin.y + self.bounds.height / 2 / target.zoom)
            let c = CGPoint(x: c0.x + (c1.x - c0.x) * e, y: c0.y + (c1.y - c0.y) * e)
            v.origin = CGPoint(x: c.x - self.bounds.width / 2 / v.zoom, y: c.y - self.bounds.height / 2 / v.zoom)
            let done = t >= 1
            self.setViewport(done ? target : v, live: !done, persist: done)
            if done { timer.invalidate(); self.controller?.layoutAll(live: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    func viewport(fitting world: CGRect, maxZoom: CGFloat = 1, insets: NSEdgeInsets) -> Viewport {
        let availW = bounds.width - insets.left - insets.right
        let availH = bounds.height - insets.top - insets.bottom
        let z = min(maxZoom, max(Self.minZoom, min(availW / max(world.width, 1), availH / max(world.height, 1))))
        let cx = world.midX, cy = world.midY
        let centerX = insets.left + availW / 2, centerY = insets.top + availH / 2
        return Viewport(origin: CGPoint(x: cx - centerX / z, y: cy - centerY / z), zoom: z)
    }

    // MARK: Events

    override func scrollWheel(with event: NSEvent) {
        if controller?.fullScreenTileID != nil { return }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            let p = convert(event.locationInWindow, from: nil)
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
            zoom(by: exp(dy * 0.01), around: p, live: true)
            return
        }
        var v = viewport
        let mult: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        v.origin.x -= event.scrollingDeltaX * mult / v.zoom
        v.origin.y -= event.scrollingDeltaY * mult / v.zoom
        setViewport(v, persist: false)
        if event.phase == .ended || event.momentumPhase == .ended || !event.hasPreciseScrollingDeltas {
            controller?.viewportChanged(viewport)
        }
    }

    override func magnify(with event: NSEvent) {
        if controller?.fullScreenTileID != nil { return }
        let p = convert(event.locationInWindow, from: nil)
        zoom(by: 1 + event.magnification, around: p, live: true)
        if event.phase == .ended || event.phase == .cancelled { scheduleZoomCommit(delay: 0.05) }
    }

    override func smartMagnify(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let id = controller?.tileID(at: p) { controller?.flyTo(tileID: id, fill: false) }
        else { controller?.zoomToFit() }
    }

    override func mouseDown(with event: NSEvent) {
        if controller?.fullScreenTileID != nil { return }
        window?.makeFirstResponder(self)
        controller?.clearFocus()
        let p = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            controller?.showPicker(at: p)
            return
        }
        controller?.dismissPicker()
        panStart = event.locationInWindow
        originAtPanStart = viewport.origin
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let s = panStart else { return }
        var v = viewport
        v.origin.x = originAtPanStart.x - (event.locationInWindow.x - s.x) / v.zoom
        v.origin.y = originAtPanStart.y + (event.locationInWindow.y - s.y) / v.zoom
        setViewport(v, persist: false)
    }

    override func mouseUp(with event: NSEvent) {
        if panStart != nil { NSCursor.pop(); controller?.viewportChanged(viewport) }
        panStart = nil
    }

    override func otherMouseDown(with event: NSEvent) {
        panStart = event.locationInWindow
        originAtPanStart = viewport.origin
    }
    override func otherMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func otherMouseUp(with event: NSEvent) { panStart = nil; controller?.viewportChanged(viewport) }

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let menu = controller?.canvasMenu(at: p) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

    // MARK: Links

    func beginLinkDrag(from id: String, event: NSEvent) {
        linkDrag = (id, convert(event.locationInWindow, from: nil))
        linksView.pending = linkDrag
    }

    func continueLinkDrag(event: NSEvent) {
        guard let d = linkDrag else { return }
        linkDrag = (d.from, convert(event.locationInWindow, from: nil))
        linksView.pending = linkDrag
        linksView.hoverTarget = controller?.tileID(at: linkDrag!.point)
    }

    func endLinkDrag(event: NSEvent) {
        defer { linkDrag = nil; linksView.pending = nil; linksView.hoverTarget = nil }
        guard let d = linkDrag else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let target = controller?.tileID(at: p), target != d.from {
            controller?.addLink(from: d.from, to: target)
        }
    }

    // MARK: Focus helpers

    func focus(tileID: String, makeFirstResponder: Bool) {
        controller?.focus(tileID: tileID, makeFirstResponder: makeFirstResponder)
    }

    // MARK: Drop files to open

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let p = convert(sender.draggingLocation, from: nil)
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else { return false }
        var at = toWorld(p)
        for u in urls {
            controller?.open(target: u.isFileURL ? u.path : u.absoluteString, at: at)
            at.x += 40; at.y += 40
        }
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        grid.needsDisplay = true
        linksView.refresh()
        GhosttyRuntime.shared.updateColorScheme()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        controller?.layoutAll(live: false)
    }
}

/// Dot grid background drawn with a phase-shifted pattern (cheap to pan).
final class GridView: NSView {
    weak var canvas: CanvasView?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let canvas, let ctx = NSGraphicsContext.current else { return }
        Theme.canvas.setFill()
        dirtyRect.fill()
        guard Prefs.shared.showGrid else { return }
        let z = canvas.viewport.zoom
        var step = CanvasView.gridStep * z
        while step < 12 { step *= 2 }
        let dotR: CGFloat = 1
        let img = NSImage(size: NSSize(width: step, height: step), flipped: true) { r in
            Theme.canvasDot.setFill()
            NSBezierPath(ovalIn: NSRect(x: r.width / 2 - dotR, y: r.height / 2 - dotR, width: dotR * 2, height: dotR * 2)).fill()
            return true
        }
        let o = canvas.viewport.origin
        let phaseX = (-o.x * z).truncatingRemainder(dividingBy: step)
        let phaseY = (-o.y * z).truncatingRemainder(dividingBy: step)
        ctx.saveGraphicsState()
        // Pattern phase is in base (unflipped) coordinates.
        ctx.patternPhase = NSPoint(x: phaseX, y: bounds.height - phaseY)
        NSColor(patternImage: img).setFill()
        dirtyRect.fill()
        ctx.restoreGraphicsState()
    }
}

/// Draws links between tiles and animates message pulses along them.
final class LinksView: NSView {
    weak var canvas: CanvasView?
    var pending: (from: String, point: CGPoint)? { didSet { refresh() } }
    var hoverTarget: String? { didSet { if oldValue != hoverTarget { refresh() } } }
    private var shapes: [String: CAShapeLayer] = [:]
    private var arrowheads: [String: CAShapeLayer] = [:]
    /// Flowing "current" layers per link (glow + sparks), shown while live.
    private var currents: [String: (glow: CAShapeLayer, sparks: CAShapeLayer)] = [:]
    /// When a link last carried a message, and in which direction.
    private var surges: [String: (until: Date, live: Date, forward: Bool)] = [:]
    private let pendingLayer = CAShapeLayer()

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(pendingLayer)
        pendingLayer.fillColor = nil
        pendingLayer.lineWidth = 2
        pendingLayer.lineDashPattern = [5, 5]
    }
    required init?(coder: NSCoder) { fatalError() }

    static func path(from a: CGRect, to b: CGRect) -> CGPath {
        // Connect the closest horizontal edges with a smooth S-curve.
        let leftToRight = a.midX <= b.midX
        let p0 = CGPoint(x: leftToRight ? a.maxX : a.minX, y: a.midY)
        let p1 = CGPoint(x: leftToRight ? b.minX : b.maxX, y: b.midY)
        let dx = max(40, abs(p1.x - p0.x) * 0.5) * (leftToRight ? 1 : -1)
        let path = CGMutablePath()
        path.move(to: p0)
        path.addCurve(to: p1, control1: CGPoint(x: p0.x + dx, y: p0.y), control2: CGPoint(x: p1.x - dx, y: p1.y))
        return path
    }

    func refresh() {
        guard let canvas, let board = canvas.controller?.board else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var seen = Set<String>()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for link in board.links {
                guard let a = board.tile(link.from), let b = board.tile(link.to),
                      let va = canvas.controller?.tileView(link.from), let vb = canvas.controller?.tileView(link.to),
                      !va.isHidden, !vb.isHidden else { continue }
                seen.insert(link.id)
                let shape = shapes[link.id] ?? {
                    let s = CAShapeLayer()
                    s.fillColor = nil
                    s.lineCap = .round
                    layer?.addSublayer(s)
                    shapes[link.id] = s
                    return s
                }()
                shape.path = Self.path(from: va.frame, to: vb.frame)
                let hot = a.state == .waiting || b.state == .waiting
                let active = a.state == .working || b.state == .working
                let color: NSColor = hot ? Theme.amber : (active ? Theme.green : Theme.text3)
                shape.strokeColor = color.withAlphaComponent(link.kind == .spawned ? 0.55 : 0.8).cgColor
                shape.lineWidth = max(1, (link.kind == .manual ? 2 : 1.5) * min(1, canvas.viewport.zoom * 1.2))
                shape.lineDashPattern = link.kind == .spawned ? [2, 4] : nil
                // Hand-off links point downstream with an arrowhead.
                arrowheads[link.id]?.removeFromSuperlayer()
                arrowheads[link.id] = nil
                if link.isHandoff {
                    let head = CAShapeLayer()
                    let p1 = CGPoint(x: vb.frame.midX <= va.frame.midX ? vb.frame.maxX : vb.frame.minX, y: vb.frame.midY)
                    let dir: CGFloat = vb.frame.midX <= va.frame.midX ? -1 : 1
                    let s = 9 * max(0.5, min(1, canvas.viewport.zoom))
                    let path = CGMutablePath()
                    path.move(to: p1)
                    path.addLine(to: CGPoint(x: p1.x - dir * s * 1.4, y: p1.y - s * 0.8))
                    path.addLine(to: CGPoint(x: p1.x - dir * s * 1.4, y: p1.y + s * 0.8))
                    path.closeSubpath()
                    head.path = path
                    head.fillColor = shape.strokeColor
                    layer?.addSublayer(head)
                    arrowheads[link.id] = head
                }
            }
            for (id, s) in shapes where !seen.contains(id) {
                s.removeFromSuperlayer(); shapes[id] = nil
                currents[id]?.glow.removeFromSuperlayer(); currents[id]?.sparks.removeFromSuperlayer(); currents[id] = nil
            }
            // Arrowheads are keyed separately; drop any whose link is gone.
            for (id, h) in arrowheads where !seen.contains(id) {
                h.removeFromSuperlayer(); arrowheads[id] = nil
            }
            updateCurrents(board: board)

            if let p = pending, let va = canvas.controller?.tileView(p.from) {
                var target = CGRect(origin: p.point, size: .zero)
                if let h = hoverTarget, let vb = canvas.controller?.tileView(h) { target = vb.frame }
                pendingLayer.path = Self.path(from: va.frame, to: target)
                pendingLayer.strokeColor = Theme.text2.cgColor
                pendingLayer.isHidden = false
            } else {
                pendingLayer.isHidden = true
            }
        }
        CATransaction.commit()
    }

    /// A message crossed a link: the wire surges with current in the
    /// direction of travel, then keeps humming for a while.
    func pulse(link: Link, fromTile: String, text: String) {
        let forward = fromTile == link.from
        surges[link.id] = (Date().addingTimeInterval(1.6), Date().addingTimeInterval(10), forward)
        refresh()
        // Re-evaluate when the surge ends and when the hum fades.
        for delay in [1.7, 10.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh() }
        }
        guard let canvas, let ctl = canvas.controller,
              let dst = ctl.tileView(forward ? link.to : link.from) else { return }
        let color = Theme.color(for: ctl.board.tile(fromTile)?.state == .waiting ? .waiting : .working)
        if Prefs.shared.motion {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { dst.flashReceive(color: color) }
        }
    }

    /// Adds, updates or removes the flowing current on each link.
    private func updateCurrents(board: Board) {
        guard let canvas, let ctl = canvas.controller else { return }
        let now = Date()
        let z = min(1, canvas.viewport.zoom * 1.2)
        for link in board.links {
            guard let base = shapes[link.id], let path = base.path,
                  let a = board.tile(link.from), let b = board.tile(link.to) else { continue }
            let surge = surges[link.id]
            let surging = surge.map { $0.until > now } ?? false
            let humming = surge.map { $0.live > now } ?? false
            let busy = link.kind == .manual && a.state == .working && b.state == .working
            guard Prefs.shared.wiresOn, surging || humming || busy else {
                if let c = currents[link.id] {
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = c.glow.opacity; fade.toValue = 0; fade.duration = 0.6
                    c.glow.add(fade, forKey: "out"); c.sparks.add(fade, forKey: "out")
                    c.glow.opacity = 0; c.sparks.opacity = 0
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        if self.currents[link.id]?.glow === c.glow, c.glow.opacity == 0 {
                            c.glow.removeFromSuperlayer(); c.sparks.removeFromSuperlayer(); self.currents[link.id] = nil
                        }
                    }
                }
                continue
            }
            let hot = a.state == .waiting || b.state == .waiting
            let color: NSColor = hot ? Theme.amber : (surging ? Theme.amber : Theme.green)
            let c = currents[link.id] ?? {
                let glow = CAShapeLayer(), sparks = CAShapeLayer()
                for l in [glow, sparks] {
                    l.fillColor = nil
                    l.lineCap = .round
                    l.shadowOffset = .zero
                    layer?.addSublayer(l)
                }
                currents[link.id] = (glow, sparks)
                return (glow, sparks)
            }()
            // Forward = from → to; dashes move forward with a negative phase.
            let forward = surge?.forward ?? true
            let intensity: Float = surging ? 1 : (humming ? 0.75 : 0.45)
            for (l, dash, width, speed, radius) in [
                (c.glow, [10, 18] as [NSNumber], 4 * z, surging ? 0.55 : 1.1, 8.0),
                (c.sparks, [1.5, 22] as [NSNumber], 2.5 * z, surging ? 0.22 : 0.5, 4.0),
            ] {
                l.path = path
                l.strokeColor = color.withAlphaComponent(l === c.glow ? 0.45 : 1).cgColor
                l.shadowColor = color.cgColor
                l.shadowOpacity = 1
                l.shadowRadius = radius * z
                l.lineWidth = max(1, surging ? width * 1.5 : width)
                l.lineDashPattern = dash
                l.opacity = intensity
                let cycle = dash.reduce(0) { $0 + $1.doubleValue }
                let key = "flow-\(forward)-\(speed)"
                if l.animation(forKey: key) == nil {
                    l.removeAllAnimations()
                    let flow = CABasicAnimation(keyPath: "lineDashPhase")
                    flow.fromValue = 0
                    flow.toValue = forward ? -cycle : cycle
                    flow.duration = speed
                    flow.repeatCount = .infinity
                    l.add(flow, forKey: key)
                }
            }
            // Brighten the wire itself while current flows.
            base.strokeColor = color.withAlphaComponent(0.9).cgColor
        }
    }

}

/// A layer-hosting view that never takes mouse events.
final class PassthroughView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A labeled group of tiles drawn behind them.
final class FrameGroupView: NSView {
    var group: FrameGroup
    weak var canvas: CanvasView?
    private let label = NSTextField(labelWithString: "")
    private let swatch = CALayer()
    private var dragStart: NSPoint?
    private var frameAtStart = CGRect.zero

    override var isFlipped: Bool { true }

    init(group: FrameGroup) {
        self.group = group
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.addSublayer(swatch)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        addSubview(label)
        update(group)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ g: FrameGroup) {
        group = g
        label.stringValue = g.title
        needsLayout = true
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() { updateColors() }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.frameFill.cgColor
            layer?.borderColor = Theme.hairline.cgColor
            layer?.borderWidth = 1
            swatch.backgroundColor = Theme.boardColors[group.colorIndex % Theme.boardColors.count].cgColor
            label.textColor = Theme.text
        }
    }

    func apply(zoom: CGFloat) {
        layer?.cornerRadius = 26 * zoom
        label.font = .systemFont(ofSize: 15 * zoom, weight: .semibold)
        swatch.frame = CGRect(x: 20 * zoom, y: 18 * zoom, width: 10 * zoom, height: 10 * zoom)
        swatch.cornerRadius = 3 * zoom
        label.frame = NSRect(x: 38 * zoom, y: 13 * zoom, width: max(0, bounds.width - 60 * zoom), height: 20 * zoom)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let sv = superview else { return nil }
        let p = convert(point, from: sv)
        // Only the title strip is interactive; the body passes through to the canvas.
        return bounds.contains(p) && p.y < 44 * (canvas?.viewport.zoom ?? 1) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { canvas?.controller?.renameFrame(group.id); return }
        dragStart = event.locationInWindow
        frameAtStart = group.frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard let s = dragStart, let canvas else { return }
        let dx = (event.locationInWindow.x - s.x) / canvas.viewport.zoom
        let dy = -(event.locationInWindow.y - s.y) / canvas.viewport.zoom
        let target = CanvasView.snap(CGPoint(x: frameAtStart.minX + dx, y: frameAtStart.minY + dy))
        canvas.controller?.moveFrame(group.id, to: target, persist: false)
    }

    override func mouseUp(with event: NSEvent) {
        if dragStart != nil { canvas?.controller?.moveFrame(group.id, to: group.frame.origin, persist: true) }
        dragStart = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        if let m = canvas?.controller?.frameMenu(group.id) { NSMenu.popUpContextMenu(m, with: event, for: self) }
    }
}
