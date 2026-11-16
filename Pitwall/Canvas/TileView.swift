import AppKit
import SwiftUI

/// Content hosted inside a tile (terminal, browser, note, …).
protocol TileContent: NSView {
    /// Apply canvas zoom. `live` is true mid-gesture: cheap visual scaling only.
    func apply(zoom: CGFloat, live: Bool)
    func update(tile: Tile)
    var focusTarget: NSView? { get }
    func setVisible(_ visible: Bool)
    func willClose()
}

extension TileContent {
    func update(tile: Tile) {}
    func setVisible(_ visible: Bool) {}
    func willClose() {}
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Chrome around a tile: rounded card, one-line header, status, resize and
/// link handles. Everything is laid out in screen points at the current zoom.
final class TileView: NSView {
    private(set) var tile: Tile
    weak var canvas: CanvasView?
    let content: TileContent

    private let card = FlippedView()           // clips content to the rounded shape
    private let header = FlippedView()
    private let dot = CALayer()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let metaField = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let zoomButton = NSButton()
    private let fullButton = NSButton()
    private let galleryButton = NSButton()
    private let timelineButton = NSButton()
    private var galleryPopover: NSPopover?
    private var timelinePopover: NSPopover?
    /// True while this tile is shown full screen (fills the window).
    var isFullScreen = false { didSet { updateFullScreenChrome() } }
    private let connector = CALayer()
    private let statusCard = StatusCardView()
    private var hovering = false { didSet { updateHoverChrome() } }
    private var zoom: CGFloat = 0 // forces fonts on first apply
    var isFocusedTile = false { didSet { if oldValue != isFocusedTile { updateRing() } } }

    /// Agents become status cards below 50%: their status matters more than
    /// tiny text. Other tiles stay live miniatures until they're very small.
    var showsCard: Bool {
        let agentLike = tile.kind == .agent || tile.kind == .subagent || tile.kind == .remote
        return zoom < (agentLike ? CGFloat(Prefs.shared.cardZoom) : 0.18)
    }

    override var isFlipped: Bool { true }

    init(tile: Tile, content: TileContent) {
        self.tile = tile
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        card.wantsLayer = true
        card.layer?.masksToBounds = true
        card.layer?.cornerCurve = .continuous
        addSubview(card)

        card.addSubview(content)
        header.wantsLayer = true
        card.addSubview(header)

        dot.cornerRadius = 4.5
        header.layer?.addSublayer(dot)
        for f in [titleField, subtitleField, metaField] {
            f.lineBreakMode = .byTruncatingTail
            f.maximumNumberOfLines = 1
            f.cell?.truncatesLastVisibleLine = true
            header.addSubview(f)
        }
        titleField.textColor = Theme.text
        subtitleField.textColor = Theme.text3
        metaField.textColor = Theme.text2
        metaField.alignment = .right

        for (b, sym, label) in [(closeButton, "xmark", "Close tile"), (zoomButton, "scope", "Center stage (⌘↩)"),
                                (fullButton, "arrow.up.left.and.arrow.down.right", "Full screen (⇧⌘F)")] {
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: label)
            b.contentTintColor = Theme.text2
            b.setAccessibilityLabel(label)
            b.toolTip = label
            b.alphaValue = 0
            header.addSubview(b)
        }
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        zoomButton.target = self
        zoomButton.action = #selector(zoomClicked)
        fullButton.target = self
        fullButton.action = #selector(fullClicked)
        galleryButton.isBordered = false
        galleryButton.imagePosition = .imageLeading
        // Keep icon and count together, centered in the pill (otherwise the
        // icon pins to the left edge and the count floats to the right).
        galleryButton.imageHugsTitle = true
        galleryButton.target = self
        galleryButton.action = #selector(galleryClicked)
        galleryButton.wantsLayer = true
        galleryButton.isHidden = true
        galleryButton.toolTip = "Images this agent mentioned"
        header.addSubview(galleryButton)
        timelineButton.isBordered = false
        timelineButton.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "Timeline")
        timelineButton.contentTintColor = Theme.text2
        timelineButton.target = self
        timelineButton.action = #selector(timelineClicked)
        timelineButton.toolTip = "What this agent did"
        timelineButton.alphaValue = 0
        header.addSubview(timelineButton)

        connector.cornerRadius = 6
        connector.borderWidth = 2
        connector.opacity = 0
        layer?.addSublayer(connector)

        statusCard.isHidden = true
        addSubview(statusCard)

        updateTrackingAreas()
        update(tile: tile)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Model

    func update(tile: Tile) {
        self.tile = tile
        titleField.stringValue = tile.displayName
        var sub: [String] = []
        if let b = tile.branch { sub.append(b) }
        else if tile.isTerminalBacked || tile.kind == .remote, let cwd = tile.cwd { sub.append(Self.abbreviate(cwd)) }
        else if tile.kind == .browser, let t = tile.target { sub.append(t) }
        subtitleField.stringValue = sub.joined(separator: " · ")
        metaField.attributedStringValue = metaString()
        statusCard.update(tile: tile)
        content.update(tile: tile)
        let n = tile.images?.count ?? 0
        galleryButton.isHidden = n == 0
        galleryButton.setAccessibilityLabel("\(n) images")
        updateColors()
        needsLayout = true
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func metaString() -> NSAttributedString {
        let s = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12 * zoom, weight: .regular)
        func add(_ t: String, _ c: NSColor) {
            if s.length > 0 { s.append(NSAttributedString(string: "  ", attributes: [.font: font])) }
            s.append(NSAttributedString(string: t, attributes: [.font: font, .foregroundColor: c]))
        }
        if Prefs.shared.showCost, let c = tile.costUSD, c >= 0.01 { add(String(format: "$%.2f", c), Theme.text3) }
        if let a = tile.diffAdded, a > 0 { add("+\(a)", Theme.green) }
        if let r = tile.diffRemoved, r > 0 { add("−\(r)", Theme.red) }
        if tile.hasBackgroundWork, let bg = tile.background {
            let names = bg.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            let one = names[0].hasPrefix("waiting on ") ? names[0] : "running \(names[0])"
            add(bg.count == 1 ? one : "\(bg.count) in background" + (names.count == 1 ? " · \(names[0])" : ""), Theme.green)
        }
        if tile.isWaitingExternally, let w = tile.waitingOn {
            add("waiting on \(w) · \((tile.waitingSince ?? tile.stateSince).elapsedShort)", Theme.green)
        } else if tile.kind != .terminal || tile.state != .idle {
            if tile.state != .idle {
                let label = tile.state == .waiting ? "needs you"
                    : (tile.state == .working && tile.waitLabel != nil ? "waiting" : tile.state.label.lowercased())
                add("\(label) · \(tile.stateSince.elapsedShort)",
                    tile.state == .waiting ? Theme.amberText : Theme.text2)
            }
        }
        return s
    }

    /// Called every few seconds to refresh timers.
    func tick() { metaField.attributedStringValue = metaString(); statusCard.update(tile: tile) }

    // MARK: Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            card.layer?.backgroundColor = (tile.isTerminalBacked ? Theme.terminalBG : Theme.tile).cgColor
            header.layer?.backgroundColor = (tile.isTerminalBacked ? Theme.terminalBG : Theme.tile).cgColor
            dot.backgroundColor = Theme.color(for: tile.state).cgColor
            connector.backgroundColor = Theme.tile.cgColor
            connector.borderColor = Theme.text2.cgColor
            layer?.shadowColor = Theme.tileShadow.cgColor
            updateRing()
        }
    }

    private func updateRing() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let l = layer else { return }
            l.shadowOpacity = 1
            l.shadowOffset = CGSize(width: 0, height: 12 * zoom)
            l.shadowRadius = (isFocusedTile ? 34 : 26) * zoom
            l.shadowColor = (isFocusedTile ? Theme.dynamic(light: Theme.hex(0x141E32, 0.22), dark: Theme.hex(0, 0.7)) : Theme.tileShadow).cgColor
            card.layer?.borderWidth = tile.state == .waiting ? max(1.5, 2 * zoom) : 1
            card.layer?.borderColor = (tile.state == .waiting ? Theme.amber : Theme.hairline).cgColor
            // Outer amber halo for "needs you".
            if tile.state == .waiting {
                l.borderWidth = 5 * zoom
                l.borderColor = Theme.amber.withAlphaComponent(0.35).cgColor
                l.cornerRadius = (Theme.tileRadius + 5) * zoom
            } else {
                l.borderWidth = 0
            }
        }
    }

    // MARK: Layout

    /// Applies zoom and lays out chrome. `live` = mid-gesture.
    private var symbolsStale = false
    private var liveZoom = false
    private var timelineSymbolZoom: CGFloat = 0
    private var gallerySymbolKey: (zoom: CGFloat, count: Int) = (0, -1)

    func apply(zoom: CGFloat, live: Bool) {
        liveZoom = live
        let changed = self.zoom != zoom
        self.zoom = zoom
        if changed {
            titleField.font = .systemFont(ofSize: 14 * zoom, weight: .semibold)
            subtitleField.font = .monospacedSystemFont(ofSize: 11 * zoom, weight: .regular)
            metaField.attributedStringValue = metaString()
            updateRing()
        }
        // Header buttons only show on hover; re-rasterize them once zooming settles.
        if (changed || symbolsStale) && !live {
            for b in [closeButton, zoomButton, fullButton] {
                b.image = b.image?.withSymbolConfiguration(.init(pointSize: 11 * zoom, weight: .semibold))
            }
            symbolsStale = false
        } else if changed {
            symbolsStale = true
        }
        let card = showsCard
        statusCard.isHidden = !card
        self.card.isHidden = card
        // Pausing a terminal is expensive mid-zoom; the card covers it anyway,
        // so only pause it once zooming settles. (Resuming is immediate.)
        let visible = !card && !isHidden
        if visible || !live { content.setVisible(visible) }
        content.apply(zoom: zoom, live: live)
        layoutChrome()
    }

    override func layout() {
        super.layout()
        layoutChrome()
    }

    private func layoutChrome() {
        let b = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let r = Theme.tileRadius * zoom
        card.frame = b
        card.layer?.cornerRadius = r
        layer?.shadowPath = CGPath(roundedRect: b, cornerWidth: r, cornerHeight: r, transform: nil)
        if layer?.borderWidth ?? 0 > 0 {
            // Halo sits outside the card.
            layer?.cornerRadius = r + 5 * zoom
        }

        let h = Theme.headerHeight * zoom
        header.frame = NSRect(x: 0, y: 0, width: b.width, height: h)
        let pad = 16 * zoom
        dot.frame = CGRect(x: pad, y: (h - 9 * zoom) / 2, width: 9 * zoom, height: 9 * zoom)
        dot.cornerRadius = 4.5 * zoom

        let btn = 22 * zoom
        let right = b.width - pad
        closeButton.frame = NSRect(x: right - btn, y: (h - btn) / 2, width: btn, height: btn)
        fullButton.frame = NSRect(x: right - btn * 2 - 4 * zoom, y: (h - btn) / 2, width: btn, height: btn)
        zoomButton.frame = NSRect(x: right - btn * 3 - 8 * zoom, y: (h - btn) / 2, width: btn, height: btn)
        zoomButton.isHidden = isFullScreen
        timelineButton.frame = NSRect(x: (isFullScreen ? fullButton.frame.minX : zoomButton.frame.minX) - btn - 4 * zoom, y: (h - btn) / 2, width: btn, height: btn)
        if !liveZoom && timelineSymbolZoom != zoom {
            timelineButton.image = timelineButton.image?.withSymbolConfiguration(.init(pointSize: 11 * zoom, weight: .semibold))
            timelineSymbolZoom = zoom
        }

        let metaW = min(metaField.attributedStringValue.size().width + 4, b.width * 0.45)
        let chromeVisible = hovering || isFullScreen
        var metaRight = chromeVisible ? (tile.kind == .agent ? timelineButton.frame.minX : (isFullScreen ? fullButton.frame.minX : zoomButton.frame.minX)) - 8 * zoom : right
        if !galleryButton.isHidden {
            let count = tile.images?.count ?? 0
            if liveZoom, gallerySymbolKey.zoom != zoom || gallerySymbolKey.count != count {
                // Keep the old rendering mid-zoom; refreshed when zooming settles.
            } else if gallerySymbolKey.zoom != zoom || gallerySymbolKey.count != count {
                gallerySymbolKey = (zoom, count)
            galleryButton.attributedTitle = NSAttributedString(string: " \(count)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11 * zoom, weight: .semibold), .foregroundColor: Theme.text2])
            galleryButton.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11 * zoom, weight: .medium))
            galleryButton.contentTintColor = Theme.text2
            }
            let gw = (32 + CGFloat(String(count).count) * 7) * zoom
            galleryButton.frame = NSRect(x: metaRight - gw, y: (h - 22 * zoom) / 2, width: gw, height: 22 * zoom)
            galleryButton.layer?.cornerRadius = 11 * zoom
            galleryButton.layer?.backgroundColor = Theme.pill.cgColor
            metaRight = galleryButton.frame.minX - 8 * zoom
        }
        // Center each label on its real line height (a fixed box puts the text high).
        func centered(_ f: NSTextField, x: CGFloat, w: CGFloat) -> NSRect {
            let lh = ceil(f.intrinsicContentSize.height)
            return NSRect(x: x, y: ((h - lh) / 2).rounded(), width: w, height: lh)
        }
        metaField.frame = centered(metaField, x: metaRight - metaW, w: metaW)

        let x0 = dot.frame.maxX + 10 * zoom
        let titleFont = titleField.font ?? .systemFont(ofSize: 14 * zoom, weight: .semibold)
        let natural = ceil((titleField.stringValue as NSString).size(withAttributes: [.font: titleFont]).width) + 4
        let titleW = min(natural, max(0, metaField.frame.minX - x0 - 8 * zoom))
        titleField.frame = centered(titleField, x: x0, w: titleW)
        let sx = titleField.frame.maxX + 8 * zoom
        subtitleField.frame = centered(subtitleField, x: sx, w: max(0, metaField.frame.minX - sx - 8 * zoom))

        content.frame = NSRect(x: 0, y: h, width: b.width, height: max(0, b.height - h))
        statusCard.frame = b
        statusCard.layer?.cornerRadius = r

        connector.frame = CGRect(x: b.width - 6, y: b.height / 2 - 6, width: 12, height: 12)
        CATransaction.commit()
    }

    // MARK: Hover & tracking

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
                                       owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false; NSCursor.arrow.set() }

    private func updateHoverChrome() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            let show = (hovering || isFullScreen) && !showsCard
            closeButton.animator().alphaValue = show ? 1 : 0
            zoomButton.animator().alphaValue = show ? 1 : 0
            fullButton.animator().alphaValue = show ? 1 : 0
            timelineButton.animator().alphaValue = show && (tile.kind == .agent) ? 1 : 0
        }
        connector.opacity = hovering && tile.kind != .subagent && !isFullScreen ? 1 : 0
        needsLayout = true
    }

    enum Zone { case none, move, link, resize(left: Bool, right: Bool, top: Bool, bottom: Bool) }

    func zone(at p: NSPoint) -> Zone {
        if isFullScreen { return p.y < Theme.headerHeight * zoom ? .move : .none }
        let b = bounds
        if connector.opacity > 0, connector.frame.insetBy(dx: -6, dy: -6).contains(p) { return .link }
        let e: CGFloat = 7
        let l = p.x < e, r = p.x > b.width - e, t = p.y < e, bo = p.y > b.height - e
        if l || r || t || bo { return .resize(left: l, right: r, top: t, bottom: bo) }
        if showsCard || p.y < Theme.headerHeight * zoom { return .move }
        return .none
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch zone(at: p) {
        case .resize(let l, let r, let t, let b):
            if (l && t) || (r && b) { Self.diagonal(nwse: true).set() }
            else if (r && t) || (l && b) { Self.diagonal(nwse: false).set() }
            else if l || r { NSCursor.resizeLeftRight.set() } else { NSCursor.resizeUpDown.set() }
        case .link: NSCursor.crosshair.set()
        case .move: NSCursor.arrow.set()
        case .none: break
        }
    }

    static func diagonal(nwse: Bool) -> NSCursor {
        if #available(macOS 15.0, *) {
            return NSCursor.frameResize(position: nwse ? .bottomRight : .bottomLeft, directions: .all)
        }
        return .crosshair
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let sv = superview else { return nil }
        let p = convert(point, from: sv)
        guard bounds.insetBy(dx: -6, dy: -6).contains(p) else { return nil }
        switch zone(at: p) {
        case .none:
            if let v = super.hitTest(point), v !== header { return v }
            return self
        case .move:
            if let v = super.hitTest(point), v is NSButton { return v }
            return self
        default:
            return self
        }
    }

    // MARK: Dragging

    private var dragStart: NSPoint = .zero
    private var dragZone: Zone = .none
    private var frameAtStart: CGRect = .zero

    override func mouseDown(with event: NSEvent) {
        canvas?.focus(tileID: tile.id, makeFirstResponder: true)
        let p = convert(event.locationInWindow, from: nil)
        dragZone = zone(at: p)
        dragStart = event.locationInWindow
        frameAtStart = tile.frame
        if event.clickCount == 2, case .move = dragZone, !showsCard {
            // On the name: rename. Anywhere else on the header: full screen,
            // like double-clicking a window's title bar.
            let onName = titleField.convert(titleField.bounds, to: self).insetBy(dx: -4, dy: -4).contains(p)
            if onName { canvas?.controller?.renameTile(tile.id) } else { canvas?.controller?.toggleFullScreen(tile.id) }
            return
        }
        if case .link = dragZone { canvas?.beginLinkDrag(from: tile.id, event: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let canvas else { return }
        let dx = (event.locationInWindow.x - dragStart.x) / canvas.viewport.zoom
        let dy = -(event.locationInWindow.y - dragStart.y) / canvas.viewport.zoom
        var f = frameAtStart
        if isFullScreen { return }
        switch dragZone {
        case .move:
            f.origin.x += dx; f.origin.y += dy
            f.origin = CanvasView.snap(f.origin)
        case .resize(let l, let r, let t, let b):
            let minW: CGFloat = 240, minH: CGFloat = 140
            if r { f.size.width = max(minW, frameAtStart.width + dx) }
            if b { f.size.height = max(minH, frameAtStart.height + dy) }
            if l { let w = max(minW, frameAtStart.width - dx); f.origin.x = frameAtStart.maxX - w; f.size.width = w }
            if t { let h = max(minH, frameAtStart.height - dy); f.origin.y = frameAtStart.maxY - h; f.size.height = h }
            f = CanvasView.snap(f)
        case .link:
            canvas.continueLinkDrag(event: event); return
        case .none:
            return
        }
        canvas.controller?.moveTile(tile.id, to: f, persist: false)
    }

    override func mouseUp(with event: NSEvent) {
        switch dragZone {
        case .link: canvas?.endLinkDrag(event: event)
        case .move, .resize: canvas?.controller?.moveTile(tile.id, to: tile.frame, persist: true)
        case .none: break
        }
        dragZone = .none
    }

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if case .none = zone(at: p) { return super.rightMouseDown(with: event) }
        if let menu = canvas?.controller?.contextMenu(for: tile.id) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    /// A message arrived over a link: a colored glow swells and fades.
    func flashReceive(color: NSColor) {
        guard let l = layer else { return }
        let glow = CAAnimationGroup()
        let c = CABasicAnimation(keyPath: "shadowColor")
        c.fromValue = color.cgColor; c.toValue = l.shadowColor
        let r = CABasicAnimation(keyPath: "shadowRadius")
        r.fromValue = 40 * zoom; r.toValue = l.shadowRadius
        let o = CABasicAnimation(keyPath: "shadowOpacity")
        o.fromValue = 1; o.toValue = l.shadowOpacity
        glow.animations = [c, r, o]
        glow.duration = 1.2
        glow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        l.add(glow, forKey: "receive")
        let b = CABasicAnimation(keyPath: "borderColor")
        b.fromValue = color.cgColor
        b.toValue = card.layer?.borderColor
        b.duration = 1.2
        card.layer?.add(b, forKey: "receive")
    }

    @objc private func closeClicked() { canvas?.controller?.closeTile(tile.id) }
    @objc private func zoomClicked() { canvas?.controller?.flyTo(tileID: tile.id, fill: true) }
    @objc private func fullClicked() { canvas?.controller?.toggleFullScreen(tile.id) }

    @objc private func timelineClicked() {
        if let p = timelinePopover, p.isShown { p.close(); return }
        guard let window, let content = window.contentView else { return }
        // Measure free space on screen (non-flipped, below the menu bar).
        let inWindow = timelineButton.convert(timelineButton.bounds, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        let visible = window.screen.map { $0.visibleFrame.intersection(window.frame) } ?? window.frame
        let below = onScreen.minY - visible.minY
        let above = visible.maxY - onScreen.maxY
        let downward = below >= 300 || below >= above
        let height = min(420, max(160, (downward ? below : above) - 40))
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = false
        // Fixed size up front: if SwiftUI resizes it after it's shown, AppKit
        // keeps the bottom edge and the popover grows up over its button.
        let host = NSHostingController(rootView: TimelineView_(tileID: tile.id, height: height))
        host.sizingOptions = []
        host.preferredContentSize = NSSize(width: 380, height: height)
        pop.contentViewController = host
        pop.contentSize = host.preferredContentSize
        // Anchor to the window's content view: NSPopover reads edges in the
        // positioning view's own coordinates, and the tile header is flipped.
        timelineDownward = downward
        pop.show(relativeTo: timelineAnchor(in: content), of: content, preferredEdge: timelineEdge(in: content))
        timelinePopover = pop
    }

    private var timelineDownward = true

    private func timelineAnchor(in content: NSView) -> NSRect {
        timelineButton.convert(timelineButton.bounds, to: content)
    }

    private func timelineEdge(in content: NSView) -> NSRectEdge {
        // "Below" is maxY in a flipped view, minY otherwise.
        timelineDownward == content.isFlipped ? .maxY : .minY
    }

    /// Keeps an open timeline attached to its button when the tile moves
    /// (panning, flying to the tile, entering full screen).
    private func repositionPopovers() {
        guard let pop = timelinePopover, pop.isShown else { return }
        guard let content = window?.contentView else { pop.close(); return }
        pop.positioningRect = timelineAnchor(in: content)
    }

    override var frame: NSRect {
        didSet { if oldValue != frame { repositionPopovers() } }
    }

    @objc private func galleryClicked() {
        if let p = galleryPopover, p.isShown { p.close(); return }
        let id = tile.id
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(rootView: GalleryView(paths: (tile.images ?? []).reversed()) { [weak self] path in
            self?.galleryPopover?.close()
            self?.canvas?.controller?.openImage(path, from: id)
        } onClear: { [weak self] in
            self?.galleryPopover?.close()
            Store.shared.updateTile(id) { $0.images = nil }
            self?.canvas?.controller?.reconcile()
        })
        pop.show(relativeTo: galleryButton.bounds, of: galleryButton, preferredEdge: .maxY)
        galleryPopover = pop
    }

    private func updateFullScreenChrome() {
        let sym = isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        let label = isFullScreen ? "Exit full screen (⇧⌘F)" : "Full screen (⇧⌘F)"
        fullButton.image = NSImage(systemSymbolName: sym, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 11 * max(zoom, 0.01), weight: .semibold))
        fullButton.toolTip = label
        fullButton.setAccessibilityLabel(label)
        updateHoverChrome()
        needsLayout = true
    }
}

/// Zoomed-out representation: a readable status card.
final class StatusCardView: NSView {
    private let dot = CALayer()
    private let name = NSTextField(labelWithString: "")
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private let chip = NSTextField(labelWithString: "")
    /// The chip's pill. A label's text sits at the top of its frame, so the
    /// pill is its own layer and the label is centered inside it.
    private let chipPill = CALayer()
    private var state: AgentState = .idle

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.addSublayer(dot)
        name.font = .systemFont(ofSize: 16, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        summary.font = .systemFont(ofSize: 14)
        summary.maximumNumberOfLines = 3
        footer.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        footer.lineBreakMode = .byTruncatingTail
        chip.font = .systemFont(ofSize: 11, weight: .semibold)
        chip.alignment = .center
        chipPill.cornerRadius = 10
        layer?.addSublayer(chipPill)
        [name, summary, footer, chip].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(tile: Tile) {
        state = tile.state
        name.stringValue = tile.displayName
        let where_ = tile.target.map { $0.hasPrefix("/") ? TileView.abbreviate(($0 as NSString).deletingLastPathComponent) : $0 }
        summary.stringValue = tile.statusMessage ?? tile.task ?? (tile.isTerminalBacked ? (tile.terminalTitle ?? tile.cwd.map(TileView.abbreviate) ?? "") : (where_ ?? ""))
        var f: [String] = []
        if let b = tile.branch { f.append(b) }
        if let a = tile.diffAdded, a > 0 { f.append("+\(a)") }
        if let r = tile.diffRemoved, r > 0 { f.append("−\(r)") }
        footer.stringValue = f.joined(separator: "  ")
        chip.stringValue = tile.state == .idle ? "" : "\(tile.state.label) · \(tile.stateSince.elapsedShort)"
        updateColors()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() { updateColors() }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.tile.cgColor
            layer?.borderWidth = state == .waiting ? 2 : 1
            layer?.borderColor = (state == .waiting ? Theme.amber : Theme.hairline).cgColor
            dot.backgroundColor = Theme.color(for: state).cgColor
            name.textColor = Theme.text
            summary.textColor = Theme.text2
            footer.textColor = Theme.text3
            chip.textColor = state == .waiting ? Theme.amberText : Theme.color(for: state)
            chipPill.backgroundColor = Theme.color(for: state).withAlphaComponent(0.14).cgColor
        }
    }

    override func layout() {
        super.layout()
        let b = bounds
        let pad: CGFloat = min(16, b.width * 0.06)
        dot.frame = CGRect(x: pad, y: pad + 6, width: 10, height: 10)
        dot.cornerRadius = 5
        name.frame = NSRect(x: pad + 18, y: pad, width: b.width - pad * 2 - 18, height: 22)
        let textSize = chip.intrinsicContentSize
        let chipW = chip.stringValue.isEmpty ? 0 : textSize.width + 18
        let pill = CGRect(x: b.width - pad - chipW, y: b.height - pad - 20, width: chipW, height: 20)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        chipPill.frame = pill
        chipPill.isHidden = chipW == 0 || b.height <= 70
        CATransaction.commit()
        chip.frame = NSRect(x: pill.minX, y: pill.midY - textSize.height / 2, width: chipW, height: textSize.height)
        footer.frame = NSRect(x: pad, y: b.height - pad - 18, width: max(0, b.width - pad * 3 - chipW), height: 18)
        summary.frame = NSRect(x: pad, y: pad + 30, width: b.width - pad * 2, height: max(0, b.height - pad * 2 - 30 - 26))
        let show = b.height > 70
        summary.isHidden = !show || b.height < 110
        footer.isHidden = !show
        chip.isHidden = !show
    }
}
