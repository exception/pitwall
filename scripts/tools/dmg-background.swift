// dmg-background <out-dir>
// Draws the installer window background (660×400 pt) at 1x and 2x:
// Pitwall's dark canvas with its dot grid, an arrow from the app to
// Applications, and a one-line hint.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let W: CGFloat = 660, H: CGFloat = 400

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Canvas + soft amber glow at the bottom.
    // Light canvas: Finder draws icon labels in black whatever the theme.
    hex(0xE9ECEF).setFill()
    NSRect(x: 0, y: 0, width: W, height: H).fill()
    let glow = NSGradient(colors: [hex(0xF5A524, 0.22), hex(0xF5A524, 0)])!
    glow.draw(fromCenter: NSPoint(x: W * 0.5, y: -60), radius: 0, toCenter: NSPoint(x: W * 0.5, y: -60), radius: 420, options: [])

    // Dot grid.
    hex(0x000000, 0.10).setFill()
    var y: CGFloat = 11
    while y < H {
        var x: CGFloat = 11
        while x < W { NSBezierPath(ovalIn: NSRect(x: x - 1, y: y - 1, width: 2, height: 2)).fill(); x += 22 }
        y += 22
    }

    // Arrow between the two icons (icons sit at x=165 and x=495, y=200 from top).
    let ay = H - 205
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 262, y: ay))
    arrow.line(to: NSPoint(x: 388, y: ay))
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    hex(0xE08A00, 1).setStroke()
    let dash: [CGFloat] = [2, 9]
    arrow.setLineDash(dash, count: 2, phase: 0)
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 384, y: ay + 9))
    head.line(to: NSPoint(x: 398, y: ay))
    head.line(to: NSPoint(x: 384, y: ay - 9))
    head.lineWidth = 3
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    // Title and hint.
    func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat) {
        let p = NSMutableParagraphStyle(); p.alignment = .center
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: p]
        NSAttributedString(string: s, attributes: a).draw(in: NSRect(x: 0, y: y, width: W, height: size * 1.4))
    }
    text("Pitwall", size: 22, weight: .bold, color: hex(0x1B1C1F), y: H - 62)
    text("Every agent, one wall.", size: 13, weight: .regular, color: hex(0x585B63), y: H - 84)
    text("Drag Pitwall to Applications to install", size: 13, weight: .medium, color: hex(0x585B63), y: 42)
    _ = ctx
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try! render(scale: 1).write(to: URL(fileURLWithPath: out).appendingPathComponent("background.png"))
try! render(scale: 2).write(to: URL(fileURLWithPath: out).appendingPathComponent("background@2x.png"))
print("wrote \(out)/background.png, background@2x.png")
