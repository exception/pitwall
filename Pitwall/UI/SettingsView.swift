import SwiftUI
import AppKit

/// The Settings window (⌘,), styled like the rest of Pitwall.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let host = NSHostingController(rootView: SettingsView(prefs: .shared))
        let w = NSWindow(contentViewController: host)
        w.title = "Settings"
        w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.setContentSize(NSSize(width: 780, height: 580))
        w.center()
        super.init(window: w)
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ section: SettingsView.Section? = nil) {
        if let section { NotificationCenter.default.post(name: .pitwallSettingsSection, object: section) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension Notification.Name {
    static let pitwallSettingsSection = Notification.Name("pitwall.settingsSection")
}

struct SettingsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case appearance, canvas, agents, notifications, terminal, remote
        var id: String { rawValue }
        var title: String {
            switch self {
            case .appearance: return "Appearance"
            case .canvas: return "Canvas & Motion"
            case .agents: return "Agents"
            case .notifications: return "Notifications"
            case .terminal: return "Terminal"
            case .remote: return "Pitwall Remote"
            }
        }
        var symbol: String {
            switch self {
            case .appearance: return "paintbrush.fill"
            case .canvas: return "square.grid.3x3.fill"
            case .agents: return "sparkle"
            case .notifications: return "bell.badge.fill"
            case .terminal: return "terminal.fill"
            case .remote: return "iphone"
            }
        }
        var tint: Color {
            switch self {
            case .appearance: return Color(red: 0.47, green: 0.36, blue: 0.86)
            case .canvas: return Color(red: 0.15, green: 0.46, blue: 0.92)
            case .agents: return Color(ns: Theme.amber)
            case .notifications: return Color(red: 0.89, green: 0.27, blue: 0.33)
            case .terminal: return Color(white: 0.25)
            case .remote: return Color(red: 0.09, green: 0.58, blue: 0.43)
            }
        }
    }

    @ObservedObject var prefs: Prefs
    @State private var section: Section = Section(rawValue: ProcessInfo.processInfo.environment["PITWALL_OPEN_SETTINGS"] ?? "") ?? .appearance

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(section.title).font(.system(size: 22, weight: .bold)).padding(.top, 4)
                    content
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 26)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 780, height: 580)
        .onReceive(NotificationCenter.default.publisher(for: .pitwallSettingsSection)) { n in
            if let s = n.object as? Section { section = s }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Color.clear.frame(height: 30)
            ForEach(Section.allCases) { s in
                Button { section = s } label: {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(s.tint.gradient)
                            .frame(width: 24, height: 24)
                            .overlay(Image(systemName: s.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white))
                        Text(s.title).font(.system(size: 13, weight: section == s ? .semibold : .regular))
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(section == s ? Color.primary.opacity(0.08) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Pitwall").font(.system(size: 12, weight: .semibold))
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(10)
        }
        .padding(10)
        .frame(width: 220)
        .background(.regularMaterial)
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .appearance: appearance
        case .canvas: canvas
        case .agents: agents
        case .notifications: notifications
        case .terminal: terminal
        case .remote: remote
        }
    }

    // MARK: Appearance

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Text("Theme").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 14) {
                    ThemeCard(title: "Match System", mode: "system", selected: prefs.appearance == "system") { prefs.appearance = "system" }
                    ThemeCard(title: "Light", mode: "light", selected: prefs.appearance == "light") { prefs.appearance = "light" }
                    ThemeCard(title: "Dark", mode: "dark", selected: prefs.appearance == "dark") { prefs.appearance = "dark" }
                }
                Text("Terminals switch between Pitwall Light and Pitwall Dark with it.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Canvas

    private var canvas: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        Row("Animations", "Flying between tiles, toasts and glows.") { Toggle("", isOn: $prefs.animations).labelsHidden().toggleStyle(.switch) }
                        Row("Live wires", "Current flows along links when agents talk.") { Toggle("", isOn: $prefs.liveWires).labelsHidden().toggleStyle(.switch).disabled(!prefs.animations) }
                    }
                    WirePreview(on: prefs.wiresOn)
                }
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    Label("Reduce Motion is on in System Settings, so animations stay off.", systemImage: "figure.walk.motion")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Card {
                Row("Dot grid", "Subtle dots for spatial orientation.") { Toggle("", isOn: $prefs.showGrid).labelsHidden().toggleStyle(.switch) }
                Divider()
                Row("Snap to grid", "Tiles align to an 11-point grid as you drag.") { Toggle("", isOn: $prefs.snapToGrid).labelsHidden().toggleStyle(.switch) }
            }
            Card {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Status cards").font(.system(size: 13, weight: .semibold))
                        Text("When you zoom out past this point, agents become readable cards.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        HStack {
                            Slider(value: $prefs.cardZoom, in: 0.2...0.8, step: 0.05)
                            Text("\(Int(prefs.cardZoom * 100))%").font(.system(size: 12).monospacedDigit()).frame(width: 40)
                        }
                    }
                    CardThresholdPreview(threshold: prefs.cardZoom)
                }
            }
        }
    }

    // MARK: Agents

    private var agents: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Text("Default agent").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 12) {
                    ForEach(AgentKind.allCases) { a in
                        AgentChoice(kind: a, selected: prefs.defaultAgent == a.rawValue) { prefs.defaultAgent = a.rawValue }
                    }
                }
            }
            Card {
                Row("New worktree by default", "Each new agent works on its own branch in .worktrees/.") { Toggle("", isOn: $prefs.worktreeByDefault).labelsHidden().toggleStyle(.switch) }
                Divider()
                Row("Detect blocking prompts", "Read an agent's screen for questions like folder trust, even without hooks.") { Toggle("", isOn: $prefs.detectPrompts).labelsHidden().toggleStyle(.switch) }
                Divider()
                Row("Image gallery", "Collect images agents mention into a gallery on the tile.") { Toggle("", isOn: $prefs.imageGallery).labelsHidden().toggleStyle(.switch) }
                Divider()
                Row("Sub-agent tiles", "Show Claude's sub-agents as small linked tiles.") { Toggle("", isOn: $prefs.showSubagents).labelsHidden().toggleStyle(.switch) }
            }
        }
    }

    // MARK: Notifications

    private var notifications: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Row("Toasts", "A card in the corner when an agent needs you.", symbol: "rectangle.portrait.on.rectangle.portrait") { Toggle("", isOn: $prefs.toasts).labelsHidden().toggleStyle(.switch) }
                Divider()
                Row("System notifications", "When Pitwall is in the background.", symbol: "bell") { Toggle("", isOn: $prefs.systemNotifications).labelsHidden().toggleStyle(.switch) }
                Divider()
                Row("Dock badge", "Number of agents waiting on you.", symbol: "app.badge") { Toggle("", isOn: $prefs.dockBadge).labelsHidden().toggleStyle(.switch) }
                Divider()
                Row("Sound", "A soft chime when an agent needs you.", symbol: "speaker.wave.2") { Toggle("", isOn: $prefs.sound).labelsHidden().toggleStyle(.switch) }
            }
        }
    }

    // MARK: Terminal

    private var monoFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.filter { fam in
            guard let f = NSFont(name: fam, size: 12) ?? NSFontManager.shared.font(withFamily: fam, traits: [], weight: 5, size: 12) else { return false }
            return f.isFixedPitch || fam.localizedCaseInsensitiveContains("mono") || fam.localizedCaseInsensitiveContains("code")
        }
    }

    private var terminal: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Row("Font") {
                    Picker("", selection: $prefs.fontFamily) {
                        Text("Default (JetBrains Mono)").tag("")
                        Divider()
                        ForEach(monoFamilies, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 240)
                }
                Divider()
                Row("Size") {
                    Stepper("\(Int(prefs.fontSize)) pt", value: $prefs.fontSize, in: 9...24, step: 1)
                }
                TerminalPreview(family: prefs.fontFamily, size: prefs.fontSize)
            }
            Card {
                Row("Compatibility mode", "Report the terminal as xterm-256color. Use this if some programs (macOS top, older servers over ssh) say “Error opening terminal”.") {
                    Toggle("", isOn: $prefs.compatTerm).labelsHidden().toggleStyle(.switch)
                }
            }
            Card {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Advanced").font(.system(size: 13, weight: .semibold))
                        Text("Everything else uses Ghostty's config format.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open terminal.ghostty") { NSWorkspace.shared.open(PitwallPaths.terminalConfig) }
                    Button("Reload") { GhosttyRuntime.shared.reloadConfig() }
                }
            }
        }
    }

    // MARK: Remote

    private var remote: some View { RemoteSettings(prefs: prefs) }
}

// MARK: - Building blocks

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

private struct Row<Control: View>: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    @ViewBuilder var control: Control

    init(_ title: String, _ subtitle: String? = nil, symbol: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 16)
            control
        }
    }
}

private struct ThemeCard: View {
    let title: String
    let mode: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    if mode == "system" {
                        HStack(spacing: 0) { mini(dark: false); mini(dark: true) }
                    } else {
                        mini(dark: mode == "dark")
                    }
                }
                .frame(width: 150, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 1))
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
            }
        }
        .buttonStyle(.plain)
    }

    /// A tiny Pitwall canvas: dotted ground, one tile, an amber "needs you" tile.
    private func mini(dark: Bool) -> some View {
        let canvas = Color(ns: dark ? Theme.hex(0x0F1012) : Theme.hex(0xE9ECEF))
        let tile = Color(ns: dark ? Theme.hex(0x1A1C20) : Theme.hex(0xFFFFFF))
        let line = Color(ns: dark ? Theme.hex(0x3A3D44) : Theme.hex(0xD6D9DE))
        return ZStack(alignment: .topLeading) {
            canvas
            RoundedRectangle(cornerRadius: 5).fill(tile).frame(width: 52, height: 40).offset(x: 12, y: 16)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 3) {
                        Circle().fill(Color(ns: Theme.green)).frame(width: 4, height: 4)
                        RoundedRectangle(cornerRadius: 1).fill(line).frame(width: 30, height: 2)
                        RoundedRectangle(cornerRadius: 1).fill(line).frame(width: 22, height: 2)
                    }
                    .offset(x: 18, y: 22)
                }
            RoundedRectangle(cornerRadius: 5).fill(tile).frame(width: 46, height: 36)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(ns: Theme.amber), lineWidth: 1.5))
                .offset(x: 74, y: 44)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AgentChoice: View {
    let kind: AgentKind
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: kind == .claude ? "sparkle" : (kind == .codex ? "chevron.left.forwardslash.chevron.right" : "terminal"))
                    .font(.system(size: 16, weight: .medium))
                Text(kind.title).font(.system(size: 12, weight: .semibold))
                Text(kind == .claude ? "Live status, sub-agents, canvas tools" : (kind == .codex ? "OpenAI Codex CLI" : "Any command"))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(selected ? 0.08 : 0.03)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Two tiles joined by a link; current flows along it when live wires are on.
private struct WirePreview: View {
    let on: Bool
    var body: some View {
        TimelineView(.animation(paused: !on)) { ctx in
            Canvas { g, size in
                let a = CGRect(x: 6, y: 18, width: 58, height: 44)
                let b = CGRect(x: size.width - 64, y: size.height - 62, width: 58, height: 44)
                var p = Path()
                p.move(to: CGPoint(x: a.maxX, y: a.midY))
                p.addCurve(to: CGPoint(x: b.minX, y: b.midY), control1: CGPoint(x: a.maxX + 40, y: a.midY), control2: CGPoint(x: b.minX - 40, y: b.midY))
                g.stroke(p, with: .color(.secondary.opacity(0.5)), lineWidth: 1.5)
                if on {
                    let phase = CGFloat(ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)) * -24
                    g.stroke(p, with: .color(Color(ns: Theme.amber)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [1.5, 22], dashPhase: phase))
                    g.stroke(p, with: .color(Color(ns: Theme.amber).opacity(0.35)), style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [10, 14], dashPhase: phase / 2))
                }
                for r in [a, b] {
                    g.fill(Path(roundedRect: r, cornerRadius: 7), with: .color(Color(nsColor: .controlBackgroundColor)))
                    g.stroke(Path(roundedRect: r, cornerRadius: 7), with: .color(.primary.opacity(0.12)))
                }
            }
        }
        .frame(width: 200, height: 110)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
    }
}

/// Shows a tile at 30%, 50% and 70% zoom: live content above the threshold,
/// a status card below it.
private struct CardThresholdPreview: View {
    let threshold: Double
    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ForEach([0.3, 0.5, 0.7], id: \.self) { z in
                VStack(spacing: 4) {
                    Group {
                        if z < threshold {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 3) { Circle().fill(Color(ns: Theme.green)).frame(width: 5, height: 5); RoundedRectangle(cornerRadius: 1).fill(.primary.opacity(0.6)).frame(width: 22, height: 3) }
                                RoundedRectangle(cornerRadius: 1).fill(.primary.opacity(0.3)).frame(width: 30, height: 2)
                                RoundedRectangle(cornerRadius: 1).fill(.primary.opacity(0.3)).frame(width: 20, height: 2)
                            }
                            .padding(6)
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(0..<5) { i in RoundedRectangle(cornerRadius: 0.5).fill(.primary.opacity(0.25)).frame(width: CGFloat([34, 26, 30, 18, 28][i]), height: 1.5) }
                            }
                            .padding(6)
                        }
                    }
                    .frame(width: 50 * (0.6 + z), height: 36 * (0.6 + z), alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.12)))
                    Text("\(Int(z * 100))%").font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 200, height: 96, alignment: .bottom)
    }
}

private struct TerminalPreview: View {
    let family: String
    let size: Double
    var font: Font {
        family.isEmpty ? .system(size: size, design: .monospaced) : .custom(family, size: size)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("erosemberg@mac pitwall % git status").font(font)
            Text("On branch main · nothing to commit").font(font).foregroundStyle(.secondary)
            (Text("● ").foregroundColor(Color(ns: Theme.green)) + Text("Update(slack.rs) ⎿ 18 additions")).font(font)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(ns: Theme.terminalBG)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }
}

// MARK: - Pitwall Remote

import CoreImage.CIFilterBuiltins

private struct RemoteSettings: View {
    @ObservedObject var prefs: Prefs
    @ObservedObject var devices = RemoteDevices.shared
    @ObservedObject var server = RemoteServer.shared
    @State private var pairURL: URL?
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        if Prefs.remoteAvailable { content } else { wip }
    }

    private var wip: some View {
        Card {
            Row("Pitwall Remote", "Coming soon: see your agents and approve their requests from your iPhone, end-to-end encrypted.",
                symbol: "iphone.radiowaves.left.and.right") {
                Text("Work in progress").font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Row("Pitwall Remote", "See your agents and answer them from your phone. Everything between your phone and this Mac is end-to-end encrypted.",
                    symbol: "iphone.radiowaves.left.and.right") {
                    Toggle("", isOn: $prefs.remoteEnabled).labelsHidden().toggleStyle(.switch)
                }
                if prefs.remoteEnabled {
                    Divider()
                    HStack(spacing: 8) {
                        Circle().fill(server.running ? Color(ns: Theme.green) : Color(ns: Theme.red)).frame(width: 7, height: 7)
                        Text(server.running ? "Listening on \(RemoteServer.addresses.first ?? "this Mac")" : "Not running")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Text("Works on your network now · anywhere once Pitwall Cloud is ready")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
            }
            if prefs.remoteEnabled {
                Card {
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Pair a phone").font(.system(size: 13, weight: .semibold))
                            Text("Scan this code with your phone's camera. It opens Pitwall Remote and pairs securely. The code works once and expires in 10 minutes.")
                                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if let offer = devices.offer, offer.expires > now, pairURL != nil {
                                Text("Expires in \(Int(offer.expires.timeIntervalSince(now)) / 60):\(String(format: "%02d", Int(offer.expires.timeIntervalSince(now)) % 60))")
                                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                                Button("Cancel") { devices.cancelOffer(); pairURL = nil }
                            } else {
                                Button("Show pairing code") { pairURL = server.pairingURL() }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(!server.running)
                            }
                        }
                        Spacer()
                        ZStack {
                            RoundedRectangle(cornerRadius: 14).fill(Color.white)
                            if let url = pairURL, let offer = devices.offer, offer.expires > now, let img = Self.qr(url.absoluteString) {
                                Image(nsImage: img).interpolation(.none).resizable().padding(10)
                            } else {
                                Image(systemName: "qrcode").font(.system(size: 54)).foregroundStyle(Color.black.opacity(0.15))
                            }
                        }
                        .frame(width: 170, height: 170)
                    }
                }
                Card {
                    Text("Paired devices").font(.system(size: 13, weight: .semibold))
                    if devices.devices.isEmpty {
                        Text("No phones paired yet.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ForEach(devices.devices) { d in
                        HStack(spacing: 10) {
                            Image(systemName: "iphone").font(.system(size: 16)).frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(d.name).font(.system(size: 13, weight: .medium))
                                    if server.connectedDevices.contains(d.id) {
                                        Text("Connected").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(ns: Theme.green))
                                    }
                                }
                                Text(d.lastSeen.map { "Last seen \($0.formatted(.relative(presentation: .named)))" } ?? "Paired \(d.addedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Revoke", role: .destructive) { devices.revoke(d.id) }
                        }
                    }
                }
            }
        }
        .onReceive(tick) { now = $0 }
        .onChange(of: devices.devices) { _ in pairURL = nil }
    }

    static func qr(_ s: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
