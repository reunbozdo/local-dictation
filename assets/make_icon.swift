// Draws the app icon: a key cap with a sound wave on it ("hold a key, speak").
// Usage: swift assets/make_icon.swift assets/icon-1024.png   (assets/make_icon.sh builds the .icns)
// Drawn with plain paths: SF Symbols may not be used in app icons.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon-1024.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// Background tile on the macOS icon grid: 824 pt square, 100 pt margin, ~185 pt corner radius.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35).cgColor)
rgb(0x000000).setFill(); tilePath.fill()
ctx.restoreGState()
NSGradient(colors: [rgb(0xFF9A3D), rgb(0xF2456E), rgb(0xB8338F)], atLocations: [0, 0.55, 1],
           colorSpace: .sRGB)!.draw(in: tilePath, angle: -60)

// Key cap: darker base (the key's side) with the lighter top face slightly raised.
let base = NSRect(x: 222, y: 236, width: 580, height: 560)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: rgb(0x5A0E3A, 0.45).cgColor)
rgb(0xFFFFFF, 0.22).setFill()
NSBezierPath(roundedRect: base, xRadius: 120, yRadius: 120).fill()
ctx.restoreGState()
let face = NSRect(x: 252, y: 290, width: 520, height: 476)
let facePath = NSBezierPath(roundedRect: face, xRadius: 100, yRadius: 100)
NSGradient(colors: [rgb(0xFFFFFF, 0.97), rgb(0xFFF1F4, 0.94)], atLocations: [0, 1], colorSpace: .sRGB)!
    .draw(in: facePath, angle: -90)

// Sound wave: rounded bars, symmetric, in the gradient's middle colour.
let heights: [CGFloat] = [70, 150, 250, 330, 250, 150, 70]
let barW: CGFloat = 40, gap: CGFloat = 22
let totalW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
var x = face.midX - totalW / 2
for h in heights {
    let bar = NSRect(x: x, y: face.midY - h / 2, width: barW, height: h)
    NSGradient(colors: [rgb(0xF04A6A), rgb(0xFF8A40)], atLocations: [0, 1], colorSpace: .sRGB)!
        .draw(in: NSBezierPath(roundedRect: bar, xRadius: barW / 2, yRadius: barW / 2), angle: 90)
    x += barW + gap
}

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
