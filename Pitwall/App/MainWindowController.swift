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
        window.setFrameAutosaveName("PitwallMain")
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
            }
        }.store(in: &bag)
        model.$sidebarVisible.dropFirst().sink { [weak self] v in
            self?.setSidebar(visible: v)
            if self?.controller.fullScreenTileID != nil { DispatchQueue.main.async { self?.controller.layoutAll(live: false) } }
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
        let trailing = host(TrailingControls(model: model))
        let dispatch = host(DispatchBar(model: model))
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

extension NSLayoutConstraint {
    func withPriority(_ p: NSLayoutConstraint.Priority) -> NSLayoutConstraint { priority = p; return self }
}
