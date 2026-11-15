import AppKit
import SwiftUI
import Darwin

/// Dev Mode: a small HUD in the bottom-right corner with frame rate, app
/// cost and canvas/agent counters. Off by default; toggled from View ›
/// Dev Mode (⌥⌘D), Settings › Canvas, `pitwall ui devmode on|off`, or
/// forced on with PITWALL_DEV=1.
///
/// The HUD samples on a display link while it's visible and publishes twice
/// a second, so it only re-renders itself and never the other overlays.
final class DevStats: ObservableObject {
    // Counters bumped from hot paths. Plain integers: free when the HUD is off.
    static var layoutPasses = 0
    static var liveLayoutPasses = 0
    static var hookEvents = 0
    static var lastHook: (event: String, at: Date)?
    static var pollMillis: Double = 0
    static var daemonSessions = 0

    struct Snapshot {
        var fps: Double = 0
        var refreshHz: Double = 0
        var worstFrameMs: Double = 0
        var hitches = 0
        var layoutsPerSec: Double = 0
        var liveLayoutsPerSec: Double = 0
        var cpu: Double = 0
        var memoryMB: Double = 0
        var threads = 0
        var tiles = 0
        var visibleTiles = 0
        var liveTerminals = 0
        var frames = 0
        var links = 0
        var boards = 0
        var agents: [AgentState: Int] = [:]
        var hookedTiles = 0
        var hooksPerMin: Double = 0
        var lastHook = "—"
        var pendingApprovals = 0
        var daemonSessions = 0
        var pollMs: Double = 0
        var zoom: Double = 1
        var origin: CGPoint = .zero
        var focused = "—"
    }

    @Published private(set) var snap = Snapshot()
    /// Recent FPS samples for the sparkline (one per publish, ~30 s).
    @Published private(set) var history: [Double] = []

    weak var controller: CanvasController?
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var windowStart: CFTimeInterval = 0
    private var frameCount = 0
    private var worstGap: CFTimeInterval = 0
    private var hitchCount = 0
    private var expected: CFTimeInterval = 1.0 / 60
    private var layoutsAtStart = 0
    private var liveLayoutsAtStart = 0
    private var cpuAtStart: Double = 0
    private var hookTimes: [Date] = []
    private var hooksSeen = 0
    /// Window creation and first layout always stall; don't count them.
    private var warmupUntil: CFTimeInterval = 0

    var running: Bool { link != nil }

    func start(on view: NSView) {
        guard link == nil else { return }
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        resetWindow(CACurrentMediaTime())
        lastTick = 0
        warmupUntil = CACurrentMediaTime() + 1
        snap.hitches = 0
        hooksSeen = Self.hookEvents
    }

    func stop() {
        link?.invalidate()
        link = nil
        history.removeAll()
    }

    private func resetWindow(_ now: CFTimeInterval) {
        windowStart = now
        frameCount = 0
        worstGap = 0
        hitchCount = 0
        layoutsAtStart = Self.layoutPasses
        liveLayoutsAtStart = Self.liveLayoutPasses
        cpuAtStart = Self.cpuSeconds()
    }

    /// Fires once per display refresh on the main thread. A late or missing
    /// tick means the main thread was busy and the canvas couldn't draw.
    @objc private func tick(_ l: CADisplayLink) {
        let now = l.timestamp
        let d = l.targetTimestamp - l.timestamp
        if d > 0.001 { expected = d }
        if lastTick > 0 {
            let gap = now - lastTick
            worstGap = max(worstGap, gap)
            if gap > expected * 1.5 && now > warmupUntil { hitchCount += 1 }
        }
        lastTick = now
        frameCount += 1
        let elapsed = now - windowStart
        if elapsed >= 0.5 { publish(elapsed: elapsed, now: now) }
    }

    private func publish(elapsed: CFTimeInterval, now: CFTimeInterval) {
        var s = Snapshot()
        s.fps = Double(frameCount) / elapsed
        s.refreshHz = 1 / expected
        s.worstFrameMs = worstGap * 1000
        s.hitches = hitchCount + (snap.hitches) // cumulative since shown
        s.layoutsPerSec = Double(Self.layoutPasses - layoutsAtStart) / elapsed
        s.liveLayoutsPerSec = Double(Self.liveLayoutPasses - liveLayoutsAtStart) / elapsed
        s.cpu = (Self.cpuSeconds() - cpuAtStart) / elapsed * 100
        s.memoryMB = Self.footprintMB()
        s.threads = Self.threadCount()

        let date = Date()
        let newHooks = Self.hookEvents - hooksSeen
        hooksSeen = Self.hookEvents
        if newHooks > 0 { hookTimes.append(contentsOf: Array(repeating: date, count: min(newHooks, 500))) }
        hookTimes.removeAll { date.timeIntervalSince($0) > 60 }
        s.hooksPerMin = Double(hookTimes.count)
        if let h = Self.lastHook { s.lastHook = "\(h.event) · \(Self.ago(h.at, date))" }
        s.pollMs = Self.pollMillis
        s.daemonSessions = Self.daemonSessions
        s.pendingApprovals = ApprovalCenter.shared.pending.count

        let store = Store.shared
        s.boards = store.boards.count
        if let c = controller {
            let b = c.board
            s.tiles = b.tiles.count
            s.frames = b.frames.count
            s.links = b.links.count
            for t in b.tiles {
                guard let v = c.tileView(t.id), !v.isHidden else { continue }
                s.visibleTiles += 1
                if t.isTerminalBacked { s.liveTerminals += 1 }
            }
            for t in b.tiles where t.kind == .agent { s.agents[t.state, default: 0] += 1 }
            s.hookedTiles = c.hookedTiles.count
            s.zoom = c.canvas.viewport.zoom
            s.origin = c.canvas.viewport.origin
            if let id = c.focusedTileID, let t = b.tiles.first(where: { $0.id == id }) { s.focused = t.displayName }
        }
        snap = s
        history.append(s.fps)
        if history.count > 60 { history.removeFirst(history.count - 60) }
        resetWindow(now)
    }

    func resetHitches() { snap.hitches = 0 }

    // MARK: Process stats

    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(u.ru_utime) + s(u.ru_stime)
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    static func threadCount() -> Int {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return 0 }
        for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[i]) }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        return Int(count)
    }

    static func ago(_ d: Date, _ now: Date) -> String {
        let s = Int(now.timeIntervalSince(d))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }

    static let buildInfo: String = {
        let i = Bundle.main.infoDictionary ?? [:]
        let v = i["CFBundleShortVersionString"] as? String ?? "?"
        let b = i["CFBundleVersion"] as? String ?? "?"
        #if DEBUG
        let cfg = "Debug"
        #else
        let cfg = "Release"
        #endif
        return "v\(v) (\(b)) · \(cfg) · pid \(getpid())"
    }()

    static let home: String = {
        if let h = ProcessInfo.processInfo.environment["PITWALL_HOME"], !h.isEmpty {
            return (h as NSString).abbreviatingWithTildeInPath
        }
        return "default"
    }()
}

// MARK: - HUD

struct DevHUD: View {
    @ObservedObject var stats: DevStats
    @AppStorage("devHUDCollapsed", store: .pitwall) private var collapsed = false

    private var s: DevStats.Snapshot { stats.snap }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !collapsed {
                Sparkline(values: stats.history, ceiling: max(60, s.refreshHz))
                    .frame(height: 26)
                group("Frame") {
                    row("Worst frame", String(format: "%.1f ms", s.worstFrameMs), warn: s.worstFrameMs > 1000 / max(s.refreshHz, 1) * 2)
                    row("Hitches", "\(s.hitches)", warn: s.hitches > 0, action: stats.resetHitches)
                    row("Layout/s", String(format: "%.0f (%.0f live)", s.layoutsPerSec, s.liveLayoutsPerSec))
                }
                group("Process") {
                    row("CPU", String(format: "%.0f%%", s.cpu), warn: s.cpu > 80)
                    row("Memory", String(format: "%.0f MB", s.memoryMB))
                    row("Threads", "\(s.threads)")
                }
                group("Canvas") {
                    row("Zoom", String(format: "%.0f%%  (%.0f, %.0f)", s.zoom * 100, s.origin.x, s.origin.y))
                    row("Tiles", "\(s.visibleTiles)/\(s.tiles) visible · \(s.liveTerminals) term")
                    row("Frames · links", "\(s.frames) · \(s.links)")
                    row("Boards", "\(s.boards)")
                    row("Focused", s.focused)
                }
                group("Agents") {
                    row("States", agentSummary)
                    row("Hooked", "\(s.hookedTiles) · \(Int(s.hooksPerMin))/min")
                    row("Last hook", s.lastHook)
                    row("Approvals", "\(s.pendingApprovals) pending", warn: s.pendingApprovals > 0)
                    row("Daemon", String(format: "%d sessions · poll %.0f ms", s.daemonSessions, s.pollMs))
                }
                Text("\(DevStats.buildInfo)\nhome: \(DevStats.home)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: collapsed ? nil : 268, alignment: .leading)
        .pitwallGlass(cornerRadius: 16)
        .font(.system(size: 11).monospacedDigit())
    }

    private var header: some View {
        Button { collapsed.toggle() } label: {
            HStack(spacing: 8) {
                Circle().fill(fpsColor).frame(width: 7, height: 7)
                Text(String(format: "%.0f fps", s.fps))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                if !collapsed {
                    Text(String(format: "/ %.0f Hz", s.refreshHz)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text("DEV").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                }
                Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show details" : "Collapse")
    }

    private var fpsColor: Color {
        let ratio = s.refreshHz > 0 ? s.fps / s.refreshHz : 1
        if ratio > 0.9 { return .green }
        if ratio > 0.6 { return Color(ns: Theme.amber) }
        return .red
    }

    private var agentSummary: String {
        let order: [AgentState] = [.working, .waiting, .done, .error, .idle]
        let parts = order.compactMap { st in s.agents[st].map { "\($0) \(st.rawValue)" } }
        return parts.isEmpty ? "none" : parts.joined(separator: " · ")
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            content()
        }
    }

    private func row(_ k: String, _ v: String, warn: Bool = false, action: (() -> Void)? = nil) -> some View {
        HStack(spacing: 6) {
            Text(k).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(v)
                .foregroundStyle(warn ? Color(ns: Theme.amberText) : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .onTapGesture { action?() }
        .help(action != nil ? "Click to reset" : "")
    }
}

private struct Sparkline: View {
    let values: [Double]
    let ceiling: Double

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let n = 60
            let step = w / CGFloat(n - 1)
            let off = n - values.count
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05))
                // 60 fps guide.
                Path { p in
                    let y = h - CGFloat(min(60, ceiling) / ceiling) * h
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                }
                .stroke(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                Path { p in
                    for (i, v) in values.enumerated() {
                        let pt = CGPoint(x: CGFloat(i + off) * step, y: h - CGFloat(min(v, ceiling) / ceiling) * (h - 2) - 1)
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                }
                .stroke(Color.green.opacity(0.85), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
            }
        }
    }
}
