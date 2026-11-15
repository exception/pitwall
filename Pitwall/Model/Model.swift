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
    case terminal, agent, note, code, image, browser, diff, logs, subagent, compare, pr
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
    /// Linked git worktree the tile's current directory is in, found by
    /// polling (covers agents started by hand inside a worktree).
    var detectedWorktree: String?
    var diffAdded: Int?
    var diffRemoved: Int?
    var terminalTitle: String?
    /// Usage reported by Claude Code's status line.
    var costUSD: Double?
    var contextPct: Int?
    var model: String?
    /// Image files this tile's output mentioned (newest last), for the gallery.
    var images: [String]?
    /// Watch tiles (kind .logs): the command being watched, as typed.
    var watchCommand: String?
    /// PR tiles: PR number/URL (nil = the current branch's PR); target is the repo.
    var prRef: String?
    /// Watch/PR tiles: send failures to the linked agent automatically.
    var autoSend: Bool?
    /// Dev servers: restart the command when it exits or crashes.
    var keepAlive: Bool?

    var displayName: String {
        if let name, !name.isEmpty { return name }
        if let autoName, !autoName.isEmpty { return autoName }
        switch kind {
        case .browser:
            guard let t = target, let u = URL(string: t), let h = u.host else { return "Browser" }
            return h + (u.port.map { ":\($0)" } ?? "")
        case .pr: return prRef.map { "PR " + ($0.hasPrefix("http") ? "#" + ($0.split(separator: "/").last.map(String.init) ?? $0) : "#" + $0) } ?? "Pull request"
        case .note, .code, .image, .diff: return target.map { ($0 as NSString).lastPathComponent } ?? kind.rawValue.capitalized
        default:
            if let t = terminalTitle, !t.isEmpty { return t }
            return cwd.map { ($0 as NSString).lastPathComponent } ?? "Terminal"
        }
    }

    /// The git worktree this tile works in, if any.
    var worktreePath: String? { worktree ?? detectedWorktree }

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

    /// Height of the title strip, and of the whole frame when collapsed.
    static let headerHeight: CGFloat = 56
    /// Where the frame is drawn: just its title strip when collapsed.
    var visibleFrame: CGRect { collapsed ? CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: Self.headerHeight) : frame }
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
    /// Named arrangements of this board's tiles.
    var layouts: [SavedLayout]?

    func tile(_ id: String) -> Tile? { tiles.first { $0.id == id } }
    func members(of frameID: String) -> [Tile] { tiles.filter { $0.frameGroupID == frameID } }
    var maxZ: Int { tiles.map(\.z).max() ?? 0 }
}

/// A saved arrangement: where each tile sat, which frames were collapsed,
/// and the viewport.
struct SavedLayout: Codable, Identifiable, Equatable {
    var id: String = "y-" + UUID().uuidString.prefix(8).lowercased()
    var name: String
    var tiles: [String: CGRect]
    var frames: [String: CGRect]
    var collapsed: [String]
    var viewport: Viewport
    var savedAt = Date()
}

/// A message sent between linked agents.
struct AgentMessage: Codable, Equatable {
    var from: String
    var fromName: String
    var text: String
    var at = Date()
}
