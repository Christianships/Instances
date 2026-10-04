// Draws the Instances app icon: a dark panel listing running apps, each with a
// dot meter of what it costs, heaviest first.
//   swift Icon/make-icon.swift   -> Icon/AppIcon.iconset/*.png + Icon/AppIcon.icns
import AppKit

let S: CGFloat = 1024

func draw(into ctx: CGContext) {
    // y-down, like a screen
    ctx.translateBy(x: 0, y: S)
    ctx.scaleBy(x: 1, y: -1)

    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // the tile, with a soft drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    ctx.addPath(tilePath)
    ctx.setFillColor(NSColor(white: 0.08, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()

    // a dark panel, lit a little from the top
    let screen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: [NSColor(white: 0.17, alpha: 1).cgColor, NSColor(white: 0.05, alpha: 1).cgColor] as CFArray,
                            locations: [0, 1])!
    ctx.drawLinearGradient(screen, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])

    // the running apps: one row each, app first, then a dot meter of what it costs.
    // The top row is the heaviest and sits highlighted, like a sorted list.
    let rows: [Int] = [9, 6, 4, 2], spacing: CGFloat = 150, firstY: CGFloat = 287
    let pitch: CGFloat = 46, dotR: CGFloat = 14, meterX: CGFloat = 352
    for (i, lit) in rows.enumerated() {
        let y = firstY + CGFloat(i) * spacing
        if i == 0 {
            let band = CGPath(roundedRect: CGRect(x: 180, y: y - 62, width: 664, height: 124), cornerWidth: 34, cornerHeight: 34, transform: nil)
            ctx.addPath(band)
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.07).cgColor)
            ctx.fillPath()
        }
        let chip = CGPath(roundedRect: CGRect(x: 214, y: y - 38, width: 76, height: 76), cornerWidth: 20, cornerHeight: 20, transform: nil)
        ctx.addPath(chip)
        ctx.setFillColor(NSColor(white: i == 0 ? 0.97 : 0.78 - CGFloat(i) * 0.1, alpha: 1).cgColor)
        ctx.fillPath()
        for d in 0..<10 {
            let x = meterX + (CGFloat(d) + 0.5) * pitch
            ctx.setFillColor(d < lit ? NSColor(white: 0.97, alpha: 1).cgColor : NSColor(white: 0.26, alpha: 1).cgColor)
            ctx.fillEllipse(in: CGRect(x: x - dotR, y: y - dotR, width: dotR * 2, height: dotR * 2))
        }
    }

    // a hairline so the tile holds its edge on dark backgrounds
    ctx.restoreGState()
    ctx.addPath(tilePath)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.09).cgColor)
    ctx.setLineWidth(2)
    ctx.strokePath()
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
draw(into: NSGraphicsContext.current!.cgContext)
NSGraphicsContext.current = nil
let full = NSImage(size: NSSize(width: S, height: S))
full.addRepresentation(rep)

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let set = here.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

func png(_ px: Int, _ name: String) {
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    NSGraphicsContext.current!.imageInterpolation = .high
    full.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.current = nil
    try! out.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
}
for base in [16, 32, 128, 256, 512] {
    png(base, "icon_\(base)x\(base).png")
    png(base * 2, "icon_\(base)x\(base)@2x.png")
}

let icns = here.appendingPathComponent("AppIcon.icns").path
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", icns]
try! p.run()
p.waitUntilExit()
print("wrote \(icns)")
