import SwiftUI
import VisionKit

struct PairView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var scanning = false
    @State private var link = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        ZStack {
            CanvasBackground()
            VStack(spacing: 18) {
                Spacer()
                Image("AppIconDisplay")
                    .resizable().frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
                Text("Pitwall Remote").font(.largeTitle.weight(.bold))
                Text("See your agents and answer them from anywhere. On your Mac, open Pitwall › Settings › Pitwall Remote and scan the code.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 28)

                if case .offline(let msg) = client.phase { Text(msg).font(.footnote).foregroundStyle(Color.pwAmber).multilineTextAlignment(.center).padding(.horizontal) }
                if let error { Text(error).font(.footnote).foregroundStyle(Color.pwRed).multilineTextAlignment(.center).padding(.horizontal) }

                VStack(spacing: 10) {
                    PillButton(title: busy ? "Pairing…" : "Scan pairing code", style: .dark, busy: busy) { scanning = true }
                        .disabled(!DataScannerViewController.isSupported)
                    HStack(spacing: 8) {
                        TextField("…or paste the pairing link", text: $link)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.footnote)
                            .padding(.horizontal, 14).frame(height: 44)
                            .background(Color.pwCard, in: Capsule())
                        Button("Pair") { pair(link) }.disabled(link.isEmpty || busy).font(.subheadline.weight(.semibold))
                    }
                }
                .padding(.horizontal, 28)
                Spacer()
                Label("End-to-end encrypted. Keys never leave your devices.", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
            }
        }
        .sheet(isPresented: $scanning) {
            QRScanner { code in
                scanning = false
                pair(code)
            }
            .ignoresSafeArea()
        }
        .onOpenURL { url in pair(url.absoluteString) }
    }

    private func pair(_ s: String) {
        guard let url = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)) else { error = RemoteError.badQR.localizedDescription; return }
        busy = true
        error = nil
        Task {
            do { try await client.pair(with: url) }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

/// Live camera QR scanner (VisionKit).
struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .fast,
                                           isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let b) = item, let s = b.payloadStringValue, s.hasPrefix("pitwall://"), !done {
                    done = true
                    dataScanner.stopScanning()
                    onCode(s)
                }
            }
        }
    }
}
