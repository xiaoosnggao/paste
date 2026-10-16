import AppKit

// square-stack geometry: Lucide, ISC. See Resources/Icon/Lucide-LICENSE.txt.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
}
func artwork(_ pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Unable to create icon canvas") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    let cg = context.cgContext
    cg.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 88, y: 88, width: 848, height: 848), xRadius: 190, yRadius: 190)
    cg.saveGState()
    tile.addClip()
    NSGradient(colors: [color(0.04, 0.65, 1), color(0.43, 0.63, 0.98), color(1, 0.79, 0.90)])!.draw(in: tile, angle: -28)
    NSGradient(starting: color(1, 0.87, 0.94), ending: color(1, 0.87, 0.94, 0))!
        .draw(fromCenter: NSPoint(x: 895, y: 900), radius: 0, toCenter: NSPoint(x: 895, y: 900), radius: 690, options: [])
    NSGradient(starting: color(0.91, 0.76, 1, 0.9), ending: color(0.91, 0.76, 1, 0))!
        .draw(fromCenter: NSPoint(x: 115, y: 280), radius: 0, toCenter: NSPoint(x: 115, y: 280), radius: 520, options: [])
    NSGradient(starting: color(1, 0.72, 0.72, 0.65), ending: color(1, 0.72, 0.72, 0))!
        .draw(fromCenter: NSPoint(x: 900, y: 130), radius: 0, toCenter: NSPoint(x: 900, y: 130), radius: 530, options: [])
    cg.restoreGState()
    color(1, 1, 1, 0.55).setStroke()
    tile.lineWidth = 3
    tile.stroke()

    let path = CGMutablePath()
    path.move(to: CGPoint(x: 4, y: 10))
    path.addCurve(to: CGPoint(x: 2, y: 8), control1: CGPoint(x: 2.9, y: 10), control2: CGPoint(x: 2, y: 9.1))
    path.addLine(to: CGPoint(x: 2, y: 4))
    path.addCurve(to: CGPoint(x: 4, y: 2), control1: CGPoint(x: 2, y: 2.9), control2: CGPoint(x: 2.9, y: 2))
    path.addLine(to: CGPoint(x: 8, y: 2))
    path.addCurve(to: CGPoint(x: 10, y: 4), control1: CGPoint(x: 9.1, y: 2), control2: CGPoint(x: 10, y: 2.9))
    path.move(to: CGPoint(x: 10, y: 16))
    path.addCurve(to: CGPoint(x: 8, y: 14), control1: CGPoint(x: 8.9, y: 16), control2: CGPoint(x: 8, y: 15.1))
    path.addLine(to: CGPoint(x: 8, y: 10))
    path.addCurve(to: CGPoint(x: 10, y: 8), control1: CGPoint(x: 8, y: 8.9), control2: CGPoint(x: 8.9, y: 8))
    path.addLine(to: CGPoint(x: 14, y: 8))
    path.addCurve(to: CGPoint(x: 16, y: 10), control1: CGPoint(x: 15.1, y: 8), control2: CGPoint(x: 16, y: 8.9))
    path.addRoundedRect(in: CGRect(x: 14, y: 14, width: 8, height: 8), cornerWidth: 2, cornerHeight: 2)
    let unit: CGFloat = 29
    var transform = CGAffineTransform(a: unit, b: 0, c: 0, d: -unit, tx: 512 - 12 * unit, ty: 512 + 12 * unit)
    let glyph = path.copy(using: &transform)!
    func stroke(_ width: CGFloat, _ gradient: NSGradient) {
        cg.saveGState()
        cg.addPath(glyph)
        cg.setLineWidth(width * unit)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.replacePathWithStrokedPath()
        cg.clip()
        gradient.draw(in: NSRect(x: 160, y: 160, width: 704, height: 704), angle: -40)
        cg.restoreGState()
    }
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -9), blur: 22, color: color(0.25, 0.26, 0.74, 0.3).cgColor)
    cg.addPath(glyph)
    cg.setStrokeColor(color(0.44, 0.44, 0.92).cgColor)
    cg.setLineWidth(2.1 * unit)
    cg.setLineCap(.round)
    cg.strokePath()
    cg.restoreGState()
    stroke(2.1, NSGradient(colors: [color(0.05, 0.32, 1), color(0.43, 0.33, 1), color(0.91, 0.36, 0.96)])!)
    stroke(1.75, NSGradient(colors: [color(0.16, 0.98, 1), color(0.87, 0.95, 1), color(1, 0.91, 1)])!)
    stroke(1.25, NSGradient(colors: [color(0.64, 1, 1), color(1, 1, 1), color(1, 0.98, 1)])!)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Unable to encode icon") }
    return png
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try artwork(size * scale).write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
