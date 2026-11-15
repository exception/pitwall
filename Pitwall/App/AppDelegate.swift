import AppKit
import UserNotifications

@main
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuDelegate {
    private var main: MainWindowController!
    private var goMenu: NSMenu?
    private var layoutsMenu: NSMenu?
    private let control = ControlServer()
    private var signalSources: [DispatchSourceSignal] = []

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        PitwallPaths.ensure()
        // SIGTERM/SIGINT (logout, kill, crash reporters): save and quit cleanly.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                Store.shared.saveNow()
                NSApp.terminate(nil)
            }
            src.resume()
            signalSources.append(src)
        }
        ClaudeIntegration.writeFiles()
        Sessions.ensureDaemon()
        GhosttyRuntime.shared.start()
        applyAppearancePreference()
        NotificationCenter.default.addObserver(forName: .pitwallAppearance, object: nil, queue: .main) { [weak self] _ in
            self?.applyAppearancePreference()
        }
        NotificationCenter.default.addObserver(forName: .pitwallTerminalConfig, object: nil, queue: .main) { _ in
            GhosttyRuntime.shared.reloadConfig()
        }

        main = MainWindowController()
        control.controller = main.controller
        control.start()
        RemoteServer.shared.controller = main.controller
        if Prefs.remoteAvailable { RemoteServer.shared.start() }
        NSApp.mainMenu = buildMenu()
        main.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Test/debug hook: open Settings on a section at launch.
        if ProcessInfo.processInfo.environment["PITWALL_OPEN_SETTINGS"] != nil { SettingsWindowController.shared.show() }

        let nc = UNUserNotificationCenter.current()
        nc.delegate = self
        nc.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Store.shared.saveNow()
        control.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        main.showWindow(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["tile"] as? String {
            main.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            if let (b, _) = Store.shared.findTile(id), b.id != Store.shared.currentBoardID { main.controller.switchBoard(b.id) }
            main.controller.flyTo(tileID: id, fill: false)
        }
        done()
    }

    // MARK: Appearance

    enum AppearancePref: String { case system, light, dark }

    private func applyAppearancePreference() {
        let pref = AppearancePref(rawValue: Prefs.shared.appearance) ?? .system
        switch pref {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        GhosttyRuntime.shared.updateColorScheme()
    }

    @objc private func setAppearance(_ sender: NSMenuItem) {
        Prefs.shared.appearance = sender.representedObject as? String ?? "system"
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let ctl = main.controller!
        let model = main.model
        let bar = NSMenu()

        func menu(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = m
            bar.addItem(item)
        }
        func key(_ item: NSMenuItem, _ mods: NSEvent.ModifierFlags) -> NSMenuItem { item.keyEquivalentModifierMask = mods; return item }

        menu("Pitwall", [
            NSMenuItem(title: "About Pitwall", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""),
            .separator(),
            MenuAction("Settings…", key: ",") { SettingsWindowController.shared.show() },
            MenuAction("Reload Terminal Settings") { GhosttyRuntime.shared.reloadConfig() },
            MenuAction("Install Command Line Tool…") { [weak self] in self?.installCLI() },
            .separator(),
            NSMenuItem(title: "Hide Pitwall", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
            key(NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"), [.command, .option]),
            .separator(),
            NSMenuItem(title: "Quit Pitwall", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ])

        menu("File", [
            MenuAction("New Agent…", key: "n") { [weak self] in self?.main.showWindow(nil); model.focusDispatch() },
            MenuAction("New Terminal", key: "t") { _ = ctl.newTerminal() },
            key(MenuAction("New Note", key: "n") { ctl.newNote() }, [.command, .shift]),
            key(MenuAction("New Browser", key: "b") { ctl.open(target: "http://localhost:3000") }, [.command, .shift]),
            key(MenuAction("Show Diff", key: "d") { ctl.newDiff() }, [.command, .shift]),
            key(MenuAction("New Frame", key: "g") { ctl.newFrame() }, [.command, .shift]),
            MenuAction("Watch a Command…") { ctl.promptWatch() },
            MenuAction("Run Dev Server…") { ctl.promptServer() },
            MenuAction("Follow Pull Request") { ctl.newPR(repo: ctl.board.root ?? ctl.defaultCwd) },
            MenuAction("Open…", key: "o") { model.chooseFile { ctl.open(target: $0.path) } },
            .separator(),
            key(MenuAction("Add Board…", key: "o") { model.addBoard() }, [.command, .shift]),
            .separator(),
            MenuAction("Close Tile", key: "w") { if let id = ctl.focusedTileID { ctl.closeTile(id) } },
            key(MenuAction("Rename Tile…", key: "r") { if let id = ctl.focusedTileID { ctl.renameTile(id) } }, [.command, .shift]),
        ])

        menu("Edit", [
            NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"),
            key(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z"), [.command, .shift]),
            .separator(),
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
            .separator(),
            MenuAction("Search Terminals…", key: "f") { [weak self] in self?.main.showWindow(nil); model.searchOpen = true },
        ])

        let appearance = NSMenu(title: "Appearance")
        for (title, value) in [("System", "system"), ("Light", "light"), ("Dark", "dark")] {
            let i = NSMenuItem(title: title, action: #selector(setAppearance(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = value
            appearance.addItem(i)
        }
        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        appearanceItem.submenu = appearance

        // Layouts are rebuilt from the current board each time the menu opens.
        let layouts = NSMenu(title: "Layouts")
        layouts.delegate = self
        layoutsMenu = layouts
        let layoutsItem = NSMenuItem(title: "Layouts", action: nil, keyEquivalent: "")
        layoutsItem.submenu = layouts
        menuNeedsUpdate(layouts)

        menu("View", [
            MenuAction("Zoom In", key: "=") { ctl.setZoom(min(CanvasView.maxZoom, ctl.canvas.viewport.zoom * 1.25)) },
            MenuAction("Zoom Out", key: "-") { ctl.setZoom(max(CanvasView.minZoom, ctl.canvas.viewport.zoom / 1.25)) },
            MenuAction("Actual Size", key: "0") { ctl.setZoom(1) },
            key(MenuAction("Zoom to Fit", key: "0") { ctl.zoomToFit() }, [.command, .shift]),
            MenuAction("Overview", key: "\\") { ctl.setZoom(0.35) },
            .separator(),
            MenuAction("Center Stage", key: "\r") { if let id = ctl.focusedTileID { ctl.flyTo(tileID: id, fill: true) } },
            key(MenuAction("Full Screen Tile", key: "f") { ctl.toggleFullScreen() }, [.command, .shift]),
            key(MenuAction("Tidy Up", key: "\\") { ctl.tidy() }, [.command, .shift]),
            layoutsItem,
            .separator(),
            key(MenuAction("Toggle Sidebar", key: "s") { model.sidebarVisible.toggle() }, [.command, .control]),
            appearanceItem,
        ])

        // Go is rebuilt from the real boards every time it opens.
        let go = NSMenu(title: "Go")
        go.delegate = self
        goMenu = go
        let goItem = NSMenuItem(title: "Go", action: nil, keyEquivalent: "")
        goItem.submenu = go
        bar.addItem(goItem)
        menuNeedsUpdate(go)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(MenuAction("Show Pitwall", key: "1") { [weak self] in self?.main.showWindow(nil) }.withMods([.command, .option]))
        let wi = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        wi.submenu = windowMenu
        bar.addItem(wi)
        NSApp.windowsMenu = windowMenu
        return bar
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === layoutsMenu, let ctl = main?.controller {
            menu.removeAllItems()
            menu.addItem(MenuAction("Save Layout…", key: "s") { ctl.promptSaveLayout() }.withMods([.command, .option]))
            let list = ctl.board.layouts ?? []
            if !list.isEmpty { menu.addItem(.separator()) }
            for (i, l) in list.enumerated() {
                menu.addItem(MenuAction(l.name, key: i < 9 ? "\(i + 1)" : "") { ctl.restoreLayout(l.id) }.withMods([.control]))
            }
            if !list.isEmpty {
                let del = NSMenu(title: "Delete Layout")
                for l in list { del.addItem(MenuAction(l.name) { ctl.deleteLayout(l.id) }) }
                let di = NSMenuItem(title: "Delete Layout", action: nil, keyEquivalent: "")
                di.submenu = del
                menu.addItem(.separator())
                menu.addItem(di)
            }
            return
        }
        guard menu === goMenu, let ctl = main?.controller else { return }
        menu.removeAllItems()
        let waiting = Store.shared.boards.flatMap(\.tiles).filter { $0.state == .waiting }.count
        let next = MenuAction(waiting > 0 ? "Next Agent Needing You (\(waiting))" : "Next Agent Needing You", key: "j") { ctl.nextAttention() }
        next.isEnabled = waiting > 0 || Store.shared.boards.flatMap(\.tiles).contains { $0.state == .done }
        menu.autoenablesItems = false
        menu.addItem(next)
        menu.addItem(MenuAction("Inbox", key: "i") { [weak self] in self?.main.model.inboxOpen.toggle() })
        menu.addItem(.separator())
        for (i, b) in Store.shared.boards.enumerated() {
            let item = MenuAction(b.name, key: i < 9 ? "\(i + 1)" : "") { ctl.switchBoard(b.id) }
            item.state = b.id == Store.shared.currentBoardID ? .on : .off
            let n = b.tiles.filter { $0.state == .waiting }.count
            if n > 0 { item.badge = NSMenuItemBadge(count: n) }
            item.image = Self.swatch(Theme.boardColors[b.colorIndex % Theme.boardColors.count])
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(MenuAction("Add Board…") { [weak self] in self?.main.model.addBoard() })
    }

    private static func swatch(_ c: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            c.setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
            return true
        }
    }

    /// Symlinks the bundled helper to /usr/local/bin/pitwall (asks for permission via osascript).
    private func installCLI() {
        let src = Sessions.helperPath
        let script = "do shell script \"mkdir -p /usr/local/bin && ln -sf '\(src)' /usr/local/bin/pitwall\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        let alert = NSAlert()
        alert.messageText = err == nil ? "Installed `pitwall`" : "Couldn't install the command line tool"
        alert.informativeText = err == nil ? "Run `pitwall help` in any terminal." : (err?[NSAppleScript.errorMessage] as? String ?? "")
        alert.runModal()
    }
}

extension NSMenuItem {
    func withMods(_ m: NSEvent.ModifierFlags) -> NSMenuItem { keyEquivalentModifierMask = m; return self }
}
