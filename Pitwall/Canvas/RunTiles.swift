import AppKit
import SwiftUI

// MARK: - Run data

/// A GitHub Actions run, decoded from `gh run view --json`.
struct RunInfo: Equatable {
    struct Step: Equatable {
        var number: Int
        var name: String
        var status: String
        var conclusion: String?
    }
    struct Job: Equatable, Identifiable {
        var id: Int
        var name: String
        var status: String       // queued, in_progress, completed, waiting, pending
        var conclusion: String?  // success, failure, cancelled, skipped, timed_out, neutral, action_required
        var startedAt: Date?
        var completedAt: Date?
        var url: String?
        var steps: [Step]

        var done: Bool { status == "completed" }
        var running: Bool { status == "in_progress" }
        var failed: Bool { done && RunInfo.failing.contains(conclusion ?? "") }
        var skipped: Bool { done && (conclusion == "skipped" || conclusion == "neutral") }
        /// The step it's on now (running jobs), or the one that broke (failed jobs).
        var currentStep: Step? {
            if failed { return steps.first { RunInfo.failing.contains($0.conclusion ?? "") } }
            return steps.first { $0.status == "in_progress" } ?? steps.first { $0.status != "completed" }
        }
        var duration: TimeInterval? {
            guard let s = startedAt else { return nil }
            return (completedAt ?? Date()).timeIntervalSince(s)
        }
    }

    static let failing: Set<String> = ["failure", "cancelled", "timed_out", "action_required", "startup_failure"]
    static let fields = "databaseId,displayTitle,workflowName,headBranch,headSha,event,status,conclusion,url,createdAt,startedAt,updatedAt,attempt,jobs"

    var id: Int
    var title: String
    var workflow: String
    var branch: String
    var sha: String
    var event: String
    var status: String
    var conclusion: String?
    var url: String
    var startedAt: Date?
    var updatedAt: Date?
    var attempt: Int
    var jobs: [Job]

    var completed: Bool { status == "completed" }
    var succeeded: Bool { completed && ["success", "skipped", "neutral"].contains(conclusion ?? "") }
    var failed: Bool { completed && !succeeded }
    /// Jobs that count toward progress (skipped matrix leftovers don't).
    var countedJobs: [Job] { jobs.filter { !$0.skipped } }
    var progress: Double {
        let j = countedJobs
        guard !j.isEmpty else { return completed ? 1 : 0 }
        return Double(j.filter(\.done).count) / Double(j.count)
    }
    var duration: TimeInterval? {
        guard let s = startedAt else { return nil }
        return ((completed ? updatedAt : nil) ?? Date()).timeIntervalSince(s)
    }

    static func parse(_ data: Data) -> RunInfo? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = o["databaseId"] as? Int else { return nil }
        let iso = ISO8601DateFormatter()
        func date(_ v: Any?) -> Date? {
            guard let s = v as? String, let d = iso.date(from: s), d.timeIntervalSince1970 > 0 else { return nil }
            return d
        }
        func nonEmpty(_ v: Any?) -> String? { (v as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let jobs: [Job] = (o["jobs"] as? [[String: Any]] ?? []).map { j in
            Job(id: j["databaseId"] as? Int ?? 0, name: j["name"] as? String ?? "job",
                status: j["status"] as? String ?? "queued", conclusion: nonEmpty(j["conclusion"]),
                startedAt: date(j["startedAt"]), completedAt: date(j["completedAt"]), url: j["url"] as? String,
                steps: (j["steps"] as? [[String: Any]] ?? []).map { s in
                    Step(number: s["number"] as? Int ?? 0, name: s["name"] as? String ?? "step",
                         status: s["status"] as? String ?? "queued", conclusion: nonEmpty(s["conclusion"]))
                })
        }
        return RunInfo(id: id, title: o["displayTitle"] as? String ?? "", workflow: o["workflowName"] as? String ?? "Workflow",
                       branch: o["headBranch"] as? String ?? "", sha: o["headSha"] as? String ?? "", event: o["event"] as? String ?? "",
                       status: o["status"] as? String ?? "queued", conclusion: nonEmpty(o["conclusion"]), url: o["url"] as? String ?? "",
                       startedAt: date(o["startedAt"]) ?? date(o["createdAt"]), updatedAt: date(o["updatedAt"]),
                       attempt: o["attempt"] as? Int ?? 1, jobs: jobs)
    }

    /// For the agent: what failed, job by job.
    var failureSummary: String {
        let bad = jobs.filter(\.failed)
        guard !bad.isEmpty else { return "" }
        return bad.map { j in
            "- \(j.name): \(j.conclusion ?? "failed")" + (j.currentStep.map { " at step \"\($0.name)\"" } ?? "")
        }.joined(separator: "\n")
    }
}

extension TimeInterval {
    /// 42s, 3m 05s, 1h 12m.
    var clock: String {
        let s = Int(self.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%dm %02ds", s / 60, s % 60) }
        return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
    }
}

/// Latest state of every Run tile, polled by the controller whether or not
/// the tile's board is open (so the agent is woken either way).
final class RunStore: ObservableObject {
    static let shared = RunStore()
    @Published var infos: [String: RunInfo] = [:]
    @Published var errors: [String: String] = [:]
    @Published var updated: [String: Date] = [:]
    func forget(_ id: String) { infos[id] = nil; errors[id] = nil; updated[id] = nil }
}

// MARK: - Controller

extension CanvasController {
    /// A wait on a GitHub Actions run, shown as a live Run tile.
    func newRunWait(runID: String, repo: String?, note: String?, cwd: String?, from: String?) -> String {
        var t = Tile(kind: .run, frame: .zero)
        t.target = runID
        t.runRepo = repo
        t.cwd = cwd ?? defaultCwd
        t.waitLabel = "CI run \(runID)"
        t.waitNote = note.flatMap { $0.isEmpty ? nil : $0 }
        t.autoName = "CI run \(runID)"
        t.statusMessage = "Waiting on CI run \(runID)"
        t.state = .working
        var spot: CGPoint?
        if let f = from.flatMap({ board.tile($0) }) {
            spot = freeSpot(size: Self.defaultSize(.run), near: CGPoint(x: f.frame.maxX + 44, y: f.frame.minY))
        }
        let id = addTile(t, at: spot)
        if let from { addLink(from: from, to: id, kind: .spawned); refreshBackground(from) }
        pollRun(id)
        return id
    }

    /// Called from the main poll: refreshes running runs every ~10s.
    func pollRuns() {
        let now = Date()
        for b in store.boards {
            for t in b.tiles where t.kind == .run {
                let known = RunStore.shared.infos[t.id] != nil
                guard t.state == .working || !known else { continue }
                if let last = runPolledAt[t.id], now.timeIntervalSince(last) < (known ? 10 : 30) { continue }
                pollRun(t.id)
            }
        }
    }

    func pollRun(_ id: String) {
        guard let t = store.findTile(id)?.tile, let runID = t.target, !runLoading.contains(id) else { return }
        runLoading.insert(id)
        runPolledAt[id] = Date()
        let args = ["run", "view", runID] + (t.runRepo.map { ["-R", $0] } ?? []) + ["--json", RunInfo.fields]
        let dir = t.cwd ?? NSHomeDirectory()
        DispatchQueue.global(qos: .utility).async {
            var err = ""
            let info = GH.run(args, in: dir, error: &err).flatMap { RunInfo.parse(Data($0.utf8)) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.runLoading.remove(id)
                let s = RunStore.shared
                s.updated[id] = Date()
                guard let info else { s.errors[id] = err.isEmpty ? "Couldn't load the run." : err; return }
                s.errors[id] = nil
                if s.infos[id] != info { s.infos[id] = info }
                self.runUpdated(id, info)
            }
        }
    }

    private func runUpdated(_ id: String, _ info: RunInfo) {
        guard let t = store.findTile(id)?.tile else { return }
        let name = info.workflow.trimmingCharacters(in: .whitespaces)
        if t.autoName != name || t.branch != info.branch {
            store.updateTile(id) { $0.autoName = name; $0.branch = info.branch.isEmpty ? nil : info.branch }
            reconcile()
        }
        guard t.state == .working else { return }
        if info.completed {
            runFinished(id, info)
        } else {
            let running = info.jobs.first(where: \.running)
            let msg = running.map { "\($0.name)" + ($0.currentStep.map { " · \($0.name)" } ?? "") } ?? "Queued"
            if t.statusMessage != msg { store.updateTile(id) { $0.statusMessage = msg }; reconcileIfCurrentBoard(id) }
        }
    }

    private func runFinished(_ id: String, _ info: RunInfo) {
        let label = "CI run \(info.id) (\(info.workflow.trimmingCharacters(in: .whitespaces)))"
        var detail = "\(info.title) · \(info.branch) · \(String(info.sha.prefix(7)))\n\(info.url)"
        guard info.failed else {
            wakeAgent(fromWait: id, ok: true, label: label, conclusion: info.conclusion ?? "success", detail: detail, took: info.duration)
            return
        }
        detail += "\nFailed jobs:\n" + info.failureSummary
        // The failing steps' logs are what the agent needs to fix it.
        guard let t = store.findTile(id)?.tile, let runID = t.target else { return }
        let args = ["run", "view", runID] + (t.runRepo.map { ["-R", $0] } ?? []) + ["--log-failed"]
        let dir = t.cwd ?? NSHomeDirectory()
        store.updateTile(id) { $0.statusMessage = "Failed · fetching logs" }
        DispatchQueue.global(qos: .utility).async {
            let log = Sessions.plain(GH.run(args, in: dir, timeout: 45) ?? "")
            let tail = log.split(separator: "\n", omittingEmptySubsequences: true).suffix(60)
                .map { line -> String in
                    // "job\tstep\t2026-…Z text": keep the step and the text.
                    let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
                    guard parts.count == 3 else { return String(line) }
                    let text = parts[2].replacingOccurrences(of: #"^\S+Z "#, with: "", options: .regularExpression)
                    return "[\(parts[1])] \(text)"
                }.joined(separator: "\n")
            DispatchQueue.main.async { [weak self] in
                if !tail.isEmpty { detail += "\nFailed step logs (tail):\n```\n\(tail)\n```" }
                self?.wakeAgent(fromWait: id, ok: false, label: label, conclusion: info.conclusion ?? "failure", detail: detail, took: info.duration)
            }
        }
    }

    private func reconcileIfCurrentBoard(_ id: String) {
        if store.findTile(id)?.board.id == store.currentBoardID { reconcile() }
    }

    /// A wait (command or run) finished: wake its agent with the result.
    /// Successful waits then close themselves; failures stay up to look at.
    func wakeAgent(fromWait id: String, ok: Bool, label: String, conclusion: String, detail: String, took: TimeInterval? = nil) {
        guard let t = store.findTile(id)?.tile else { return }
        let took = took ?? Date().timeIntervalSince(t.stateSince)
        setState(id, ok ? .done : .error, message: (ok ? "Succeeded" : "Failed · \(conclusion)") + " · " + took.clock)
        Timelines.shared.add(id, ok ? .done : .error, "\(label) \(ok ? "succeeded" : "failed (\(conclusion))")")
        guard let agent = agentTarget(for: id) else {
            model?.toast(.init(kind: ok ? .info : .error, title: "\(label) \(ok ? "succeeded" : "failed")", body: "No agent was linked to wake up.", tileID: id))
            return
        }
        var text = "Your wait on \(label) finished after \(took.clock): \(ok ? "SUCCESS" : "FAILED (\(conclusion))").\n\(detail)"
        if let n = t.waitNote { text += "\nWhat you planned to do next: \(n)" }
        if let err = sendMessage(from: id, to: agent, text: text) {
            model?.toast(.init(kind: .error, title: "Couldn't wake the agent", body: err, tileID: id))
            return
        }
        refreshBackground(agent)
        if ok {
            // Give it a moment on screen, then tidy up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                if self?.store.findTile(id)?.tile.state == .done { self?.closeTile(id) }
            }
        }
    }
}

// MARK: - Run tile

final class RunTileContent: NSView, TileContent {
    private let hostView: NSHostingView<RunView>
    private let host = FlippedView()
    private var zoom: CGFloat = 1
    override var isFlipped: Bool { true }

    init(tileID: String, controller: CanvasController) {
        hostView = NSHostingView(rootView: RunView(tileID: tileID, controller: controller))
        super.init(frame: .zero)
        addSubview(host)
        host.addSubview(hostView)
    }
    required init?(coder: NSCoder) { fatalError() }

    var focusTarget: NSView? { nil }
    func apply(zoom: CGFloat, live: Bool) { self.zoom = zoom; needsLayout = true }

    override func layout() {
        super.layout()
        host.frame = bounds
        let w = bounds.width / max(zoom, 0.01), h = bounds.height / max(zoom, 0.01)
        host.setBoundsSize(CGSize(width: w, height: h))
        hostView.frame = CGRect(x: 0, y: 0, width: w, height: h)
    }
}

struct RunView: View {
    let tileID: String
    weak var controller: CanvasController?
    @ObservedObject var runs = RunStore.shared
    @ObservedObject var store = Store.shared

    var body: some View {
        // Ticks once a second so elapsed times move between polls.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 12) {
                if let info = runs.infos[tileID] { content(info) } else { empty }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var tile: Tile? { store.findTile(tileID)?.tile }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let e = runs.errors[tileID] {
                Text(e).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Retry") { controller?.pollRun(tileID) }.controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
                Text("Loading run \(tile?.target ?? "")…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func content(_ r: RunInfo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            pill(r)
            Text(r.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
            Spacer(minLength: 0)
        }
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
            Text(r.branch).lineLimit(1)
            Text("·")
            Text(String(r.sha.prefix(7))).font(.system(size: 11, design: .monospaced))
            if !r.event.isEmpty { Text("·"); Text(r.event.replacingOccurrences(of: "_", with: " ")) }
            if r.attempt > 1 { Text("· attempt \(r.attempt)") }
            Spacer(minLength: 0)
            if let d = r.duration { Text(d.clock).font(.system(size: 11).monospacedDigit()) }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)

        let counted = r.countedJobs
        VStack(alignment: .leading, spacing: 5) {
            ProgressView(value: r.progress)
                .tint(Color(ns: r.failed || counted.contains(where: \.failed) ? Theme.red : (r.completed ? Theme.green : Theme.amber)))
            Text("\(counted.filter(\.done).count) of \(counted.count) jobs done"
                 + (counted.contains(where: \.failed) ? " · \(counted.filter(\.failed).count) failed" : ""))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }

        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(r.jobs.filter { !$0.skipped }.sorted { rank($0) < rank($1) }) { j in jobRow(j) }
                let skipped = r.jobs.filter(\.skipped).count
                if skipped > 0 {
                    Text("\(skipped) skipped").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        footer(r)
    }

    private func jobRow(_ j: RunInfo.Job) -> some View {
        HStack(alignment: .top, spacing: 8) {
            jobIcon(j).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(j.name).font(.system(size: 12, weight: j.running ? .semibold : .regular)).lineLimit(1)
                if (j.running || j.failed), let s = j.currentStep {
                    let total = j.steps.count
                    Text((j.failed ? "Failed at " : "Step \(s.number)/\(total) · ") + s.name)
                        .font(.system(size: 11)).lineLimit(1)
                        .foregroundStyle(j.failed ? Color(ns: Theme.red) : .secondary)
                }
            }
            Spacer(minLength: 0)
            if let d = j.duration { Text(d.clock).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary) }
            if let u = j.url, let url = URL(string: u) {
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Open job on GitHub")
            }
        }
    }

    @ViewBuilder
    private func footer(_ r: RunInfo) -> some View {
        Divider()
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: tile?.state == .working ? "bell.badge" : "bell")
                .foregroundStyle(.secondary).font(.system(size: 11))
            Text(wakeLine).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
            Button("Open on GitHub") { if let u = URL(string: r.url) { NSWorkspace.shared.open(u) } }
                .controlSize(.small)
        }
    }

    private var wakeLine: String {
        guard let t = tile else { return "" }
        let agent = controller?.agentTarget(for: tileID).flatMap { store.findTile($0)?.tile.displayName } ?? "the agent"
        switch t.state {
        case .working: return "Wakes \(agent) when it finishes" + (t.waitNote.map { ": \($0)" } ?? "")
        case .done: return "Sent the result to \(agent) · closing"
        case .error: return "Sent the failure to \(agent)"
        default: return ""
        }
    }

    private func rank(_ j: RunInfo.Job) -> Int { j.failed ? 0 : (j.running ? 1 : (j.done ? 3 : 2)) }

    @ViewBuilder
    private func jobIcon(_ j: RunInfo.Job) -> some View {
        if j.failed { Image(systemName: "xmark.circle.fill").foregroundStyle(Color(ns: Theme.red)) }
        else if j.running { ProgressView().controlSize(.mini).scaleEffect(0.8) }
        else if j.done { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(ns: Theme.green)) }
        else { Image(systemName: "circle.dotted").foregroundStyle(.secondary) }
    }

    private func pill(_ r: RunInfo) -> some View {
        let (text, color): (String, NSColor) = {
            if !r.completed { return (r.status == "in_progress" ? "Running" : "Queued", Theme.amber) }
            if r.succeeded { return ("Succeeded", Theme.green) }
            if r.conclusion == "cancelled" { return ("Cancelled", Theme.text3) }
            return ("Failed", Theme.red)
        }()
        return Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Color(ns: color)))
    }
}
