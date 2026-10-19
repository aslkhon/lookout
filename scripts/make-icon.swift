// Renders Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

// The four agents peeking up from the bottom, as pixel art on a 24×24 grid, with the amber "needs you".
let art = [
    "........................",
    "........................",
    "........................",
    "........................",
    "........................",
    "........................",
    "........................",
    "........................",
    "........................",
    "........................",
    "........................",
    "........................",
    "................AA......",
    "................AA......",
    "........................",
    "........................",
    "..OOO...GGG...BBB...WWW.",
    ".OOOOO.GGGGG.BBBBB.WWWWW",
    ".OeOeO.GeGeG.BeBeB.WeWeW",
    ".OeOeO.GeGeG.BeBeB.WeWeW",
    ".OOOOO.GGGGG.BBBBB.WWWWW",
    ".OOOOO.GGGGG.BBBBB.WWWWW",
    ".OOOOO.GGGGG.BBBBB.WWWWW",
    ".OOOOO.GGGGG.BBBBB.WWWWW"
]
let palette: [Character: UInt32] = [
    "O": 0xD97757, "G": 0xB9C1CD, "B": 0x4F86F7, "W": 0xF3F0EA, "e": 0x1E1D22, "A": 0xFFB82E,
]

func color(_ v: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024

    // macOS icon grid: 824pt body inset 100pt, ~185pt corner radius, soft drop shadow.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 24 * s
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [color(0x121115), color(0x1E1D22)])!.draw(in: shape, angle: 90)

    // Cells sit on a grid inset from the body; the bottom row runs to the body's edge, which clips it.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGraphicsContext.current?.shouldAntialias = false
    let n = art.count, inset = 40 * s, cell = (824 * s - 2 * inset) / CGFloat(n)
    for (row, line) in art.enumerated() {
        for (col, ch) in line.enumerated() {
            guard let v = palette[ch] else { continue }
            color(v).setFill()
            // Cells overlap by a hair so no seams show between them.
            let bottom = row == n - 1 ? inset : 0
            NSRect(x: body.minX + inset + CGFloat(col) * cell, y: body.maxY - inset - CGFloat(row + 1) * cell - bottom,
                   width: cell + 0.5, height: cell + 0.5 + bottom).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    try! render(pt).write(to: iconset.appendingPathComponent("icon_\(pt)x\(pt).png"))
    try! render(pt * 2).write(to: iconset.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! task.run(); task.waitUntilExit()
print("Wrote Resources/AppIcon.icns")
