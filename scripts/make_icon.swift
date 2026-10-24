// Renders the MyNotch app icon → <outdir>/AppIcon.icns
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
let iconset = URL(fileURLWithPath: out).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS squircle-ish tile with margin
    let inset = s * 0.1
    let tile = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [NSColor(red: 0.13, green: 0.12, blue: 0.17, alpha: 1).cgColor,
                                 NSColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    // warm glow
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 0.55).cgColor,
                                   NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: tile.midX, y: tile.maxY - tile.height * 0.32), startRadius: 0,
                           endCenter: CGPoint(x: tile.midX, y: tile.maxY - tile.height * 0.32), endRadius: tile.width * 0.55, options: [])

    // the notch (expanded island) hanging from the top edge
    let nw = tile.width * 0.66, nh = tile.height * 0.34
    let nx = tile.midX - nw / 2, ny = tile.maxY - nh
    let notch = CGMutablePath()
    let r = nh * 0.42
    notch.move(to: CGPoint(x: nx, y: tile.maxY))
    notch.addLine(to: CGPoint(x: nx, y: ny + r))
    notch.addQuadCurve(to: CGPoint(x: nx + r, y: ny), control: CGPoint(x: nx, y: ny))
    notch.addLine(to: CGPoint(x: nx + nw - r, y: ny))
    notch.addQuadCurve(to: CGPoint(x: nx + nw, y: ny + r), control: CGPoint(x: nx + nw, y: ny))
    notch.addLine(to: CGPoint(x: nx + nw, y: tile.maxY))
    notch.closeSubpath()
    ctx.addPath(notch); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()

    // rings inside the island (Claude coral + Codex mint)
    func ring(_ c: CGPoint, _ rad: CGFloat, _ frac: CGFloat, _ color: NSColor) {
        ctx.setLineWidth(rad * 0.32); ctx.setLineCap(.round)
        ctx.setStrokeColor(color.withAlphaComponent(0.2).cgColor)
        ctx.addArc(center: c, radius: rad, startAngle: 0, endAngle: .pi * 2, clockwise: false); ctx.strokePath()
        ctx.setStrokeColor(color.cgColor)
        ctx.addArc(center: c, radius: rad, startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 2 * frac, clockwise: true); ctx.strokePath()
    }
    let cy = ny + nh * 0.48
    ring(CGPoint(x: tile.midX - nw * 0.22, y: cy), nh * 0.22, 0.62, NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1))
    ring(CGPoint(x: tile.midX + nw * 0.22, y: cy), nh * 0.22, 0.35, NSColor(red: 0.24, green: 0.84, blue: 0.69, alpha: 1))
    // little equalizer in the middle
    for i in 0..<3 {
        let h = nh * [0.28, 0.46, 0.34][i]
        let bx = tile.midX - nw * 0.05 + CGFloat(i) * nw * 0.05
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.fill(CGRect(x: bx - nw * 0.012, y: cy - h / 2, width: nw * 0.024, height: h))
    }
    // dock dots below
    let colors: [NSColor] = [.systemBlue, .systemPurple, .systemPink, .systemOrange]
    for (i, c) in colors.enumerated() {
        let d = tile.width * 0.1
        let x = tile.midX - d * 2.4 + CGFloat(i) * d * 1.6
        let rect = CGRect(x: x - d / 2, y: tile.minY + tile.height * 0.2, width: d, height: d)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: d * 0.28, cornerHeight: d * 0.28, transform: nil))
        ctx.setFillColor(c.cgColor); ctx.fillPath()
    }
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", URL(fileURLWithPath: out).appendingPathComponent("AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("icon written")
