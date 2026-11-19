import Foundation
import Combine

/// Single source of truth for boards. Persists to Application Support as one
/// JSON file per board, debounced.
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var boards: [Board] = []
    @Published var currentBoardID: String = ""
    /// Messages waiting to be delivered to a tile's agent.
    @Published var inbox: [String: [AgentMessage]] = [:]
    /// Agent ↔ agent connections across boards (saved to portals.json).
    @Published private(set) var portals: [Portal] = []

    private var saveWork: DispatchWorkItem?
    private struct AppState: Codable { var currentBoardID: String; var order: [String] }
    private struct PortalsFile: Codable { var version = 1; var portals: [Portal] }

    private init() {
        load()
    }

    var current: Board {
        get { boards.first { $0.id == currentBoardID } ?? boards[0] }
    }

    func board(_ id: String) -> Board? { boards.first { $0.id == id } }

    /// Mutate a board in place and schedule a save.
    func update(_ boardID: String? = nil, _ change: (inout Board) -> Void) {
        let id = boardID ?? currentBoardID
        guard let i = boards.firstIndex(where: { $0.id == id }) else { return }
        change(&boards[i])
        scheduleSave()
    }

    func updateTile(_ tileID: String, _ change: (inout Tile) -> Void) {
        for bi in boards.indices {
            if let ti = boards[bi].tiles.firstIndex(where: { $0.id == tileID }) {
                change(&boards[bi].tiles[ti])
                scheduleSave()
                return
            }
        }
    }

    func findTile(_ tileID: String) -> (board: Board, tile: Tile)? {
        for b in boards { if let t = b.tile(tileID) { return (b, t) } }
        return nil
    }

    func addBoard(name: String, root: String?, switchTo: Bool = true) -> Board {
        var b = Board(name: name, root: root)
        b.colorIndex = boards.count % Theme.boardColors.count
        boards.append(b)
        if switchTo { currentBoardID = b.id }
        scheduleSave()
        return b
    }

    func removeBoard(_ id: String) {
        guard boards.count > 1 else { return }
        boards.removeAll { $0.id == id }
        portals.removeAll { $0.a.boardID == id || $0.b.boardID == id }
        if currentBoardID == id { currentBoardID = boards[0].id }
        try? FileManager.default.removeItem(at: PitwallPaths.boardsDir.appendingPathComponent("\(id).json"))
        scheduleSave()
    }

    // MARK: Portals

    /// Adds a portal unless the pair is already connected (either way round).
    @discardableResult
    func addPortal(_ p: Portal) -> (portal: Portal, created: Bool) {
        if let existing = portals.first(where: { $0.key == p.key }) { return (existing, false) }
        portals.append(p)
        scheduleSave()
        return (p, true)
    }

    @discardableResult
    func removePortals(where match: (Portal) -> Bool) -> [Portal] {
        let gone = portals.filter(match)
        guard !gone.isEmpty else { return [] }
        portals.removeAll(where: match)
        scheduleSave()
        return gone
    }

    func updatePortal(_ id: String, _ change: (inout Portal) -> Void) {
        guard let i = portals.firstIndex(where: { $0.id == id }) else { return }
        change(&portals[i])
        scheduleSave()
    }

    func portal(_ id: String) -> Portal? { portals.first { $0.id == id } }
    func portals(of tileID: String) -> [Portal] { portals.filter { $0.involves(tileID) } }

    // MARK: Persistence

    private func load() {
        PitwallPaths.ensure()
        let fm = FileManager.default
        var loaded: [Board] = []
        if let files = try? fm.contentsOfDirectory(at: PitwallPaths.boardsDir, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "json" {
                if var b = try? Wire.decoder.decode(Board.self, from: (try? Data(contentsOf: f)) ?? Data()) {
                    // Older boards: frames owned whatever sat inside them.
                    for i in b.tiles.indices where b.tiles[i].frameGroupID == nil {
                        if let fr = b.frames.first(where: { $0.frame.contains(b.tiles[i].frame) }) { b.tiles[i].frameGroupID = fr.id }
                    }
                    loaded.append(b)
                }
            }
        }
        var state: AppState?
        if let d = try? Data(contentsOf: PitwallPaths.stateFile) {
            state = try? Wire.decoder.decode(AppState.self, from: d)
        }
        if let order = state?.order {
            loaded.sort { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
        }
        if loaded.isEmpty {
            let home = NSHomeDirectory()
            loaded = [Board(name: "Home", root: home)]
        }
        boards = loaded
        if let d = try? Data(contentsOf: PitwallPaths.portalsFile), let f = try? Wire.decoder.decode(PortalsFile.self, from: d) {
            portals = Portals.pruned(f.portals, boards: loaded)
        }
        currentBoardID = state.flatMap { s in loaded.contains { $0.id == s.currentBoardID } ? s.currentBoardID : nil } ?? loaded[0].id
    }

    func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    func saveNow() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        for b in boards {
            if let d = try? enc.encode(b) {
                try? d.write(to: PitwallPaths.boardsDir.appendingPathComponent("\(b.id).json"), options: .atomic)
            }
        }
        if let d = try? enc.encode(PortalsFile(portals: portals)) {
            try? d.write(to: PitwallPaths.portalsFile, options: .atomic)
        }
        if let d = try? enc.encode(AppState(currentBoardID: currentBoardID, order: boards.map(\.id))) {
            try? d.write(to: PitwallPaths.stateFile, options: .atomic)
        }
    }
}
