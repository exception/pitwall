import SwiftUI
import AppKit

/// Everything that needs the user, across all boards (⌘I).
struct InboxView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var approvals = ApprovalCenter.shared
    private var selection: String? { model.inboxSelection }

    enum ItemKind { case approval(ApprovalCenter.Pending), waiting, done, error }
    struct Item: Identifiable {
        let id: String
        let kind: ItemKind
        let tile: Tile
        let board: Board
    }

    static func items(model: AppModel) -> [Item] {
        var out: [Item] = []
        for p in ApprovalCenter.shared.pending {
            if let (b, t) = model.store.findTile(p.tileID) { out.append(Item(id: "a-" + p.id, kind: .approval(p), tile: t, board: b)) }
        }
        let pendingTiles = Set(ApprovalCenter.shared.pending.map(\.tileID))
        for b in model.store.boards {
            for t in b.tiles where t.kind != .subagent && !pendingTiles.contains(t.id) {
                switch t.state {
                case .waiting: out.append(Item(id: "w-" + t.id, kind: .waiting, tile: t, board: b))
                case .error: out.append(Item(id: "e-" + t.id, kind: .error, tile: t, board: b))
                case .done: out.append(Item(id: "d-" + t.id, kind: .done, tile: t, board: b))
                default: break
                }
            }
        }
        return out
    }

    var body: some View {
        let list = Self.items(model: model)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Inbox").font(.system(size: 15, weight: .bold))
                if !list.isEmpty {
                    Text("\(list.count)").font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                Spacer()
                Button { model.inboxOpen = false } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Close inbox")
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            if list.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.system(size: 28)).foregroundStyle(Color(ns: Theme.green))
                    Text("Nothing needs you").font(.system(size: 13, weight: .semibold))
                    Text("Approvals, questions and finished agents show up here.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 36)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(list) { item in
                                InboxRow(item: item, selected: selection == item.id, model: model)
                                    .id(item.id)
                                    .onTapGesture { model.inboxSelection = item.id }
                            }
                        }
                        .padding(.horizontal, 10).padding(.bottom, 10)
                    }
                    .onChange(of: selection) { s in if let s { withAnimation { proxy.scrollTo(s) } } }
                }
                Text("↑↓ select · A allow · ⇧A always · D deny · ↩ go to")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
        }
        .frame(width: 380)
        .frame(maxHeight: 560)
        .pitwallGlass(cornerRadius: 20)
        .onAppear { if model.inboxSelection == nil { model.inboxSelection = list.first?.id } }
    }

    /// Keyboard handling for the open Inbox (driven by a window key monitor).
    /// Returns true if the key was used.
    static func handleKey(_ e: NSEvent, model: AppModel) -> Bool {
        let list = items(model: model)
        let ids = list.map(\.id)
        // Nothing (or something stale) selected: act on the top item.
        if model.inboxSelection.flatMap({ ids.firstIndex(of: $0) }) == nil { model.inboxSelection = ids.first }
        let i = model.inboxSelection.flatMap { ids.firstIndex(of: $0) } ?? -1
        switch e.keyCode {
        case 125: model.inboxSelection = ids.isEmpty ? nil : ids[min(i + 1, ids.count - 1)]; return true   // ↓
        case 126: model.inboxSelection = ids.isEmpty ? nil : ids[max(i - 1, 0)]; return true               // ↑
        case 36: if let it = list.first(where: { $0.id == model.inboxSelection }) { model.goTo(tileID: it.tile.id) }; return true // ↩
        case 53: model.inboxOpen = false; return true                                                      // esc
        default: break
        }
        guard e.modifierFlags.isDisjoint(with: [.command, .control, .option]),
              let c = e.charactersIgnoringModifiers?.lowercased(), c == "a" || c == "d",
              let it = list.first(where: { $0.id == model.inboxSelection }), case .approval(let p) = it.kind else { return false }
        let next = list.firstIndex { $0.id == it.id }.flatMap { list.indices.contains($0 + 1) ? list[$0 + 1].id : nil }
        if c == "d" { ApprovalCenter.shared.decide(p.id, .deny) }
        else if e.modifierFlags.contains(.shift) && p.canAlwaysAllow { ApprovalCenter.shared.decide(p.id, .allowAlways) }
        else { ApprovalCenter.shared.decide(p.id, .allow) }
        model.inboxSelection = next
        return true
    }
}

private struct InboxRow: View {
    let item: InboxView.Item
    let selected: Bool
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(item.tile.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Text(item.tile.stateSince.elapsedShort).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(Color(ns: Theme.boardColors[item.board.colorIndex % Theme.boardColors.count])).frame(width: 8, height: 8)
                Text(item.board.name).font(.system(size: 11)).foregroundStyle(.secondary)
                Text("· " + label).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            switch item.kind {
            case .approval(let p):
                Text(p.summary)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(4)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                if let d = p.detail { Text(d).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
                HStack(spacing: 6) {
                    InboxButton(title: "Allow", style: .accent) { ApprovalCenter.shared.decide(p.id, .allow) }
                    if p.canAlwaysAllow { InboxButton(title: "Always", style: .plain) { ApprovalCenter.shared.decide(p.id, .allowAlways) } }
                    InboxButton(title: "Deny", style: .plain) { ApprovalCenter.shared.decide(p.id, .deny) }
                    InboxButton(title: "Go to", style: .plain) { model.goTo(tileID: item.tile.id) }
                }
            default:
                if let m = item.tile.statusMessage, !m.isEmpty {
                    Text(m).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                }
                HStack(spacing: 6) {
                    InboxButton(title: "Go to", style: .primary) { model.goTo(tileID: item.tile.id) }
                    if case .done = item.kind {
                        InboxButton(title: "Mark seen", style: .plain) { model.controller?.setState(item.tile.id, .idle) }
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(selected ? Color.primary.opacity(0.08) : Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(selected ? Color(ns: Theme.amber).opacity(0.6) : Color.primary.opacity(0.06)))
        .contentShape(Rectangle())
    }

    private var color: Color {
        switch item.kind {
        case .approval, .waiting: return Color(ns: Theme.amber)
        case .done: return Color(ns: Theme.blue)
        case .error: return Color(ns: Theme.red)
        }
    }

    private var label: String {
        switch item.kind {
        case .approval(let p): return "Wants to use \(p.tool)"
        case .waiting: return "Needs you"
        case .done: return "Finished"
        case .error: return "Error"
        }
    }
}

private struct InboxButton: View {
    enum Style { case accent, primary, plain }
    let title: String
    let style: Style
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: style == .plain ? .medium : .semibold))
                .padding(.horizontal, 12).frame(height: 28)
                .foregroundStyle(style == .accent ? Color(red: 0.1, green: 0.07, blue: 0.02) : (style == .primary ? Color(nsColor: .windowBackgroundColor) : .primary))
                .background(Capsule().fill(style == .accent ? Color(ns: Theme.amber) : (style == .primary ? Color.primary : Color.primary.opacity(0.08))))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A tile's timeline: prompts, tool calls, approvals, messages.
struct TimelineView_: View {
    let tileID: String
    var height: CGFloat = 420
    @ObservedObject var timelines = Timelines.shared

    var body: some View {
        let events = (timelines.events[tileID] ?? []).reversed()
        VStack(alignment: .leading, spacing: 0) {
            Text("Timeline").font(.system(size: 13, weight: .semibold)).padding(.bottom, 8)
            if events.isEmpty {
                Text("Nothing yet. Prompts, tool calls and approvals appear here.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(events)) { e in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(spacing: 0) {
                                Image(systemName: icon(e.kind)).font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(tint(e.kind))
                                    .frame(width: 20, height: 20)
                                    .background(Circle().fill(tint(e.kind).opacity(0.15)))
                                Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1).frame(maxHeight: .infinity)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.text).font(.system(size: 12, design: e.kind == .tool || e.kind == .permission ? .monospaced : .default))
                                    .lineLimit(4)
                                Text(e.at.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            .padding(.bottom, 10)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 380, height: height)
        .onAppear { timelines.load(tileID) }
    }

    private func icon(_ k: TimelineEvent.Kind) -> String {
        switch k {
        case .prompt: return "text.bubble"
        case .tool: return "wrench.and.screwdriver"
        case .permission: return "hand.raised"
        case .approved: return "checkmark"
        case .denied: return "xmark"
        case .notification: return "bell"
        case .message: return "arrow.left.arrow.right"
        case .done: return "flag.checkered"
        case .error: return "exclamationmark.triangle"
        case .subagent: return "person.2"
        }
    }

    private func tint(_ k: TimelineEvent.Kind) -> Color {
        switch k {
        case .permission, .notification: return Color(ns: Theme.amber)
        case .approved, .done: return Color(ns: Theme.green)
        case .denied, .error: return Color(ns: Theme.red)
        case .message, .subagent: return Color(ns: Theme.blue)
        default: return .secondary
        }
    }
}
