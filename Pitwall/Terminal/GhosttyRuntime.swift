// Portions adapted from Ghostty (https://github.com/ghostty-org/ghostty),
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.

import AppKit
import GhosttyKit

/// Owns the single libghostty app instance and routes its callbacks to the
/// right `TerminalSurfaceView`.
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?

    private init() {}

    var isReady: Bool { app != nil }

    /// Resources bundled at Contents/Resources/ghostty (themes, shell integration).
    static var resourcesDir: String? {
        let path = Bundle.main.resourceURL?.appendingPathComponent("ghostty").path
        return path.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
    }

    func start() {
        guard app == nil else { return }
        if let res = Self.resourcesDir { setenv("GHOSTTY_RESOURCES_DIR", res, 1) }
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            NSLog("pitwall: ghostty_init failed")
            return
        }
        let dark = Theme.isDark
        guard let cfg = Self.makeConfig(dark: dark) else { return }
        config = cfg
        configIsDark = dark

        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { ud in GhosttyRuntime.wakeup(ud) },
            action_cb: { app, target, action in GhosttyRuntime.action(app, target: target, action: action) },
            read_clipboard_cb: { ud, loc, state, mimes, count, list in
                GhosttyRuntime.readClipboard(ud, location: loc, state: state, mimes: mimes, count: count, list: list)
            },
            confirm_read_clipboard_cb: { ud, confirm, state, request in
                GhosttyRuntime.confirmReadClipboard(ud, confirm: confirm, state: state, request: request)
            },
            write_clipboard_cb: { ud, loc, content, len, _ in
                GhosttyRuntime.writeClipboard(ud, location: loc, content: content, len: len)
            },
            close_surface_cb: { ud, processAlive in GhosttyRuntime.closeSurface(ud, processAlive: processAlive) }
        )
        guard let app = ghostty_app_new(&runtime, cfg) else {
            NSLog("pitwall: ghostty_app_new failed")
            return
        }
        self.app = app
        ghostty_app_set_focus(app, NSApp.isActive)
        updateColorScheme()

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            if let app = self?.app { ghostty_app_set_focus(app, true) }
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            if let app = self?.app { ghostty_app_set_focus(app, false) }
        }
        nc.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            if let app = self?.app { ghostty_app_keyboard_changed(app) }
        }
    }

    private var configIsDark: Bool?

    /// Pitwall swaps whole configs on appearance change instead of using
    /// Ghostty's `light:/dark:` themes: conditional configs are rebuilt by
    /// replaying files, which would drop each surface's command.
    func updateColorScheme() {
        guard let app else { return }
        let dark = Theme.isDark
        ghostty_app_set_color_scheme(app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
        if configIsDark != dark { reloadConfig() }
    }

    /// Reloads terminal.ghostty and pushes it to every surface.
    func reloadConfig() {
        guard let app else { return }
        let dark = Theme.isDark
        guard let cfg = Self.makeConfig(dark: dark) else { return }
        ghostty_app_update_config(app, cfg)
        if let old = config { ghostty_config_free(old) }
        config = cfg
        configIsDark = dark
    }

    // MARK: Config

    static let defaultConfig = """
    # Pitwall terminal settings. This file uses Ghostty's config format:
    # https://ghostty.org/docs/config/reference
    window-padding-x = 14
    window-padding-y = 10
    window-padding-balance = true
    cursor-style = bar
    mouse-hide-while-typing = true
    confirm-close-surface = false
    shell-integration = none
    clipboard-read = allow
    clipboard-write = allow
    clipboard-paste-protection = false
    macos-option-as-alt = false
    """

    /// Bindings are owned by Pitwall so canvas shortcuts never get swallowed.
    static let bindings = """
    keybind = clear
    keybind = super+c=copy_to_clipboard
    keybind = super+v=paste_from_clipboard
    keybind = super+a=select_all
    keybind = super+k=clear_screen
    keybind = super+up=jump_to_prompt:-1
    keybind = super+down=jump_to_prompt:1
    keybind = super+home=scroll_to_top
    keybind = super+end=scroll_to_bottom
    keybind = super+page_up=scroll_page_up
    keybind = super+page_down=scroll_page_down
    keybind = super+left=text:\\x01
    keybind = super+right=text:\\x05
    keybind = super+backspace=text:\\x15
    keybind = alt+left=esc:b
    keybind = alt+right=esc:f
    keybind = alt+backspace=text:\\x17
    """

    private static func makeConfig(dark: Bool) -> ghostty_config_t? {
        guard let cfg = ghostty_config_new() else { return nil }
        PitwallPaths.ensure()
        let fm = FileManager.default
        let user = PitwallPaths.terminalConfig
        if !fm.fileExists(atPath: user.path) {
            try? defaultConfig.write(to: user, atomically: true, encoding: .utf8)
        }
        // Base: our themes and bindings, then the user's file on top.
        var base = bindings + "\n"
        let prefs = Prefs.shared
        if !prefs.fontFamily.trimmingCharacters(in: .whitespaces).isEmpty { base += "font-family = \(prefs.fontFamily)\n" }
        base += "font-size = \(Int(prefs.fontSize))\n"
        if prefs.compatTerm { base += "term = xterm-256color\n" }
        if let themes = Bundle.main.resourceURL?.appendingPathComponent("Themes") {
            base += "theme = \(themes.appendingPathComponent(dark ? "Pitwall Dark" : "Pitwall Light").path)\n"
        }
        let baseFile = PitwallPaths.support.appendingPathComponent(".base.ghostty")
        try? base.write(to: baseFile, atomically: true, encoding: .utf8)
        ghostty_config_load_file(cfg, baseFile.path)
        ghostty_config_load_file(cfg, user.path)
        ghostty_config_finalize(cfg)
        let n = ghostty_config_diagnostics_count(cfg)
        for i in 0..<n {
            let d = ghostty_config_get_diagnostic(cfg, i)
            NSLog("pitwall: terminal config: %@", String(cString: d.message))
        }
        return cfg
    }

    // MARK: Callbacks

    private static func wakeup(_ ud: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async {
            if let app = GhosttyRuntime.shared.app { ghostty_app_tick(app) }
        }
    }

    private static func surfaceView(_ ud: UnsafeMutableRawPointer?) -> TerminalSurfaceView? {
        guard let ud else { return nil }
        return Unmanaged<TerminalSurfaceView>.fromOpaque(ud).takeUnretainedValue()
    }

    private static func surfaceView(of surface: ghostty_surface_t) -> TerminalSurfaceView? {
        surfaceView(ghostty_surface_userdata(surface))
    }

    private static func closeSurface(_ ud: UnsafeMutableRawPointer?, processAlive: Bool) {
        guard let view = surfaceView(ud) else { return }
        DispatchQueue.main.async { view.delegate?.surfaceDidRequestClose(view, processAlive: processAlive) }
    }

    private static func readClipboard(
        _ ud: UnsafeMutableRawPointer?, location: ghostty_clipboard_e, state: UnsafeMutableRawPointer,
        mimes: UnsafePointer<UnsafePointer<CChar>>, count: Int, list: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard let view = surfaceView(ud), let surface = view.surface,
              location == GHOSTTY_CLIPBOARD_STANDARD else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        let pb = NSPasteboard.general
        var items: [(String, Data)] = []
        for i in 0..<count {
            let mime = String(cString: mimes[i])
            if let data = pb.pitwallData(forMime: mime) { items.append((mime, data)) }
        }
        if items.isEmpty && !list { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        complete(surface, items: items, available: list ? pb.pitwallAvailableMimes() : [], state: state, confirmed: false)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    private static func confirmReadClipboard(
        _ ud: UnsafeMutableRawPointer?, confirm: UnsafePointer<ghostty_clipboard_confirm_s>,
        state: UnsafeMutableRawPointer, request: ghostty_clipboard_request_e
    ) {
        guard let view = surfaceView(ud), let surface = view.surface else { return }
        // Pastes are always allowed; programs reading the clipboard are not.
        guard request == GHOSTTY_CLIPBOARD_REQUEST_PASTE else {
            ghostty_surface_deny_clipboard_request(surface, state)
            return
        }
        let c = confirm.pointee
        var items: [(String, Data)] = []
        if let contents = c.contents {
            for i in 0..<c.contents_len {
                let item = contents[i]
                let mime = String(cString: item.mime)
                let data = Data(bytes: item.data, count: item.len)
                items.append((mime, data))
            }
        }
        complete(surface, items: items, available: [], state: state, confirmed: true)
    }

    private static func complete(_ surface: ghostty_surface_t, items: [(String, Data)], available: [String],
                                 state: UnsafeMutableRawPointer, confirmed: Bool) {
        // Keep every C string alive for the duration of the call.
        let mimePtrs = items.map { strdup($0.0)! }
        let dataPtrs: [UnsafeMutablePointer<CChar>] = items.map { item in
            let p = UnsafeMutablePointer<CChar>.allocate(capacity: max(item.1.count, 1))
            item.1.withUnsafeBytes { raw in
                if let base = raw.baseAddress { memcpy(p, base, item.1.count) }
            }
            return p
        }
        let availPtrs = available.map { UnsafePointer(strdup($0)!) }
        defer {
            mimePtrs.forEach { free($0) }
            dataPtrs.forEach { $0.deallocate() }
            availPtrs.forEach { free(UnsafeMutableRawPointer(mutating: $0)) }
        }
        var contents = items.indices.map { i in
            ghostty_clipboard_content_s(mime: mimePtrs[i], data: dataPtrs[i], len: items[i].1.count)
        }
        contents.withUnsafeMutableBufferPointer { cbuf in
            availPtrs.withUnsafeBufferPointer { abuf in
                var done = ghostty_clipboard_complete_s(
                    contents: cbuf.baseAddress.map { UnsafePointer($0) }, contents_len: cbuf.count,
                    available: abuf.baseAddress, available_len: abuf.count,
                    confirmed: confirmed, remember: false)
                ghostty_surface_complete_clipboard_request(surface, &done, state)
            }
        }
    }

    private static func writeClipboard(_ ud: UnsafeMutableRawPointer?, location: ghostty_clipboard_e,
                                       content: UnsafePointer<ghostty_clipboard_content_s>, len: Int) {
        guard location == GHOSTTY_CLIPBOARD_STANDARD, len > 0 else { return }
        let pb = NSPasteboard.general
        var wrote = false
        for i in 0..<len {
            let item = content[i]
            let mime = String(cString: item.mime)
            let data = Data(bytes: item.data, count: item.len)
            if mime.hasPrefix("text/plain"), let s = String(data: data, encoding: .utf8) {
                if !wrote { pb.clearContents(); wrote = true }
                pb.setString(s, forType: .string)
            } else if mime == "image/png" {
                if !wrote { pb.clearContents(); wrote = true }
                pb.setData(data, forType: .png)
            }
        }
    }

    private static func action(_ app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface,
              let view = surfaceView(of: surface) else {
            return false
        }
        let d = view.delegate
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            let title = String(cString: action.action.set_title.title)
            DispatchQueue.main.async { d?.surface(view, titleChanged: title) }
            return true
        case GHOSTTY_ACTION_PWD:
            let pwd = String(cString: action.action.pwd.pwd)
            DispatchQueue.main.async { d?.surface(view, pwdChanged: pwd) }
            return true
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let n = action.action.desktop_notification
            let title = String(cString: n.title)
            let body = String(cString: n.body)
            DispatchQueue.main.async { d?.surface(view, notification: title, body: body) }
            return true
        case GHOSTTY_ACTION_RING_BELL:
            DispatchQueue.main.async { d?.surfaceDidRingBell(view) }
            return true
        case GHOSTTY_ACTION_PROGRESS_REPORT:
            let p = action.action.progress_report
            DispatchQueue.main.async { d?.surface(view, progress: p.state, percent: Int(p.progress)) }
            return true
        case GHOSTTY_ACTION_COMMAND_FINISHED:
            let c = action.action.command_finished
            DispatchQueue.main.async { d?.surface(view, commandFinished: Int(c.exit_code), duration: c.duration) }
            return true
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            let code = Int(action.action.child_exited.exit_code)
            DispatchQueue.main.async { d?.surface(view, childExited: code) }
            return true
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            view.setCursorShape(action.action.mouse_shape)
            return true
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            NSCursor.setHiddenUntilMouseMoves(action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN)
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            let u = action.action.open_url
            let s = String(decoding: UnsafeRawBufferPointer(start: u.url, count: Int(u.len)), as: UTF8.self)
            DispatchQueue.main.async { d?.surface(view, openURL: s) }
            return true
        case GHOSTTY_ACTION_CELL_SIZE:
            let c = action.action.cell_size
            view.cellSize = CGSize(width: CGFloat(c.width), height: CGFloat(c.height))
            return true
        case GHOSTTY_ACTION_RENDER, GHOSTTY_ACTION_SCROLLBAR, GHOSTTY_ACTION_COLOR_CHANGE,
             GHOSTTY_ACTION_CONFIG_CHANGE, GHOSTTY_ACTION_RENDERER_HEALTH, GHOSTTY_ACTION_MOUSE_OVER_LINK,
             GHOSTTY_ACTION_SELECTION_CHANGED, GHOSTTY_ACTION_KEY_SEQUENCE, GHOSTTY_ACTION_KEY_TABLE:
            return true
        default:
            return false
        }
    }
}

extension NSPasteboard {
    func pitwallData(forMime mime: String) -> Data? {
        switch mime {
        case let m where m.hasPrefix("text/plain"):
            if let s = string(forType: .string) { return Data(s.utf8) }
            // Files dropped/copied from Finder paste as shell-quoted paths.
            if let urls = readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
                return Data(urls.map { shellQuote($0.path) }.joined(separator: " ").utf8)
            }
            return nil
        case "image/png": return data(forType: .png)
        case "text/html": return data(forType: .html)
        default: return nil
        }
    }

    func pitwallAvailableMimes() -> [String] {
        var out: [String] = []
        if types?.contains(.string) == true { out.append("text/plain") }
        if types?.contains(.png) == true { out.append("image/png") }
        if types?.contains(.html) == true { out.append("text/html") }
        return out
    }
}
