import SwiftUI
import AppKit
import QuickLookThumbnailing

/// Thumbnails of images an agent mentioned in its output.
struct GalleryView: View {
    let paths: [String]
    let onOpen: (String) -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Images").font(.system(size: 13, weight: .semibold))
                Text("\(paths.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button("Clear", action: onClear).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 10)], spacing: 10) {
                    ForEach(paths, id: \.self) { p in
                        Thumb(path: p).onTapGesture { onOpen(p) }
                            .help(p)
                            .contextMenu {
                                Button("Open on canvas") { onOpen(p) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
                                Button("Copy path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(p, forType: .string) }
                            }
                    }
                }
            }
            .frame(maxHeight: 420)
            Text("Click an image to pin it to the canvas.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 400)
    }
}

private struct Thumb: View {
    let path: String
    @State private var image: NSImage?
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06))
                if let image {
                    Image(nsImage: image).resizable().scaledToFit().padding(4)
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .frame(height: 88)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(hover ? 0.3 : 0.08)))
            Text((path as NSString).lastPathComponent).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .task(id: path) {
            let req = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: 240, height: 176),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
                image = rep.nsImage
            } else {
                image = NSImage(contentsOfFile: path)
            }
        }
    }
}
