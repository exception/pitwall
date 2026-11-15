import AppKit
let r = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))!
let a = CommandLine.arguments.dropFirst(2).compactMap { Int($0) }
let (x0, y0, x1, y1) = a.count == 4 ? (a[0], a[1], a[2], a[3]) : (0, 0, r.pixelsWide, r.pixelsHigh)
var n = 0
for y in stride(from: y0, to: min(y1, r.pixelsHigh), by: 1) { for x in stride(from: x0, to: min(x1, r.pixelsWide), by: 1) {
  if let c = r.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.greenComponent > c.redComponent + 0.15, c.greenComponent > c.blueComponent + 0.05 { n += 1 } } }
print(n)
