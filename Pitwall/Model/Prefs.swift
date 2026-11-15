import AppKit
import Combine

/// User preferences, persisted in UserDefaults. Observable so the UI and
/// canvas react immediately when a setting changes.
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    private func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }
    private func double(_ k: String, _ def: Double) -> Double { d.object(forKey: k) as? Double ?? def }
    private func string(_ k: String, _ def: String) -> String { d.string(forKey: k) ?? def }

    // MARK: General
    @Published var appearance: String { didSet { d.set(appearance, forKey: "appearance"); NotificationCenter.default.post(name: .pitwallAppearance, object: nil) } }
    @Published var defaultAgent: String { didSet { d.set(defaultAgent, forKey: "defaultAgent") } }
    @Published var worktreeByDefault: Bool { didSet { d.set(worktreeByDefault, forKey: "worktreeByDefault") } }

    // MARK: Motion
    /// Master switch for canvas animations (flying, toasts, glows).
    @Published var animations: Bool { didSet { d.set(animations, forKey: "animations") } }
    /// Flowing current on links when agents talk.
    @Published var liveWires: Bool { didSet { d.set(liveWires, forKey: "liveWires") } }

    // MARK: Canvas
    @Published var showGrid: Bool { didSet { d.set(showGrid, forKey: "showGrid") } }
    @Published var snapToGrid: Bool { didSet { d.set(snapToGrid, forKey: "snapToGrid") } }
    /// Below this zoom, agent tiles turn into status cards.
    @Published var cardZoom: Double { didSet { d.set(cardZoom, forKey: "cardZoom") } }
    @Published var showSubagents: Bool { didSet { d.set(showSubagents, forKey: "showSubagents") } }

    // MARK: Notifications
    @Published var toasts: Bool { didSet { d.set(toasts, forKey: "toasts") } }
    @Published var systemNotifications: Bool { didSet { d.set(systemNotifications, forKey: "systemNotifications") } }
    @Published var dockBadge: Bool { didSet { d.set(dockBadge, forKey: "dockBadge") } }
    @Published var sound: Bool { didSet { d.set(sound, forKey: "sound") } }

    // MARK: Agents
    @Published var detectPrompts: Bool { didSet { d.set(detectPrompts, forKey: "detectPrompts") } }
    @Published var imageGallery: Bool { didSet { d.set(imageGallery, forKey: "imageGallery") } }

    // MARK: Remote
    @Published var remoteEnabled: Bool {
        didSet {
            d.set(remoteEnabled, forKey: "remoteEnabled")
            if remoteEnabled { RemoteServer.shared.start() } else { RemoteServer.shared.stop() }
        }
    }

    // MARK: Terminal
    @Published var fontFamily: String { didSet { d.set(fontFamily, forKey: "fontFamily"); NotificationCenter.default.post(name: .pitwallTerminalConfig, object: nil) } }
    /// Report the terminal as xterm-256color instead of xterm-ghostty, for
    /// programs that can't load custom terminfo (e.g. macOS `top`, servers).
    @Published var compatTerm: Bool { didSet { d.set(compatTerm, forKey: "compatTerm"); NotificationCenter.default.post(name: .pitwallTerminalConfig, object: nil) } }
    @Published var fontSize: Double { didSet { d.set(fontSize, forKey: "fontSize"); NotificationCenter.default.post(name: .pitwallTerminalConfig, object: nil) } }

    private init() {
        let d = UserDefaults.standard
        func b(_ k: String, _ v: Bool) -> Bool { d.object(forKey: k) as? Bool ?? v }
        appearance = d.string(forKey: "appearance") ?? "system"
        defaultAgent = d.string(forKey: "defaultAgent") ?? "claude"
        worktreeByDefault = b("worktreeByDefault", true)
        animations = b("animations", true)
        liveWires = b("liveWires", true)
        showGrid = b("showGrid", true)
        snapToGrid = b("snapToGrid", true)
        cardZoom = d.object(forKey: "cardZoom") as? Double ?? 0.5
        showSubagents = b("showSubagents", true)
        toasts = b("toasts", true)
        systemNotifications = b("systemNotifications", true)
        dockBadge = b("dockBadge", true)
        sound = b("sound", false)
        detectPrompts = b("detectPrompts", true)
        imageGallery = b("imageGallery", true)
        fontFamily = d.string(forKey: "fontFamily") ?? ""
        fontSize = d.object(forKey: "fontSize") as? Double ?? 13
        compatTerm = b("compatTerm", false)
        remoteEnabled = b("remoteEnabled", false)
    }

    /// Animations are on only if enabled here and macOS Reduce Motion is off.
    var motion: Bool { animations && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var wiresOn: Bool { liveWires && motion }
}

extension Notification.Name {
    static let pitwallAppearance = Notification.Name("pitwall.appearance")
    static let pitwallTerminalConfig = Notification.Name("pitwall.terminalConfig")
}
