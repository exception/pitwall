import UIKit
import SwiftUI
import CoreText

/// A headless terminal (libghostty-vt) fed with a tile's output.
final class TerminalModel: ObservableObject {
    private var t: UnsafeMutableRawPointer?
    private(set) var cells: [pw_cell] = []
    @Published private(set) var frame = pw_frame(cols: 80, rows: 24, cursor_x: -1, cursor_y: -1)
    private var pending = false

    init(cols: Int = 80, rows: Int = 24) {
        t = pwt_new(UInt16(cols), UInt16(rows))
    }
    deinit { pwt_free(t) }

    func resize(cols: Int, rows: Int) { pwt_resize(t, UInt16(cols), UInt16(rows)); scheduleRender() }

    func reset() { pwt_reset(t) }

    func write(_ data: Data) {
        data.withUnsafeBytes { raw in
            if let b = raw.baseAddress { pwt_write(t, b.assumingMemoryBound(to: UInt8.self), raw.count) }
        }
        scheduleRender()
    }

    /// Coalesces bursts of output into one redraw per frame.
    private func scheduleRender() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            let cap = 400 * 200
            if self.cells.count != cap { self.cells = Array(repeating: pw_cell(), count: cap) }
            let f = self.cells.withUnsafeMutableBufferPointer { pwt_render(self.t, $0.baseAddress, cap) }
            self.frame = f
        }
    }
}

/// Draws a TerminalModel with Core Text, scaled so every column fits the width.
final class TerminalCanvas: UIView {
    var model: TerminalModel? { didSet { setNeedsDisplay() } }
    var dark = true { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError() }

    static func palette(dark: Bool) -> (fg: UIColor, bg: UIColor, cursor: UIColor) {
        dark ? (UIColor(rgb: 0xD8DADF), UIColor(rgb: 0x141518), UIColor(rgb: 0xF5A524))
             : (UIColor(rgb: 0x26282D), UIColor(rgb: 0xFDFCFA), UIColor(rgb: 0x1B1C1F))
    }

    /// Font size that fits `cols` monospaced columns in `width`.
    static func fontSize(cols: Int, width: CGFloat) -> CGFloat {
        let probe = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let adv = ("M" as NSString).size(withAttributes: [.font: probe]).width / 10
        return max(5, min(14, floor(width / (CGFloat(max(cols, 1)) * adv) * 10) / 10))
    }

    override func draw(_ rect: CGRect) {
        guard let model, let ctx = UIGraphicsGetCurrentContext() else { return }
        let f = model.frame
        let cols = Int(f.cols), rows = Int(f.rows)
        guard cols > 0, rows > 0, model.cells.count >= cols * rows else { return }
        let pal = Self.palette(dark: dark)
        pal.bg.setFill()
        ctx.fill(bounds)

        let size = Self.fontSize(cols: cols, width: bounds.width)
        let regular = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let bold = UIFont.monospacedSystemFont(ofSize: size, weight: .bold)
        let cw = ("M" as NSString).size(withAttributes: [.font: regular]).width
        let ch = ceil(regular.lineHeight)

        for y in 0..<rows {
            let rowY = CGFloat(y) * ch
            if rowY > rect.maxY || rowY + ch < rect.minY { continue }
            // Backgrounds first, in runs.
            var x = 0
            while x < cols {
                let c = model.cells[y * cols + x]
                var bg = c.bg
                if c.flags & PW_INVERSE != 0 { bg = c.fg == PW_DEFAULT ? Self.rgb(pal.fg) : c.fg }
                if bg == PW_DEFAULT { x += 1; continue }
                var end = x + 1
                while end < cols, model.cells[y * cols + end].bg == c.bg, model.cells[y * cols + end].flags & PW_INVERSE == c.flags & PW_INVERSE { end += 1 }
                UIColor(rgb: bg).setFill()
                ctx.fill(CGRect(x: CGFloat(x) * cw, y: rowY, width: CGFloat(end - x) * cw, height: ch))
                x = end
            }
            // Text as one attributed line per row (runs of equal style).
            let line = NSMutableAttributedString()
            for x in 0..<cols {
                let c = model.cells[y * cols + x]
                let scalar = c.cp == 0 ? " " : (Unicode.Scalar(c.cp).map { String(Character($0)) } ?? " ")
                var fg = c.fg == PW_DEFAULT ? pal.fg : UIColor(rgb: c.fg)
                if c.flags & PW_INVERSE != 0 { fg = c.bg == PW_DEFAULT ? pal.bg : UIColor(rgb: c.bg) }
                if c.flags & PW_FAINT != 0 { fg = fg.withAlphaComponent(0.6) }
                var attrs: [NSAttributedString.Key: Any] = [.font: c.flags & PW_BOLD != 0 ? bold : regular, .foregroundColor: fg]
                if c.flags & PW_UNDERLINE != 0 { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if c.flags & PW_STRIKE != 0 { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                line.append(NSAttributedString(string: scalar, attributes: attrs))
            }
            line.draw(at: CGPoint(x: 0, y: rowY))
        }
        if f.cursor_x >= 0, f.cursor_y >= 0 {
            pal.cursor.setFill()
            ctx.fill(CGRect(x: CGFloat(f.cursor_x) * cw, y: CGFloat(f.cursor_y) * ch, width: max(1.5, cw * 0.15), height: ch))
        }
    }

    static func rgb(_ c: UIColor) -> UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return UInt32(r * 255) << 16 | UInt32(g * 255) << 8 | UInt32(b * 255)
    }

    /// Height needed for the current frame at this width.
    static func height(for f: pw_frame, width: CGFloat) -> CGFloat {
        let size = fontSize(cols: Int(f.cols), width: width)
        return ceil(UIFont.monospacedSystemFont(ofSize: size, weight: .regular).lineHeight) * CGFloat(f.rows)
    }
}

/// SwiftUI wrapper.
struct TerminalScreen: UIViewRepresentable {
    @ObservedObject var model: TerminalModel
    @Environment(\.colorScheme) private var scheme

    func makeUIView(context: Context) -> TerminalCanvas {
        let v = TerminalCanvas()
        v.model = model
        return v
    }

    func updateUIView(_ v: TerminalCanvas, context: Context) {
        v.dark = scheme == .dark
        v.model = model
        v.setNeedsDisplay()
    }
}

extension UIColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
                  blue: CGFloat(rgb & 0xff) / 255, alpha: alpha)
    }
}
