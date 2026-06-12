#!/usr/bin/env swift
//
// Generates the Skillet app icon: a side-view skillet tossing the $ and @
// symbols. Renders a 1024×1024 master PNG; downscaling to the appiconset
// sizes is done by the caller (sips).
//
// Usage: swift scripts/generate-icon.swift <output.png>

import AppKit

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "icon_1024.png"

let canvas: CGFloat = 1024

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvas),
    pixelsHigh: Int(canvas),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let nsContext = NSGraphicsContext(bitmapImageRep: rep) else {
    fatalError("Could not create drawing context")
}

NSGraphicsContext.current = nsContext
let ctx = nsContext.cgContext

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

// MARK: - Background squircle

let inset: CGFloat = 100
let squircleRect = NSRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)
let squircle = NSBezierPath(
    roundedRect: squircleRect,
    xRadius: squircleRect.width * 0.225,
    yRadius: squircleRect.width * 0.225
)

let background = NSGradient(
    starting: color(0x322E3B),
    ending: color(0x16131B)
)
background?.draw(in: squircle, angle: -90)

// Warm ember glow rising from the pan area.
ctx.saveGState()
squircle.addClip()
let glow = NSGradient(
    colors: [color(0xFF8C2E, 0.32), color(0xFF8C2E, 0.0)]
)
glow?.draw(
    fromCenter: NSPoint(x: 470, y: 360), radius: 0,
    toCenter: NSPoint(x: 470, y: 360), radius: 420,
    options: []
)
ctx.restoreGState()

// MARK: - Tossed symbols

func drawGlyph(
    _ string: String,
    center: NSPoint,
    fontSize: CGFloat,
    fill: NSColor,
    angleDegrees: CGFloat
) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angleDegrees * .pi / 180)
    ctx.setShadow(
        offset: CGSize(width: 0, height: -10),
        blur: 26,
        color: color(0x000000, 0.55).cgColor
    )
    let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    let attributed = NSAttributedString(string: string, attributes: [
        .font: font,
        .foregroundColor: fill,
    ])
    let bounds = attributed.size()
    attributed.draw(at: NSPoint(x: -bounds.width / 2, y: -bounds.height / 2))
    ctx.restoreGState()
}

// Short motion strokes radiating up from the pan — the cartoon "toss".
func drawTossStroke(at base: NSPoint, angleDegrees: CGFloat, length: CGFloat, alpha: CGFloat) {
    let radians = angleDegrees * .pi / 180
    let end = NSPoint(
        x: base.x + cos(radians) * length,
        y: base.y + sin(radians) * length
    )
    let path = NSBezierPath()
    path.move(to: base)
    path.line(to: end)
    path.lineWidth = 13
    path.lineCapStyle = .round
    color(0xFFC97A, alpha).setStroke()
    path.stroke()
}

ctx.saveGState()
squircle.addClip()

drawTossStroke(at: NSPoint(x: 300, y: 480), angleDegrees: 105, length: 64, alpha: 0.4)
drawTossStroke(at: NSPoint(x: 440, y: 505), angleDegrees: 90, length: 72, alpha: 0.45)
drawTossStroke(at: NSPoint(x: 580, y: 485), angleDegrees: 72, length: 64, alpha: 0.4)

drawGlyph(
    "@",
    center: NSPoint(x: 405, y: 665),
    fontSize: 270,
    fill: color(0xFF9F2E),
    angleDegrees: -14
)
drawGlyph(
    "$",
    center: NSPoint(x: 665, y: 700),
    fontSize: 205,
    fill: color(0xFFD23F),
    angleDegrees: 16
)

ctx.restoreGState()

// MARK: - Skillet (side view, mid-toss tilt)

ctx.saveGState()
squircle.addClip()
ctx.translateBy(x: 430, y: 350)
ctx.rotate(by: -8 * .pi / 180)

// Drop shadow for the whole pan.
ctx.setShadow(
    offset: CGSize(width: 0, height: -16),
    blur: 30,
    color: color(0x000000, 0.5).cgColor
)

// Handle: extends to the right, slightly tapered, rounded end.
let handle = NSBezierPath()
handle.move(to: NSPoint(x: 180, y: 30))
handle.line(to: NSPoint(x: 455, y: 16))
handle.appendArc(
    withCenter: NSPoint(x: 455, y: -3),
    radius: 19,
    startAngle: 90,
    endAngle: -90,
    clockwise: true
)
handle.line(to: NSPoint(x: 180, y: -28))
handle.close()
color(0x3A3E47).setFill()
handle.fill()

// Pan body: flared walls, flat base — classic skillet profile.
let pan = NSBezierPath()
pan.move(to: NSPoint(x: -232, y: 48))            // left rim
pan.line(to: NSPoint(x: -178, y: -58))           // left wall (flared)
pan.curve(
    to: NSPoint(x: -144, y: -78),
    controlPoint1: NSPoint(x: -172, y: -71),
    controlPoint2: NSPoint(x: -159, y: -78)
)                                                 // left base corner
pan.line(to: NSPoint(x: 144, y: -78))            // base
pan.curve(
    to: NSPoint(x: 178, y: -58),
    controlPoint1: NSPoint(x: 159, y: -78),
    controlPoint2: NSPoint(x: 172, y: -71)
)                                                 // right base corner
pan.line(to: NSPoint(x: 232, y: 48))             // right wall
pan.close()                                       // rim line

let panGradient = NSGradient(starting: color(0x4A4E59), ending: color(0x23252C))
panGradient?.draw(in: pan, angle: -90)

// Rim highlight: the bright lip that reads "metal" at small sizes.
ctx.setShadow(offset: .zero, blur: 0, color: nil)
let rim = NSBezierPath()
rim.move(to: NSPoint(x: -228, y: 48))
rim.line(to: NSPoint(x: 228, y: 48))
rim.lineWidth = 9
rim.lineCapStyle = .round
color(0x878D9A).setStroke()
rim.stroke()

ctx.restoreGState()

// MARK: - Save

nsContext.flushGraphics()
guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode PNG")
}
try png.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath)")
