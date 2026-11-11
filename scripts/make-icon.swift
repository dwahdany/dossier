// Draws the Dossier app icon programmatically and writes an .iconset directory.
// Usage: swift scripts/make-icon.swift <output.iconset>
// No external assets: a rounded-rectangle gradient plate with an SF Symbol on top.
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }

    let size = CGFloat(pixels)
    // macOS icon grid: the plate occupies 824/1024 of the canvas, corner radius ~22.4 %.
    let inset = size * 100 / 1024
    let plate = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let radius = plate.width * 0.2237
    let path = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

    // Soft drop shadow under the plate.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = size * 0.022
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Deep indigo → teal gradient plate.
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.48, alpha: 1),
        NSColor(calibratedRed: 0.13, green: 0.42, blue: 0.62, alpha: 1),
        NSColor(calibratedRed: 0.16, green: 0.62, blue: 0.66, alpha: 1),
    ])
    gradient?.draw(in: path, angle: -55)

    // Subtle top highlight.
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.20), NSColor.white.withAlphaComponent(0)])?
        .draw(in: NSRect(x: plate.minX, y: plate.midY, width: plate.width, height: plate.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // The glyph: a record card with a person, plus a small magnifier badge.
    func symbol(_ name: String, points: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: points, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }
    if let glyph = symbol("person.text.rectangle", points: size * 0.40, weight: .semibold, color: .white) {
        let g = glyph.size
        let scale = min(plate.width * 0.62 / g.width, plate.height * 0.62 / g.height)
        let rect = NSRect(x: plate.midX - g.width * scale / 2, y: plate.midY - g.height * scale / 2 + size * 0.02,
                          width: g.width * scale, height: g.height * scale)
        glyph.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.97)
    }
    if pixels >= 64, let lens = symbol("magnifyingglass", points: size * 0.12, weight: .heavy, color: NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.36, alpha: 1)) {
        let side = plate.width * 0.30
        let rect = NSRect(x: plate.maxX - side - plate.width * 0.08, y: plate.minY + plate.height * 0.09, width: side, height: side)
        NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.36, alpha: 0.9).setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: -side * 0.05, dy: -side * 0.05)).fill()
        NSColor(calibratedRed: 1.0, green: 0.76, blue: 0.28, alpha: 1).setFill()
        NSBezierPath(ovalIn: rect).fill()
        let l = lens.size
        let scale = side * 0.56 / max(l.width, l.height)
        lens.draw(in: NSRect(x: rect.midX - l.width * scale / 2, y: rect.midY - l.height * scale / 2, width: l.width * scale, height: l.height * scale),
                  from: .zero, operation: .sourceOver, fraction: 1)
    }
    return rep.representation(using: .png, properties: [:])
}

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in variants {
    guard let png = render(pixels: pixels) else {
        FileHandle.standardError.write(Data("could not render \(name)\n".utf8))
        exit(1)
    }
    try png.write(to: output.appendingPathComponent(name + ".png"))
}
print("wrote \(variants.count) icon sizes to \(output.path)")
