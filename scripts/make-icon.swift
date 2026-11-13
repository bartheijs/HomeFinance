// Tekent het app-icoon en schrijft scripts/AppIcon.icns. Gebruik: swift scripts/make-icon.swift
import AppKit

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = size * 0.1
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(srgbRed: 0.30, green: 0.78, blue: 0.60, alpha: 1),
                        NSColor(srgbRed: 0.07, green: 0.36, blue: 0.30, alpha: 1)])!.draw(in: path, angle: -90)
    // Staafjes als een oplopend maandoverzicht
    let bars: [CGFloat] = [0.30, 0.46, 0.38, 0.62]
    let bw = rect.width * 0.11, gap = rect.width * 0.055
    let total = CGFloat(bars.count) * bw + CGFloat(bars.count - 1) * gap
    var x = rect.midX - total / 2
    for (i, h) in bars.enumerated() {
        let bar = NSRect(x: x, y: rect.minY + rect.height * 0.2, width: bw, height: rect.height * h)
        NSColor.white.withAlphaComponent(i == bars.count - 1 ? 1 : 0.55).setFill()
        NSBezierPath(roundedRect: bar, xRadius: bw * 0.3, yRadius: bw * 0.3).fill()
        x += bw + gap
    }
    // Euroteken rechtsboven
    let font = NSFont.systemFont(ofSize: rect.width * 0.24, weight: .heavy)
    let text = NSAttributedString(string: "€", attributes: [.font: font, .foregroundColor: NSColor.white])
    text.draw(at: NSPoint(x: rect.minX + rect.width * 0.14, y: rect.maxY - rect.height * 0.36))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try draw(size: CGFloat(px)).representation(using: .png, properties: [:])!
        .write(to: dir.appendingPathComponent("icon_\(name).png"))
}
