import Foundation
import CoreGraphics

/// Who asked for a portal. The in-app menu is the user; anything that comes
/// through the control socket (MCP, CLI, scripts) counts as an agent, so the
/// Settings toggle and the rate limit always apply to it.
enum OpenedBy: String { case user, agent }

struct PortalError: Error, Equatable, CustomStringConvertible {
    let message: String
    init(_ m: String) { message = m }
    var description: String { message }
}

/// Pure portal logic: lookups, validation, routing, prompts. Unit-tested.
enum Portals {
    static let rateLimit = 3
    static let rateWindow: TimeInterval = 600
    /// Marks the first prompt of a portal-spawned agent (kept out of `task`).
    static let promptMarker = "[Pitwall portal]"

    // MARK: Board lookup

    /// An exact id wins; then a case-insensitive name. Ambiguous names fail
    /// with the candidates' ids.
    static func board(_ q: String, in boards: [Board]) -> Result<Board, PortalError> {
        let q = q.trimmingCharacters(in: .whitespaces)
        if let b = boards.first(where: { $0.id == q }) { return .success(b) }
        let named = boards.filter { $0.name.caseInsensitiveCompare(q) == .orderedSame }
        if named.count == 1 { return .success(named[0]) }
        if named.isEmpty { return .failure(PortalError("no board named \(q)")) }
        let list = named.map { b in "\(b.id)" + (b.root.map { " (\(abbreviate($0)))" } ?? "") }.joined(separator: ", ")
        return .failure(PortalError("several boards are named \(q): \(list); pass the id"))
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: Validation

    enum Plan: Equatable {
        case spawn(source: Tile, sourceBoard: Board, target: Board, task: String)
        case connect(source: Tile, sourceBoard: Board, target: Board, tile: Tile, task: String?, existing: Portal?)

        var target: Board {
            switch self { case .spawn(_, _, let t, _), .connect(_, _, let t, _, _, _): return t }
        }
    }

    static func isAgent(_ t: Tile, hooked: Set<String>) -> Bool { t.kind == .agent || hooked.contains(t.id) }

    static func validate(source: String, board query: String, task: String?, existing: String?, by: OpenedBy,
                         boards: [Board], portals: [Portal], hooked: Set<String>,
                         agentPortalsEnabled: Bool, recentOpens: [Date], now: Date = Date()) -> Result<Plan, PortalError> {
        guard let sb = boards.first(where: { $0.tile(source) != nil }), let src = sb.tile(source) else {
            return .failure(PortalError("run this inside a Pitwall tile"))
        }
        guard isAgent(src, hooked: hooked) else { return .failure(PortalError("tile \(src.displayName) isn't an agent")) }
        let target: Board
        switch board(query, in: boards) {
        case .success(let b): target = b
        case .failure(let e): return .failure(e)
        }
        guard target.id != sb.id else { return .failure(PortalError("that's this tile's own board; use a link instead")) }
        if by == .agent {
            guard agentPortalsEnabled else { return .failure(PortalError("portals from agents are turned off in Pitwall Settings")) }
            let recent = recentOpens.filter { now.timeIntervalSince($0) < rateWindow }
            if recent.count >= rateLimit {
                return .failure(PortalError("too many portals: \(recent.count) opened in the last 10 minutes"))
            }
        }
        let task = task?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing, !existing.isEmpty {
            guard let t = target.tile(existing), isAgent(t, hooked: hooked) else {
                return .failure(PortalError("tile \(existing) isn't an agent on board \(target.name)"))
            }
            let pair: Set<String> = [src.id, t.id]
            return .success(.connect(source: src, sourceBoard: sb, target: target, tile: t,
                                     task: (task?.isEmpty ?? true) ? nil : task, existing: portals.first { $0.key == pair }))
        }
        guard let task, !task.isEmpty else { return .failure(PortalError("task required to start a new agent")) }
        return .success(.spawn(source: src, sourceBoard: sb, target: target, task: task))
    }

    // MARK: Pruning

    /// Drops portals whose tiles are gone, whose ends share a board, and
    /// duplicate pairs (keeps the oldest). Refreshes the board id cache.
    static func pruned(_ portals: [Portal], boards: [Board]) -> [Portal] {
        var where_: [String: String] = [:]
        for b in boards { for t in b.tiles { where_[t.id] = b.id } }
        var seen = Set<Set<String>>()
        var out: [Portal] = []
        for var p in portals.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard let ba = where_[p.a.tileID], let bb = where_[p.b.tileID], ba != bb, !seen.contains(p.key) else { continue }
            seen.insert(p.key)
            p.a.boardID = ba
            p.b.boardID = bb
            out.append(p)
        }
        return out
    }

    // MARK: Routing

    enum Route: Equatable {
        case link(Link, Board)
        case portal(Portal)
    }

    /// How a message from `from` reaches `to`: a link on the target's board
    /// wins, else a portal between them.
    static func route(from: String, to: String, boards: [Board], portals: [Portal]) -> Route? {
        if let b = boards.first(where: { $0.tile(to) != nil }),
           let l = b.links.first(where: { ($0.from == from && $0.to == to) || ($0.from == to && $0.to == from) }) {
            return .link(l, b)
        }
        let pair: Set<String> = [from, to]
        return portals.first { $0.key == pair }.map { .portal($0) }
    }

    /// The tiles on the other side of `tileID`'s portals, with their boards.
    static func peers(of tileID: String, boards: [Board], portals: [Portal]) -> [(portal: Portal, board: Board, tile: Tile)] {
        portals.compactMap { p in
            guard let o = p.other(tileID) else { return nil }
            for b in boards { if let t = b.tile(o.tileID) { return (p, b, t) } }
            return nil
        }
    }

    // MARK: Placement

    /// Top-left for a new tile at the middle of the board's saved view.
    static func spotStart(on b: Board, viewSize: CGSize, size: CGSize) -> CGPoint {
        let z = max(b.viewport.zoom, 0.05)
        let w = (viewSize.width > 0 ? viewSize.width : 1400) / z
        let h = (viewSize.height > 0 ? viewSize.height : 900) / z
        let c = CGPoint(x: b.viewport.origin.x + w / 2, y: b.viewport.origin.y + h / 2)
        return CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2)
    }

    // MARK: Prompts

    static func agentPrompt(source: Tile, sourceBoard: Board, target: Board, cwd: String, branch: String?, task: String) -> String {
        let srcPath = source.worktreePath ?? source.cwd ?? sourceBoard.root ?? "?"
        var s = "\(promptMarker) You were started through a Pitwall portal by \"\(source.displayName)\" (tile \(source.id)), "
        s += "an agent on board \"\(sourceBoard.name)\" working in \(abbreviate(srcPath))"
        if let br = source.branch { s += " on branch \(br)" }
        s += ". You are on board \"\(target.name)\" in \(abbreviate(cwd))"
        if let branch { s += ", a new git worktree on branch \(branch)" }
        s += ".\n\nTask: \(task)\n\n"
        s += "Coordinate through the portal: use the pitwall send_message tool with tile_id \(source.id) to ask questions or report back "
        s += "(it can message you the same way; list_links shows it with relation \"portal\"). When you're done, send it a short summary: "
        s += "what you changed, the branch, and anything it has to do on its side."
        return s
    }

    static func connectMessage(task: String, source: Tile, sourceBoard: Board) -> String {
        let path = source.worktreePath ?? source.cwd ?? sourceBoard.root ?? "?"
        return "I opened a Pitwall portal to you from board \"\(sourceBoard.name)\" (\(abbreviate(path))). "
            + "Reply to me with send_message.\n\n\(task)"
    }

    /// Prompt context listing an agent's portal peers (nil when none).
    static func context(for tileID: String, boards: [Board], portals: [Portal]) -> String? {
        let ps = peers(of: tileID, boards: boards, portals: portals)
        guard !ps.isEmpty else { return nil }
        var s = "Pitwall portals: you can message these agents on other boards with send_message:"
        for p in ps.prefix(5) {
            var line = "\n- \"\(p.tile.displayName)\" (tile \(p.tile.id)) on board \"\(p.board.name)\""
            if let c = p.tile.worktreePath ?? p.tile.cwd { line += " in \(abbreviate(c))" }
            s += line
        }
        if ps.count > 5 { s += "\n- …and \(ps.count - 5) more (list_links)" }
        return String(s.prefix(600))
    }
}
