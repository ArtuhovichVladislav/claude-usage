// Generates AppIcon.icns: swift make_icon.swift
import AppKit

func render(_ size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Background tile (macOS icon grid: 824pt tile inside 1024 canvas)
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let bg = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(calibratedWhite: 0.20, alpha: 1),
               ending: NSColor(calibratedWhite: 0.09, alpha: 1))!.draw(in: bg, angle: -90)

    let center = NSPoint(x: 512 * s, y: 512 * s)
    let radius = 260 * s
    let width = 80 * s

    // Track
    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
    track.lineWidth = width
    NSColor(calibratedWhite: 1, alpha: 0.12).setStroke()
    track.stroke()

    // Progress arc (~70%, clockwise from top)
    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 252, clockwise: true)
    arc.lineWidth = width
    arc.lineCapStyle = .round
    NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 1).setStroke()
    arc.stroke()

    // Center dot
    let dot = 70 * s
    NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: dir)
try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(CGFloat(base * scale)).write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
    }
}
