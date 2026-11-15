import AppKit
import SwiftUI
import Combine

/// The single Pitwall window: canvas underneath, glass overlays on top.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let model = AppModel()
    let canvas = CanvasView(frame: .zero)
    private(set) var controller: CanvasController!
    private var picker: NSHostingView<PickerView>?
    private var sidebarHost: NSView!
    private var toolbarHost: NSView?
    private var inboxHost: NSView?
    private var inboxMonitor: Any?
    private var searchHost: NSView?
    private var scrollMonitor: Any?
    private var scrollLatch = ScrollLatch<NSView>()
    private var trailingHost: NSView?
    private var dispatchHost: NSView?
    private var sidebarLeading: NSLayoutConstraint!
    private var dispatchCenter: NSLayoutConstraint!
    private var bag = Set<AnyCancellable>()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Pitwall"
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 760, height: 520)
        if UserDefaults.pitwall === UserDefaults.standard { window.setFrameAutosaveName("PitwallMain") }
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        if window.frame.origin == .zero { window.center() }

        controller = CanvasController(canvas: canvas)
        controller.model = model
        model.controller = controller
        buildViews()
        controller.reconcile()
        model.refreshAttention()

        if !model.sidebarVisible { sidebarLeading.constant = -320; dispatchCenter.constant = 0; sidebarHost.alphaValue = 0; sidebarHost.isHidden = true }
        model.onPickerChange = { [weak self] in self?.updatePicker() }
        Prefs.shared.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.canvas.grid.needsDisplay = true
                self.controller.layoutAll(live: false)
                self.controller.reconcile()
                self.controller.refreshTileChrome()
            }
        }.store(in: &bag)
        model.$sidebarVisible.dropFirst().sink { [weak self] v in
            self?.setSidebar(visible: v)
            if self?.controller.fullScreenTileID != nil { DispatchQueue.main.async { self?.controller.layoutAll(live: false) } }
        }.store(in: &bag)
        // "New agent": give the dispatch bar real keyboard focus.
        model.$dispatchFocusToken.dropFirst().sink { [weak self] _ in
            guard let self, let host = self.dispatchHost else { return }
            if self.controller.fullScreenTileID != nil { self.controller.exitFullScreen() }
            self.window?.makeKeyAndOrderFront(nil)
            self.window?.makeFirstResponder(host)
            DispatchQueue.main.async { self.model.dispatchFocused = true }
        }.store(in: &bag)
        model.$inboxOpen.sink { [weak self] open in
            guard let self, let h = self.inboxHost else { return }
            h.isHidden = !open
            if open {
                self.model.inboxSelection = nil
                self.inboxMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                    guard let self, self.model.inboxOpen, e.window === self.window else { return e }
                    return InboxView.handleKey(e, model: self.model) ? nil : e
                }
            } else if let m = self.inboxMonitor {
                NSEvent.removeMonitor(m)
                self.inboxMonitor = nil
            }
        }.store(in: &bag)
        model.search.controller = controller
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self, e.window === self.window else { return e }
            return self.routeScroll(e)
        }
        model.$searchOpen.dropFirst().sink { [weak self] open in
            guard let self, let content = self.window?.contentView else { return }
            self.searchHost?.removeFromSuperview()
            self.searchHost = nil
            guard open else {
                if let id = self.controller.focusedTileID { self.controller.focus(tileID: id, makeFirstResponder: true) }
                return
            }
            if self.controller.fullScreenTileID != nil { self.controller.exitFullScreen() }
            let h = self.host(SearchPanel(model: self.model, search: self.model.search))
            content.addSubview(h)
            NSLayoutConstraint.activate([
                h.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                h.topAnchor.constraint(equalTo: content.topAnchor, constant: 90),
            ])
            self.searchHost = h
            self.window?.makeKeyAndOrderFront(nil)
            self.window?.makeFirstResponder(h)
        }.store(in: &bag)
        model.$fullScreen.dropFirst().sink { [weak self] full in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                for v in [self.toolbarHost, self.trailingHost, self.dispatchHost] { v?.animator().alphaValue = full ? 0 : 1 }
            }
            for v in [self.toolbarHost, self.trailingHost, self.dispatchHost] { v?.isHidden = false }
            if full { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if self.model.fullScreen { [self.toolbarHost, self.trailingHost, self.dispatchHost].forEach { $0?.isHidden = true } }
            } }
        }.store(in: &bag)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildViews() {
        guard let content = window?.contentView else { return }
        canvas.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(canvas)

        let sidebar = host(SidebarView(model: model))
        let toolbar = host(ToolbarPill(model: model))
        let trailing = host(TrailingControls(model: model, zoomLevel: model.zoomLevel))
        let dispatch = host(DispatchBar(model: model, draft: model.draft))
        let toasts = host(ToastStack(model: model))
        let inbox = host(InboxView(model: model))
        inboxHost = inbox
        inbox.isHidden = true
        sidebarHost = sidebar
        toolbarHost = toolbar
        trailingHost = trailing
        dispatchHost = dispatch
        [sidebar, toolbar, trailing, dispatch, toasts, inbox].forEach(content.addSubview)

        dispatchCenter = dispatch.centerXAnchor.constraint(equalTo: canvas.centerXAnchor, constant: 128).withPriority(.defaultHigh)
        sidebarLeading = sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: content.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            sidebarLeading,
            sidebar.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),

            toolbar.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 20).withPriority(.defaultHigh),
            toolbar.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 84),
            toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),

            trailing.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            trailing.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),

            inbox.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            inbox.topAnchor.constraint(equalTo: trailing.bottomAnchor, constant: 12),
            toasts.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            toasts.topAnchor.constraint(equalTo: trailing.bottomAnchor, constant: 14),

            dispatch.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            dispatchCenter,
            dispatch.leadingAnchor.constraint(greaterThanOrEqualTo: sidebar.trailingAnchor, constant: 16).withPriority(.defaultHigh),
            dispatch.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 16),
        ])
    }

    private func host<V: View>(_ view: V) -> NSHostingView<V> {
        let h = NSHostingView(rootView: view)
        h.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 13.0, *) { h.sizingOptions = [.intrinsicContentSize] }
        return h
    }

    private func setSidebar(visible: Bool) {
        if visible { sidebarHost.isHidden = false }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Prefs.shared.motion ? 0.22 : 0
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            // Slide past the panel's shadow so nothing peeks in.
            sidebarLeading.animator().constant = visible ? 6 : -320
            dispatchCenter.animator().constant = visible ? 128 : 0
            sidebarHost.animator().alphaValue = visible ? 1 : 0
            window?.contentView?.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            if !visible { self?.sidebarHost.isHidden = true }
        })
    }

    private func updatePicker() {
        picker?.removeFromSuperview()
        picker = nil
        guard let p = model.pickerPoint, let content = window?.contentView else { return }
        let h = NSHostingView(rootView: PickerView(model: model))
        let size = h.fittingSize
        // Canvas is flipped; content view is not.
        var origin = NSPoint(x: p.view.x + 12, y: content.bounds.height - p.view.y - 24 - size.height + 24)
        origin.x = min(max(origin.x, 16), content.bounds.width - size.width - 16)
        origin.y = min(max(origin.y, 16), content.bounds.height - size.height - 16)
        h.frame = NSRect(origin: origin, size: size)
        content.addSubview(h)
        picker = h
        h.alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; h.animator().alphaValue = 1 }
    }

    // MARK: Scroll latching

    /// AppKit sends every scroll event to whatever is under the cursor, so a
    /// canvas pan that drifts over a tile would suddenly scroll the tile.
    /// Instead, whoever is under the cursor when a gesture begins keeps it
    /// until it ends (momentum included). Mouse wheels have no gestures, so
    /// ticks less than 0.3 s apart count as one scroll.
    private func routeScroll(_ e: NSEvent) -> NSEvent? {
        guard let content = window?.contentView else { return e }
        let p = content.superview.map { $0.convert(e.locationInWindow, from: nil) } ?? e.locationInWindow
        let under = content.hitTest(p)
        let owner = scrollLatch.owner(for: .init(precise: e.hasPreciseScrollingDeltas, phase: e.phase, momentum: e.momentumPhase),
                                      under: under, now: Date())
        if let owner, owner !== under, owner.window === window {
            owner.scrollWheel(with: e)
            return nil
        }
        return e
    }

    // MARK: Window

    func windowDidBecomeKey(_ notification: Notification) {
        if let id = controller.focusedTileID { controller.focus(tileID: id, makeFirstResponder: true) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing the window hides it; agents keep running.
        sender.orderOut(nil)
        return false
    }
}

/// Decides who gets a scroll event. AppKit sends each one to whatever is
/// under the cursor, so a canvas pan that drifts over a tile would suddenly
/// scroll the tile. Instead, whatever is under the cursor when a gesture
/// begins keeps it until the gesture (and its momentum) ends. Mouse wheels
/// have no gestures: ticks less than 0.3 s apart count as one scroll.
struct ScrollLatch<Target: AnyObject> {
    struct Event {
        var precise: Bool
        var phase: NSEvent.Phase
        var momentum: NSEvent.Phase
    }
    private weak var current: Target?
    private var wheelUntil = Date.distantPast

    /// The target that should receive this event.
    mutating func owner(for e: Event, under: Target?, now: Date) -> Target? {
        let starts = e.precise ? (e.phase.contains(.began) || e.phase.contains(.mayBegin)) : now > wheelUntil
        if !e.precise { wheelUntil = now.addingTimeInterval(0.3) }
        if starts || current == nil { current = under }
        let owner = current
        if e.momentum.contains(.ended) || e.momentum.contains(.cancelled) || e.phase.contains(.cancelled) { current = nil }
        return owner
    }
}

extension NSLayoutConstraint {
    func withPriority(_ p: NSLayoutConstraint.Priority) -> NSLayoutConstraint { priority = p; return self }
}
