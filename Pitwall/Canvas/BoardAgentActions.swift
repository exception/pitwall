import Foundation

/// The board agent's inbox: asks come in (Slack, `pitwall ask`), and get
/// picked up as worker agents or ignored.
extension CanvasController {
    /// Puts an ask in a board's inbox, or explains why it was dropped.
    /// Nothing starts until you pick it up.
    func receiveAsk(_ ask: AgentAsk, boardID: String, quiet: Bool = false) -> (ok: Bool, message: String) {
        guard let b = store.board(boardID) else { return (false, "No such board") }
        let cfg = b.agentConfig
        if let why = BoardAgent.rejection(ask, config: cfg) { return (false, "Dropped: \(why).") }
        store.update(boardID) { $0.asks = BoardAgent.trimmed(($0.asks ?? []) + [ask]) }
        if !quiet { model?.toast(.init(kind: .info, title: "\(cfg.name): \(ask.from) asked", body: String(ask.text.prefix(140)))) }
        return (true, "\(ask.id): in \(cfg.name)'s inbox on \(b.name).")
    }

    /// Starts a worker agent on an ask, in its own worktree when the board is
    /// a git repo. Returns the worker's tile id.
    @discardableResult
    func pickUp(askID: String, boardID: String) -> String? {
        guard let b = store.board(boardID), let ask = b.asks?.first(where: { $0.id == askID }), ask.state == .new else { return nil }
        if b.id != store.currentBoardID { switchBoard(b.id) }
        let id = newAgent(task: BoardAgent.task(for: ask, config: b.agentConfig), repo: b.root, worktree: true, agent: .claude)
        store.update(boardID) { board in
            guard let i = board.asks?.firstIndex(where: { $0.id == askID }) else { return }
            board.asks?[i].state = .pickedUp
            board.asks?[i].workerTileID = id
        }
        return id
    }

    func ignoreAsk(askID: String, boardID: String) {
        store.update(boardID) { board in
            guard let i = board.asks?.firstIndex(where: { $0.id == askID }) else { return }
            board.asks?[i].state = .ignored
            board.asks = BoardAgent.trimmed(board.asks ?? [])
        }
    }

    func clearHandledAsks(boardID: String) {
        store.update(boardID) { $0.asks = $0.asks?.filter { $0.state == .new } }
    }
}
