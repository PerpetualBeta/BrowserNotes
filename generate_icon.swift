#!/usr/bin/env swift

import AppKit
import CoreGraphics

let brandBlue = NSColor(red: 0x00/255.0, green: 0x40/255.0, blue: 0x80/255.0, alpha: 1.0)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let s = size
    let cx = s / 2
    let cy = s / 2

    // Background
    let bgRect = NSRect(x: s * 0.04, y: s * 0.04, width: s * 0.92, height: s * 0.92)
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: s * 0.18, yRadius: s * 0.18)
    brandBlue.setFill()
    bgPath.fill()

    // Subtle gradient
    let gradSpace = CGColorSpaceCreateDeviceRGB()
    let gradColors = [
        NSColor(white: 1.0, alpha: 0.08).cgColor,
        NSColor(white: 0.0, alpha: 0.10).cgColor
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: gradSpace, colors: gradColors, locations: [0.0, 1.0]) {
        ctx.saveGState()
        ctx.addPath(bgPath.cgPath)
        ctx.clip()
        ctx.drawRadialGradient(gradient,
            startCenter: CGPoint(x: cx, y: cy + s * 0.12),
            startRadius: 0, endCenter: CGPoint(x: cx, y: cy),
            endRadius: s * 0.55, options: [])
        ctx.restoreGState()
    }

    // Highlighter pen — angled from bottom-left to top-right
    ctx.saveGState()
    ctx.addPath(bgPath.cgPath)
    ctx.clip()

    ctx.translateBy(x: cx, y: cy)
    ctx.rotate(by: 0.65)  // ~37 degrees

    let penLen = s * 0.36
    let penW = s * 0.10
    let tipLen = s * 0.08

    // Pen body — yellow highlight colour
    let bodyRect = CGRect(x: -penW/2, y: -penLen * 0.1, width: penW, height: penLen)
    ctx.setFillColor(NSColor(red: 1.0, green: 0.92, blue: 0.3, alpha: 0.9).cgColor)
    ctx.fill(bodyRect)

    // Pen body outline
    ctx.setStrokeColor(NSColor(white: 1.0, alpha: 0.5).cgColor)
    ctx.setLineWidth(s * 0.005)
    ctx.stroke(bodyRect)

    // Pen cap (top)
    let capRect = CGRect(x: -penW/2, y: penLen * 0.9 - penLen * 0.1, width: penW, height: penLen * 0.15)
    ctx.setFillColor(NSColor(white: 0.85, alpha: 0.9).cgColor)
    ctx.fill(capRect)
    ctx.setStrokeColor(NSColor(white: 1.0, alpha: 0.4).cgColor)
    ctx.stroke(capRect)

    // Pen tip (chisel shape at bottom)
    let tipPath = CGMutablePath()
    tipPath.move(to: CGPoint(x: -penW/2, y: -penLen * 0.1))
    tipPath.addLine(to: CGPoint(x: penW/2, y: -penLen * 0.1))
    tipPath.addLine(to: CGPoint(x: penW * 0.15, y: -penLen * 0.1 - tipLen))
    tipPath.addLine(to: CGPoint(x: -penW * 0.15, y: -penLen * 0.1 - tipLen))
    tipPath.closeSubpath()
    ctx.setFillColor(NSColor(white: 0.4, alpha: 0.9).cgColor)
    ctx.addPath(tipPath)
    ctx.fillPath()
    ctx.setStrokeColor(NSColor(white: 1.0, alpha: 0.3).cgColor)
    ctx.setLineWidth(s * 0.004)
    ctx.addPath(tipPath)
    ctx.strokePath()

    // Highlight streak behind the pen (yellow glow)
    ctx.restoreGState()

    // Draw a yellow highlight streak across the icon
    ctx.saveGState()
    ctx.addPath(bgPath.cgPath)
    ctx.clip()

    let streakPath = CGMutablePath()
    let streakY = cy - s * 0.08
    let streakH = s * 0.06
    streakPath.move(to: CGPoint(x: s * 0.15, y: streakY))
    streakPath.addLine(to: CGPoint(x: s * 0.55, y: streakY))
    streakPath.addLine(to: CGPoint(x: s * 0.55, y: streakY + streakH))
    streakPath.addLine(to: CGPoint(x: s * 0.15, y: streakY + streakH))
    streakPath.closeSubpath()
    ctx.setFillColor(NSColor(red: 1.0, green: 1.0, blue: 0.0, alpha: 0.2).cgColor)
    ctx.addPath(streakPath)
    ctx.fillPath()

    ctx.restoreGState()

    image.unlockFocus()
    return image
}

extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        let points = UnsafeMutablePointer<NSPoint>.allocate(capacity: 3)
        defer { points.deallocate() }
        for i in 0..<elementCount {
            let element = self.element(at: i, associatedPoints: points)
            switch element {
            case .moveTo:    path.move(to: points[0])
            case .lineTo:    path.addLine(to: points[0])
            case .curveTo:   path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

let scriptDir = CommandLine.arguments[0].components(separatedBy: "/").dropLast().joined(separator: "/")
let iconsetDir = (scriptDir.isEmpty ? "." : scriptDir) + "/Resources/BrowserNotes.iconset"
let fm = FileManager.default
try? fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

for (size, name) in sizes {
    let image = drawIcon(size: CGFloat(size))
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else { continue }
    try! png.write(to: URL(fileURLWithPath: iconsetDir + "/" + name))
    print("  \(name) (\(size)x\(size))")
}

let icnsPath = (scriptDir.isEmpty ? "." : scriptDir) + "/Resources/AppIcon.icns"
let result = Process()
result.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
result.arguments = ["-c", "icns", iconsetDir, "-o", icnsPath]
try! result.run()
result.waitUntilExit()
print("  AppIcon.icns")
print("Done.")
