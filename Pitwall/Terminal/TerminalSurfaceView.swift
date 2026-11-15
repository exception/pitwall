// Portions adapted from Ghostty (https://github.com/ghostty-org/ghostty),
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.

import AppKit
import Carbon
import GhosttyKit

protocol TerminalSurfaceDelegate: AnyObject {
    func surface(_ view: TerminalSurfaceView, titleChanged title: String)
    func surface(_ view: TerminalSurfaceView, pwdChanged pwd: String)
    func surface(_ view: TerminalSurfaceView, notification title: String, body: String)
    func surfaceDidRingBell(_ view: TerminalSurfaceView)
    func surface(_ view: TerminalSurfaceView, progress: ghostty_action_progress_report_state_e, percent: Int)
    func surface(_ view: TerminalSurfaceView, commandFinished exitCode: Int, duration: UInt64)
    func surface(_ view: TerminalSurfaceView, childExited exitCode: Int)
    func surface(_ view: TerminalSurfaceView, openURL url: String)
    func surfaceDidRequestClose(_ view: TerminalSurfaceView, processAlive: Bool)
    func surfaceDidFocus(_ view: TerminalSurfaceView)
}

/// An AppKit view hosting one libghostty surface.
///
/// The view is sized in world points (100%); the canvas zoom is applied by a
/// scaled parent, so the terminal grid never changes while zooming.
final class TerminalSurfaceView: NSView, NSTextInputClient {
    struct Launch {
        var command: String?
        var workingDirectory: String?
        var env: [String: String] = [:]
    }

    weak var delegate: TerminalSurfaceDelegate?
    /// Agent CLIs (Claude Code, Codex) read images off the clipboard on
    /// Ctrl+V, so ⌘V with only an image on the clipboard sends Ctrl+V.
    var imagePasteSendsControlV = false
    /// Output only: keystrokes and pastes are ignored (copying still works).
    var readOnly = false
    private(set) var surface: ghostty_surface_t?
    var cellSize: CGSize = .zero

    /// Canvas zoom applied to this surface.
    var zoom: CGFloat = 1 {
        didSet { if oldValue != zoom { updateScaleAndSize() } }
    }

    private var lastPixelSize = CGSize.zero
    private var lastScale: CGFloat = 0
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var lastPerformKeyEvent: TimeInterval?
    private var trackingArea: NSTrackingArea?
    private var cursorShape: NSCursor = .iBeam
    private(set) var focused = false

    init(launch: Launch, zoom: CGFloat) {
        self.zoom = zoom
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        guard let app = GhosttyRuntime.shared.app else { return }

        var cfg = ghostty_surface_config_new()
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        cfg.font_size = 0
        cfg.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        let keys = launch.env.keys.map { strdup($0)! }
        let vals = launch.env.values.map { strdup($0)! }
        defer { keys.forEach { free($0) }; vals.forEach { free($0) } }
        var envs = zip(keys, vals).map { ghostty_env_var_s(key: $0.0, value: $0.1) }

        if ProcessInfo.processInfo.environment["PITWALL_DEBUG"] != nil {
            FileHandle.standardError.write(Data("pitwall: surface command=\(launch.command ?? "nil") cwd=\(launch.workingDirectory ?? "nil")\n".utf8))
        }
        surface = launch.workingDirectory.withOptionalCString { cwd in
            launch.command.withOptionalCString { cmd in
                envs.withUnsafeMutableBufferPointer { buf -> ghostty_surface_t? in
                    cfg.working_directory = cwd
                    cfg.command = cmd
                    cfg.env_vars = buf.baseAddress
                    cfg.env_var_count = buf.count
                    return ghostty_surface_new(app, &cfg)
                }
            }
        }
        updateTrackingAreas()
        registerForDraggedTypes([.fileURL, .URL, .string])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let surface { ghostty_surface_free(surface) }
    }

    /// Frees the surface now (closing its PTY client) instead of at deinit.
    func destroy() {
        if let surface { ghostty_surface_free(surface) }
        surface = nil
    }

    // MARK: Geometry

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateScaleAndSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        updateScaleAndSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let surface, let screen = window?.screen,
           let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
            ghostty_surface_set_display_id(surface, id)
        }
        updateScaleAndSize()
    }

    private func updateScaleAndSize() {
        guard let surface, bounds.width > 1, bounds.height > 1 else { return }
        let backing = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let scale = backing * zoom
        if scale != lastScale { ghostty_surface_set_content_scale(surface, scale, scale) }
        // Not convertToBacking: that would include the canvas zoom applied by
        // our scaled parent and change the grid on every zoom step.
        let pw = (bounds.width * backing).rounded(), ph = (bounds.height * backing).rounded()
        guard pw != lastPixelSize.width || ph != lastPixelSize.height || scale != lastScale else { return }
        lastPixelSize = CGSize(width: pw, height: ph)
        lastScale = scale
        ghostty_surface_set_size(surface, UInt32(max(pw, 1)), UInt32(max(ph, 1)))
    }

    /// Hides rendering while the tile is off-screen or shown as a card.
    func setOccluded(_ occluded: Bool) {
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, !occluded)
    }

    func setColorScheme(dark: Bool) {
        guard let surface else { return }
        ghostty_surface_set_color_scheme(surface, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    // MARK: Text helpers

    func sendText(_ text: String) {
        guard let surface else { return }
        let len = text.utf8CString.count
        text.withCString { ghostty_surface_text(surface, $0, UInt(len - 1)) }
    }

    /// Types `text` then presses Return, as if the user did.
    func submit(_ text: String) {
        sendText(text)
        guard let surface else { return }
        var ev = ghostty_input_key_s()
        ev.action = GHOSTTY_ACTION_PRESS
        ev.keycode = 0x24 // kVK_Return
        ev.mods = GHOSTTY_MODS_NONE
        ev.consumed_mods = GHOSTTY_MODS_NONE
        "\r".withCString { p in
            ev.text = p
            _ = ghostty_surface_key(surface, ev)
        }
        ev.action = GHOSTTY_ACTION_RELEASE
        ev.text = nil
        _ = ghostty_surface_key(surface, ev)
    }

    /// Presses a non-text key (arrows, escape, tab, return) as a real key event.
    static let namedKeys: [String: UInt32] = ["return": 0x24, "enter": 0x24, "escape": 0x35, "esc": 0x35, "tab": 0x30,
                                              "up": 0x7E, "down": 0x7D, "left": 0x7B, "right": 0x7C, "space": 0x31]
    func press(key name: String) -> Bool {
        guard let surface, let code = Self.namedKeys[name.lowercased()] else { return false }
        var ev = ghostty_input_key_s()
        ev.action = GHOSTTY_ACTION_PRESS
        ev.keycode = code
        ev.mods = GHOSTTY_MODS_NONE
        ev.consumed_mods = GHOSTTY_MODS_NONE
        _ = ghostty_surface_key(surface, ev)
        ev.action = GHOSTTY_ACTION_RELEASE
        _ = ghostty_surface_key(surface, ev)
        return true
    }

    private func pressControlV() {
        guard let surface else { return }
        var ev = ghostty_input_key_s()
        ev.action = GHOSTTY_ACTION_PRESS
        ev.keycode = 0x09 // kVK_ANSI_V
        ev.mods = GHOSTTY_MODS_CTRL
        ev.consumed_mods = GHOSTTY_MODS_NONE
        ev.unshifted_codepoint = 0x76 // "v"
        // Same shape as a real Ctrl+V: the letter, with the ctrl modifier.
        "v".withCString { p in
            ev.text = p
            _ = ghostty_surface_key(surface, ev)
        }
        ev.action = GHOSTTY_ACTION_RELEASE
        ev.text = nil
        _ = ghostty_surface_key(surface, ev)
    }

    func readVisibleText() -> String? {
        guard let surface else { return nil }
        var sel = ghostty_selection_s()
        sel.top_left = ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
        sel.bottom_right = ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
        sel.rectangle = false
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, sel, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { setFocus(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { setFocus(false) }
        return ok
    }

    private func setFocus(_ f: Bool) {
        focused = f
        if let surface { ghostty_surface_set_focus(surface, f) }
        if f { delegate?.surfaceDidFocus(self) }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways, .cursorUpdate],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
        super.updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) { cursorShape.set() }

    func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
        let c: NSCursor
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: c = .arrow
        case GHOSTTY_MOUSE_SHAPE_POINTER: c = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_TEXT: c = .iBeam
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: c = .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB: c = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: c = .closedHand
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: c = .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE, GHOSTTY_MOUSE_SHAPE_COL_RESIZE: c = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE, GHOSTTY_MOUSE_SHAPE_ROW_RESIZE: c = .resizeUpDown
        default: c = .iBeam
        }
        cursorShape = c
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            let p = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if self.bounds.contains(p) { c.set() }
        }
    }

    /// `convert` already undoes the canvas zoom, so these are 100% points.
    private func sendMousePos(_ event: NSEvent) {
        guard let surface else { return }
        let p = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, p.x, bounds.height - p.y,
                                  TerminalInput.mods(event.modifierFlags))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let surface else { return }
        sendMousePos(event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, TerminalInput.mods(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, TerminalInput.mods(event.modifierFlags))
        ghostty_surface_mouse_pressure(surface, 0, 0)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return super.rightMouseDown(with: event) }
        if !ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, TerminalInput.mods(event.modifierFlags)) {
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return super.rightMouseUp(with: event) }
        if !ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, TerminalInput.mods(event.modifierFlags)) {
            super.rightMouseUp(with: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        // Middle-drag pans the canvas.
        if event.buttonNumber == 2 { return super.otherMouseDown(with: event) }
    }

    override func mouseMoved(with event: NSEvent) { sendMousePos(event) }
    override func mouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMousePos(event) }

    override func mouseEntered(with event: NSEvent) { sendMousePos(event) }
    override func mouseExited(with event: NSEvent) {
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, TerminalInput.mods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        // Shift-scroll, pinch-modifiers and unfocused tiles pan the canvas instead.
        if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            return super.scrollWheel(with: event)
        }
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise { x *= 2; y *= 2 }
        var mods: Int32 = precise ? 1 : 0
        let momentum: Int32
        switch event.momentumPhase {
        case .began: momentum = 1
        case .stationary: momentum = 2
        case .changed: momentum = 3
        case .ended: momentum = 4
        case .cancelled: momentum = 5
        case .mayBegin: momentum = 6
        default: momentum = 0
        }
        mods |= momentum << 1
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if readOnly { return }
        guard let surface else { interpretKeyEvents([event]); return }

        let translationModsGhostty = TerminalInput.flags(ghostty_surface_key_translation_mods(surface, TerminalInput.mods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationModsGhostty.contains(flag) { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type, location: event.locationInWindow, modifierFlags: translationMods,
                timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let markedTextBefore = markedText.length > 0
        let keyboardIdBefore: String? = markedTextBefore ? nil : TerminalInput.keyboardLayoutID
        lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        if !markedTextBefore && keyboardIdBefore != TerminalInput.keyboardLayoutID { return }
        syncPreedit(clearIfNeeded: markedTextBefore)
        let composing = markedText.length > 0 || markedTextBefore

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list {
                if TerminalInput.suppressComposingControl(text, composing: composing) { continue }
                if markedTextBefore {
                    _ = committedTextAction(action, text: text)
                } else {
                    _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
                }
            }
        } else {
            if TerminalInput.suppressComposingControl(event.characters, composing: composing) { return }
            _ = keyAction(action, event: event, translationEvent: translationEvent,
                          text: TerminalInput.characters(translationEvent), composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, focused, let surface else { return false }

        if readOnly {
            // Copying out still works; everything else goes to the app's menus.
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return false }
            switch event.charactersIgnoringModifiers {
            case "c": copy(nil); return true
            case "a": selectAll(nil); return true
            default: return false
            }
        }

        if imagePasteSendsControlV, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "v", ImageAttachments.isImageOnly(.general) {
            pressControlV()
            return true
        }

        // Terminal bindings (copy, paste, …) win.
        var ev = TerminalInput.keyEvent(event, GHOSTTY_ACTION_PRESS)
        var flags = ghostty_binding_flags_e(0)
        let isBinding = (event.characters ?? "").withCString { p -> Bool in
            ev.text = p
            return ghostty_surface_key_is_binding(surface, ev, &flags)
        }
        if isBinding {
            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            if !event.modifierFlags.contains(.control) { return false }
            equivalent = "\r"
        case "/":
            if !event.modifierFlags.contains(.control) ||
                !event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) { return false }
            equivalent = "_"
        default:
            if event.timestamp == 0 { return false }
            // Command shortcuts belong to the app menu (canvas, tiles, …).
            if event.modifierFlags.contains(.command) { return false }
            if !event.modifierFlags.contains(.control) {
                lastPerformKeyEvent = nil
                return false
            }
            if let last = lastPerformKeyEvent {
                lastPerformKeyEvent = nil
                if last == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }
            lastPerformKeyEvent = event.timestamp
            return false
        }
        if let final = NSEvent.keyEvent(
            with: .keyDown, location: event.locationInWindow, modifierFlags: event.modifierFlags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: equivalent, charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat, keyCode: event.keyCode) {
            keyDown(with: final)
        }
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }
        let mods = TerminalInput.mods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: sidePressed = true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }
        _ = keyAction(action, event: event)
    }

    private func keyAction(_ action: ghostty_input_action_e, event: NSEvent, translationEvent: NSEvent? = nil,
                           text: String? = nil, composing: Bool = false) -> Bool {
        guard let surface else { return false }
        var ev = TerminalInput.keyEvent(event, action, translationMods: translationEvent?.modifierFlags)
        ev.composing = composing
        if let text = TerminalInput.keyEventText(text) {
            return text.withCString { p in
                ev.text = p
                return ghostty_surface_key(surface, ev)
            }
        }
        return ghostty_surface_key(surface, ev)
    }

    private func committedTextAction(_ action: ghostty_input_action_e, text: String) -> Bool {
        guard let surface else { return false }
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.mods = GHOSTTY_MODS_NONE
        ev.consumed_mods = GHOSTTY_MODS_NONE
        return text.withCString { p in
            ev.text = p
            return ghostty_surface_key(surface, ev)
        }
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let s = markedText.string
            let len = s.utf8CString.count
            s.withCString { ghostty_surface_preedit(surface, $0, UInt(len - 1)) }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    override func doCommand(by selector: Selector) {
        if let last = lastPerformKeyEvent, let cur = NSApp.currentEvent, last == cur.timestamp {
            NSApp.sendEvent(cur)
        }
    }

    // MARK: NSTextInputClient

    func hasMarkedText() -> Bool { markedText.length > 0 }
    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString: markedText = NSMutableAttributedString(attributedString: v)
        case let v as String: markedText = NSMutableAttributedString(string: v)
        default: break
        }
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let r = NSRect(x: x, y: bounds.height - y, width: w, height: max(h, 1))
        let win = convert(r, to: nil)
        return window?.convertToScreen(win) ?? win
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        if readOnly { return }
        guard NSApp.currentEvent != nil else { return }
        let chars: String
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as String: chars = v
        default: return
        }
        unmarkText()
        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
            return
        }
        if !chars.isEmpty { _ = committedTextAction(GHOSTTY_ACTION_PRESS, text: chars) }
    }

    // MARK: Drag and drop: paste file paths / URLs

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            sendText(urls.map { $0.isFileURL ? shellQuote($0.path) : $0.absoluteString }.joined(separator: " "))
            return true
        }
        if let s = pb.string(forType: .string) { sendText(s); return true }
        return false
    }

    // MARK: Edit menu

    @objc func copy(_ sender: Any?) {
        guard let surface else { return }
        let a = "copy_to_clipboard"
        _ = ghostty_surface_binding_action(surface, a, UInt(a.utf8.count))
    }

    @objc func paste(_ sender: Any?) {
        guard !readOnly, let surface else { return }
        let a = "paste_from_clipboard"
        _ = ghostty_surface_binding_action(surface, a, UInt(a.utf8.count))
    }

    override func selectAll(_ sender: Any?) {
        guard let surface else { return }
        let a = "select_all"
        _ = ghostty_surface_binding_action(surface, a, UInt(a.utf8.count))
    }
}

/// NSEvent ↔ libghostty key translation.
enum TerminalInput {
    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var m: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { m |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { m |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { m |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { m |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { m |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { m |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(m)
    }

    static func flags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var f = NSEvent.ModifierFlags()
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { f.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { f.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { f.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { f.insert(.command) }
        return f
    }

    static func keyEvent(_ event: NSEvent, _ action: ghostty_input_action_e,
                         translationMods: NSEvent.ModifierFlags? = nil) -> ghostty_input_key_s {
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.keycode = UInt32(event.keyCode)
        ev.text = nil
        ev.composing = false
        ev.mods = mods(event.modifierFlags)
        ev.consumed_mods = mods((translationMods ?? event.modifierFlags).subtracting([.control, .command]))
        ev.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp,
           let chars = event.characters(byApplyingModifiers: []),
           let cp = chars.unicodeScalars.first {
            ev.unshifted_codepoint = cp.value
        }
        return ev
    }

    static func characters(_ event: NSEvent) -> String? {
        guard let chars = event.characters else { return nil }
        if chars.count == 1, let s = chars.unicodeScalars.first {
            if s.value < 0x20 { return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control)) }
            if s.value >= 0xF700 && s.value <= 0xF8FF { return nil }
        }
        return chars
    }

    static func keyEventText(_ s: String?) -> String? {
        guard let s, !s.isEmpty, let first = s.unicodeScalars.first else { return nil }
        if first.value < 0x20 || first.value == 0x7F { return nil }
        return s
    }

    static func suppressComposingControl(_ text: String?, composing: Bool) -> Bool {
        guard composing, let text else { return false }
        let sc = text.unicodeScalars
        guard sc.count == 1, let s = sc.first else { return false }
        return s.value < 0x20
    }

    static var keyboardLayoutID: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }
}

extension Optional where Wrapped == String {
    func withOptionalCString<R>(_ body: (UnsafePointer<CChar>?) throws -> R) rethrows -> R {
        switch self {
        case .some(let s): return try s.withCString { try body($0) }
        case .none: return try body(nil)
        }
    }
}
