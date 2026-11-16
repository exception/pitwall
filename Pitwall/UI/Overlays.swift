import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Spacer()
                SidebarToggle(model: model)
            }
            .frame(height: 18) // traffic lights live on the left
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.store.boards) { b in
                    BoardRow(board: b, selected: b.id == model.store.currentBoardID, activity: model.activity(on: b)) {
                        model.controller?.switchBoard(b.id)
                    }
                    .contextMenu {
                        Button("Rename…") { renameBoard(b) }
                        if model.store.boards.count > 1 {
                            Button("Remove board") { model.store.removeBoard(b.id); model.controller?.reconcile() }
                        }
                    }
                }
                Button(action: model.addBoard) {
                    HStack(spacing: 10) {
                        Image(systemName: "plus").frame(width: 22, height: 22)
                        Text("Add board…")
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add a board for a project folder (⇧⌘O)")
            }
            Divider().padding(.horizontal, 8)
            Text("On this board")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.sortedTiles) { t in
                        TileRow(tile: t, focused: model.focusedTileID == t.id) {
                            model.controller?.flyTo(tileID: t.id, fill: false)
                        }
                    }
                    if model.sortedTiles.isEmpty {
                        Text("Double-click the canvas or type a task below to start.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(10)
                    }
                }
            }
            Spacer(minLength: 0)
            BoardAgentCard(model: model)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(width: 256)
        .frame(maxHeight: .infinity, alignment: .top)
        .pitwallGlass(cornerRadius: 22)
    }

    private func renameBoard(_ b: Board) {
        let alert = NSAlert()
        alert.messageText = "Rename board"
        let field = NSTextField(string: b.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {
            model.store.update(b.id) { $0.name = field.stringValue }
        }
    }
}

struct BoardRow: View {
    let board: Board
    let selected: Bool
    let activity: BoardActivity
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(ns: Theme.boardColors[board.colorIndex % Theme.boardColors.count]))
                    .frame(width: 22, height: 22)
                    .overlay(Text(board.name.prefix(1).uppercased()).font(.system(size: 11, weight: .bold)).foregroundStyle(.white))
                Text(board.name)
                    .fontWeight(selected ? .semibold : .regular)
                    .lineLimit(1)
                Spacer(minLength: 4)
                indicators
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Color.primary.opacity(0.07) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(board.name): \(activity.summary)")
        .accessibilityLabel("\(board.name), \(activity.summary)")
    }

    /// Working (green dot), finished (blue), failing (red), needs you (amber).
    @ViewBuilder private var indicators: some View {
        HStack(spacing: 5) {
            if activity.working > 0 && activity.waiting + activity.failing + activity.done == 0 {
                Circle().fill(Color(ns: Theme.green)).frame(width: 7, height: 7)
                    .overlay(Circle().stroke(Color(ns: Theme.green).opacity(0.3), lineWidth: 3))
            } else if activity.background > 0 && activity.working + activity.waiting + activity.failing + activity.done == 0 {
                // Only background work: a hollow ring, live but nothing in front.
                Circle().stroke(Color(ns: Theme.green), lineWidth: 1.6).frame(width: 7, height: 7)
            }
            if activity.done > 0 { tag(activity.done, symbol: "checkmark", Theme.blue) }
            if activity.failing > 0 { tag(activity.failing, symbol: "exclamationmark", Theme.red) }
            if activity.waiting > 0 { count(activity.waiting, Theme.amber, text: Color(red: 0.1, green: 0.07, blue: 0.02)) }
        }
    }

    /// Softer, symbol-led chip for finished / failing.
    private func tag(_ n: Int, symbol: String, _ c: NSColor) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 9, weight: .heavy))
            Text("\(n)").font(.system(size: 11, weight: .bold).monospacedDigit())
        }
        .foregroundStyle(Color(ns: c))
        .padding(.horizontal, 6)
        .frame(minHeight: 18)
        .background(Capsule().fill(Color(ns: c).opacity(0.16)))
    }

    private func count(_ n: Int, _ c: NSColor, text: Color) -> some View {
        Text("\(n)")
            .font(.system(size: 11, weight: .bold).monospacedDigit())
            .foregroundStyle(text)
            .padding(.horizontal, n > 9 ? 5 : 0)
            .frame(minWidth: 18, minHeight: 18)
            .background(Capsule().fill(Color(ns: c)))
    }
}

struct TileRow: View {
    let tile: Tile
    let focused: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: action) {
                HStack(spacing: 10) {
                    Circle().fill(Color(ns: Theme.color(for: tile.state))).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tile.displayName).lineLimit(1)
                        if tile.state == .waiting, let m = tile.statusMessage {
                            Text(m).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        } else if tile.worktreePath != nil {
                            Label(tile.branch ?? "worktree", systemImage: "arrow.triangle.branch")
                                .labelStyle(.titleAndIcon)
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if tile.state != .idle {
                        Text(tile.stateSince.elapsedShort)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let wt = tile.worktreePath {
                WorktreeButton(path: wt, visible: hover || focused)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(tile.state == .waiting ? Color(ns: Theme.amber).opacity(0.14) : (focused ? Color.primary.opacity(0.06) : .clear)))
        .onHover { hover = $0 }
    }
}

/// Opens a tile's worktree in Finder.
struct WorktreeButton: View {
    let path: String
    let visible: Bool
    @State private var hover = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
        } label: {
            Image(systemName: "folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hover ? .primary : .secondary)
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hover ? 0.1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(visible || hover ? 1 : 0.45)
        .onHover { hover = $0 }
        .help("Open worktree in Finder\n" + (path as NSString).abbreviatingWithTildeInPath)
        .accessibilityLabel("Open worktree in Finder")
    }
}

struct SidebarToggle: View {
    @ObservedObject var model: AppModel
    @State private var hover = false
    var body: some View {
        Button { model.sidebarVisible.toggle() } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hover ? .primary : .secondary)
                .frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hover ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(model.sidebarVisible ? "Hide sidebar (⌃⌘S)" : "Show sidebar (⌃⌘S)")
        .accessibilityLabel(model.sidebarVisible ? "Hide sidebar" : "Show sidebar")
    }
}

// MARK: - Toolbar

struct ToolbarPill: View {
    @ObservedObject var prefs = Prefs.shared
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            if !model.sidebarVisible {
                SidebarToggle(model: model)
                Divider().frame(height: 16)
            }
            Text(model.board.name).fontWeight(.semibold)
            let agents = model.board.tiles.filter { $0.kind == .agent }.count
            if agents > 0 { Text("· \(agents) agent\(agents == 1 ? "" : "s")").foregroundStyle(.secondary) }
            if Prefs.shared.showCost && model.boardCost >= 0.01 { Text("· " + String(format: "$%.2f", model.boardCost)).foregroundStyle(.secondary).monospacedDigit() }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .pitwallGlass(cornerRadius: 20)
    }
}

struct TrailingControls: View {
    @ObservedObject var model: AppModel
    @ObservedObject var zoomLevel: ZoomLevel

    var body: some View {
        HStack(spacing: 8) {
            if model.attentionCount > 0 {
                Button { model.inboxOpen.toggle() } label: {
                    HStack(spacing: 8) {
                        Circle().fill(Color(ns: Theme.amber)).frame(width: 7, height: 7)
                        Text("\(model.attentionCount) need\(model.attentionCount == 1 ? "s" : "") you").fontWeight(.semibold)
                        Text("⌘J").font(.system(size: 11, design: .monospaced)).opacity(0.7)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .foregroundStyle(Color(ns: Theme.amberText))
                    .pitwallGlass(cornerRadius: 20)
                }
                .buttonStyle(.plain)
                .help("Open the Inbox (⌘I) · ⌘J jumps to the next agent")
            }
            Button { model.controller?.zoomToFit() } label: {
                Text("\(Int((zoomLevel.value * 100).rounded()))%")
                    .font(.system(size: 12).monospacedDigit())
                    .frame(width: 54, height: 40)
                    .pitwallGlass(cornerRadius: 20)
            }
            .buttonStyle(.plain)
            .help("Zoom to fit (⌘0 for 100%)")
        }
    }
}

// MARK: - Dispatch bar

struct DispatchBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var draft: DispatchDraft
    @FocusState private var focused: Bool
    @State private var highlight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !draft.images.isEmpty && model.dispatchAgent != .shell {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(draft.images, id: \.self) { url in
                            AttachmentThumb(url: url) { draft.images.removeAll { $0 == url } }
                        }
                    }
                    .padding(.top, 6)
                }
            }
            TextField(placeholder, text: $draft.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit { model.dispatch() }
                .padding(.top, 4)
            HStack(spacing: 6) {
                ChipPicker(symbol: "folder", title: repoLabel, options: repoOptions, selected: model.dispatchRepo ?? model.board.root ?? "") { v in
                    if v == "__choose__" { model.chooseFile(directories: true) { model.dispatchRepo = $0.path } }
                    else { model.dispatchRepo = v == model.board.root ? nil : v }
                }
                if model.dispatchAgent != .shell {
                    ChipPicker(symbol: "arrow.triangle.branch", title: model.dispatchWorktree ? "New worktree" : "Current branch",
                               options: [
                                .init(value: "worktree", symbol: "arrow.triangle.branch", title: "New worktree",
                                      subtitle: "Its own branch in .worktrees/ — parallel agents never collide"),
                                .init(value: "current", symbol: "point.topleft.down.to.point.bottomright.curvepath", title: "Current branch",
                                      subtitle: "Works directly in the folder's checked-out branch"),
                               ],
                               selected: model.dispatchWorktree ? "worktree" : "current") { model.dispatchWorktree = $0 == "worktree" }
                }
                if model.dispatchAgent != .shell {
                    ChipPicker(symbol: "square.stack.3d.up", title: model.dispatchCount == 1 ? "×1" : "×\(model.dispatchCount) attempts",
                               options: [
                                .init(value: "1", symbol: "1.circle", title: "One agent", subtitle: "The usual"),
                                .init(value: "2", symbol: "2.circle", title: "Two attempts", subtitle: "Same task in 2 worktrees, then pick the best"),
                                .init(value: "3", symbol: "3.circle", title: "Three attempts", subtitle: "Same task in 3 worktrees, then pick the best"),
                               ],
                               selected: String(model.dispatchCount)) { model.dispatchCount = Int($0) ?? 1 }
                }
                ChipPicker(symbol: model.dispatchAgent == .shell ? "terminal" : "sparkle", title: model.dispatchAgent.title,
                           options: [
                            .init(value: AgentKind.claude.rawValue, symbol: "sparkle", title: "Claude Code",
                                  subtitle: "Live status, sub-agents and canvas tools"),
                            .init(value: AgentKind.codex.rawValue, symbol: "chevron.left.forwardslash.chevron.right", title: "Codex",
                                  subtitle: "OpenAI Codex CLI"),
                            .init(value: AgentKind.shell.rawValue, symbol: "terminal", title: "Shell command",
                                  subtitle: "Run any command in a new terminal"),
                           ],
                           selected: model.dispatchAgent.rawValue) { model.dispatchAgent = AgentKind(rawValue: $0) ?? .claude }
                Spacer()
                Button(action: model.dispatch) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.primary))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Start (⌘↩)")
                .accessibilityLabel("Start agent")
            }
        }
        .padding(.leading, 18).padding(.trailing, 10).padding(.vertical, 10)
        .frame(width: 640)
        .pitwallGlass(cornerRadius: 26)
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
            .strokeBorder(Color(ns: Theme.amber).opacity(highlight ? 0.9 : 0), lineWidth: 2))
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            guard model.dispatchAgent != .shell else { return false }
            for p in providers {
                if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        guard let url, ImageAttachments.imageExtensions.contains(url.pathExtension.lowercased()) else { return }
                        DispatchQueue.main.async { model.attachToDispatch([url]) }
                    }
                } else {
                    p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                        guard let data, let rep = NSBitmapImageRep(data: data),
                              let png = rep.representation(using: .png, properties: [:]),
                              let url = ImageAttachments.save(png) else { return }
                        DispatchQueue.main.async { model.attachToDispatch([url]) }
                    }
                }
            }
            return true
        }
        .onChange(of: model.dispatchFocused) { f in
            guard f else { return }
            focused = true
            model.dispatchFocused = false
            withAnimation(.easeOut(duration: 0.15)) { highlight = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation(.easeOut(duration: 0.4)) { highlight = false } }
        }
    }

    private var placeholder: String {
        if model.dispatchAgent == .shell { return "Command to run…" }
        return draft.images.isEmpty ? "What should a new agent work on? (⌘V to attach an image)" : "What should the agent do with this?"
    }

    private var repoOptions: [ChipPicker.Option] {
        var seen = Set<String>()
        var out: [ChipPicker.Option] = []
        let paths = ([model.board.root] + model.store.boards.map(\.root)).compactMap { $0 }
        for p in paths where !seen.contains(p) {
            seen.insert(p)
            out.append(.init(value: p, symbol: "folder", title: (p as NSString).lastPathComponent,
                             subtitle: (p as NSString).abbreviatingWithTildeInPath))
        }
        out.append(.init(value: "__choose__", symbol: "folder.badge.plus", title: "Choose folder…", subtitle: nil))
        return out
    }

    private var repoLabel: String {
        let p = model.dispatchRepo ?? model.board.root ?? NSHomeDirectory()
        return (p as NSString).lastPathComponent
    }
}

/// A pasted image waiting to go out with the next agent.
struct AttachmentThumb: View {
    let url: URL
    let onRemove: () -> Void
    @State private var hover = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let img = NSImage(contentsOf: url) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.primary))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .opacity(hover ? 1 : 0.85)
            .help("Remove image")
            .accessibilityLabel("Remove image")
        }
        .padding(.trailing, 6)
        .onHover { hover = $0 }
        .help(url.lastPathComponent)
    }
}

/// A pill that opens a glass popover of rich options.
struct ChipPicker: View {
    struct Option: Identifiable {
        var value: String
        var symbol: String
        var title: String
        var subtitle: String?
        var id: String { value }
    }
    let symbol: String
    let title: String
    let options: [Option]
    let selected: String
    let onSelect: (String) -> Void
    @State private var open = false
    @State private var hovered: String?

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                Chip(text: title, symbol: symbol, trailingChevron: true, active: open)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(options) { o in
                    Button {
                        open = false
                        onSelect(o.value)
                    } label: {
                        HStack(alignment: .center, spacing: 10) {
                            Image(systemName: o.symbol)
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 28, height: 28)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(o.title).font(.system(size: 13, weight: .medium))
                                if let sub = o.subtitle {
                                    Text(sub).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 12)
                            if o.value == selected {
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(hovered == o.value ? Color.primary.opacity(0.07) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 ? o.value : (hovered == o.value ? nil : hovered) }
                }
            }
            .padding(6)
            .frame(minWidth: 280)
        }
    }
}

struct Chip: View {
    let text: String
    let symbol: String
    var trailingChevron = false
    var active = false
    @State private var hover = false
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
            Text(text).font(.system(size: 12, weight: .medium)).lineLimit(1)
            if trailingChevron {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.55)
            }
        }
        .padding(.horizontal, 12).frame(height: 30)
        .background(Capsule().fill(Color.primary.opacity(active ? 0.14 : (hover ? 0.11 : 0.07))))
        .contentShape(Capsule())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

// MARK: - Toasts

struct ToastStack: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            ForEach(model.toasts) { t in ToastView(toast: t, model: model) }
        }
        .frame(width: 310, alignment: .topTrailing)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.toasts)
    }
}

struct ToastView: View {
    let toast: Toast
    @ObservedObject var model: AppModel

    var isPermission: Bool {
        if let id = toast.tileID, ApprovalCenter.shared.pending(for: id) != nil { return true }
        return toast.body.localizedCaseInsensitiveContains("permission")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 9, height: 9)
                Text(toast.title).fontWeight(.semibold).lineLimit(1)
                Spacer()
                Button { model.dismiss(toast) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Dismiss")
            }
            Text(toast.body).foregroundStyle(.secondary).lineLimit(3)
            if toast.tileID != nil {
                HStack(spacing: 6) {
                    if isPermission {
                        ToastButton(title: "Approve", primary: true, accent: true) { model.answer(toast, allow: true) }
                        ToastButton(title: "Deny", primary: false) { model.answer(toast, allow: false) }
                    }
                    ToastButton(title: "Go to", primary: !isPermission, accent: !isPermission && toast.kind == .attention) { model.goTo(toast) }
                }
            }
        }
        .padding(14)
        .frame(width: 300)
        .pitwallGlass(cornerRadius: 18)
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private var color: Color {
        switch toast.kind {
        case .attention: return Color(ns: Theme.amber)
        case .error: return Color(ns: Theme.red)
        case .info: return Color(ns: Theme.blue)
        }
    }
}

struct ToastButton: View {
    let title: String
    let primary: Bool
    var accent = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: primary ? .semibold : .medium))
                .frame(maxWidth: .infinity, minHeight: 30)
                .foregroundStyle(accent ? Color(red: 0.10, green: 0.07, blue: 0.02) : (primary ? Color(nsColor: .windowBackgroundColor) : Color.primary))
                .background(Capsule().fill(accent ? Color(ns: Theme.amber) : (primary ? Color.primary : Color.primary.opacity(0.08))))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - New tile picker

struct PickerView: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @FocusState private var focused: Bool

    struct Item: Identifiable {
        let kind: TileKind
        let name: String
        let glyph: String
        let key: String
        var server = false
        var id: String { name }
    }

    let items: [Item] = [
        .init(kind: .agent, name: "Agent", glyph: "sparkle", key: "a"),
        .init(kind: .terminal, name: "Terminal", glyph: "terminal", key: "t"),
        .init(kind: .browser, name: "Browser", glyph: "globe", key: "b"),
        .init(kind: .note, name: "Note", glyph: "text.alignleft", key: "n"),
        .init(kind: .code, name: "File", glyph: "curlybraces", key: "f"),
        .init(kind: .diff, name: "Diff", glyph: "plusminus", key: "d"),
        .init(kind: .logs, name: "Watch", glyph: "waveform.path.ecg", key: "w"),
        .init(kind: .pr, name: "Pull request", glyph: "arrow.triangle.pull", key: "p"),
        .init(kind: .logs, name: "Dev server", glyph: "server.rack", key: "s", server: true),
    ]

    var body: some View {
        VStack(spacing: 8) {
            TextField("Agent task, file, URL, or command…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
                .focused($focused)
                .onSubmit { model.pickerSubmit(query) }
                .onExitCommand { model.pickerPoint = nil }
                .onKeyPress { press in
                    // Single keys pick a type while the field is empty.
                    guard query.isEmpty, press.modifiers.isEmpty else { return .ignored }
                    let c = press.characters.lowercased()
                    if let item = items.first(where: { $0.key == c }) { choose(item); return .handled }
                    if c == "g" { model.pickerPoint = nil; model.controller?.newFrame(); return .handled }
                    return .ignored
                }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(items) { item in
                    Button { choose(item) } label: {
                        VStack(spacing: 6) {
                            Image(systemName: item.glyph)
                                .font(.system(size: 15, weight: .medium))
                                .frame(width: 34, height: 34)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(item.kind == .agent ? 0.85 : 0.07)))
                                .foregroundStyle(item.kind == .agent ? Color(nsColor: .windowBackgroundColor) : .primary)
                            Text(item.name).font(.system(size: 12, weight: .medium))
                            Text(item.key.uppercased()).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button { model.pickerPoint = nil; model.controller?.newFrame() } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "rectangle.dashed").font(.system(size: 15, weight: .medium))
                            .frame(width: 34, height: 34)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
                        Text("Frame").font(.system(size: 12, weight: .medium))
                        Text("G").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(hint).font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
        }
        .padding(10)
        .frame(width: 400)
        .pitwallGlass(cornerRadius: 22)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func choose(_ item: Item) {
        if item.server {
            let at = model.pickerPoint?.world
            model.pickerPoint = nil
            model.controller?.promptServer(at: at)
        } else {
            model.pick(item.kind)
        }
    }

    private var hint: String {
        let s = query.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return "Return opens a terminal. Type a sentence to start an agent." }
        if s.hasPrefix("http") || s.hasPrefix("localhost") { return "Return opens a browser tile" }
        if s.hasPrefix("/") || s.hasPrefix("~") { return "Return opens this path" }
        return AppModel.looksLikeCommand(s) ? "Return runs this command in a terminal" : "Return starts a Claude Code agent with this task"
    }
}
