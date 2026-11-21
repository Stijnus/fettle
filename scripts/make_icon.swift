// Renders the Fettle app icon at every macOS size.
// Usage: swift make_icon.swift <output-dir>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [
        CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255,
        CGFloat(hex & 0xff) / 255, a])!
}

/// macOS-style continuous-corner squircle.
func squircle(_ r: CGRect, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let k: CGFloat = 1.17  // smoothing factor (spreads the curve like Apple's shape)
    let c = radius * k
    let (minX, minY, maxX, maxY) = (r.minX, r.minY, r.maxX, r.maxY)
    p.move(to: CGPoint(x: minX + c, y: minY))
    p.addLine(to: CGPoint(x: maxX - c, y: minY))
    p.addCurve(to: CGPoint(x: maxX, y: minY + c),
               control1: CGPoint(x: maxX - c * 0.33, y: minY),
               control2: CGPoint(x: maxX, y: minY + c * 0.33))
    p.addLine(to: CGPoint(x: maxX, y: maxY - c))
    p.addCurve(to: CGPoint(x: maxX - c, y: maxY),
               control1: CGPoint(x: maxX, y: maxY - c * 0.33),
               control2: CGPoint(x: maxX - c * 0.33, y: maxY))
    p.addLine(to: CGPoint(x: minX + c, y: maxY))
    p.addCurve(to: CGPoint(x: minX, y: maxY - c),
               control1: CGPoint(x: minX + c * 0.33, y: maxY),
               control2: CGPoint(x: minX, y: maxY - c * 0.33))
    p.addLine(to: CGPoint(x: minX, y: minY + c))
    p.addCurve(to: CGPoint(x: minX + c, y: minY),
               control1: CGPoint(x: minX, y: minY + c * 0.33),
               control2: CGPoint(x: minX + c * 0.33, y: minY))
    p.closeSubpath()
    return p
}

func sparkle(center: CGPoint, size s: CGFloat) -> CGPath {
    // Four-point star with concave sides.
    let p = CGMutablePath()
    let pts = [CGPoint(x: 0, y: -s), CGPoint(x: s, y: 0), CGPoint(x: 0, y: s), CGPoint(x: -s, y: 0)]
    let pinch: CGFloat = 0.16
    p.move(to: CGPoint(x: center.x + pts[0].x, y: center.y + pts[0].y))
    for i in 0..<4 {
        let n = pts[(i + 1) % 4]
        p.addQuadCurve(to: CGPoint(x: center.x + n.x, y: center.y + n.y),
                       control: CGPoint(x: center.x + (pts[i].x + n.x) * pinch,
                                        y: center.y + (pts[i].y + n.y) * pinch))
    }
    p.closeSubpath()
    return p
}

func render(px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let s = CGFloat(px) / 1024
    // Work in a 1024pt, top-left-origin canvas.
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: s, y: -s)
    let small = px <= 32
    let tiny = px <= 16

    // --- Body: Apple icon grid (824pt body, 100pt margin) ---
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(body, radius: 185)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 28 * s, color: rgb(0x000000, 0.28))
    ctx.addPath(shape); ctx.setFillColor(rgb(0x0E7A6C)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x5BE8B0), rgb(0x1FB59A), rgb(0x0B6C68)] as CFArray,
                        locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 260, y: 100), end: CGPoint(x: 764, y: 924), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // Soft top glow.
    let glow = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.28), rgb(0xFFFFFF, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 360, y: 220), startRadius: 0,
                           endCenter: CGPoint(x: 360, y: 220), endRadius: 560, options: [])
    // Thin inner highlight on the rim.
    ctx.addPath(shape); ctx.setStrokeColor(rgb(0xFFFFFF, 0.18)); ctx.setLineWidth(4); ctx.strokePath()

    // --- Leaf glyph ---
    let leaf = CGMutablePath()
    leaf.move(to: CGPoint(x: -250, y: 0))
    leaf.addCurve(to: CGPoint(x: 300, y: 0), control1: CGPoint(x: -215, y: -245), control2: CGPoint(x: 160, y: -250))
    leaf.addCurve(to: CGPoint(x: -250, y: 0), control1: CGPoint(x: 160, y: 250), control2: CGPoint(x: -215, y: 245))
    leaf.closeSubpath()

    let pulse = CGMutablePath()
    let pulsePts: [CGPoint] = [(-205, 0), (-75, 0), (-42, 62), (2, -118), (48, 72), (80, 0), (215, 0)]
        .map { CGPoint(x: $0.0, y: $0.1) }
    pulse.addLines(between: pulsePts)

    let stem = CGMutablePath()
    stem.move(to: CGPoint(x: -235, y: 0))
    stem.addQuadCurve(to: CGPoint(x: -330, y: 62), control: CGPoint(x: -290, y: 6))

    var t = CGAffineTransform(translationX: 520, y: 528).rotated(by: -.pi * 0.22)

    // Shadow under the glyph.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * s), blur: 30 * s, color: rgb(0x04423F, 0.40))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(leaf.copy(using: &t)!)
    ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
    ctx.addPath(stem.copy(using: &t)!)
    ctx.setStrokeColor(rgb(0xFFFFFF)); ctx.setLineWidth(34); ctx.setLineCap(.round); ctx.strokePath()
    // Cut the heartbeat vein out of the leaf.
    if !tiny {
        ctx.setBlendMode(.clear)
        ctx.addPath(pulse.copy(using: &t)!)
        ctx.setLineWidth(small ? 46 : 36); ctx.setLineJoin(.round); ctx.setLineCap(.round); ctx.strokePath()
    }
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // --- Sparkles (cleanup) ---
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 14 * s, color: rgb(0x04423F, 0.30))
    ctx.setFillColor(rgb(0xFFFFFF))
    if !tiny { ctx.addPath(sparkle(center: CGPoint(x: 300, y: 318), size: small ? 96 : 84)); ctx.fillPath() }
    if !small {
        ctx.addPath(sparkle(center: CGPoint(x: 762, y: 742), size: 44)); ctx.fillPath()
    }
    ctx.restoreGState()

    ctx.restoreGState()
    return ctx.makeImage()!
}

for px in [16, 32, 64, 128, 256, 512, 1024] {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("icon_\(px).png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, render(px: px), nil)
    CGImageDestinationFinalize(dest)
}
print("wrote icons to \(outDir)")
