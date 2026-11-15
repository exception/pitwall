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

    private var saveWork: DispatchWorkItem?
    private struct AppState: Codable { var currentBoardID: String; var order: [String] }

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

    func addBoard(name: String, root: String?) -> Board {
        var b = Board(name: name, root: root)
        b.colorIndex = boards.count % Theme.boardColors.count
        boards.append(b)
        currentBoardID = b.id
        scheduleSave()
        return b
    }

    func removeBoard(_ id: String) {
        guard boards.count > 1 else { return }
        boards.removeAll { $0.id == id }
        if currentBoardID == id { currentBoardID = boards[0].id }
        try? FileManager.default.removeItem(at: PitwallPaths.boardsDir.appendingPathComponent("\(id).json"))
        scheduleSave()
    }

    // MARK: Persistence

    private func load() {
        PitwallPaths.ensure()
        let fm = FileManager.default
        var loaded: [Board] = []
        if let files = try? fm.contentsOfDirectory(at: PitwallPaths.boardsDir, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "json" {
                if let d = try? Data(contentsOf: f), let b = try? Wire.decoder.decode(Board.self, from: d) {
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
        if let d = try? enc.encode(AppState(currentBoardID: currentBoardID, order: boards.map(\.id))) {
            try? d.write(to: PitwallPaths.stateFile, options: .atomic)
        }
    }
}
