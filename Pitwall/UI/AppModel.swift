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
    /// Portal toasts: the button jumps through this portal.
    var portalID: String? = nil
}

struct BoardActivity: Equatable {
    var waiting = 0, failing = 0, done = 0, working = 0, background = 0

    var summary: String {
        var p: [String] = []
        if waiting > 0 { p.append("\(waiting) need\(waiting == 1 ? "s" : "") you") }
        if failing > 0 { p.append("\(failing) failing") }
        if done > 0 { p.append("\(done) finished") }
        if working > 0 { p.append("\(working) working") }
        if background > 0 { p.append("\(background) running in background") }
        return p.isEmpty ? "Nothing running" : p.joined(separator: " · ")
    }
}

final class ZoomLevel: ObservableObject {
    @Published var value: CGFloat = 1
}

final class DispatchDraft: ObservableObject {
    @Published var text = ""
    /// Images pasted or dropped into the dispatch bar, sent with the task.
    @Published var images: [URL] = []
}

/// Images pasted into Pitwall: attached to a new agent's task, or pasted
/// into a terminal.
enum ImageAttachments {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "tif", "bmp"]
    static var dir: URL { PitwallPaths.support.appendingPathComponent("attachments", isDirectory: true) }

    /// Images on the pasteboard: image files (copied in Finder) are used in
    /// place; raw image data (screenshots, "Copy Image") is saved as PNG.
    /// Empty when the pasteboard holds text, so a normal paste goes ahead.
    static func images(from pb: NSPasteboard) -> [URL] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL], !urls.isEmpty {
            return urls.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
        }
        if pb.string(forType: .string) != nil { return [] }
        guard let png = pngData(from: pb) else { return [] }
        return save(png).map { [$0] } ?? []
    }

    /// The pasteboard holds an image and nothing a text paste could use.
    static func isImageOnly(_ pb: NSPasteboard) -> Bool {
        guard pb.string(forType: .string) == nil else { return false }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty { return false }
        return NSImage.canInit(with: pb)
    }

    static func pngData(from pb: NSPasteboard) -> Data? {
        if let d = pb.data(forType: .png) { return d }
        guard let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func save(_ png: Data) -> URL? {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("pasted-\(f.string(from: Date()))-\(UUID().uuidString.prefix(4).lowercased()).png")
        do { try png.write(to: url); return url } catch { return nil }
    }

    /// Pasted images older than a week are no longer needed.
    static func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        for f in files where ((try? f.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()) < cutoff {
            try? fm.removeItem(at: f)
        }
    }
}

/// UI state shared by the SwiftUI overlays.
final class AppModel: ObservableObject {
    weak var controller: CanvasController?
    let store = Store.shared

    /// Zoom lives in its own object (only the zoom pill watches it), and only
    /// whole-percent changes are published, so zooming doesn't re-render
    /// every overlay on every frame.
    let zoomLevel = ZoomLevel()
    var zoom: CGFloat {
        get { zoomLevel.value }
        set { if Int((newValue * 100).rounded()) != Int((zoomLevel.value * 100).rounded()) { zoomLevel.value = newValue } }
    }
    @Published var focusedTileID: String?
    @Published var toasts: [Toast] = []
    @Published var pickerPoint: (world: CGPoint, view: CGPoint)? = nil {
        didSet { onPickerChange?() }
    }
    /// The dispatch bar's draft lives in its own object so typing only
    /// re-renders the bar, not every view that watches the app model.
    let draft = DispatchDraft()
    var dispatchText: String {
        get { draft.text }
        set { draft.text = newValue }
    }
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
    @Published var searchOpen = false
    let search = SearchModel()
    @Published var inboxSelection: String?
    @Published var sidebarVisible = UserDefaults.pitwall.object(forKey: "sidebarVisible") as? Bool ?? true {
        didSet { UserDefaults.pitwall.set(sidebarVisible, forKey: "sidebarVisible") }
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

    /// What's going on in a board, for its sidebar indicators.
    func activity(on b: Board) -> BoardActivity {
        var a = BoardActivity()
        for t in b.tiles where t.kind != .subagent {
            switch t.state {
            case .waiting: a.waiting += 1
            case .error: a.failing += 1
            case .done: a.done += 1
            case .working: if t.isWaitingExternally { a.background += 1 } else { a.working += 1 }
            case .idle: break
            }
            if t.hasBackgroundWork { a.background += 1 }
        }
        return a
    }

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
        let images = draft.images
        if dispatchAgent == .shell {
            _ = ctl.newTerminal(cwd: dispatchRepo ?? board.root, command: task.isEmpty ? nil : task)
        } else if dispatchCount > 1 && !(task.isEmpty && images.isEmpty) {
            ctl.fanOut(task: task, repo: dispatchRepo ?? board.root, agent: dispatchAgent, count: dispatchCount, images: images)
        } else {
            ctl.newAgent(task: task, repo: dispatchRepo ?? board.root, worktree: dispatchWorktree, agent: dispatchAgent, images: images)
        }
        dispatchText = ""
        if dispatchAgent != .shell { draft.images = [] }
    }

    /// ⌘V in the dispatch bar: attaches clipboard images. Returns false when
    /// there's nothing to attach, so the text field pastes as usual.
    func pasteImagesIntoDispatch(from pb: NSPasteboard = .general) -> Bool {
        guard dispatchAgent != .shell else { return false }
        return attachToDispatch(ImageAttachments.images(from: pb))
    }

    @discardableResult
    func attachToDispatch(_ urls: [URL]) -> Bool {
        let new = urls.filter { !draft.images.contains($0) }
        guard !urls.isEmpty else { return false }
        draft.images.append(contentsOf: new)
        return true
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

    /// Jumps through a toast's portal from whichever end is on screen.
    func jump(_ t: Toast) {
        guard let pid = t.portalID, let p = store.portal(pid), let ctl = controller else { goTo(t); return }
        let from = store.findTile(p.a.tileID)?.board.id == store.currentBoardID ? p.a.tileID
            : (store.findTile(p.b.tileID)?.board.id == store.currentBoardID ? p.b.tileID : p.a.tileID)
        ctl.jumpThroughPortal(pid, from: from)
        dismiss(t)
    }

    /// Boards this board has portals to.
    func portalPeers(of b: Board) -> [Board] {
        var ids: [String] = []
        for p in store.portals {
            if p.a.boardID == b.id, !ids.contains(p.b.boardID) { ids.append(p.b.boardID) }
            if p.b.boardID == b.id, !ids.contains(p.a.boardID) { ids.append(p.a.boardID) }
        }
        return ids.compactMap { store.board($0) }
    }

    func goTo(_ t: Toast) {
        guard let id = t.tileID, let ctl = controller else { return }
        if let (b, _) = store.findTile(id), b.id != store.currentBoardID { ctl.switchBoard(b.id) }
        ctl.flyTo(tileID: id, fill: false)
        dismiss(t)
    }
}
