import SwiftUI

// MARK: - Inbox

struct InboxScreen: View {
    @EnvironmentObject var client: RemoteClient

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ConnectionBanner()
                let pendingTiles = Set(client.approvals.map(\.tile))
                let waiting = client.agents.filter { $0.state == "waiting" && !pendingTiles.contains($0.id) }
                let finished = client.agents.filter { $0.state == "done" || $0.state == "error" }

                if client.approvals.isEmpty && waiting.isEmpty && finished.isEmpty {
                    EmptyInbox()
                }
                if !client.approvals.isEmpty {
                    SectionTitle("Approvals")
                    ForEach(client.approvals) { ApprovalCard(approval: $0) }
                }
                if !waiting.isEmpty {
                    SectionTitle("Needs you")
                    ForEach(waiting) { a in NavigationLink(value: a) { AgentCard(agent: a) }.buttonStyle(.plain) }
                }
                if !finished.isEmpty {
                    SectionTitle("Finished")
                    ForEach(finished) { a in NavigationLink(value: a) { AgentCard(agent: a) }.buttonStyle(.plain) }
                }
            }
            .padding(16)
        }
        .background(CanvasBackground())
        .navigationTitle("Inbox")
        .navigationDestination(for: RAgent.self) { AgentDetail(agentID: $0.id) }
        .refreshable { client.connect() }
    }
}

struct SectionTitle: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8).padding(.leading, 4)
    }
}

struct EmptyInbox: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle").font(.system(size: 40)).foregroundStyle(Color.pwGreen)
            Text("Nothing needs you").font(.headline)
            Text("Approvals, questions and finished agents show up here.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 80)
    }
}

struct ApprovalCard: View {
    @EnvironmentObject var client: RemoteClient
    let approval: RApproval
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusDot(state: "waiting")
                Text(approval.tileName).font(.headline).lineLimit(1)
                Spacer()
                Text(approval.at.elapsedShort).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text("\(approval.board) · wants to use \(approval.tool)").font(.caption).foregroundStyle(.secondary)
            Text(approval.summary)
                .font(.system(.callout, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            if let d = approval.detail { Text(d).font(.footnote).foregroundStyle(.secondary) }
            if let error { Text(error).font(.footnote).foregroundStyle(Color.pwRed) }
            HStack(spacing: 8) {
                PillButton(title: "Allow", style: .amber, busy: busy) { decide("allow") }
                if approval.canAlways { PillButton(title: "Always", style: .plain, busy: busy) { decide("always") } }
                PillButton(title: "Deny", style: .plain, busy: busy) { decide("deny") }
            }
        }
        .card(attention: true)
    }

    private func decide(_ d: String) {
        busy = true
        let gen = UINotificationFeedbackGenerator()
        Task {
            do { try await client.decide(approval, d); gen.notificationOccurred(.success) }
            catch { self.error = error.localizedDescription; gen.notificationOccurred(.error) }
            busy = false
        }
    }
}

struct PillButton: View {
    enum Style { case amber, dark, plain }
    let title: String
    var style: Style = .plain
    var busy = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(style == .amber ? Color(red: 0.1, green: 0.07, blue: 0.02) : (style == .dark ? Color(uiColor: .systemBackground) : .primary))
                .background(Capsule().fill(style == .amber ? Color.pwAmber : (style == .dark ? Color.primary : Color.primary.opacity(0.08))))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .opacity(busy ? 0.6 : 1)
    }
}

// MARK: - Agents

struct AgentsScreen: View {
    @EnvironmentObject var client: RemoteClient
    @Binding var newAgent: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ConnectionBanner()
                ForEach(client.boards) { b in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 4).fill(Color.boardColors[b.color % Color.boardColors.count]).frame(width: 12, height: 12)
                        Text(b.name).font(.headline)
                        Spacer()
                        let cost = b.agents.compactMap(\.cost).reduce(0, +)
                        if cost >= 0.01 { Text(String(format: "$%.2f", cost)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                    .padding(.top, 10).padding(.horizontal, 4)
                    if b.agents.isEmpty {
                        Text("No tiles on this board.").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
                    }
                    ForEach(b.agents.sorted(by: Self.order)) { a in
                        NavigationLink(value: a) { AgentCard(agent: a) }.buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
        .background(CanvasBackground())
        .navigationTitle(client.macName.isEmpty ? "Agents" : client.macName)
        .navigationDestination(for: RAgent.self) { AgentDetail(agentID: $0.id) }
        .toolbar {
            Button { newAgent = true } label: { Image(systemName: "plus") }
                .accessibilityLabel("New agent")
        }
    }

    static func order(_ a: RAgent, _ b: RAgent) -> Bool {
        let p = ["waiting": 0, "error": 1, "done": 2, "working": 3, "idle": 4]
        return (p[a.state] ?? 5, b.since) < (p[b.state] ?? 5, a.since)
    }
}

struct AgentCard: View {
    let agent: RAgent
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusDot(state: agent.state)
                Text(agent.name).font(.headline).lineLimit(1)
                Spacer()
                if agent.state != "idle" {
                    Text(agent.since.elapsedShort).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            if let m = agent.message ?? agent.task, !m.isEmpty {
                Text(m).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 10) {
                if let b = agent.branch { Label(b, systemImage: "arrow.triangle.branch").lineLimit(1) }
                if let a = agent.added, a > 0 { Text("+\(a)").foregroundStyle(Color.pwGreen) }
                if let r = agent.removed, r > 0 { Text("−\(r)").foregroundStyle(Color.pwRed) }
                Spacer()
                if let c = agent.cost, c >= 0.01 { Text(String(format: "$%.2f", c)) }
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .card(attention: agent.needsYou)
    }
}

// MARK: - Agent detail

struct AgentDetail: View {
    @EnvironmentObject var client: RemoteClient
    let agentID: String
    @State private var view = 0
    @State private var draft = ""
    @State private var timeline: [RTimelineEvent] = []
    @State private var sending = false
    @State private var note: String?
    @FocusState private var composing: Bool

    private var agent: RAgent? { client.agents.first { $0.id == agentID } }

    var body: some View {
        if let agent {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ConnectionBanner()
                    header(agent)
                    if let a = client.approvals.first(where: { $0.tile == agent.id }) { ApprovalCard(approval: a) }
                    Picker("", selection: $view) {
                        if agent.terminal { Text("Terminal").tag(0) }
                        Text("Timeline").tag(1)
                    }
                    .pickerStyle(.segmented)
                    if view == 0 && agent.terminal {
                        TerminalPanel(agent: agent)
                    } else {
                        TimelineList(events: timeline)
                    }
                }
                .padding(16)
                .padding(.bottom, 80)
            }
            .background(CanvasBackground())
            .navigationTitle(agent.name)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { composer(agent) }
            .task(id: view) {
                if !agent.terminal { view = 1 }
                if view == 1 { timeline = (try? await client.timeline(agent)) ?? [] }
            }
            .onDisappear { client.closeTerminal(agent) }
        } else {
            ContentUnavailableView("This tile was closed", systemImage: "xmark.square")
        }
    }

    private func header(_ a: RAgent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusDot(state: a.state, size: 10)
                Text(label(a.state)).font(.subheadline.weight(.semibold)).foregroundStyle(Color.state(a.state))
                Text("· \(a.since.elapsedShort)").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(a.boardName).font(.caption).foregroundStyle(.secondary)
            }
            // The approval card below already shows what it wants to run.
            if !client.approvals.contains(where: { $0.tile == a.id }), let m = a.message ?? a.task, !m.isEmpty {
                Text(m).font(.callout)
            }
            HStack(spacing: 6) {
                if let b = a.branch { Chip(text: b, icon: "arrow.triangle.branch") }
                if let c = a.cost, c >= 0.01 { Chip(text: String(format: "$%.2f", c), icon: "dollarsign.circle") }
                if let ctx = a.context { Chip(text: "\(ctx)% context", icon: "gauge.with.dots.needle.33percent") }
                if let m = a.model { Chip(text: m, icon: "sparkle") }
            }
        }
        .card(attention: a.needsYou)
    }

    private func label(_ s: String) -> String {
        ["working": "Working", "waiting": "Needs you", "done": "Done", "error": "Error"][s] ?? "Idle"
    }

    private func composer(_ a: RAgent) -> some View {
        VStack(spacing: 6) {
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message \(a.name)…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($composing)
                    .padding(.vertical, 10)
                Button {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    sending = true
                    Task {
                        let r = try? await client.message(a, text)
                        note = r == "queued" ? "Queued: \(a.name) gets it when it finishes its current turn." : (r == nil ? "Couldn't send." : "Sent.")
                        if r != nil { draft = "" }
                        sending = false
                    }
                } label: {
                    Image(systemName: "arrow.up").font(.body.weight(.bold))
                        .frame(width: 38, height: 38)
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .background(Circle().fill(Color.primary))
                }
                .disabled(sending || draft.isEmpty)
                .accessibilityLabel("Send")
            }
            .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .padding(.horizontal, 12).padding(.bottom, 6)
    }
}

struct Chip: View {
    let text: String
    let icon: String
    var body: some View {
        Label(text, systemImage: icon).font(.caption).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

struct TerminalPanel: View {
    @EnvironmentObject var client: RemoteClient
    let agent: RAgent
    @State private var model: TerminalModel?

    var body: some View {
        GeometryReader { geo in
            if let model {
                TerminalScreenSized(model: model, width: geo.size.width)
            }
        }
        .frame(height: model.map { TerminalCanvas.height(for: $0.frame, width: UIScreen.main.bounds.width - 52) } ?? 300)
        .padding(10)
        .background(Color.pwTerminal, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        .overlay(alignment: .topTrailing) {
            Label("Live · read-only", systemImage: "eye").font(.caption2.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(8)
        }
        .onAppear { model = client.terminal(for: agent) }
    }
}

private struct TerminalScreenSized: View {
    @ObservedObject var model: TerminalModel
    let width: CGFloat
    var body: some View {
        TerminalScreen(model: model).frame(width: width, height: TerminalCanvas.height(for: model.frame, width: width))
    }
}

struct TimelineList: View {
    let events: [RTimelineEvent]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if events.isEmpty {
                Text("Nothing yet. Prompts, tool calls and approvals appear here.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.vertical, 20)
            }
            ForEach(events) { e in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Circle().fill(color(e.kind)).frame(width: 9, height: 9).padding(.top, 5)
                        Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.text).font(e.kind == "tool" || e.kind == "permission" ? .system(.footnote, design: .monospaced) : .subheadline)
                        Text(e.at.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 14)
                }
            }
        }
        .card()
    }

    private func color(_ k: String) -> Color {
        switch k {
        case "permission", "notification": return .pwAmber
        case "approved", "done": return .pwGreen
        case "denied", "error": return .pwRed
        case "message", "subagent": return .pwBlue
        default: return .pwIdle
        }
    }
}

// MARK: - New agent

struct NewAgentSheet: View {
    @EnvironmentObject var client: RemoteClient
    @Environment(\.dismiss) private var dismiss
    @State private var task = ""
    @State private var board = ""
    @State private var worktree = true
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What should the agent work on?", text: $task, axis: .vertical).lineLimit(4...10)
                }
                Section {
                    Picker("Board", selection: $board) {
                        ForEach(client.boards) { Text($0.name).tag($0.id) }
                    }
                    Toggle("Own worktree", isOn: $worktree)
                } footer: {
                    Text("Starts Claude Code on your Mac. With its own worktree, it works on a separate branch so it can't collide with other agents.")
                }
                if let error { Text(error).foregroundStyle(Color.pwRed) }
            }
            .navigationTitle("New agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        busy = true
                        Task {
                            do { try await client.newAgent(board: board, task: task, worktree: worktree); dismiss() }
                            catch { self.error = error.localizedDescription }
                            busy = false
                        }
                    }
                    .disabled(task.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
            }
            .onAppear { board = client.boards.first?.id ?? "" }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Settings

struct SettingsScreen: View {
    @EnvironmentObject var client: RemoteClient
    @State private var confirmUnpair = false

    var body: some View {
        Form {
            Section("This iPhone") {
                TextField("Name", text: $client.deviceName)
            }
            Section("Mac") {
                LabeledContent("Paired with", value: client.macName)
                LabeledContent("Status") {
                    switch client.phase {
                    case .connected: Text("Connected").foregroundStyle(Color.pwGreen)
                    case .connecting: Text("Connecting…")
                    case .offline: Text("Offline").foregroundStyle(Color.pwAmber)
                    case .unpaired: Text("Not paired")
                    }
                }
                Button("Unpair", role: .destructive) { confirmUnpair = true }
            }
            Section {
                Label("End-to-end encrypted", systemImage: "lock.fill")
                Text("Everything between this iPhone and your Mac is encrypted with keys that never leave the two devices. Approvals are signed by this iPhone.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Unpair from \(client.macName)?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { client.unpair() }
        } message: {
            Text("You'll need to scan a new pairing code to connect again. Also remove this iPhone in Pitwall › Settings on your Mac.")
        }
    }
}
