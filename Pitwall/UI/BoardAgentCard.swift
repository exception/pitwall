import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Avatar

/// The board agent's face: a picture or an emoji on the agent's color, ringed
/// with its state (amber needs you, green working), with an inbox badge.
struct AgentAvatar: View {
    let config: BoardAgentConfig
    let state: AgentState
    var size: CGFloat = 32
    var badge = 0

    private var tint: Color {
        Color(ns: Theme.boardColors[(config.colorIndex ?? 0) % Theme.boardColors.count])
    }

    var body: some View {
        ZStack {
            Circle().fill(tint.gradient)
            if let p = config.avatarImage, let img = NSImage(contentsOfFile: p) {
                Image(nsImage: img).resizable().scaledToFill().clipShape(Circle())
            } else {
                Text(config.avatar.isEmpty ? String(config.name.prefix(1)).uppercased() : config.avatar)
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .padding(2.5)
        .overlay(Circle().stroke(state == .idle ? Color.primary.opacity(0.12) : Color(ns: Theme.color(for: state)), lineWidth: 2))
        .overlay(alignment: .topTrailing) {
            if badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(Color(red: 0.1, green: 0.07, blue: 0.02))
                    .padding(.horizontal, badge > 9 ? 4 : 0)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Capsule().fill(Color(ns: Theme.amber)))
                    .offset(x: 4, y: -3)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Sidebar card

/// The board's agent, pinned to the bottom of the sidebar. Collapsed it shows
/// who it is and what it's up to; expanded, its inbox and what it started.
struct BoardAgentCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var checker = SlackChecker.shared
    @AppStorage("boardAgentExpanded", store: .pitwall) private var expanded = false

    private var board: Board { model.board }
    private var cfg: BoardAgentConfig { board.agentConfig }
    private var asks: [AgentAsk] { board.asks ?? [] }
    private var newAsks: [AgentAsk] { asks.filter { $0.state == .new }.sorted { $0.at > $1.at } }
    private var picked: [AgentAsk] { asks.filter { $0.state == .pickedUp }.sorted { $0.at > $1.at } }
    private var state: AgentState { BoardAgent.state(asks: asks, tiles: board.tiles) }

    private var subtitle: String {
        if !newAsks.isEmpty { return "\(newAsks.count) ask\(newAsks.count == 1 ? "" : "s") waiting" }
        let busy = picked.filter { a in board.tile(a.workerTileID ?? "").map { $0.state == .working || $0.state == .waiting } ?? false }
        if !busy.isEmpty { return "Working on \(busy.count) task\(busy.count == 1 ? "" : "s")" }
        if cfg.slack.enabled, checker.checking.contains(board.id) { return "Checking Slack…" }
        if cfg.slack.enabled, board.agentCheckError != nil { return "Can't reach Slack" }
        if cfg.slack.enabled, !cfg.slack.channels.isEmpty {
            return "Watching " + cfg.slack.channels.prefix(2).map { "#" + BoardAgent.normalize(channel: $0) }.joined(separator: ", ")
                + (cfg.slack.channels.count > 2 ? " +\(cfg.slack.channels.count - 2)" : "")
        }
        return "Nothing to do"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if expanded {
                details
                Divider().padding(.horizontal, 6)
            }
            header
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(expanded ? 0.05 : 0.035)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(state == .waiting ? Color(ns: Theme.amber).opacity(0.45) : Color.primary.opacity(0.06), lineWidth: 1))
        .animation(.snappy(duration: 0.22), value: expanded)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 10) {
                    AgentAvatar(config: cfg, state: state, size: 30, badge: expanded ? 0 : newAsks.count)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(cfg.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(subtitle).font(.system(size: 11))
                            .foregroundStyle(state == .waiting ? Color(ns: Theme.amberText) : .secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide \(cfg.name)'s inbox" : "Show \(cfg.name)'s inbox")
            .accessibilityLabel("\(cfg.name), \(subtitle)")
            Button { BoardAgentSettingsWindowController.show(boardID: board.id) } label: {
                Image(systemName: "gearshape").font(.system(size: 12, weight: .medium)).frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("\(cfg.name)'s settings: name, picture, Slack channels, permissions")
            .accessibilityLabel("\(cfg.name) settings")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                section("Inbox", count: newAsks.count)
                if newAsks.isEmpty {
                    Text(emptyInbox).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 4)
                }
                ForEach(newAsks) { a in AskRow(ask: a, model: model, boardID: board.id) }
                if !picked.isEmpty {
                    HStack {
                        section("Doing", count: picked.count)
                        Spacer()
                        Button("Clear") { model.controller?.clearHandledAsks(boardID: board.id) }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                            .help("Forget handled asks (their agents stay on the board)")
                    }
                    ForEach(picked) { a in DoingRow(ask: a, worker: board.tile(a.workerTileID ?? ""), model: model) }
                }
                listening
            }
            .padding(10)
        }
        .frame(maxHeight: 340)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var emptyInbox: String {
        cfg.slack.enabled ? "Nothing waiting." : "Nothing waiting. Turn on Slack in settings, or use `pitwall ask`."
    }

    /// One quiet row: is it listening, where, when it last looked. The
    /// details are in the tooltip.
    private var listening: some View {
        let s = cfg.slack
        let busy = checker.checking.contains(board.id)
        let place = s.workspace ?? "Slack"
        let line: String
        let dot: NSColor
        if !s.enabled { line = "Not listening on Slack"; dot = Theme.idle }
        else if busy { line = "\(place) · checking…"; dot = Theme.green }
        else if board.agentCheckError != nil { line = "\(place) · can't reach Slack"; dot = Theme.red }
        else if let t = board.agentChecked { line = "\(place) · " + (t.elapsedShort == "now" ? "just now" : t.elapsedShort + " ago"); dot = Theme.green }
        else { line = "\(place) · not checked yet"; dot = Theme.idle }

        var what: [String] = []
        if s.directMessages { what.append("DMs") }
        if s.mentions { what.append("@mentions") }
        what += s.channels.map { "#" + BoardAgent.normalize(channel: $0) }
        if !s.triggerReaction.isEmpty { what.append(":\(s.triggerReaction):") }
        var tip = s.enabled ? "Listening for \(what.joined(separator: ", ")), every \(s.everyMinutes) min" : "Turn on Slack in \(cfg.name)'s settings"
        if let e = board.agentCheckError, s.enabled { tip += "\n\nLast check failed: \(e)" }

        return HStack(spacing: 6) {
            Circle().fill(Color(ns: dot)).frame(width: 6, height: 6)
            Text(line).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if s.enabled {
                Button { checker.check(boardID: board.id) } label: {
                    Group {
                        if busy { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                    }
                    .frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(busy)
                .help("Check Slack now")
                .accessibilityLabel("Check Slack now")
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .help(tip)
    }

    private func section(_ title: String, count: Int) -> some View {
        HStack(spacing: 5) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).kerning(0.4)
            if count > 0 { Text("\(count)").font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 4)
    }
}

private struct AskRow: View {
    let ask: AgentAsk
    @ObservedObject var model: AppModel
    let boardID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(ask.from).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if let c = ask.channel, !c.isEmpty {
                    Text("#" + BoardAgent.normalize(channel: c)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 2)
                Text(ask.at.elapsedShort).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary)
            }
            if let t = ask.title {
                Text(t).font(.system(size: 12, weight: .medium)).lineLimit(2)
            }
            Text(ask.text).font(.system(size: 11.5)).foregroundStyle(ask.title == nil ? .primary : .secondary)
                .lineLimit(ask.title == nil ? 3 : 2).textSelection(.enabled)
                .help(ask.text)
            if let n = ask.count, n > 1 {
                Text("\(n) messages").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                Button("Pick up") { model.controller?.pickUp(askID: ask.id, boardID: boardID) }
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(Color(ns: Theme.blue))
                    .help("Start an agent on this in its own worktree")
                Button("Ignore") { model.controller?.ignoreAsk(askID: ask.id, boardID: boardID) }
                    .buttonStyle(.bordered).controlSize(.small)
                Spacer()
                if let l = ask.link, let url = URL(string: l) {
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Open the original message")
                }
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(ns: Theme.amber).opacity(0.12)))
    }
}

private struct DoingRow: View {
    let ask: AgentAsk
    let worker: Tile?
    @ObservedObject var model: AppModel

    var body: some View {
        Button { if let w = worker { model.goTo(tileID: w.id) } } label: {
            HStack(spacing: 8) {
                Circle().fill(Color(ns: Theme.color(for: worker?.state ?? .idle))).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(worker?.displayName ?? "Agent closed").font(.system(size: 12)).lineLimit(1)
                        .foregroundStyle(worker == nil ? .secondary : .primary)
                    Text("for \(ask.from)" + (worker.map { " · " + $0.state.label } ?? ""))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 2)
                if let w = worker, w.state != .idle {
                    Text(w.stateSince.elapsedShort).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(worker == nil)
        .help(worker == nil ? ask.text : "Go to the agent")
    }
}

// MARK: - Settings

/// One settings window per board agent.
final class BoardAgentSettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [String: BoardAgentSettingsWindowController] = [:]
    private let boardID: String

    static func show(boardID: String) {
        let c = open[boardID] ?? BoardAgentSettingsWindowController(boardID: boardID)
        open[boardID] = c
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(boardID: String) {
        self.boardID = boardID
        let host = NSHostingController(rootView: BoardAgentSettingsView(boardID: boardID))
        let w = NSWindow(contentViewController: host)
        w.title = (Store.shared.board(boardID)?.agentConfig.name ?? "Agent") + " · " + (Store.shared.board(boardID)?.name ?? "")
        w.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.setContentSize(NSSize(width: 540, height: 660))
        w.center()
        super.init(window: w)
        w.delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) { Self.open[boardID] = nil }
}

/// Who the board's agent is, where it listens, and what it may do as you.
/// Changes apply as you make them.
struct BoardAgentSettingsView: View {
    let boardID: String
    @State private var cfg: BoardAgentConfig
    @State private var channels: String
    @State private var people: String

    init(boardID: String) {
        self.boardID = boardID
        let c = Store.shared.board(boardID)?.agentConfig ?? BoardAgent.defaultConfig
        _cfg = State(initialValue: c)
        _channels = State(initialValue: c.slack.channels.joined(separator: ", "))
        _people = State(initialValue: c.slack.allowedUsers.joined(separator: ", "))
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    AgentAvatar(config: cfg, state: .idle, size: 52)
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Name", text: $cfg.name, prompt: Text("Pit"))
                        HStack(spacing: 8) {
                            TextField("Emoji", text: $cfg.avatar, prompt: Text("🏎"))
                                .frame(width: 110)
                                .disabled(cfg.avatarImage != nil)
                            Button("Choose picture…", action: choosePicture)
                            if cfg.avatarImage != nil { Button("Remove") { cfg.avatarImage = nil } }
                        }
                    }
                }
                HStack(spacing: 8) {
                    Text("Color")
                    Spacer()
                    ForEach(Theme.boardColors.indices, id: \.self) { i in
                        Button { cfg.colorIndex = i } label: {
                            Circle().fill(Color(ns: Theme.boardColors[i])).frame(width: 18, height: 18)
                                .overlay(Circle().stroke(Color.primary, lineWidth: (cfg.colorIndex ?? 0) == i ? 2 : 0).padding(-3))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Color \(i + 1)")
                    }
                }
            } header: { Text("Identity") }

            Section {
                TextEditor(text: $cfg.instructions)
                    .font(.system(size: 12))
                    .frame(minHeight: 70)
                Text("Given to every agent it starts. For example: “Only pick up bugs in the API. Never touch billing. Reply in a friendly, short tone.”")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Instructions") }

            Section {
                Toggle("Listen on Slack", isOn: $cfg.slack.enabled)
                Picker("Connection", selection: $cfg.slack.connection) {
                    ForEach(SlackConnection.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!cfg.slack.enabled)
                if cfg.slack.connection == .boardSignIn {
                    HStack {
                        Text(cfg.slack.workspace.map { "Signed in to \($0)" } ?? "Not signed in yet")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(cfg.slack.workspace == nil ? "Connect Slack…" : "Switch workspace…") {
                            SlackChecker.shared.connect(boardID: boardID)
                        }
                    }
                    .disabled(!cfg.slack.enabled)
                } else {
                    Text("Uses the workspace your claude.ai account's Slack connector is on" + (cfg.slack.workspace.map { " (\($0))" } ?? "") + ". For a different workspace, give this board its own sign-in.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Stepper(value: $cfg.slack.everyMinutes, in: 1...120) {
                    Text("Check every \(cfg.slack.everyMinutes) min")
                }
                .disabled(!cfg.slack.enabled)
                TextField("Channels", text: $channels, prompt: Text("e.g. eng-backend, bugs"))
                    .disabled(!cfg.slack.enabled)
                Toggle("Direct messages to you", isOn: $cfg.slack.directMessages).disabled(!cfg.slack.enabled)
                Toggle("@mentions of you", isOn: $cfg.slack.mentions).disabled(!cfg.slack.enabled)
                TextField("Hand-off reaction", text: $cfg.slack.triggerReaction, prompt: Text("robot_face"))
                    .disabled(!cfg.slack.enabled)
                TextField("Only from", text: $people, prompt: Text("Anyone (or: alice, bob)"))
                Text("A reaction hands any message to \(cfg.name.isEmpty ? "the agent" : cfg.name), in any channel it can see. “Only from” also applies to `pitwall ask`. Checks only read Slack: a headless Claude Code session (\(cfg.slack.model)) that can search and read, nothing else.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Where it listens") }

            Section {
                permission("Pick up tasks", \.pickUpTasks,
                           "Offer to start an agent, in its own worktree, for an ask.")
                Text("\(cfg.name.isEmpty ? "The agent" : cfg.name) never acts on its own: everything it may do waits for you to approve it. Checking Slack only reads. Its agents use your installed skills first.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("On this board") }

            Section {
                permission("Reply in threads", \.replyAsMe, "Post replies as you.")
                permission("React to messages", \.reactAsMe, "👀 when it sees an ask, ✅ when it's done.")
                permission("Set your status", \.setMyStatus, "Claude's Slack tools can't set a status yet.")
                    .disabled(true)
                Text("These act with your own Slack account, so people see them as coming from you. You'll see exactly what will be sent and approve it first.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Acting as you on Slack") }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 420, idealHeight: 660)
        .onChange(of: cfg) { _ in save() }
        .onChange(of: channels) { _ in save() }
        .onChange(of: people) { _ in save() }
    }

    private func permission(_ title: String, _ key: WritableKeyPath<AgentPermissions, PermissionLevel>, _ detail: String) -> some View {
        Toggle(isOn: Binding(get: { cfg.permissions[keyPath: key] == .ask }, set: { cfg.permissions[keyPath: key] = $0 ? .ask : .off })) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func save() {
        var c = cfg
        c.name = c.name.trimmingCharacters(in: .whitespaces)
        if c.name.isEmpty { c.name = BoardAgent.defaultConfig.name }
        c.avatar = String(c.avatar.trimmingCharacters(in: .whitespaces).prefix(2))
        c.slack.channels = BoardAgent.list(channels)
        c.slack.allowedUsers = BoardAgent.list(people)
        c.slack.triggerReaction = c.slack.triggerReaction.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        Store.shared.update(boardID) { $0.agent = c }
    }

    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let dir = PitwallPaths.support.appendingPathComponent("avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(boardID)-\(UUID().uuidString.prefix(4).lowercased()).\(url.pathExtension.lowercased())")
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            if let old = cfg.avatarImage { try? FileManager.default.removeItem(atPath: old) }
            cfg.avatarImage = dest.path
        } catch {
            NSSound.beep()
        }
    }
}
