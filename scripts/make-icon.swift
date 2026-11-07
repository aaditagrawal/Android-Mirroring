// Renders the app icon (1024x1024 PNG) with CoreGraphics.
//   swift scripts/make-icon.swift out.png
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, a])!
}

// macOS icon grid: 824pt squircle centered in 1024 canvas.
let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(color(0.1, 0.1, 0.1))
ctx.fillPath()
ctx.restoreGState()

// Background gradient: deep teal → green
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [color(0.05, 0.20, 0.22), color(0.08, 0.42, 0.36), color(0.30, 0.78, 0.48)] as CFArray,
                    locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: tile.minX, y: tile.minY), end: CGPoint(x: tile.maxX, y: tile.maxY), options: [])
// Soft top highlight
let hl = CGGradient(colorsSpace: cs, colors: [color(1, 1, 1, 0.18), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(hl, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.midY), options: [])
ctx.restoreGState()

// Two phones: a back "ghost" (the phone) and a front glass (the mirror on the Mac).
func phone(_ rect: CGRect, fill: CGColor, stroke: CGColor, lineWidth: CGFloat, screen: Bool) {
    let p = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.2, cornerHeight: rect.width * 0.2, transform: nil)
    ctx.addPath(p)
    ctx.setFillColor(fill)
    ctx.fillPath()
    ctx.addPath(p)
    ctx.setStrokeColor(stroke)
    ctx.setLineWidth(lineWidth)
    ctx.strokePath()
    if screen {
        let s = rect.insetBy(dx: rect.width * 0.08, dy: rect.width * 0.08)
        let sp = CGPath(roundedRect: s, cornerWidth: s.width * 0.14, cornerHeight: s.width * 0.14, transform: nil)
        ctx.saveGState()
        ctx.addPath(sp)
        ctx.clip()
        let g = CGGradient(colorsSpace: cs, colors: [color(0.62, 0.95, 0.80), color(0.20, 0.62, 0.86)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: s.minX, y: s.maxY), end: CGPoint(x: s.maxX, y: s.minY), options: [])
        // camera dot
        ctx.setFillColor(color(0.05, 0.12, 0.14, 0.9))
        let d: CGFloat = s.width * 0.07
        ctx.fillEllipse(in: CGRect(x: s.midX - d / 2, y: s.maxY - d * 2.0, width: d, height: d))
        // a few "app" tiles
        let cols = 3, rows = 4
        let pad = s.width * 0.12
        let cell = (s.width - pad * 2) / CGFloat(cols)
        for r in 0..<rows {
            for c in 0..<cols {
                let x = s.minX + pad + CGFloat(c) * cell + cell * 0.15
                let y = s.minY + s.height * 0.18 + CGFloat(r) * cell * 1.05
                let t = CGRect(x: x, y: y, width: cell * 0.7, height: cell * 0.7)
                ctx.setFillColor(color(1, 1, 1, 0.55))
                ctx.addPath(CGPath(roundedRect: t, cornerWidth: t.width * 0.28, cornerHeight: t.width * 0.28, transform: nil))
                ctx.fillPath()
            }
        }
        ctx.restoreGState()
    }
}

let pw: CGFloat = 330, ph: CGFloat = 610
let back = CGRect(x: size / 2 - pw / 2 - 95, y: size / 2 - ph / 2 + 40, width: pw, height: ph)
let front = CGRect(x: size / 2 - pw / 2 + 85, y: size / 2 - ph / 2 - 40, width: pw, height: ph)
phone(back, fill: color(1, 1, 1, 0.10), stroke: color(1, 1, 1, 0.45), lineWidth: 10, screen: false)

// Connection arcs between them
ctx.saveGState()
ctx.setStrokeColor(color(1, 1, 1, 0.55))
ctx.setLineCap(.round)
for (i, r) in [CGFloat(60), 100, 140].enumerated() {
    ctx.setLineWidth(14 - CGFloat(i) * 2)
    ctx.addArc(center: CGPoint(x: back.maxX - 10, y: back.maxY - 70), radius: r, startAngle: -.pi / 3.2, endAngle: .pi / 7, clockwise: false)
    ctx.strokePath()
}
ctx.restoreGState()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0, 0, 0, 0.45))
phone(front, fill: color(0.07, 0.09, 0.10), stroke: color(0.85, 0.95, 0.92, 0.9), lineWidth: 8, screen: true)
ctx.restoreGState()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
