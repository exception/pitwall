import AppKit
import SwiftUI

// MARK: - Watch tiles & PR tiles (stage E)
//
// A watch tile runs a command (tests, a build, a deploy, a CI tail) and turns
// red when it fails: either the command exits non-zero or its recent output
// matches a failure pattern. A PR tile follows a GitHub pull request through
// `gh`: checks, reviews and comments. Both can hand failures to an agent.

extension CanvasController {

    // MARK: Watch

    /// Opens a terminal that runs `command` and reports how it ends.
    @discardableResult
    func newWatch(command: String, cwd: String? = nil, at: CGPoint? = nil, from: String? = nil, autoSend: Bool = false) -> String {
        var t = Tile(kind: .logs, frame: .zero)
        t.autoSend = autoSend ? true : nil
        t.cwd = cwd ?? defaultCwd
        t.watchCommand = command
        t.command = Self.watchScript(command)
        t.autoName = command.count > 40 ? String(command.prefix(38)) + "…" : command
        t.sessionID = t.id
        t.state = .working
        t.statusMessage = "Running"
        let id = addTile(t, at: at)
        if let from { addLink(from: from, to: id, kind: .spawned) }
        return id
    }

    // MARK: Waits

    /// What `wait_for` waits on, as a command whose exit code is the result.
    struct WaitSpec: Equatable {
        var command: String
        var label: String
        /// GitHub Actions runs get a live Run tile instead of a terminal.
        var runID: String? = nil
        var runRepo: String? = nil
    }

    /// A GitHub Actions run (id or URL), a PR's checks, or any command.
    static func waitSpec(run: String?, pr: String?, command: String?) -> WaitSpec? {
        if let run = run?.trimmingCharacters(in: .whitespaces), !run.isEmpty {
            var repo: String?
            var id = run
            if let m = run.range(of: #"github\.com/([^/]+/[^/]+)/actions/runs/(\d+)"#, options: .regularExpression) {
                let parts = run[m].split(separator: "/")
                repo = parts[1] + "/" + parts[2]
                id = String(parts[5])
            }
            guard id.allSatisfy(\.isNumber) else { return nil }
            let r = repo.map { " -R " + shellQuote($0) } ?? ""
            return WaitSpec(command: "gh run watch \(id)\(r) --exit-status --interval 30", label: "CI run \(id)", runID: id, runRepo: repo)
        }
        if let pr = pr?.trimmingCharacters(in: .whitespaces), !pr.isEmpty {
            let num = pr.split(separator: "/").last.map(String.init) ?? pr
            return WaitSpec(command: "gh pr checks \(shellQuote(pr)) --watch --interval 30", label: "PR #\(num.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) checks")
        }
        if let c = command?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
            let one = c.replacingOccurrences(of: "\n", with: " ")
            return WaitSpec(command: c, label: one.count > 40 ? String(one.prefix(38)) + "…" : one)
        }
        return nil
    }

    /// Starts a wait for an agent: a watch tile linked to it that wakes the
    /// agent with the result when it finishes, pass or fail.
    func newWait(_ spec: WaitSpec, note: String?, cwd: String?, from: String?) -> String {
        let id = newWatch(command: spec.command, cwd: cwd, at: from.flatMap { near(agent: $0) }, from: from)
        store.updateTile(id) {
            $0.waitLabel = spec.label
            $0.waitNote = note.flatMap { $0.isEmpty ? nil : $0 }
            $0.autoName = "Waiting · " + spec.label
            $0.statusMessage = "Waiting on " + spec.label
        }
        if let from { refreshBackground(from) }
        reconcile()
        return id
    }

    private func near(agent id: String) -> CGPoint? {
        guard let f = board.tile(id) else { return nil }
        return freeSpot(size: Self.defaultSize(.logs), near: CGPoint(x: f.frame.maxX + 44, y: f.frame.minY))
    }

    /// A command wait ended: tell the agent how it went so it can carry on.
    private func waitFinished(_ id: String, _ t: Tile, code: Int) {
        let raw = t.sessionID.flatMap { Sessions.scrollback($0, bytes: 16_000) } ?? ""
        let tail = Sessions.plain(raw).split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.contains("watch-exit") }.suffix(code == 0 ? 15 : 60).joined(separator: "\n")
        var detail = "Command: `\(t.watchCommand ?? "")`"
        if !tail.isEmpty { detail += "\nLast output:\n```\n\(tail)\n```" }
        wakeAgent(fromWait: id, ok: code == 0, label: t.waitLabel ?? t.watchCommand ?? "the command",
                  conclusion: "exit \(code)", detail: detail)
    }

    /// The command, then a report of its exit status back to Pitwall.
    static func watchScript(_ command: String) -> String {
        // A subshell, so `exit` in the command doesn't end the tile's shell.
        "(\n" + command + "\n)\n\"$" + PitwallEnv.helper + "\" watch-exit $? >/dev/null 2>&1"
    }

    /// The watched command finished.
    func watchExited(_ id: String, code: Int) {
        guard let t = store.findTile(id)?.tile else { return }
        if t.keepAlive == true { serverExited(id, code: code); return }
        if t.waitLabel != nil { waitFinished(id, t, code: code); return }
        if code == 0 {
            setState(id, .done, message: "Passed · exit 0")
        } else {
            setState(id, .error, message: "Failed · exit \(code)")
            failed(id, t)
        }
    }

    /// Re-runs a watch tile's command in a fresh session.
    func rerunWatch(_ id: String) {
        guard let t = store.findTile(id)?.tile, let cmd = t.watchCommand else { return }
        if let sid = t.sessionID { Sessions.kill(sid) }
        store.updateTile(id) {
            $0.command = Self.watchScript(cmd)
            $0.sessionID = "s-" + UUID().uuidString.prefix(8).lowercased()
        }
        watchFailingLine[id] = nil
        restartSession(id)
        setState(id, .working, message: "Running")
    }

    /// Lines that mean "this is broken" in typical build/test/deploy output.
    static let failurePattern = try! NSRegularExpression(pattern: [
        "^\\s*(?:FAIL|FAILED|ERROR)\\b", "\\berror(?:\\[E\\d+\\])?:", "\\berror TS\\d+", "Error: ",
        "\\b\\d+ (?:failing|failed)\\b", "Tests?:.*\\bfailed\\b", "Build failed", "Deployment failed",
        "Traceback \\(most recent call last\\)", "panicked at", "Segmentation fault", "npm ERR!",
        "Command failed", "^\\s*[✗✘]",
    ].joined(separator: "|"), options: [.anchorsMatchLines])
    static let recoveryPattern = try! NSRegularExpression(pattern: [
        "Found 0 errors", "compiled successfully", "Compiled successfully", "\\b0 failed\\b", "All tests passed",
        "Tests?:\\s+\\d+ passed(?!.*failed)", "\\bready\\b.*\\bin\\b", "Build succeeded", "Deployment (?:ready|succeeded|complete)",
        "✓ (?:Ready|Compiled)",
    ].joined(separator: "|"), options: [.anchorsMatchLines])

    /// Called from the screen scanner with the tail of a watch tile's output.
    func watchScan(_ id: String, tail: String) {
        // Only while it runs: a finished command's exit code is authoritative.
        guard let t = store.findTile(id)?.tile, t.kind == .logs, t.waitLabel == nil,
              t.state == .working || watchFailingLine[id] != nil else { return }
        let lines = tail.split(separator: "\n", omittingEmptySubsequences: true).suffix(30).map(String.init)
        if t.keepAlive == true { detectServerURL(id, tail: tail) }
        var lastFail: (Int, String)?, lastOK: Int?
        for (i, l) in lines.enumerated() {
            let r = NSRange(l.startIndex..., in: l)
            if Self.failurePattern.firstMatch(in: l, range: r) != nil { lastFail = (i, l) }
            if Self.recoveryPattern.firstMatch(in: l, range: r) != nil { lastOK = i }
        }
        if let (i, line) = lastFail, i > (lastOK ?? -1) {
            let clean = line.trimmingCharacters(in: .whitespaces)
            guard watchFailingLine[id] != clean else { return }
            watchFailingLine[id] = clean
            if t.state != .error {
                setState(id, .error, message: String(clean.prefix(160)))
                failed(id, t)
            }
        } else if watchFailingLine[id] != nil, lastOK != nil {
            watchFailingLine[id] = nil
            if t.state == .error { setState(id, .working, message: "Recovered") }
        }
    }

    private func failed(_ id: String, _ t: Tile) {
        Timelines.shared.add(id, .error, store.findTile(id)?.tile.statusMessage ?? "Failed")
        let target = agentTarget(for: id)
        if t.autoSend == true, target != nil {
            sendFailure(id)
        } else if Prefs.shared.toasts {
            model?.toast(.init(kind: .error, title: t.displayName + " failed",
                               body: store.findTile(id)?.tile.statusMessage ?? "", tileID: id))
            if Prefs.shared.sound { NSSound(named: "Basso")?.play() }
        }
    }

    /// The agent a watch/PR tile reports to: a linked agent, else the one
    /// working in the same checkout.
    func agentTarget(for id: String) -> String? {
        guard let (b, t) = store.findTile(id) else { return nil }
        if let linked = linkedTiles(of: id).first(where: { $0.1.kind == .agent || hookedTiles.contains($0.1.id) })?.1 { return linked.id }
        let dir = t.kind == .pr ? t.target : t.cwd
        guard let dir, let top = Git.toplevel(dir) else { return nil }
        return b.tiles.first { $0.kind == .agent && ($0.worktree ?? $0.cwd).flatMap(Git.toplevel) == top }?.id
    }

    /// Sends a watch tile's failing output to its agent.
    func sendFailure(_ id: String) {
        guard let t = store.findTile(id)?.tile else { return }
        guard let agent = agentTarget(for: id) else {
            model?.toast(.init(kind: .info, title: "No agent to send to", body: "Link this tile to an agent first (drag from its edge).", tileID: id))
            return
        }
        addLink(from: id, to: agent)
        let raw = t.sessionID.flatMap { Sessions.scrollback($0, bytes: 24_000) } ?? ""
        let tail = Sessions.plain(raw).split(separator: "\n", omittingEmptySubsequences: false).suffix(80).joined(separator: "\n")
        let cmd = t.watchCommand ?? t.command ?? "the command"
        let text = "`\(cmd)` is failing in \(t.cwd ?? "the project"). Please fix it; Pitwall will run it again when you're done (no need to reply). Last output:\n```\n\(tail)\n```"
        if let err = sendMessage(from: id, to: agent, text: text) {
            model?.toast(.init(kind: .error, title: "Couldn't send", body: err, tileID: id))
        } else {
            Timelines.shared.add(agent, .message, "Failure from \(t.displayName)")
            if t.watchCommand != nil, t.keepAlive != true { fixRequests[agent] = id }
        }
    }

    func toggleAutoSend(_ id: String) {
        store.updateTile(id) { $0.autoSend = !($0.autoSend ?? false) }
        reconcile()
    }

    // MARK: PRs

    /// Opens a PR tile for `repo` (the current branch's PR when `ref` is nil).
    @discardableResult
    func newPR(repo: String, ref: String? = nil, at: CGPoint? = nil, from: String? = nil) -> String? {
        guard let top = Git.toplevel(repo) else {
            model?.toast(.init(kind: .error, title: "Not a git repository", body: repo)); return nil
        }
        var t = Tile(kind: .pr, frame: .zero)
        t.target = top
        t.cwd = top
        t.prRef = ref
        t.branch = Git.branch(top)
        var spot = at
        if spot == nil, let f = from.flatMap({ board.tile($0) }) {
            spot = freeSpot(size: Self.defaultSize(.pr), near: CGPoint(x: f.frame.maxX + 44, y: f.frame.minY))
        }
        let id = addTile(t, at: spot)
        if let from { addLink(from: from, to: id, kind: .spawned) }
        return id
    }

    /// Status from a PR tile's latest poll.
    func prUpdated(_ id: String, _ pr: PRInfo) {
        guard let t = store.findTile(id)?.tile else { return }
        store.updateTile(id) {
            if $0.prRef == nil { $0.prRef = String(pr.number) }
            $0.branch = pr.headRefName
            $0.autoName = "#\(pr.number) " + pr.title
        }
        let failing = pr.checks.filter(\.failed)
        let (state, msg): (AgentState, String) = {
            if pr.state == "MERGED" { return (.done, "Merged") }
            if pr.state == "CLOSED" { return (.idle, "Closed") }
            if !failing.isEmpty { return (.error, "\(failing.count) check\(failing.count == 1 ? "" : "s") failing: " + failing.map(\.name).prefix(3).joined(separator: ", ")) }
            if pr.checks.contains(where: \.pending) { return (.working, "Checks running") }
            if pr.reviewDecision == "CHANGES_REQUESTED" { return (.waiting, "Changes requested") }
            if pr.reviewDecision == "APPROVED" { return (.done, "Approved · checks passed") }
            return (.done, pr.checks.isEmpty ? "Open" : "Checks passed")
        }()
        let wasFailing = t.state == .error
        setState(id, state, message: msg)
        if state == .error && !wasFailing {
            Timelines.shared.add(id, .error, msg)
            if t.autoSend == true, agentTarget(for: id) != nil { sendPRFailures(id, pr) }
            else if Prefs.shared.toasts { model?.toast(.init(kind: .error, title: t.displayName, body: msg, tileID: id)) }
        }
        // New review comments go to the agent when auto-send is on.
        let seen = prSeenComments[id] ?? Set(pr.comments.map(\.id))
        let fresh = pr.comments.filter { !seen.contains($0.id) }
        prSeenComments[id] = Set(pr.comments.map(\.id))
        if t.autoSend == true, !fresh.isEmpty, agentTarget(for: id) != nil { sendPRComments(id, fresh) }
    }

    /// Sends failing checks (with the failed job logs) to the PR's agent.
    func sendPRFailures(_ id: String, _ pr: PRInfo) {
        guard let agent = agentTarget(for: id), let repo = store.findTile(id)?.tile.target else {
            model?.toast(.init(kind: .info, title: "No agent to send to", body: "Link this PR tile to an agent first.", tileID: id)); return
        }
        addLink(from: id, to: agent)
        let failing = pr.checks.filter(\.failed)
        DispatchQueue.global(qos: .userInitiated).async {
            var parts: [String] = []
            var seenRuns = Set<String>()
            for c in failing {
                var block = "### \(c.name) — \(c.conclusion ?? "failed")\n\(c.url ?? "")"
                if let run = c.runID, !seenRuns.contains(run) {
                    seenRuns.insert(run)
                    // The PR may live in another repo than the checkout (URL refs).
                    let slug = pr.url.components(separatedBy: "/pull/").first.map { $0.replacingOccurrences(of: "https://github.com/", with: "") }
                    let log = GH.run(["run", "view", run, "--log-failed"] + (slug.map { ["-R", $0] } ?? []), in: repo, timeout: 30) ?? ""
                    let tail = Self.failureExcerpt(log)
                    if !tail.isEmpty { block += "\n```\n\(tail)\n```" }
                }
                parts.append(block)
            }
            let text = "CI is failing on PR #\(pr.number) (\(pr.title)). Please fix and push.\n\n" + parts.joined(separator: "\n\n")
            DispatchQueue.main.async {
                if let err = self.sendMessage(from: id, to: agent, text: text) {
                    self.model?.toast(.init(kind: .error, title: "Couldn't send", body: err, tileID: id))
                }
            }
        }
    }

    /// The interesting part of a `gh run view --log-failed` dump: lines
    /// around the last error, without gh's "job\tstep\ttimestamp" prefixes.
    static func failureExcerpt(_ log: String) -> String {
        let lines: [String] = log.split(separator: "\n").map { line in
            var msg = String(line.split(separator: "\t", maxSplits: 2).last ?? line)
            if let r = msg.range(of: "^\\d{4}-\\d\\d-\\d\\dT[\\d:.]+Z ?", options: .regularExpression) { msg.removeSubrange(r) }
            return msg
        }
        let marker = try! NSRegularExpression(pattern: "##\\[error\\]|--- FAIL|\\bFAIL\\b|\\berror\\b|Error:|failed", options: [.caseInsensitive])
        let idx = lines.lastIndex { l in
            !l.hasPrefix("[command]") && marker.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil
        }
        guard let i = idx else { return lines.suffix(40).joined(separator: "\n") }
        // First error in the final failing block reads best: walk back over the run of errors.
        var start = i
        while start > 0, i - start < 25 { start -= 1 }
        return lines[start...min(i + 5, lines.count - 1)].joined(separator: "\n")
    }

    func sendPRComments(_ id: String, _ comments: [PRInfo.Comment]) {
        guard let agent = agentTarget(for: id), let t = store.findTile(id)?.tile else {
            model?.toast(.init(kind: .info, title: "No agent to send to", body: "Link this PR tile to an agent first.", tileID: id)); return
        }
        addLink(from: id, to: agent)
        let body = comments.map { c in
            "- \(c.author)\(c.path.map { " on \($0)" } ?? ""): \(c.body)"
        }.joined(separator: "\n")
        let text = "Review feedback on \(t.displayName). Address it, then push:\n\(body)"
        if let err = sendMessage(from: id, to: agent, text: text) {
            model?.toast(.init(kind: .error, title: "Couldn't send", body: err, tileID: id))
        }
    }
}

// MARK: - gh

enum GH {
    static let path: String? = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Runs gh; returns stdout, or nil (with stderr in `error`) on failure.
    static func run(_ args: [String], in dir: String, timeout: TimeInterval = 20, error: UnsafeMutablePointer<String>? = nil) -> String? {
        guard let path else { error?.pointee = "GitHub CLI (gh) isn't installed. brew install gh"; return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env = ProcessInfo.processInfo.environment
        env["GH_PROMPT_DISABLED"] = "1"
        env["NO_COLOR"] = "1"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let edata = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationStatus == 0 else {
            error?.pointee = String(decoding: edata, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// What a PR tile shows. Decoded from `gh pr view --json`.
struct PRInfo: Equatable {
    struct Check: Equatable, Identifiable {
        var id: String { name + (url ?? "") }
        var name: String
        var status: String       // QUEUED, IN_PROGRESS, COMPLETED (or state for status contexts)
        var conclusion: String?  // SUCCESS, FAILURE, CANCELLED, TIMED_OUT, SKIPPED, NEUTRAL, ACTION_REQUIRED
        var url: String?
        var failed: Bool { ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "ERROR", "STARTUP_FAILURE"].contains(conclusion ?? "") }
        var pending: Bool { conclusion == nil || conclusion == "" || ["PENDING", "EXPECTED"].contains(conclusion ?? "") }
        var runID: String? {
            guard let url, let r = url.range(of: "/runs/(\\d+)", options: .regularExpression) else { return nil }
            return String(url[r].dropFirst(6))
        }
    }
    struct Comment: Equatable, Identifiable {
        var id: String
        var author: String
        var body: String
        var path: String?
        var at: Date?
        var kind: String // comment, review, CHANGES_REQUESTED, APPROVED
    }
    var number: Int
    var title: String
    var url: String
    var state: String
    var isDraft: Bool
    var headRefName: String
    var reviewDecision: String?
    var mergeable: String?
    var additions: Int
    var deletions: Int
    var checks: [Check]
    var comments: [Comment]

    static let fields = "number,title,url,state,isDraft,headRefName,reviewDecision,mergeable,additions,deletions,statusCheckRollup,comments,reviews"

    static func parse(_ data: Data) -> PRInfo? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let n = o["number"] as? Int else { return nil }
        let iso = ISO8601DateFormatter()
        var checks: [Check] = []
        for c in o["statusCheckRollup"] as? [[String: Any]] ?? [] {
            if c["__typename"] as? String == "StatusContext" {
                let st = (c["state"] as? String) ?? "PENDING"
                checks.append(Check(name: c["context"] as? String ?? "status", status: st,
                                    conclusion: st == "PENDING" ? nil : st, url: c["targetUrl"] as? String))
            } else {
                let concl = (c["conclusion"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                var name = c["name"] as? String ?? "check"
                if let wf = c["workflowName"] as? String, !wf.isEmpty, wf != name { name = wf + " / " + name }
                checks.append(Check(name: name, status: c["status"] as? String ?? "", conclusion: concl, url: c["detailsUrl"] as? String))
            }
        }
        var comments: [Comment] = []
        for c in o["comments"] as? [[String: Any]] ?? [] {
            let body = (c["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            comments.append(Comment(id: c["id"] as? String ?? UUID().uuidString, author: (c["author"] as? [String: Any])?["login"] as? String ?? "someone",
                                    body: body, path: nil, at: (c["createdAt"] as? String).flatMap(iso.date), kind: "comment"))
        }
        for r in o["reviews"] as? [[String: Any]] ?? [] {
            let body = (r["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let st = r["state"] as? String ?? "COMMENTED"
            guard !body.isEmpty || st == "CHANGES_REQUESTED" || st == "APPROVED" else { continue }
            comments.append(Comment(id: r["id"] as? String ?? UUID().uuidString, author: (r["author"] as? [String: Any])?["login"] as? String ?? "someone",
                                    body: body.isEmpty ? (st == "APPROVED" ? "Approved" : "Requested changes") : body,
                                    path: nil, at: (r["submittedAt"] as? String).flatMap(iso.date), kind: st))
        }
        comments.sort { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) }
        return PRInfo(number: n, title: o["title"] as? String ?? "", url: o["url"] as? String ?? "", state: o["state"] as? String ?? "OPEN",
                      isDraft: o["isDraft"] as? Bool ?? false, headRefName: o["headRefName"] as? String ?? "",
                      reviewDecision: (o["reviewDecision"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                      mergeable: o["mergeable"] as? String, additions: o["additions"] as? Int ?? 0, deletions: o["deletions"] as? Int ?? 0,
                      checks: checks, comments: comments)
    }
}

// MARK: - PR tile

final class PRTileContent: NSView, TileContent {
    private let model: PRModel
    private let hostView: NSHostingView<PRView>
    private let host = FlippedView()
    private var zoom: CGFloat = 1
    override var isFlipped: Bool { true }

    init(tileID: String, repo: String, ref: String?, controller: CanvasController) {
        model = PRModel(tileID: tileID, repo: repo, ref: ref)
        model.controller = controller
        hostView = NSHostingView(rootView: PRView(model: model))
        super.init(frame: .zero)
        addSubview(host)
        host.addSubview(hostView)
        model.start()
    }
    required init?(coder: NSCoder) { fatalError() }

    var info: PRInfo? { model.info }
    var focusTarget: NSView? { nil }
    func willClose() { model.stop() }
    func apply(zoom: CGFloat, live: Bool) { self.zoom = zoom; needsLayout = true }
    func update(tile: Tile) {
        model.autoSend = tile.autoSend ?? false
        if model.ref == nil, let r = tile.prRef { model.ref = r }
    }

    override func layout() {
        super.layout()
        host.frame = bounds
        let w = bounds.width / max(zoom, 0.01), h = bounds.height / max(zoom, 0.01)
        host.setBoundsSize(CGSize(width: w, height: h))
        hostView.frame = CGRect(x: 0, y: 0, width: w, height: h)
    }
}

final class PRModel: ObservableObject {
    let tileID: String
    let repo: String
    var ref: String?
    weak var controller: CanvasController?
    @Published var info: PRInfo?
    @Published var error: String?
    @Published var loading = false
    @Published var autoSend = false
    @Published var updated: Date?
    private var timer: Timer?

    init(tileID: String, repo: String, ref: String?) {
        self.tileID = tileID
        self.repo = repo
        self.ref = ref
    }

    func start() {
        load()
        // Poll faster while checks are running.
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            let running = self.info?.checks.contains(where: \.pending) ?? true
            if running || Int(Date().timeIntervalSince1970) % 60 < 20 { self.load() }
        }
    }

    func stop() { timer?.invalidate() }

    func load() {
        guard !loading else { return }
        loading = true
        let args = ["pr", "view"] + (ref.map { [$0] } ?? []) + ["--json", PRInfo.fields]
        let repo = self.repo
        DispatchQueue.global(qos: .utility).async {
            var err = ""
            let out = GH.run(args, in: repo, error: &err)
            let info = out.flatMap { PRInfo.parse(Data($0.utf8)) }
            DispatchQueue.main.async {
                self.loading = false
                self.updated = Date()
                if let info {
                    self.error = nil
                    if info != self.info { self.info = info }
                    self.controller?.prUpdated(self.tileID, info)
                } else {
                    self.error = err.contains("no pull requests found") ? "No pull request for this branch yet." : (err.isEmpty ? "Couldn't load the pull request." : err)
                }
            }
        }
    }
}

struct PRView: View {
    @ObservedObject var model: PRModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let pr = model.info { content(pr) } else { empty }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.loading && model.error == nil {
                ProgressView().controlSize(.small)
                Text("Loading pull request…").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text(model.error ?? "").font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button("Retry") { model.load() }
                    Button("Create PR") {
                        _ = model.controller?.newTerminal(cwd: model.repo, command: "git push -u origin HEAD && gh pr create --fill", name: "Open PR")
                    }
                }.controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func content(_ pr: PRInfo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            badge(pr)
            Text(pr.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
            Spacer(minLength: 0)
            Text("+\(pr.additions)").foregroundStyle(Color(ns: Theme.green)).font(.system(size: 12, design: .monospaced))
            Text("−\(pr.deletions)").foregroundStyle(Color(ns: Theme.red)).font(.system(size: 12, design: .monospaced))
        }
        HStack(spacing: 8) {
            Button("Open on GitHub") { if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) } }
            let failing = pr.checks.filter(\.failed)
            Button(failing.isEmpty ? "Send failures" : "Send \(failing.count) failure\(failing.count == 1 ? "" : "s") to agent") {
                model.controller?.sendPRFailures(model.tileID, pr)
            }.disabled(failing.isEmpty)
            Button("Send comments") { model.controller?.sendPRComments(model.tileID, pr.comments.suffix(10)) }
                .disabled(pr.comments.isEmpty)
            Spacer(minLength: 0)
            Toggle("Auto-fix", isOn: Binding(get: { model.autoSend }, set: { _ in model.controller?.toggleAutoSend(model.tileID) }))
                .toggleStyle(.switch).controlSize(.mini)
                .help("Send new CI failures and review comments to the linked agent automatically")
        }
        .controlSize(.small)

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("Checks", count: pr.checks.count) {
                    if pr.checks.isEmpty { Text("No checks").font(.system(size: 12)).foregroundStyle(.secondary) }
                    ForEach(pr.checks.sorted { rank($0) < rank($1) }) { c in
                        HStack(spacing: 8) {
                            checkIcon(c)
                            Text(c.name).font(.system(size: 12)).lineLimit(1)
                            Spacer(minLength: 0)
                            if let u = c.url, let url = URL(string: u) {
                                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                section("Conversation", count: pr.comments.count) {
                    if pr.comments.isEmpty { Text("No comments yet").font(.system(size: 12)).foregroundStyle(.secondary) }
                    ForEach(pr.comments.suffix(12).reversed()) { c in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(c.author).font(.system(size: 12, weight: .semibold))
                                if c.kind == "CHANGES_REQUESTED" { tag("changes requested", Theme.amber) }
                                if c.kind == "APPROVED" { tag("approved", Theme.green) }
                                Spacer(minLength: 0)
                                if let at = c.at { Text(at.elapsedShort).font(.system(size: 11)).foregroundStyle(.secondary) }
                            }
                            Text(c.body).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(6).textSelection(.enabled)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let u = model.updated {
            Text("Updated \(u.elapsedShort == "now" ? "just now" : u.elapsedShort + " ago")" + (model.loading ? " · refreshing…" : ""))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private func rank(_ c: PRInfo.Check) -> Int { c.failed ? 0 : (c.pending ? 1 : 2) }

    private func badge(_ pr: PRInfo) -> some View {
        let (text, color): (String, NSColor) = {
            if pr.state == "MERGED" { return ("Merged", NSColor.systemPurple) }
            if pr.state == "CLOSED" { return ("Closed", Theme.red) }
            if pr.isDraft { return ("Draft", Theme.text3) }
            return ("#\(pr.number)", Theme.green)
        }()
        return Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Color(ns: color)))
    }

    private func tag(_ s: String, _ c: NSColor) -> some View {
        Text(s).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(ns: c))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color(ns: c).opacity(0.14)))
    }

    @ViewBuilder
    private func checkIcon(_ c: PRInfo.Check) -> some View {
        if c.failed { Image(systemName: "xmark.circle.fill").foregroundStyle(Color(ns: Theme.red)) }
        else if c.pending { Image(systemName: "circle.dotted").foregroundStyle(Color(ns: Theme.amber)) }
        else if c.conclusion == "SKIPPED" || c.conclusion == "NEUTRAL" { Image(systemName: "minus.circle").foregroundStyle(.secondary) }
        else { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(ns: Theme.green)) }
    }

    private func section<C: View>(_ title: String, count: Int, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(title) · \(count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            c()
        }
    }
}
