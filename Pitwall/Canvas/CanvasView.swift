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
        cameraLink?.invalidate()
        cameraStep = { [weak self] in
            guard let self else { return true }
            let t = min(1, (CACurrentMediaTime() - t0) / duration)
            // Quick hops ease out; long camera moves ease in and out.
            let e = duration > 0.6 ? (t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2) : 1 - pow(1 - t, 3)
            var v = Viewport()
            // Interpolate zoom geometrically for a natural feel.
            v.zoom = start.zoom * pow(target.zoom / start.zoom, e)
            let c0 = CGPoint(x: start.origin.x + self.bounds.width / 2 / start.zoom, y: start.origin.y + self.bounds.height / 2 / start.zoom)
            let c1 = CGPoint(x: target.origin.x + self.bounds.width / 2 / target.zoom, y: target.origin.y + self.bounds.height / 2 / target.zoom)
            let c = CGPoint(x: c0.x + (c1.x - c0.x) * e, y: c0.y + (c1.y - c0.y) * e)
            v.origin = CGPoint(x: c.x - self.bounds.width / 2 / v.zoom, y: c.y - self.bounds.height / 2 / v.zoom)
            let done = t >= 1
            self.setViewport(done ? target : v, live: !done, persist: done)
            if done { self.controller?.layoutAll(live: false) }
            return done
        }
        // Step once per display refresh, in sync with the screen.
        let link = displayLink(target: self, selector: #selector(cameraTick(_:)))
        link.add(to: .main, forMode: .common)
        cameraLink = link
    }

    private var cameraLink: CADisplayLink?
    private var cameraStep: (() -> Bool)?

    @objc private func cameraTick(_ link: CADisplayLink) {
        if cameraStep?() ?? true {
            link.invalidate()
            if cameraLink === link { cameraLink = nil; cameraStep = nil }
        }
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

/// A labeled group of tiles drawn behind them. The title strip shows a
/// collapse chevron and a live summary; edges resize the frame.
final class FrameGroupView: NSView {
    struct Summary: Equatable {
        var text = ""
        var states: [AgentState] = []
        var attention = false
    }

    var group: FrameGroup
    weak var canvas: CanvasView?
    var summary = Summary() { didSet { if summary != oldValue { renderSummary() } } }
    var dropTarget = false { didSet { if dropTarget != oldValue { updateColors() } } }

    private let label = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let swatch = CALayer()
    private let chevron = NSImageView()
    private var dots: [CALayer] = []
    private var zoom: CGFloat = 1
    private var dragStart: NSPoint?
    private var frameAtStart = CGRect.zero
    private enum Mode { case move, resize(right: Bool, bottom: Bool, left: Bool) }
    private var mode: Mode = .move

    override var isFlipped: Bool { true }

    init(group: FrameGroup) {
        self.group = group
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.addSublayer(swatch)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.alignment = .right
        chevron.imageScaling = .scaleProportionallyUpOrDown
        [label, summaryLabel, chevron].forEach(addSubview)
        update(group)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ g: FrameGroup) {
        let collapsedChanged = g.collapsed != group.collapsed
        group = g
        label.stringValue = g.title
        chevron.image = NSImage(systemSymbolName: g.collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: g.collapsed ? "Expand" : "Collapse")
        chevron.setAccessibilityLabel(g.collapsed ? "Expand frame" : "Collapse frame")
        if collapsedChanged { renderSummary() }
        needsLayout = true
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() { updateColors(); renderSummary() }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = Theme.boardColors[group.colorIndex % Theme.boardColors.count]
            layer?.backgroundColor = (dropTarget ? accent.withAlphaComponent(0.10) : (group.collapsed ? Theme.tile : Theme.frameFill)).cgColor
            let attention = group.collapsed && summary.attention
            layer?.borderColor = (dropTarget ? accent : (attention ? Theme.amber : Theme.hairline)).cgColor
            layer?.borderWidth = dropTarget || attention ? 1.5 : 1
            layer?.shadowOpacity = group.collapsed ? 0.12 : 0
            layer?.shadowRadius = 10
            layer?.shadowOffset = CGSize(width: 0, height: -3)
            swatch.backgroundColor = accent.cgColor
            label.textColor = Theme.text
            summaryLabel.textColor = attention ? Theme.amberText : Theme.text2
            chevron.contentTintColor = Theme.text2
        }
    }

    private func renderSummary() {
        summaryLabel.stringValue = summary.text
        dots.forEach { $0.removeFromSuperlayer() }
        dots = []
        // Status dots only when collapsed (the tiles themselves show it otherwise).
        if group.collapsed {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                for s in summary.states {
                    let d = CALayer()
                    d.backgroundColor = Theme.color(for: s).cgColor
                    layer?.addSublayer(d)
                    dots.append(d)
                }
            }
        }
        updateColors()
        needsLayout = true
    }

    func apply(zoom: CGFloat) {
        self.zoom = zoom
        layer?.cornerRadius = (group.collapsed ? 18 : 26) * zoom
        label.font = .systemFont(ofSize: 15 * zoom, weight: .semibold)
        summaryLabel.font = .systemFont(ofSize: 12 * zoom, weight: .medium)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let z = zoom
        let h = FrameGroup.headerHeight * z
        let midY = h / 2
        chevron.frame = NSRect(x: 16 * z, y: midY - 6 * z, width: 12 * z, height: 12 * z)
        swatch.frame = CGRect(x: 36 * z, y: midY - 5 * z, width: 10 * z, height: 10 * z)
        swatch.cornerRadius = 3 * z
        let dotsW = CGFloat(dots.count) * 12 * z
        let summaryW = min(max(0, bounds.width * 0.45), summaryLabel.attributedStringValue.size().width + 8 * z)
        let right = bounds.width - 20 * z
        summaryLabel.frame = NSRect(x: right - summaryW, y: midY - 9 * z, width: summaryW, height: 18 * z)
        for (i, d) in dots.enumerated() {
            let x = right - summaryW - 8 * z - dotsW + CGFloat(i) * 12 * z
            d.frame = CGRect(x: x, y: midY - 4 * z, width: 8 * z, height: 8 * z)
            d.cornerRadius = 4 * z
        }
        let labelX = 54 * z
        label.frame = NSRect(x: labelX, y: midY - 10 * z, width: max(0, right - summaryW - dotsW - 16 * z - labelX), height: 20 * z)
    }

    // MARK: Hit testing: title strip and edges are interactive; the body passes through.

    private var edge: CGFloat { 8 }

    private func zone(_ p: NSPoint) -> Mode? {
        let headerH = FrameGroup.headerHeight * zoom
        if group.collapsed { return bounds.contains(p) ? .move : nil }
        let r = p.x >= bounds.width - edge, b = p.y >= bounds.height - edge, l = p.x <= edge
        if (r || b || l) && bounds.contains(p) { return .resize(right: r, bottom: b, left: l) }
        if bounds.contains(p) && p.y < headerH { return .move }
        return nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let sv = superview else { return nil }
        return zone(convert(point, from: sv)) != nil ? self : nil
    }

    override func resetCursorRects() {
        guard !group.collapsed else { return }
        let w = bounds.width, h = bounds.height
        addCursorRect(NSRect(x: w - edge, y: 0, width: edge, height: h - edge), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: 0, y: 0, width: edge, height: h - edge), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: edge, y: h - edge, width: w - edge * 2, height: edge), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: w - edge, y: h - edge, width: edge, height: edge), cursor: TileView.diagonal(nwse: true))
        addCursorRect(NSRect(x: 0, y: h - edge, width: edge, height: edge), cursor: TileView.diagonal(nwse: false))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let ctl = canvas?.controller
        if chevron.frame.insetBy(dx: -10 * zoom, dy: -10 * zoom).contains(p) { ctl?.toggleCollapsed(group.id); return }
        if event.clickCount == 2 {
            if group.collapsed { ctl?.toggleCollapsed(group.id) } else { ctl?.renameFrame(group.id) }
            return
        }
        mode = zone(p) ?? .move
        dragStart = event.locationInWindow
        frameAtStart = group.frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard let s = dragStart, let canvas else { return }
        let dx = (event.locationInWindow.x - s.x) / canvas.viewport.zoom
        let dy = -(event.locationInWindow.y - s.y) / canvas.viewport.zoom
        switch mode {
        case .move:
            let target = CanvasView.snap(CGPoint(x: frameAtStart.minX + dx, y: frameAtStart.minY + dy))
            canvas.controller?.moveFrame(group.id, to: target, persist: false)
        case .resize(let r, let b, let l):
            var f = frameAtStart
            if r { f.size.width = frameAtStart.width + dx }
            if b { f.size.height = frameAtStart.height + dy }
            if l { f.origin.x = frameAtStart.minX + dx; f.size.width = frameAtStart.width - dx }
            canvas.controller?.resizeFrame(group.id, to: f, persist: false)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if dragStart != nil {
            switch mode {
            case .move: canvas?.controller?.moveFrame(group.id, to: group.frame.origin, persist: true)
            case .resize: canvas?.controller?.resizeFrame(group.id, to: group.frame, persist: true)
            }
        }
        dragStart = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        if let m = canvas?.controller?.frameMenu(group.id) { NSMenu.popUpContextMenu(m, with: event, for: self) }
    }
}
