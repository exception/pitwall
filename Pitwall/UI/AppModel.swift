import AppKit
import SwiftUI
import Combine

struct Toast: Identifiable, Equatable {
    enum Kind { case attention, info, error }
    var id = UUID()
    var kind: Kind
    var title: String
    var body: String
    var tileID: String?
}

/// UI state shared by the SwiftUI overlays.
final class AppModel: ObservableObject {
    weak var controller: CanvasController?
    let store = Store.shared

    @Published var zoom: CGFloat = 1
    @Published var focusedTileID: String?
    @Published var toasts: [Toast] = []
    @Published var pickerPoint: (world: CGPoint, view: CGPoint)? = nil {
        didSet { onPickerChange?() }
    }
    @Published var dispatchText = ""
    @Published var dispatchWorktree = Prefs.shared.worktreeByDefault
    @Published var dispatchAgent: AgentKind = AgentKind(rawValue: Prefs.shared.defaultAgent) ?? .claude
    @Published var dispatchRepo: String?
    /// Fan-out: how many parallel attempts to start.
    @Published var dispatchCount = 1
    @Published var dispatchFocusToken = 0
    /// Drives the dispatch field's focus + highlight.
    @Published var dispatchFocused = false
    @Published var attentionCount = 0
    /// A tile is filling the window; canvas chrome steps aside.
    @Published var fullScreen = false
    @Published var inboxOpen = false
    @Published var inboxSelection: String?
    @Published var sidebarVisible = UserDefaults.standard.object(forKey: "sidebarVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sidebarVisible, forKey: "sidebarVisible") }
    }

    var onPickerChange: (() -> Void)?
    private var bag = Set<AnyCancellable>()

    init() {
        store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }.store(in: &bag)
    }

    var canvasInsets: NSEdgeInsets {
        NSEdgeInsets(top: 76, left: sidebarVisible ? 290 : 24, bottom: 150, right: 30)
    }

    var board: Board { store.current }

    var sortedTiles: [Tile] {
        board.tiles.filter { $0.kind != .subagent }.sorted {
            ($0.state.priority, $1.stateSince) < ($1.state.priority, $0.stateSince)
        }
    }

    func attention(on b: Board) -> Int { b.tiles.filter { $0.state == .waiting }.count }

    func refreshAttention() {
        attentionCount = store.boards.flatMap(\.tiles).filter { $0.state == .waiting }.count
    }

    func toast(_ t: Toast) {
        if let tid = t.tileID { toasts.removeAll { $0.tileID == tid } }
        toasts.insert(t, at: 0)
        if toasts.count > 4 { toasts.removeLast(toasts.count - 4) }
        if t.kind != .attention {
            let id = t.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.toasts.removeAll { $0.id == id } }
        }
    }

    func dismiss(_ t: Toast) { toasts.removeAll { $0.id == t.id } }

    func showPicker(world: CGPoint, view: CGPoint) { pickerPoint = (world, view) }

    func focusDispatch() { dispatchFocusToken += 1 }

    // MARK: Actions

    func dispatch() {
        let task = dispatchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ctl = controller else { return }
        if dispatchAgent == .shell {
            _ = ctl.newTerminal(cwd: dispatchRepo ?? board.root, command: task.isEmpty ? nil : task)
        } else if dispatchCount > 1 && !task.isEmpty {
            ctl.fanOut(task: task, repo: dispatchRepo ?? board.root, agent: dispatchAgent, count: dispatchCount)
        } else {
            ctl.newAgent(task: task, repo: dispatchRepo ?? board.root, worktree: dispatchWorktree, agent: dispatchAgent)
        }
        dispatchText = ""
    }

    /// Interprets free text typed into the picker.
    func pickerSubmit(_ text: String) {
        guard let ctl = controller, let p = pickerPoint else { return }
        pickerPoint = nil
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { _ = ctl.newTerminal(at: p.world); return }
        let expanded = (s as NSString).expandingTildeInPath
        if s.hasPrefix("http://") || s.hasPrefix("https://") || s.hasPrefix("localhost") || s.range(of: "^[a-z0-9.-]+\\.[a-z]{2,}(/|$)", options: .regularExpression) != nil {
            ctl.open(target: s.contains("://") || s.hasPrefix("localhost") ? s : "https://" + s, at: p.world)
        } else if (s.hasPrefix("/") || s.hasPrefix("~") || s.hasPrefix(".")) && FileManager.default.fileExists(atPath: expanded) {
            ctl.open(target: expanded, at: p.world)
        } else if Self.looksLikeCommand(s) {
            _ = ctl.newTerminal(command: s, at: p.world)
        } else {
            ctl.newAgent(task: s, repo: board.root, worktree: false, agent: .claude, at: p.world)
        }
    }

    static let commonCommands: Set<String> = ["git", "npm", "npx", "pnpm", "yarn", "bun", "make", "cargo", "docker", "kubectl", "python", "python3",
                                              "node", "ls", "cd", "go", "swift", "brew", "ssh", "tail", "less", "vim", "nvim", "htop", "top", "gh",
                                              "uv", "pip", "rails", "bundle", "mix", "deno", "terraform", "helm", "claude", "codex", "expo", "watch"]

    static func looksLikeCommand(_ s: String) -> Bool {
        let first = s.split(separator: " ").first.map(String.init) ?? s
        if commonCommands.contains(first) { return true }
        if s.contains("&&") || s.contains("|") || s.hasPrefix("./") || s.hasPrefix("$ ") { return true }
        return !s.contains(" ") && s.count < 24 // single word → a command
    }

    func pick(_ kind: TileKind) {
        guard let ctl = controller, let p = pickerPoint else { return }
        pickerPoint = nil
        switch kind {
        case .agent: ctl.newAgent(task: "", repo: board.root, worktree: false, agent: .claude, at: p.world)
        case .terminal: _ = ctl.newTerminal(at: p.world)
        case .browser: ctl.open(target: "http://localhost:3000", at: p.world)
        case .note: ctl.newNote(at: p.world)
        case .code:
            chooseFile { url in ctl.open(target: url.path, at: p.world) }
        case .diff: ctl.newDiff(at: p.world)
        case .logs: ctl.promptWatch(at: p.world)
        case .pr: ctl.newPR(repo: board.root ?? ctl.defaultCwd, at: p.world)
        default: break
        }
    }

    func chooseFile(directories: Bool = false, _ done: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directories
        panel.canChooseDirectories = directories
        panel.allowsMultipleSelection = false
        panel.directoryURL = board.root.map { URL(fileURLWithPath: $0) }
        panel.begin { r in if r == .OK, let u = panel.url { done(u) } }
    }

    func addBoard() {
        chooseFile(directories: true) { [weak self] url in
            guard let self else { return }
            _ = self.store.addBoard(name: url.lastPathComponent, root: url.path)
            self.controller?.reconcile()
        }
    }

    /// Answers a permission prompt from a toast: through the hook when one is
    /// waiting, otherwise by typing the choice into Claude's prompt.
    func answer(_ t: Toast, allow: Bool) {
        guard let id = t.tileID else { return }
        if let p = ApprovalCenter.shared.pending(for: id) {
            ApprovalCenter.shared.decide(p.id, allow ? .allow : .deny)
        } else if let s = controller?.surface(for: id) {
            s.sendText(allow ? "1" : "3")
            controller?.setState(id, .working)
        }
        dismiss(t)
    }

    func goTo(tileID: String) {
        guard let ctl = controller else { return }
        if let (b, _) = store.findTile(tileID), b.id != store.currentBoardID { ctl.switchBoard(b.id) }
        ctl.flyTo(tileID: tileID, fill: false)
    }

    /// Total estimated spend of agents on the current board.
    var boardCost: Double { board.tiles.compactMap(\.costUSD).reduce(0, +) }

    func goTo(_ t: Toast) {
        guard let id = t.tileID, let ctl = controller else { return }
        if let (b, _) = store.findTile(id), b.id != store.currentBoardID { ctl.switchBoard(b.id) }
        ctl.flyTo(tileID: id, fill: false)
        dismiss(t)
    }
}
