import SwiftUI

@main
struct PitwallRemoteApp: App {
    @StateObject private var client = RemoteClient()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(client)
                .tint(Color.pwAmber)
                .onOpenURL { url in
                    Task { try? await client.pair(with: url) }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { client.connect() }
                }
                .task {
                    #if DEBUG
                    // Test hooks: --pair <url>
                    let args = ProcessInfo.processInfo.arguments
                    if let i = args.firstIndex(of: "--pair"), i + 1 < args.count, let u = URL(string: args[i + 1]) {
                        try? await client.pair(with: u)
                    }
                    #endif
                    client.connect()
                }
        }
    }
}

extension Color {
    static let pwAmber = Color(red: 0.96, green: 0.65, blue: 0.14)
    static let pwGreen = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0x3DD68C) : UIColor(rgb: 0x16874A) })
    static let pwBlue = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0x5B9CFF) : UIColor(rgb: 0x2563EB) })
    static let pwRed = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0xFF6B61) : UIColor(rgb: 0xC62828) })
    static let pwIdle = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0x5A5E68) : UIColor(rgb: 0xB9BCC3) })
    static let pwCanvas = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0x0F1012) : UIColor(rgb: 0xE9ECEF) })
    static let pwCard = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0x1A1C20) : .white })
    static let pwTerminal = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0x141518) : UIColor(rgb: 0xFDFCFA) })
    static let boardColors: [Color] = [0xE08A00, 0x2563EB, 0x16874A, 0x7C4DDB, 0xD9467A, 0x0E7C86].map { Color(uiColor: UIColor(rgb: UInt32($0))) }

    static func state(_ s: String) -> Color {
        switch s {
        case "working": return .pwGreen
        case "waiting": return .pwAmber
        case "done": return .pwBlue
        case "error": return .pwRed
        default: return .pwIdle
        }
    }
}

extension Date {
    var elapsedShort: String {
        let s = Int(Date().timeIntervalSince(self))
        if s < 5 { return "now" }
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}

/// The dotted canvas background, like the Mac app.
struct CanvasBackground: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 22
            for x in stride(from: step / 2, to: size.width, by: step) {
                for y in stride(from: step / 2, to: size.height, by: step) {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6)), with: .color(.primary.opacity(0.08)))
                }
            }
        }
        .background(Color.pwCanvas)
        .ignoresSafeArea()
    }
}
