import AppKit
import SwiftUI

// MARK: - Stage F: saved layouts, dev servers, search across terminals

extension CanvasController {

    // MARK: Layouts

    @discardableResult
    func saveLayout(name: String) -> SavedLayout {
        let b = targetBoard
        var l = SavedLayout(name: name,
                            tiles: Dictionary(uniqueKeysWithValues: b.tiles.map { ($0.id, $0.frame) }),
                            frames: Dictionary(uniqueKeysWithValues: b.frames.map { ($0.id, $0.frame) }),
                            collapsed: b.frames.filter(\.collapsed).map(\.id),
                            viewport: b.id == board.id ? canvas.viewport : b.viewport)
        store.update(b.id) { bb in
            var list = bb.layouts ?? []
            // Saving under an existing name replaces it.
            if let i = list.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                l.id = list[i].id
                list[i] = l
            } else {
                list.append(l)
            }
            bb.layouts = list
        }
        if !quietCreation { model?.toast(.init(kind: .info, title: "Layout saved", body: "“\(name)” · \(l.tiles.count) tiles")) }
        return l
    }

    /// Moves tiles back to where the layout had them. Tiles added since then
    /// stay where they are; tiles that are gone are skipped.
    func restoreLayout(_ id: String) {
        let tb = targetBoard
        guard let l = tb.layouts?.first(where: { $0.id == id }) else { return }
        let onScreen = tb.id == board.id
        if onScreen && fullScreenTileID != nil && !quietCreation { exitFullScreen() }
        store.update(tb.id) { b in
            // Off screen (or an agent asked): the saved view applies, without moving the camera.
            if !onScreen { b.viewport = l.viewport }
            for i in b.tiles.indices { if let f = l.tiles[b.tiles[i].id] { b.tiles[i].frame = f } }
            for i in b.frames.indices {
                if let f = l.frames[b.frames[i].id] { b.frames[i].frame = f }
                b.frames[i].collapsed = l.collapsed.contains(b.frames[i].id)
            }
        }
        layoutSubagents()
        guard onScreen else { return }
        reconcile()
        animateLayout()
        if !quietCreation { canvas.animate(to: l.viewport) }
    }

    func deleteLayout(_ id: String) {
        store.update { $0.layouts?.removeAll { $0.id == id } }
    }

    func promptSaveLayout() {
        let n = (board.layouts?.count ?? 0) + 1
        promptText(title: "Save layout", value: "Layout \(n)", button: "Save") { [weak self] name in
            let name = name.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { self?.saveLayout(name: name) }
        }
    }

    // MARK: Dev servers

    /// A long-running command (a dev server) that restarts when it exits.
    @discardableResult
    func newServer(command: String, cwd: String? = nil, at: CGPoint? = nil, from: String? = nil) -> String {
        let id = newWatch(command: command, cwd: cwd, at: at, from: from)
        store.updateTile(id) { $0.keepAlive = true; $0.statusMessage = "Starting" }
        reconcile()
        return id
    }

    func promptServer(at: CGPoint? = nil) {
        promptText(title: "Run a dev server", value: Self.suggestedServer(in: defaultCwd), button: "Run") { [weak self] cmd in
            guard let self, !cmd.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            self.newServer(command: cmd, at: at)
        }
    }

    static func suggestedServer(in dir: String) -> String {
        let fm = FileManager.default
        func has(_ f: String) -> Bool { fm.fileExists(atPath: (dir as NSString).appendingPathComponent(f)) }
        if has("package.json") {
            let pm = has("pnpm-lock.yaml") ? "pnpm" : (has("bun.lockb") || has("bun.lock") ? "bun" : (has("yarn.lock") ? "yarn" : "npm"))
            return pm == "npm" ? "npm run dev" : "\(pm) dev"
        }
        if has("manage.py") { return "python manage.py runserver" }
        if has("Cargo.toml") { return "cargo run" }
        if has("go.mod") { return "go run ." }
        if has("Gemfile") { return "bin/rails server" }
        return ""
    }

    /// The server process ended. Restart it, backing off if it crash-loops.
    func serverExited(_ id: String, code: Int) {
        guard let t = store.findTile(id)?.tile, t.keepAlive == true else { return }
        let now = Date()
        var recent = (serverRestarts[id] ?? []).filter { now.timeIntervalSince($0) < 60 }
        if recent.count >= 5 {
            setState(id, .error, message: "Crashing repeatedly (exit \(code)). Right-click → Run again.")
            Timelines.shared.add(id, .error, "Stopped restarting after 5 crashes in a minute")
            if Prefs.shared.toasts { model?.toast(.init(kind: .error, title: t.displayName + " keeps crashing", body: "Stopped restarting it.", tileID: id)) }
            serverRestarts[id] = nil
            return
        }
        recent.append(now)
        serverRestarts[id] = recent
        let delay = [1.0, 2, 4, 8, 15][min(recent.count - 1, 4)]
        setState(id, .error, message: "Exited (\(code)) · restarting in \(Int(delay))s")
        Timelines.shared.add(id, .error, "Exited with code \(code); restarting")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.store.findTile(id)?.tile.keepAlive == true else { return }
            self.rerunWatch(id)
            self.setState(id, .working, message: "Restarted")
        }
    }

    static let localURLPattern = try! NSRegularExpression(pattern: "https?://(?:localhost|127\\.0\\.0\\.1|0\\.0\\.0\\.0|\\[::1?\\])(?::\\d{2,5})?[^\\s'\"<>)]*")

    /// First time a server prints a local URL, open a browser tile on it.
    func detectServerURL(_ id: String, tail: String) {
        guard let (b, t) = store.findTile(id), !b.tiles.contains(where: { $0.serverTileID == id }) else { return }
        let ns = tail as NSString
        guard let m = Self.localURLPattern.matches(in: tail, range: NSRange(location: 0, length: ns.length)).last else { return }
        var url = ns.substring(with: m.range)
        for host in ["0.0.0.0", "[::]", "[::1]"] { url = url.replacingOccurrences(of: host, with: "localhost") }
        while let last = url.last, ".,;:".contains(last) { url.removeLast() }
        guard b.id == board.id else { return }
        let spot = freeSpot(size: Self.defaultSize(.browser), near: CGPoint(x: t.frame.maxX + 44, y: t.frame.minY))
        guard let bid = open(target: url, at: spot) else { return }
        store.updateTile(bid) { $0.serverTileID = id }
        addLink(from: id, to: bid, kind: .spawned)
        setState(id, .working, message: "Serving " + url)
    }

    /// Opens a browser on a running server tile's URL (re-detected).
    func stopServer(_ id: String) {
        store.updateTile(id) { $0.keepAlive = false }
        if let sid = store.findTile(id)?.tile.sessionID { Sessions.kill(sid) }
        setState(id, .idle, message: "Stopped")
    }

    // MARK: Search

    struct SearchHit: Identifiable, Equatable {
        var id: String { tileID + "#" + String(line) }
        let boardID: String
        let boardName: String
        let tileID: String
        let tileName: String
        let line: Int
        let text: String
        /// Lines before and after, for context.
        let before: String?
        let after: String?
    }

    /// Searches every terminal's history (screen + scrollback) on every board.
    /// Runs off the main thread; at most `limit` hits, newest lines first per tile.
    static func searchTerminals(_ query: String, tiles: [(Board, Tile)], limit: Int = 200) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        let regex: NSRegularExpression? = {
            // /pattern/ searches by regular expression.
            if q.count > 2, q.hasPrefix("/"), q.hasSuffix("/") { return try? NSRegularExpression(pattern: String(q.dropFirst().dropLast()), options: [.caseInsensitive]) }
            return nil
        }()
        var hits: [SearchHit] = []
        for (b, t) in tiles {
            guard let sid = t.sessionID, let raw = Sessions.scrollback(sid, bytes: 4_000_000) else { continue }
            let lines = Sessions.plain(raw).components(separatedBy: "\n")
            var perTile = 0
            for i in stride(from: lines.count - 1, through: 0, by: -1) {
                let l = lines[i]
                let match = regex.map { $0.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil }
                    ?? (l.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
                guard match else { continue }
                hits.append(SearchHit(boardID: b.id, boardName: b.name, tileID: t.id, tileName: t.displayName, line: i,
                                      text: String(l.prefix(400)), before: i > 0 ? String(lines[i - 1].prefix(200)) : nil,
                                      after: i + 1 < lines.count ? String(lines[i + 1].prefix(200)) : nil))
                perTile += 1
                if perTile >= 40 || hits.count >= limit { break }
            }
            if hits.count >= limit { break }
        }
        return hits
    }

    func goToHit(_ h: SearchHit) {
        if h.boardID != store.currentBoardID { switchBoard(h.boardID) }
        DispatchQueue.main.async {
            self.flyTo(tileID: h.tileID, fill: false)
            self.focus(tileID: h.tileID, makeFirstResponder: true)
            self.tileView(h.tileID)?.flashReceive(color: Theme.amber)
        }
    }
}

// MARK: - Search panel (⌘⇧F)

final class SearchModel: ObservableObject {
    @Published var query = "" { didSet { schedule() } }
    @Published var hits: [CanvasController.SearchHit] = []
    @Published var searching = false
    @Published var selection = 0
    weak var controller: CanvasController?
    private var work: DispatchWorkItem?
    private var generation = 0

    func schedule() {
        work?.cancel()
        let q = query
        generation += 1
        let gen = generation
        guard q.trimmingCharacters(in: .whitespaces).count >= 2 else { hits = []; searching = false; return }
        let tiles = Store.shared.boards.flatMap { b in b.tiles.filter(\.isTerminalBacked).map { (b, $0) } }
        searching = true
        let item = DispatchWorkItem { [weak self] in
            let found = CanvasController.searchTerminals(q, tiles: tiles)
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.hits = found
                self.selection = 0
                self.searching = false
            }
        }
        work = item
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15, execute: item)
    }
}

struct SearchPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var search: SearchModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search every terminal's history…", text: $search.query)
                    .textFieldStyle(.plain).font(.system(size: 16))
                    .focused($focused)
                    .onSubmit { open(search.selection) }
                    .onExitCommand { model.searchOpen = false }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                if search.searching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 16).frame(height: 52)

            if !search.hits.isEmpty || !search.query.isEmpty { Divider() }

            if search.hits.isEmpty {
                if search.query.trimmingCharacters(in: .whitespaces).count >= 2 && !search.searching {
                    Text("No matches in any terminal").font(.system(size: 12)).foregroundStyle(.secondary).padding(18)
                } else if search.query.isEmpty {
                    Text("Searches the output of every terminal and agent on every board. Use /regex/ for patterns.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(search.hits.enumerated()), id: \.element.id) { i, h in
                                row(h, selected: i == search.selection)
                                    .id(i)
                                    .onTapGesture { open(i) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 420)
                    .onChange(of: search.selection) { _, s in proxy.scrollTo(s) }
                }
                Divider()
                Text("\(search.hits.count)\(search.hits.count >= 200 ? "+" : "") matches · ↩ to jump · esc to close")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 7)
            }
        }
        .frame(width: 640)
        .pitwallGlass(cornerRadius: 18)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func move(_ d: Int) {
        guard !search.hits.isEmpty else { return }
        search.selection = max(0, min(search.hits.count - 1, search.selection + d))
    }

    private func open(_ i: Int) {
        guard search.hits.indices.contains(i) else { return }
        let h = search.hits[i]
        model.searchOpen = false
        model.controller?.goToHit(h)
    }

    private func row(_ h: CanvasController.SearchHit, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(h.tileName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(h.boardName).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text("line \(h.line + 1)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            }
            if let b = h.before, !b.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(b).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
            }
            highlighted(h.text).font(.system(size: 12, design: .monospaced)).lineLimit(2)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Color(ns: Theme.amber).opacity(0.18) : .clear))
        .contentShape(Rectangle())
    }

    private func highlighted(_ s: String) -> Text {
        let q = search.query.trimmingCharacters(in: .whitespaces)
        guard !q.hasPrefix("/"), let r = s.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { return Text(s) }
        return Text(s[..<r.lowerBound]) + Text(s[r]).bold().foregroundColor(Color(ns: Theme.amberText)) + Text(s[r.upperBound...])
    }
}
