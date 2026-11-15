import Foundation
import CoreGraphics

/// What an agent (or plain shell) in a tile is doing.
enum AgentState: String, Codable, CaseIterable {
    case idle, working, waiting, done, error

    /// Sort order for "who needs me first".
    var priority: Int {
        switch self {
        case .waiting: return 0
        case .error: return 1
        case .done: return 2
        case .working: return 3
        case .idle: return 4
        }
    }

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .working: return "Working"
        case .waiting: return "Needs you"
        case .done: return "Done"
        case .error: return "Error"
        }
    }

    var needsAttention: Bool { self == .waiting || self == .error }
}

enum TileKind: String, Codable {
    case terminal, agent, note, code, image, browser, diff, logs, subagent, compare
}

/// A tile on a board. Frames are in world coordinates (points at 100% zoom).
struct Tile: Codable, Identifiable, Equatable {
    var id: String = "t-" + UUID().uuidString.prefix(8).lowercased()
    var kind: TileKind
    var frame: CGRect
    var z: Int = 0
    /// User-set name; nil means auto (derived from task / title / cwd).
    var name: String?
    var autoName: String?
    var cwd: String?
    /// Command the session was started with (agent tiles: the agent CLI).
    var command: String?
    /// Daemon session id (terminal/agent/logs tiles).
    var sessionID: String?
    /// File path (note/code/image/diff tiles) or URL (browser).
    var target: String?
    /// The terminal tile that runs the dev server this browser shows.
    var serverTileID: String?
    var frameGroupID: String?

    // Live agent info (persisted so the card renders before reconnect).
    var state: AgentState = .idle
    var stateSince: Date = Date()
    var statusMessage: String?
    var task: String?
    var branch: String?
    var worktree: String?
    var diffAdded: Int?
    var diffRemoved: Int?
    var terminalTitle: String?
    /// Usage reported by Claude Code's status line.
    var costUSD: Double?
    var contextPct: Int?
    var model: String?
    /// Image files this tile's output mentioned (newest last), for the gallery.
    var images: [String]?

    var displayName: String {
        if let name, !name.isEmpty { return name }
        if let autoName, !autoName.isEmpty { return autoName }
        switch kind {
        case .browser:
            guard let t = target, let u = URL(string: t), let h = u.host else { return "Browser" }
            return h + (u.port.map { ":\($0)" } ?? "")
        case .note, .code, .image, .diff: return target.map { ($0 as NSString).lastPathComponent } ?? kind.rawValue.capitalized
        default:
            if let t = terminalTitle, !t.isEmpty { return t }
            return cwd.map { ($0 as NSString).lastPathComponent } ?? "Terminal"
        }
    }

    var isTerminalBacked: Bool { kind == .terminal || kind == .agent || kind == .logs }
}

/// A connection between two tiles.
struct Link: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case spawned, manual }
    var id: String = "l-" + UUID().uuidString.prefix(8).lowercased()
    var from: String
    var to: String
    var kind: Kind
    /// Last time a message travelled along this link (drives the pulse).
    var lastActivity: Date?
    /// Pipeline: when `from` finishes a turn, its result goes to `to`.
    var handoff: Bool?
    var isHandoff: Bool { handoff == true }
}

/// A labeled group of tiles.
struct FrameGroup: Codable, Identifiable, Equatable {
    var id: String = "f-" + UUID().uuidString.prefix(8).lowercased()
    var title: String
    var frame: CGRect
    var colorIndex: Int = 0
    var collapsed = false
}

struct Viewport: Codable, Equatable {
    /// World point at the top-left of the canvas view.
    var origin: CGPoint = CGPoint(x: -80, y: -80)
    var zoom: CGFloat = 1
}

/// A project canvas. Each board has its own tiles and root folder.
struct Board: Codable, Identifiable, Equatable {
    var id: String = "b-" + UUID().uuidString.prefix(8).lowercased()
    var name: String
    var root: String?
    var colorIndex: Int = 0
    var tiles: [Tile] = []
    var links: [Link] = []
    var frames: [FrameGroup] = []
    var viewport = Viewport()

    func tile(_ id: String) -> Tile? { tiles.first { $0.id == id } }
    var maxZ: Int { tiles.map(\.z).max() ?? 0 }
}

/// A message sent between linked agents.
struct AgentMessage: Codable, Equatable {
    var from: String
    var fromName: String
    var text: String
    var at = Date()
}
