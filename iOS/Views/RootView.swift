import SwiftUI

struct RootView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var tab = Self.debugArg("--tab").flatMap(Int.init) ?? 0
    @State private var newAgent = false
    @State private var agentPath: [RAgent] = []

    /// DEBUG test hooks (--tab N, --agent <tile id>); nil in release builds.
    static func debugArg(_ name: String) -> String? {
        #if DEBUG
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
        #endif
        return nil
    }

    var body: some View {
        if client.paired == nil {
            PairView()
        } else {
            TabView(selection: $tab) {
                Tab("Inbox", systemImage: "tray.full", value: 0) {
                    NavigationStack { InboxScreen() }
                }
                .badge(client.badge)
                Tab("Agents", systemImage: "square.grid.2x2", value: 1) {
                    NavigationStack(path: $agentPath) { AgentsScreen(newAgent: $newAgent) }
                }
                Tab("Settings", systemImage: "gearshape", value: 2) {
                    NavigationStack { SettingsScreen() }
                }
            }
            .sheet(isPresented: $newAgent) { NewAgentSheet() }
            .onChange(of: client.boards) { _, _ in
                if agentPath.isEmpty, let id = Self.debugArg("--agent"), let a = client.agents.first(where: { $0.id == id }) {
                    agentPath = [a]
                }
            }
        }
    }
}

/// Connection status shown at the top of each screen.
struct ConnectionBanner: View {
    @EnvironmentObject var client: RemoteClient
    var body: some View {
        switch client.phase {
        case .connected, .unpaired:
            EmptyView()
        case .connecting:
            banner(icon: "antenna.radiowaves.left.and.right", text: "Connecting to \(client.macName)…", color: .secondary)
        case .offline(let msg):
            banner(icon: "wifi.exclamationmark", text: msg, color: .pwAmber)
        }
    }

    private func banner(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(text).font(.footnote).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if case .offline = client.phase {
                Button("Retry") { client.connect() }.font(.footnote.weight(.semibold))
            }
        }
        .foregroundStyle(color)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct StatusDot: View {
    let state: String
    var size: CGFloat = 9
    var body: some View {
        Circle().fill(Color.state(state)).frame(width: size, height: size)
            .overlay(Circle().stroke(Color.state(state).opacity(state == "working" ? 0.25 : 0), lineWidth: 3).frame(width: size + 4, height: size + 4))
    }
}

/// A white (or dark) rounded card like the Mac's tiles.
struct CardBackground: ViewModifier {
    var attention = false
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(Color.pwCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(attention ? Color.pwAmber : Color.primary.opacity(0.07), lineWidth: attention ? 1.5 : 1))
            .shadow(color: attention ? Color.pwAmber.opacity(0.25) : .black.opacity(0.08), radius: attention ? 10 : 12, y: 6)
    }
}

extension View {
    func card(attention: Bool = false) -> some View { modifier(CardBackground(attention: attention)) }
}
