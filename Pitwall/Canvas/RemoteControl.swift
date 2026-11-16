import AppKit
import SwiftUI

// Claude Code Remote Control on the canvas.
//
// A host tile runs `claude remote-control` for a folder. Every session you
// start from your phone (or claude.ai) is a headless Claude Code process the
// host spawns with Pitwall's `--settings`, so its hooks reach Pitwall. They
// arrive tagged with the host's tile (inherited env) plus
// CLAUDE_CODE_ENVIRONMENT_KIND=bridge, and are routed to a Remote tile per
// session that shows the conversation live from its transcript.

// MARK: - Transcript

struct RemoteTranscript: Equatable {
    enum ToolStatus: Equatable { case running, ok, failed }

    enum Item: Equatable, Identifiable {
        case prompt(id: String, text: String)
        case reply(id: String, text: String)
        case tool(id: String, name: String, summary: String, status: ToolStatus)
        case note(id: String, text: String)

        var id: String {
            switch self {
            case .prompt(let id, _), .reply(let id, _), .note(let id, _): return id
            case .tool(let id, _, _, _): return id
            }
        }
    }

    var items: [Item] = []
    var title: String?
    /// Remote Control's id for the session (`cse_…`).
    var bridgeID: String?
    var cost: Double?
    var model: String?

    /// The session on claude.ai: Remote Control ids map `cse_X` → `session_X`.
    var url: URL? {
        guard let b = bridgeID, b.hasPrefix("cse_") else { return nil }
        return URL(string: "https://claude.ai/code/session_" + b.dropFirst(4))
    }

    var prompts: Int { items.filter { if case .prompt = $0 { return true } else { return false } }.count }
}

/// Reads a Claude Code transcript (JSONL) incrementally.
final class TranscriptReader {
    let path: String
    private var offset: UInt64 = 0
    private var partial = Data()
    private var toolIndex: [String: Int] = [:]
    private(set) var transcript = RemoteTranscript()
    static let maxItems = 600

    init(path: String) { self.path = path }

    /// Reads what was appended since last time. Returns true if anything changed.
    func read() -> Bool {
        guard let h = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < offset { offset = 0; partial = Data(); toolIndex = [:]; transcript = RemoteTranscript() }
        guard size > offset else { return false }
        try? h.seek(toOffset: offset)
        guard let data = try? h.readToEnd() else { return false }
        offset += UInt64(data.count)
        partial.append(data)
        let before = transcript
        while let nl = partial.firstIndex(of: 0x0A) {
            let line = partial[partial.startIndex..<nl]
            partial.removeSubrange(partial.startIndex...nl)
            if !line.isEmpty { ingest(Data(line)) }
        }
        if transcript.items.count > Self.maxItems {
            let drop = transcript.items.count - Self.maxItems
            transcript.items.removeFirst(drop)
            toolIndex = toolIndex.compactMapValues { $0 >= drop ? $0 - drop : nil }
        }
        return transcript != before
    }

    func ingest(_ line: Data) {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = o["type"] as? String else { return }
        switch type {
        case "ai-title":
            if let t = o["aiTitle"] as? String, !t.isEmpty { transcript.title = t }
        case "bridge-session":
            if let b = o["bridgeSessionId"] as? String { transcript.bridgeID = b }
        case "cost-state":
            if let c = o["totalCostUSD"] as? Double { transcript.cost = c }
        case "user":
            guard o["isMeta"] as? Bool != true, o["isSidechain"] as? Bool != true,
                  let m = o["message"] as? [String: Any] else { return }
            let uuid = o["uuid"] as? String ?? UUID().uuidString
            if let s = m["content"] as? String {
                addPrompt(s, id: uuid)
            } else if let blocks = m["content"] as? [[String: Any]] {
                for (i, b) in blocks.enumerated() {
                    switch b["type"] as? String {
                    case "tool_result":
                        guard let tid = b["tool_use_id"] as? String, let idx = toolIndex[tid],
                              case .tool(let id, let name, let summary, _) = transcript.items[idx] else { continue }
                        let failed = (b["is_error"] as? Bool) == true
                        transcript.items[idx] = .tool(id: id, name: name, summary: summary, status: failed ? .failed : .ok)
                    case "text":
                        addPrompt(b["text"] as? String ?? "", id: "\(uuid)-\(i)")
                    default: break
                    }
                }
            }
        case "assistant":
            guard o["isSidechain"] as? Bool != true, let m = o["message"] as? [String: Any] else { return }
            if let model = m["model"] as? String, !model.hasPrefix("<") { transcript.model = model }
            let uuid = o["uuid"] as? String ?? UUID().uuidString
            for (i, b) in (m["content"] as? [[String: Any]] ?? []).enumerated() {
                switch b["type"] as? String {
                case "text":
                    let t = (b["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { transcript.items.append(.reply(id: "\(uuid)-\(i)", text: t)) }
                case "tool_use":
                    let tid = b["id"] as? String ?? "\(uuid)-\(i)"
                    let name = b["name"] as? String ?? "Tool"
                    let input = b["input"] as? [String: Any] ?? [:]
                    toolIndex[tid] = transcript.items.count
                    transcript.items.append(.tool(id: tid, name: name, summary: Self.summary(tool: name, input: input), status: .running))
                default: break
                }
            }
        default: break
        }
    }

    private func addPrompt(_ raw: String, id: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        if s.hasPrefix("[Request interrupted") { transcript.items.append(.note(id: id, text: "Interrupted")); return }
        // Slash-command plumbing, caveats and reminders aren't prompts.
        if s.hasPrefix("<") { return }
        transcript.items.append(.prompt(id: id, text: s))
    }

    static func summary(tool: String, input: [String: Any]) -> String {
        func str(_ k: String) -> String? { (input[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        switch tool {
        case "Bash": return str("command").map { $0.split(separator: "\n").first.map(String.init) ?? $0 } ?? ""
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit":
            return (str("file_path") ?? str("notebook_path")).map { ($0 as NSString).lastPathComponent } ?? ""
        case "Grep", "Glob": return str("pattern") ?? ""
        case "WebFetch": return str("url") ?? ""
        case "WebSearch": return str("query") ?? ""
        case "Task", "Agent": return str("description") ?? ""
        case "TodoWrite": return "Updated the plan"
        default:
            if tool.hasPrefix("mcp__") { return input.values.compactMap { $0 as? String }.first.map { String($0.prefix(120)) } ?? "" }
            return input.values.compactMap { $0 as? String }.first.map { String($0.prefix(120)) } ?? ""
        }
    }
}

/// Live transcripts of Remote tiles.
final class RemoteTranscripts: ObservableObject {
    static let shared = RemoteTranscripts()
    @Published private(set) var all: [String: RemoteTranscript] = [:]
    private var readers: [String: TranscriptReader] = [:]
    private var reading = Set<String>()
    private let io = DispatchQueue(label: "pitwall.transcripts")

    /// Main thread. Picks up whatever the session wrote since last time.
    func refresh(_ tileID: String, path: String?, then: ((RemoteTranscript) -> Void)? = nil) {
        guard let path, !path.isEmpty, !reading.contains(tileID) else { return }
        if readers[tileID]?.path != path { readers[tileID] = TranscriptReader(path: path) }
        guard let r = readers[tileID] else { return }
        reading.insert(tileID)
        io.async {
            let changed = r.read()
            let t = r.transcript
            DispatchQueue.main.async {
                self.reading.remove(tileID)
                if changed || self.all[tileID] == nil { self.all[tileID] = t; then?(t) }
            }
        }
    }

    func forget(_ tileID: String) { readers[tileID] = nil; all[tileID] = nil }
}

// MARK: - Controller

extension CanvasController {
    static func remoteControlCommand(name: String, worktree: Bool) -> String {
        "claude remote-control --name \(shellQuote(name)) --spawn \(worktree ? "worktree" : "same-dir")"
            + " --settings \(shellQuote(ClaudeIntegration.settingsFile.path))"
    }

    /// Opens a host terminal running `claude remote-control` for a folder.
    @discardableResult
    func startRemoteControl(cwd: String? = nil, worktree: Bool = false, at: CGPoint? = nil) -> String {
        let dir = cwd ?? board.root ?? defaultCwd
        // Remote Control refuses worktree mode outside a git repository.
        let worktree = worktree && Git.toplevel(dir) != nil
        let name = board.name + " · " + (dir as NSString).lastPathComponent
        var t = Tile(kind: .terminal, frame: CGRect(origin: .zero, size: CGSize(width: 440, height: 616)))
        t.cwd = dir
        t.command = Self.remoteControlCommand(name: name, worktree: worktree)
        t.name = "Remote Control"
        t.sessionID = t.id
        t.rcSpawn = worktree ? "worktree" : "same-dir"
        return addTile(t, at: at)
    }

    func promptRemoteControl(at: CGPoint? = nil) {
        let a = NSAlert()
        a.messageText = "Start Remote Control?"
        a.informativeText = "Runs claude remote-control in \(Self.abbreviated(board.root ?? defaultCwd)). Sessions you start from the Claude app or claude.ai open here as tiles."
        let repo = Git.toplevel(board.root ?? defaultCwd) != nil
        a.addButton(withTitle: "Same Folder")
        if repo { a.addButton(withTitle: "New Worktree Each") }
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn: startRemoteControl(at: at)
        case .alertSecondButtonReturn where repo: startRemoteControl(worktree: true, at: at)
        default: break
        }
    }

    private static func abbreviated(_ p: String) -> String { TileView.abbreviate(p) }

    /// Hook traffic from a session a Remote Control host spawned arrives with
    /// the host's tile id. Returns the session's own tile (made on its first
    /// prompt), the original id for ordinary hooks, or nil to drop it.
    func resolveHookTile(_ tileID: String, args: [String: String]) -> String? {
        guard args["bridge"] == "1", let sid = args["session_id"], !sid.isEmpty else { return tileID }
        if let (_, t) = remoteTile(session: sid) {
            if let p = args["transcript_path"], t.target != p { store.updateTile(t.id) { $0.target = p } }
            refreshTranscript(t.id)
            return t.id
        }
        let event = args["event"] ?? ""
        // Its tile was closed: keep it listed on the host until it ends.
        if let host = store.findTile(tileID)?.tile, let c = host.rcClosed?.first(where: { $0.session == sid }) {
            let path = args["transcript_path"].flatMap { $0.isEmpty ? nil : $0 }
            if event == "SessionEnd" {
                updateClosedRemote(host: tileID) { $0.removeAll { $0.session == sid } }
            } else if let path, path != c.transcript {
                updateClosedRemote(host: tileID) { l in
                    if let i = l.firstIndex(where: { $0.session == sid }) { l[i].transcript = path }
                }
            }
            return nil
        }
        // The host starts a session ahead of time; it stays hidden until it's used.
        guard ["UserPromptSubmit", "PreToolUse", "PermissionRequest", "Notification"].contains(event),
              !dismissedRemote.contains(sid), let (b, host) = store.findTile(tileID) else { return nil }
        return newRemoteTile(on: b, host: host, session: sid, cwd: args["cwd"], transcript: args["transcript_path"],
                             prompt: event == "UserPromptSubmit" ? args["prompt"].flatMap { $0.isEmpty ? nil : $0 } : nil)
    }

    private func updateClosedRemote(host: String, _ change: (inout [ClosedRemote]) -> Void) {
        store.updateTile(host) { t in
            var l = t.rcClosed ?? []
            change(&l)
            t.rcClosed = l.isEmpty ? nil : l
        }
    }

    /// Opens the tile of a session closed earlier that is still running.
    func reopenRemote(host hostID: String, session: String) {
        guard let (b, host) = store.findTile(hostID), let c = host.rcClosed?.first(where: { $0.session == session }) else { return }
        updateClosedRemote(host: hostID) { $0.removeAll { $0.session == session } }
        if let (_, t) = remoteTile(session: session) { focus(tileID: t.id, makeFirstResponder: false); flyTo(tileID: t.id, fill: false); return }
        // The host is gone or stopped, and its sessions with it.
        if let p = RemoteHosts.shared.status[hostID]?.phase, p == .stopped || p == .failed { return }
        dismissedRemote.remove(session)
        let id = newRemoteTile(on: b, host: host, session: session, cwd: c.cwd, transcript: c.transcript, prompt: nil, name: c.name, announce: false)
        if let br = c.branch { store.updateTile(id) { $0.branch = br } }
        focus(tileID: id, makeFirstResponder: false)
        flyTo(tileID: id, fill: false)
    }

    func remoteTile(session: String) -> (Board, Tile)? {
        for b in store.boards { if let t = b.tiles.first(where: { $0.rcSession == session }) { return (b, t) } }
        return nil
    }

    private func newRemoteTile(on b: Board, host: Tile, session: String, cwd: String?, transcript: String?, prompt: String?,
                               name: String? = nil, announce: Bool = true) -> String {
        var t = Tile(kind: .remote, frame: .zero)
        t.cwd = cwd ?? host.cwd
        t.target = transcript
        t.rcSession = session
        // Named from the first prompt for now; Claude's own title replaces it.
        t.autoName = name ?? prompt.map { ClaudeIntegration.name(fromTask: $0) } ?? "Remote session"
        if host.rcSpawn == "worktree", let c = t.cwd { t.branch = Git.branch(c) }
        let size = Self.defaultSize(.remote)
        // Fan out to the right of the host, one column per row of sessions.
        let n = b.links.filter { $0.from == host.id && $0.kind == .spawned }.count
        let start = CGPoint(x: host.frame.maxX + 44, y: host.frame.minY + CGFloat(n % 2) * (size.height + 44))
        let spot = Self.freeSpot(in: b, size: size, near: start)
        if b.id == board.id {
            addTile(t, at: spot, focus: false, fly: false)
            addLink(from: host.id, to: t.id, kind: .spawned)
        } else {
            t.frame = CGRect(origin: spot, size: size)
            t.z = b.maxZ + 1
            store.update(b.id) { bb in
                bb.tiles.append(t)
                bb.links.append(Link(from: host.id, to: t.id, kind: .spawned))
            }
        }
        if announce { model?.toast(.init(kind: .info, title: "New Remote Control session", body: "Started from your phone in \((t.cwd.map { ($0 as NSString).lastPathComponent }) ?? b.name).", tileID: t.id)) }
        refreshTranscript(t.id)
        return t.id
    }

    static func freeSpot(in b: Board, size: CGSize, near p: CGPoint) -> CGPoint {
        let others = b.tiles.map { $0.frame.insetBy(dx: -20, dy: -20) }
        var r = CGRect(origin: p, size: size)
        var tries = 0
        while others.contains(where: { $0.intersects(r) }) && tries < 80 {
            r.origin.x += 44
            if tries % 16 == 15 { r.origin.x = p.x; r.origin.y += 88 }
            tries += 1
        }
        return CanvasView.snap(r.origin)
    }

    /// Re-reads a Remote tile's transcript and mirrors its title and cost onto the tile.
    func refreshTranscript(_ id: String) {
        guard let t = store.findTile(id)?.tile, t.kind == .remote else { return }
        RemoteTranscripts.shared.refresh(id, path: t.target) { [weak self] tr in
            guard let self, let cur = self.store.findTile(id)?.tile else { return }
            let name = tr.title
            if (name != nil && cur.autoName != name) || (tr.cost != nil && cur.costUSD != tr.cost) || (tr.model != nil && cur.model != tr.model) {
                self.store.updateTile(id) { x in
                    if let name { x.autoName = name }
                    if let c = tr.cost { x.costUSD = c }
                    if let m = tr.model { x.model = m }
                }
                self.reconcileIfVisible(id)
            }
        }
    }
}

// MARK: - Remote tile

final class RemoteTileContent: NSView, TileContent {
    private let hostView: NSHostingView<RemoteSessionView>
    private let host = FlippedView()
    private var zoom: CGFloat = 1
    private var timer: Timer?
    private let tileID: String
    private weak var controller: CanvasController?
    override var isFlipped: Bool { true }

    init(tileID: String, controller: CanvasController) {
        self.tileID = tileID
        self.controller = controller
        hostView = NSHostingView(rootView: RemoteSessionView(tileID: tileID, controller: controller))
        super.init(frame: .zero)
        addSubview(host)
        host.addSubview(hostView)
        controller.refreshTranscript(tileID)
    }
    required init?(coder: NSCoder) { fatalError() }

    var focusTarget: NSView? { nil }
    func apply(zoom: CGFloat, live: Bool) { self.zoom = zoom; needsLayout = true }
    func update(tile: Tile) {}

    func setVisible(_ visible: Bool) {
        timer?.invalidate(); timer = nil
        guard visible else { return }
        // Hooks refresh it on every event; this catches streamed text in between.
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.controller?.refreshTranscript(self.tileID)
        }
    }

    func willClose() { timer?.invalidate(); timer = nil; RemoteTranscripts.shared.forget(tileID) }

    override func layout() {
        super.layout()
        host.frame = bounds
        let w = bounds.width / max(zoom, 0.01), h = bounds.height / max(zoom, 0.01)
        host.setBoundsSize(CGSize(width: w, height: h))
        hostView.frame = CGRect(x: 0, y: 0, width: w, height: h)
    }
}

struct RemoteSessionView: View {
    let tileID: String
    weak var controller: CanvasController?
    @ObservedObject var transcripts = RemoteTranscripts.shared
    @ObservedObject var store = Store.shared
    @ObservedObject var approvals = ApprovalCenter.shared

    private var tile: Tile? { store.findTile(tileID)?.tile }
    private var transcript: RemoteTranscript { transcripts.all[tileID] ?? RemoteTranscript() }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            conversation
            if let p = approvals.pending(for: tileID) { approval(p) }
            Divider().opacity(0.6)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(ns: Theme.terminalBG))
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "iphone.radiowaves.left.and.right").font(.system(size: 10, weight: .semibold))
                Text("Remote Control").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Color(ns: Theme.blue))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color(ns: Theme.blue).opacity(0.12)))
            if let m = transcript.model ?? tile?.model { Text(Self.modelName(m)).font(.system(size: 11)).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            if let br = tile?.branch {
                Label(br, systemImage: "arrow.triangle.branch").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone").font(.system(size: 11)).foregroundStyle(.secondary)
            Text(footerLine).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            if let u = transcript.url {
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u.absoluteString, forType: .string) } label: {
                    Image(systemName: "link")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Copy the session link")
                Button("Open in Claude") { NSWorkspace.shared.open(u) }.controlSize(.small)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var footerLine: String {
        let n = transcript.prompts
        let turns = n == 0 ? "" : " · \(n) prompt\(n == 1 ? "" : "s")"
        return "Driven from your phone or claude.ai" + turns
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if transcript.items.isEmpty { empty }
                    ForEach(transcript.items) { item in row(item).id(item.id) }
                    if tile?.state == .working { working.id("working") }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { scrollToEnd(proxy, animated: false) }
            .onChange(of: transcript.items.count) { _, _ in scrollToEnd(proxy, animated: true) }
            .onChange(of: tile?.state) { _, _ in scrollToEnd(proxy, animated: true) }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool) {
        let target = tile?.state == .working ? "working" : transcript.items.last?.id
        guard let target else { return }
        if animated { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .bottom) } }
        else { proxy.scrollTo(target, anchor: .bottom) }
    }

    private var empty: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Waiting for the session…").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private var working: some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.mini)
            Text(tile?.statusMessage ?? "Working…").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func row(_ item: RemoteTranscript.Item) -> some View {
        switch item {
        case .prompt(_, let text):
            HStack {
                Spacer(minLength: 48)
                Text(text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(ns: Theme.blue).opacity(0.13)))
            }
        case .reply(_, let text):
            MarkdownBlocks(text: text)
        case .tool(_, let name, let summary, let status):
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: Self.icon(name)).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
                Text(Self.verb(name)).font(.system(size: 12, weight: .medium))
                if !summary.isEmpty {
                    Text(summary).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                switch status {
                case .running: ProgressView().controlSize(.mini)
                case .failed: Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Color(ns: Theme.red))
                case .ok: EmptyView()
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.045)))
        case .note(_, let text):
            Text(text).font(.system(size: 11).italic()).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
        }
    }

    // MARK: Approval

    private func approval(_ p: ApprovalCenter.Pending) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").font(.system(size: 11)).foregroundStyle(Color(ns: Theme.amber))
                Text("Wants to use \(p.tool)").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Text(p.createdAt.elapsedShort).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(p.summary).font(.system(size: 11.5, design: .monospaced)).lineLimit(3).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.05)))
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Deny") { ApprovalCenter.shared.decide(p.id, .deny) }.controlSize(.small)
                if p.canAlwaysAllow { Button("Always Allow") { ApprovalCenter.shared.decide(p.id, .allowAlways) }.controlSize(.small) }
                Button("Allow") { ApprovalCenter.shared.decide(p.id, .allow) }.controlSize(.small).buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(ns: Theme.amber).opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(ns: Theme.amber).opacity(0.45)))
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    // MARK: Formatting

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    /// "claude-opus-5-5" → "Opus 5.5".
    static func modelName(_ m: String) -> String {
        let parts = m.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
        guard let fam = parts.first else { return m }
        let ver = parts.dropFirst().prefix(2).filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        return fam.prefix(1).uppercased() + fam.dropFirst() + (ver.isEmpty ? "" : " " + ver)
    }

    static func verb(_ tool: String) -> String {
        switch tool {
        case "Bash": return "Ran"
        case "Read": return "Read"
        case "Write": return "Wrote"
        case "Edit", "MultiEdit", "NotebookEdit": return "Edited"
        case "Grep", "Glob": return "Searched"
        case "WebFetch": return "Fetched"
        case "WebSearch": return "Searched the web"
        case "Task", "Agent": return "Sub-agent"
        case "TodoWrite": return "Plan"
        default:
            if tool.hasPrefix("mcp__") { return tool.split(separator: "__").dropFirst().joined(separator: " › ") }
            return tool
        }
    }

    static func icon(_ tool: String) -> String {
        switch tool {
        case "Bash": return "terminal"
        case "Read": return "doc.text"
        case "Write": return "doc.badge.plus"
        case "Edit", "MultiEdit", "NotebookEdit": return "pencil"
        case "Grep", "Glob": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        case "Task", "Agent": return "sparkles"
        case "TodoWrite": return "checklist"
        default: return tool.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }
}

/// Just enough Markdown for agent replies: paragraphs, bullets, numbered
/// items, headings and fenced code, with inline styling inside each.
struct MarkdownBlocks: View {
    let text: String

    enum Block: Hashable {
        case para(String), bullet(String, Int), numbered(String, String), heading(String), code(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, b in block(b) }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func block(_ b: Block) -> some View {
        switch b {
        case .para(let s):
            Text(RemoteSessionView.markdown(s)).font(.system(size: 13)).lineSpacing(2)
        case .heading(let s):
            Text(RemoteSessionView.markdown(s)).font(.system(size: 13, weight: .semibold)).padding(.top, 2)
        case .bullet(let s, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("•").font(.system(size: 13)).foregroundStyle(.secondary)
                Text(RemoteSessionView.markdown(s)).font(.system(size: 13)).lineSpacing(2)
            }
            .padding(.leading, CGFloat(depth) * 14 + 2)
        case .numbered(let n, let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(n).font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                Text(RemoteSessionView.markdown(s)).font(.system(size: 13)).lineSpacing(2)
            }
            .padding(.leading, 2)
        case .code(let s):
            Text(s).font(.system(size: 11.5, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.05)))
        }
    }

    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        var code: [String]?
        func flush() { if !para.isEmpty { out.append(.para(para.joined(separator: "\n"))); para = [] } }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { flush(); continue }
            let indent = raw.prefix { $0 == " " }.count / 2
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush(); out.append(.bullet(String(line.dropFirst(2)), indent)); continue
            }
            if let r = line.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                flush(); out.append(.numbered(String(line[r]).trimmingCharacters(in: .whitespaces), String(line[r.upperBound...]))); continue
            }
            if line.hasPrefix("#") {
                flush(); out.append(.heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))); continue
            }
            para.append(line)
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flush()
        return out
    }
}

// MARK: - Host tile

/// What the `claude remote-control` screen says, parsed from its output.
struct RemoteHostStatus: Equatable {
    enum Phase: Equatable { case starting, needsTrust, needsSpawnMode, connected, reconnecting, stopped, failed }
    var phase: Phase = .starting
    var capacity: (used: Int, total: Int)?
    var environmentURL: URL?
    var worktreeSpawn: Bool?
    var message: String?
    /// Worktree mode needs a git repository.
    var isGitRepo = false

    static func == (a: RemoteHostStatus, b: RemoteHostStatus) -> Bool {
        a.phase == b.phase && a.isGitRepo == b.isGitRepo && a.capacity?.used == b.capacity?.used && a.capacity?.total == b.capacity?.total
            && a.environmentURL == b.environmentURL && a.worktreeSpawn == b.worktreeSpawn && a.message == b.message
    }

    static func parse(_ screen: String, shellInForeground: Bool) -> RemoteHostStatus {
        var s = RemoteHostStatus()
        // Only the latest run counts (after a restart the old output is still above).
        let runs = screen.components(separatedBy: "Remote Control starts")
        let text = runs.count > 1 ? runs.last! : screen
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let m = text.range(of: #"https://claude\.ai/code\?environment=[A-Za-z0-9_-]+"#, options: .regularExpression) {
            s.environmentURL = URL(string: String(text[m]))
        }
        if let m = text.range(of: #"Capacity: \d+/\d+"#, options: [.regularExpression, .backwards]) {
            let nums = text[m].dropFirst("Capacity: ".count).split(separator: "/").compactMap { Int($0) }
            if nums.count == 2 { s.capacity = (nums[0], nums[1]) }
        }
        if let l = lines.last(where: { $0.contains("New sessions will be created in") }) {
            s.worktreeSpawn = !l.contains("current directory")
        }
        let tail = lines.suffix(4).joined(separator: "\n")
        // "Ready" with no sessions, "Connected" with some.
        let lastConnected = lines.lastIndex { l in ["Connected ·", "Ready ·"].contains { l.contains($0) } || l.hasSuffix("Connected") }
        let lastTrouble = lines.lastIndex { l in
            ["Reconnecting", "Disconnected", "Connecting", "connection lost"].contains { l.localizedCaseInsensitiveContains($0) }
        }
        // "[12:00:00] Session failed: …" is one session, not the host.
        let lastError = lines.lastIndex { l in
            guard !l.hasPrefix("[") else { return false }
            return l.localizedCaseInsensitiveContains("error") || l.contains("already being served") || l.contains("not logged in")
                || l.localizedCaseInsensitiveContains("failed")
        }
        if shellInForeground {
            s.phase = lastError.map { _ in .failed } ?? .stopped
            s.message = lastError.map { lines[$0] }
        } else if tail.contains("[y/N]") {
            s.phase = .needsTrust
        } else if tail.contains("Choose [1/2]") {
            s.phase = .needsSpawnMode
        } else if let e = lastError, e > (lastConnected ?? -1) {
            s.phase = .failed
            s.message = lines[e]
        } else if let t = lastTrouble, t > (lastConnected ?? -1) {
            s.phase = .reconnecting
        } else if lastConnected != nil {
            s.phase = .connected
        }
        return s
    }
}

final class RemoteHosts: ObservableObject {
    static let shared = RemoteHosts()
    @Published var status: [String: RemoteHostStatus] = [:]
    @Published var showTerminal = Set<String>()
    private var reading = Set<String>()

    /// Main thread. Re-reads the host's screen off the main thread.
    private var repo: [String: Bool] = [:]

    func refresh(_ tileID: String, session: String?, cwd: String?) {
        guard let session, !reading.contains(tileID) else { return }
        reading.insert(tileID)
        let knownRepo = cwd.flatMap { repo[$0] }
        DispatchQueue.global(qos: .utility).async {
            let isRepo = knownRepo ?? (cwd.map { Git.toplevel($0) != nil } ?? false)
            let screen = Sessions.plain(Sessions.scrollback(session, bytes: 6000) ?? "")
            let fg = Sessions.list().first { $0.id == session }
            let shells: Set<String> = ["zsh", "bash", "fish", "sh", "nu", "login", "-zsh", "-bash"]
            let stopped = fg.map { !$0.alive || shells.contains($0.foregroundName ?? "") } ?? true
            var st = RemoteHostStatus.parse(screen, shellInForeground: stopped)
            st.isGitRepo = isRepo
            DispatchQueue.main.async {
                if let cwd { self.repo[cwd] = isRepo }
                self.reading.remove(tileID)
                if self.status[tileID] != st { self.status[tileID] = st }
            }
        }
    }
}

extension CanvasController {
    func stopRemoteControl(_ id: String) { surface(for: id)?.pressControlC() }

    func restartRemoteControl(_ id: String) {
        guard let t = store.findTile(id)?.tile else { return }
        // It can only fail the same way again: worktree mode outside a repo.
        if t.rcSpawn == "worktree", let c = t.cwd, Git.toplevel(c) == nil { setRemoteSpawn(id, worktree: false, live: false) }
        guard let cmd = store.findTile(id)?.tile.command else { return }
        store.updateTile(id) { $0.rcExternal = cmd.contains(ClaudeIntegration.settingsFile.path) ? nil : true }
        if let s = surface(for: id) { s.submit(cmd) } else if let sid = t.sessionID { Sessions.submit(sid, text: cmd) }
    }

    /// Same folder ⇄ own worktree. A running host flips with its `w` key;
    /// either way the choice is kept for the next start.
    func setRemoteSpawn(_ id: String, worktree: Bool, live: Bool) {
        guard let t = store.findTile(id)?.tile, t.rcSpawn != nil else { return }
        if live { surface(for: id)?.sendText("w") }
        let mode = worktree ? "worktree" : "same-dir"
        store.updateTile(id) { x in
            x.rcSpawn = mode
            guard var c = x.command else { return }
            if let r = c.range(of: #"--spawn[ =](same-dir|worktree|session)"#, options: .regularExpression) {
                c.replaceSubrange(r, with: "--spawn " + mode)
            } else if !live {
                c += " --spawn " + mode
            }
            x.command = c
        }
    }

    func chooseRemoteSpawn(_ id: String, worktree: Bool) { surface(for: id)?.submit(worktree ? "2" : "1") }

    func isRestartingRemote(_ id: String) -> Bool { rcRestart[id] != nil }

    /// Stops a host started outside Pitwall and starts it again with Pitwall's settings.
    func restartRemoteUnderPitwall(_ id: String) {
        stopRemoteControl(id)
        rcRestart[id] = RemoteRestart(stage: .stopping, at: Date())
    }

    func trustRemoteFolder(_ id: String) { surface(for: id)?.submit("y") }

    /// Sessions this host started, newest first.
    func remoteSessions(of hostID: String) -> [Tile] {
        guard let (b, _) = store.findTile(hostID) else { return [] }
        let ids = b.links.filter { $0.from == hostID && $0.kind == .spawned }.map(\.to)
        return ids.compactMap { b.tile($0) }.filter { $0.kind == .remote }.reversed()
    }
}

/// The host's native face: the terminal stays underneath (it runs the
/// command and answers prompts) and can be shown when something goes wrong.
final class RemoteHostTileContent: NSView, TileContent {
    let terminal: TerminalTileContent
    private let hostView: NSHostingView<RemoteHostView>
    private let host = FlippedView()
    private var zoom: CGFloat = 1
    private var timer: Timer?
    private let tileID: String
    private var observer: Any?
    private let back = NSButton(title: "Hide Terminal", target: nil, action: nil)
    override var isFlipped: Bool { true }

    init(tileID: String, terminal: TerminalTileContent, controller: CanvasController) {
        self.tileID = tileID
        self.terminal = terminal
        hostView = NSHostingView(rootView: RemoteHostView(tileID: tileID, controller: controller))
        super.init(frame: .zero)
        addSubview(terminal)
        addSubview(host)
        host.addSubview(hostView)
        back.bezelStyle = .rounded
        back.controlSize = .small
        back.target = self
        back.action = #selector(hideTerminal)
        addSubview(back)
        observer = RemoteHosts.shared.$showTerminal.sink { [weak self] set in
            guard let self else { return }
            let show = set.contains(self.tileID)
            self.terminal.isHidden = !show
            self.back.isHidden = !show
            self.host.isHidden = show
        }
        terminal.isHidden = true
        back.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    var focusTarget: NSView? { terminal.isHidden ? nil : terminal.focusTarget }
    func apply(zoom: CGFloat, live: Bool) { self.zoom = zoom; terminal.apply(zoom: zoom, live: live); needsLayout = true }
    func update(tile: Tile) { terminal.update(tile: tile) }
    func freezeGrid(_ worldSize: CGSize?) { terminal.freezeGrid(worldSize) }

    func setVisible(_ visible: Bool) {
        terminal.setVisible(visible)
        timer?.invalidate(); timer = nil
        guard visible else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func refresh() {
        let t = Store.shared.findTile(tileID)?.tile
        RemoteHosts.shared.refresh(tileID, session: t?.sessionID, cwd: t?.cwd)
    }

    func willClose() { timer?.invalidate(); timer = nil; terminal.willClose() }

    @objc private func hideTerminal() { RemoteHosts.shared.showTerminal.remove(tileID) }

    override func layout() {
        super.layout()
        terminal.frame = bounds
        host.frame = bounds
        back.sizeToFit()
        back.frame.origin = CGPoint(x: bounds.maxX - back.frame.width - 10, y: bounds.maxY - back.frame.height - 10)
        let w = bounds.width / max(zoom, 0.01), h = bounds.height / max(zoom, 0.01)
        host.setBoundsSize(CGSize(width: w, height: h))
        hostView.frame = CGRect(x: 0, y: 0, width: w, height: h)
    }
}

struct RemoteHostView: View {
    let tileID: String
    weak var controller: CanvasController?
    @ObservedObject var hosts = RemoteHosts.shared
    @ObservedObject var store = Store.shared

    private var tile: Tile? { store.findTile(tileID)?.tile }
    private var status: RemoteHostStatus { hosts.status[tileID] ?? RemoteHostStatus() }
    private var sessions: [Tile] { controller?.remoteSessions(of: tileID) ?? [] }
    /// Sessions whose tile was closed and that still run, newest first.
    private var closed: [ClosedRemote] { (tile?.rcClosed ?? []).reversed() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusRow.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
            if tile?.rcExternal == true { externalBanner }
            Divider().opacity(0.6)
            Group {
                switch status.phase {
                case .needsTrust: trustCard
                case .needsSpawnMode: spawnChoiceCard
                case .stopped, .failed: stoppedCard
                default: pairCard
                }
            }
            .padding(16)
            Divider().opacity(0.6)
            spawnRow.padding(.horizontal, 16).padding(.vertical, 10)
            Divider().opacity(0.6)
            sessionList
            Divider().opacity(0.6)
            footer.padding(.horizontal, 16).padding(.vertical, 9)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(ns: Theme.terminalBG))
    }

    // MARK: Status

    private var statusRow: some View {
        HStack(spacing: 8) {
            StatusDot(color: phaseColor, pulsing: status.phase == .connected || status.phase == .starting || status.phase == .reconnecting)
            Text(phaseLabel).font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            if let c = status.capacity, status.phase == .connected {
                Text("\(sessions.count) active · \(c.total) max").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private var phaseLabel: String {
        switch status.phase {
        case .starting: return "Starting…"
        case .needsTrust, .needsSpawnMode: return "Waiting for you"
        case .connected: return "Live on your phone"
        case .reconnecting: return "Reconnecting…"
        case .stopped: return "Stopped"
        case .failed: return "Couldn't connect"
        }
    }

    private var phaseColor: NSColor {
        switch status.phase {
        case .connected: return Theme.green
        case .starting, .reconnecting, .needsTrust, .needsSpawnMode: return Theme.amber
        case .stopped: return Theme.idle
        case .failed: return Theme.red
        }
    }

    // MARK: Cards

    private var pairCard: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white)
                if let u = status.environmentURL, let img = Self.qr(u.absoluteString) {
                    Image(nsImage: img).interpolation(.none).resizable().scaledToFit().padding(9)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 132, height: 132)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))

            VStack(alignment: .leading, spacing: 7) {
                Text("Start sessions from your phone").font(.system(size: 13, weight: .semibold))
                Text("Scan with your iPhone camera, or open Code in the Claude app and pick \(envName). Each session you start opens here as a tile.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 2)
                if let u = status.environmentURL {
                    HStack(spacing: 8) {
                        Button("Open claude.ai") { NSWorkspace.shared.open(u) }.controlSize(.small)
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u.absoluteString, forType: .string) } label: {
                            Image(systemName: "link")
                        }
                        .controlSize(.small).help("Copy link")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 132)
    }

    private var envName: String {
        let cmd = tile?.command ?? ""
        if let r = cmd.range(of: #"--name '([^']*)'"#, options: .regularExpression) {
            return "“" + cmd[r].dropFirst("--name '".count).dropLast() + "”"
        }
        return "this Mac"
    }

    private var trustCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Trust this folder?", systemImage: "lock.shield").font(.system(size: 13, weight: .semibold))
            Text("Sessions started from your phone can read, edit and run files in \(TileView.abbreviate(tile?.cwd ?? "this folder")), and its project settings apply to them.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Show Terminal") { hosts.showTerminal.insert(tileID) }.controlSize(.small)
                Button("Trust Folder") { controller?.trustRemoteFolder(tileID) }.controlSize(.small).buttonStyle(.borderedProminent)
            }
        }
        .frame(height: 132, alignment: .top)
    }

    private var externalBanner: some View {
        let restarting = controller?.isRestartingRemote(tileID) ?? false
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: restarting ? "arrow.triangle.2.circlepath" : "info.circle").font(.system(size: 11)).foregroundStyle(.secondary)
            Text(restarting ? "Restarting with Pitwall's settings so its sessions show up here…"
                 : "Started outside Pitwall: sessions from your phone won't show up here.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if !restarting && status.phase == .connected {
                Button("Restart") { controller?.restartRemoteUnderPitwall(tileID) }.controlSize(.small)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
    }

    private var spawnChoiceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Where should new sessions run?", systemImage: "folder").font(.system(size: 13, weight: .semibold))
            Text("Same folder shares this checkout. Own worktree gives each session its own branch and folder (needs a git repository). You can change it later.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if status.isGitRepo { Button("Own Worktree") { controller?.chooseRemoteSpawn(tileID, worktree: true) }.controlSize(.small) }
                Button("Same Folder") { controller?.chooseRemoteSpawn(tileID, worktree: false) }.controlSize(.small).buttonStyle(.borderedProminent)
            }
        }
        .frame(height: 132, alignment: .top)
    }

    private var stoppedCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(status.phase == .failed ? "Remote Control stopped with an error" : "Remote Control isn't running",
                  systemImage: status.phase == .failed ? "exclamationmark.triangle" : "pause.circle")
                .font(.system(size: 13, weight: .semibold))
            Text(status.message ?? "Your phone can't start new sessions here until you start it again. Sessions already open stay on the canvas.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Show Terminal") { hosts.showTerminal.insert(tileID) }.controlSize(.small)
                Button("Start Again") { controller?.restartRemoteControl(tileID) }.controlSize(.small).buttonStyle(.borderedProminent)
            }
        }
        .frame(height: 132, alignment: .top)
    }

    // MARK: Spawn mode

    private var spawnRow: some View {
        let worktree = status.worktreeSpawn ?? (tile?.rcSpawn == "worktree")
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("New sessions").font(.system(size: 12, weight: .medium))
                Text(TileView.abbreviate(tile?.cwd ?? "")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 0)
            if status.isGitRepo {
                Picker("", selection: Binding(get: { worktree }, set: { v in
                    if v != worktree { controller?.setRemoteSpawn(tileID, worktree: v, live: status.phase == .connected) }
                })) {
                    Text("Same folder").tag(false)
                    Text("Own worktree").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            } else {
                Text("Same folder").font(.system(size: 12)).foregroundStyle(.secondary)
                    .help("Own worktrees need a git repository")
            }
        }
    }

    // MARK: Sessions

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sessions").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                Spacer()
                if sessions.count + closed.count > 0 { Text("\(sessions.count + closed.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
            if sessions.isEmpty && closed.isEmpty {
                Text("Nothing yet. Sessions you start from your phone or claude.ai show up here and on the canvas.")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(sessions) { s in sessionRow(s) }
                        ForEach(closed) { c in closedRow(c) }
                    }.padding(.horizontal, 8).padding(.bottom, 8)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func sessionRow(_ s: Tile) -> some View {
        Button { controller?.focus(tileID: s.id, makeFirstResponder: false); controller?.flyTo(tileID: s.id, fill: false) } label: {
            HStack(spacing: 9) {
                Circle().fill(Color(ns: Theme.color(for: s.state))).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(sessionLine(s)).font(.system(size: 11)).foregroundStyle(s.state == .waiting ? Color(ns: Theme.amberText) : .secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(s.stateSince.elapsedShort).font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
    }

    private func closedRow(_ c: ClosedRemote) -> some View {
        Button { controller?.reopenRemote(host: tileID, session: c.session) } label: {
            HStack(spacing: 9) {
                Circle().strokeBorder(Color.secondary, lineWidth: 1).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                    Text("Tile closed · click to open").font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(c.closedAt.elapsedShort).font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
        .help("Still running. Open its tile again.")
    }

    private func sessionLine(_ s: Tile) -> String {
        switch s.state {
        case .waiting: return s.statusMessage ?? "Needs you"
        case .working: return s.statusMessage ?? "Working"
        case .done: return "Done" + (s.branch.map { " · \($0)" } ?? "")
        case .error: return s.statusMessage ?? "Error"
        case .idle: return s.branch ?? "Idle"
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button { hosts.showTerminal.insert(tileID) } label: { Label("Terminal", systemImage: "terminal") }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if status.phase == .connected || status.phase == .reconnecting {
                Button("Stop") { controller?.stopRemoteControl(tileID) }.controlSize(.small)
            }
        }
    }

    static func qr(_ s: String) -> NSImage? {
        let f = CIFilter(name: "CIQRCodeGenerator")
        f?.setValue(Data(s.utf8), forKey: "inputMessage")
        f?.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f?.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

private struct StatusDot: View {
    let color: NSColor
    let pulsing: Bool
    @State private var on = false
    var body: some View {
        ZStack {
            if pulsing {
                Circle().fill(Color(ns: color).opacity(0.35)).frame(width: 16, height: 16)
                    .scaleEffect(on ? 1 : 0.5).opacity(on ? 0 : 1)
                    .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: on)
            }
            Circle().fill(Color(ns: color)).frame(width: 8, height: 8)
        }
        .frame(width: 16, height: 16)
        .onAppear { on = true }
    }
}

private struct HoverRowStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(configuration.isPressed ? 0.09 : (hover ? 0.05 : 0))))
            .onHover { hover = $0 }
    }
}

// MARK: - `claude rc` typed by hand

/// A host being restarted under Pitwall's settings.
struct RemoteRestart {
    enum Stage { case waitReady, stopping }
    var stage: Stage
    var at: Date
}

enum ProcessArgs {
    /// argv of a process this user owns (KERN_PROCARGS2).
    static func argv(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: Int(argmax))
        var len = Int(argmax)
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buf, &len, nil, 0) == 0, len > 4 else { return nil }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        while i < len && buf[i] != 0 { i += 1 } // executable path
        while i < len && buf[i] == 0 { i += 1 }
        var out: [String] = []
        while out.count < Int(argc) && i < len {
            let start = i
            while i < len && buf[i] != 0 { i += 1 }
            out.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return out
    }

    static func startTime(_ pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }
}

extension CanvasController {
    /// `claude rc` or `claude remote-control` (not `claude --remote-control`,
    /// which is one interactive session).
    static func isRemoteControlCommand(_ argv: [String]) -> Bool {
        argv.count >= 2 && (argv[1] == "rc" || argv[1] == "remote-control")
    }

    /// From the poll, for every terminal-backed tile: notices `claude rc`
    /// typed by hand, restarts it under Pitwall, and turns the tile back into
    /// a plain terminal when it's stopped.
    func pollRemoteHost(_ t: Tile, info: SessionInfo, isAgent: Bool) {
        if t.rcSpawn == nil {
            guard isAgent, let pid = info.foregroundPid, rcCheckedPID[t.id] != pid else { return }
            rcCheckedPID[t.id] = pid
            if let argv = ProcessArgs.argv(pid), Self.isRemoteControlCommand(argv) { adoptRemoteHost(t.id, pid: pid, argv: argv) }
            return
        }
        if var r = rcRestart[t.id] {
            switch r.stage {
            case .waitReady:
                RemoteHosts.shared.refresh(t.id, session: t.sessionID, cwd: t.cwd)
                if RemoteHosts.shared.status[t.id]?.phase == .connected {
                    // Trust and spawn-mode questions are answered; nothing has
                    // been started from a phone yet. Restart with Pitwall's settings.
                    stopRemoteControl(t.id)
                    r.stage = .stopping
                    r.at = Date()
                } else if Date().timeIntervalSince(r.at) > 180 {
                    rcRestart[t.id] = nil
                    return
                }
            case .stopping:
                if !isAgent {
                    rcRestart[t.id] = nil
                    restartRemoteControl(t.id)
                    return
                }
                if Date().timeIntervalSince(r.at) > 10 { rcRestart[t.id] = nil; return }
            }
            rcRestart[t.id] = r
            return
        }
        // Stopped: its sessions ended with it, closed ones included.
        if t.rcClosed != nil, let p = RemoteHosts.shared.status[t.id]?.phase, p == .stopped || p == .failed {
            store.updateTile(t.id) { $0.rcClosed = nil }
        }
        // Typed by hand and now stopped: it's their terminal again.
        if t.rcAdopted == true, !isAgent, info.alive {
            store.updateTile(t.id) { x in
                x.rcSpawn = nil; x.rcAdopted = nil; x.rcExternal = nil; x.command = nil
                if x.name == "Remote Control" { x.name = nil }
            }
            rcCheckedPID[t.id] = nil
            RemoteHosts.shared.status[t.id] = nil
            RemoteHosts.shared.showTerminal.remove(t.id)
            rebuildTileView(t.id)
        }
    }

    func adoptRemoteHost(_ id: String, pid: Int32, argv: [String]) {
        let ours = ClaudeIntegration.settingsFile.path
        var rest = Array(argv.dropFirst(2))
        let hasOurs = rest.contains { $0.contains(ours) }
        let hasOther = !hasOurs && rest.contains { $0 == "--settings" || $0.hasPrefix("--settings=") }
        var spawn: String?
        for (i, a) in rest.enumerated() {
            if a.hasPrefix("--spawn=") { spawn = String(a.dropFirst("--spawn=".count)) }
            else if a == "--spawn", i + 1 < rest.count { spawn = rest[i + 1] }
        }
        if !hasOurs && !hasOther { rest += ["--settings", ours] }
        let cmd = (["claude", "remote-control"] + rest).map(shellQuote).joined(separator: " ")
        // Just typed: safe to restart before anyone starts a session from a phone.
        let fresh = ProcessArgs.startTime(pid).map { Date().timeIntervalSince($0) < 90 } ?? false
        store.updateTile(id) { x in
            x.kind = .terminal
            x.rcSpawn = spawn ?? "same-dir"
            x.rcAdopted = true
            x.command = cmd
            x.rcExternal = hasOurs ? nil : true
            if x.name == nil { x.name = "Remote Control" }
        }
        if !hasOurs && !hasOther && fresh { rcRestart[id] = RemoteRestart(stage: .waitReady, at: Date()) }
        rebuildTileView(id)
    }
}
