// Renders the Leftless app icon (1024×1024 PNG). Usage: swift scripts/render-icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
// Top-left origin for easier layout.
ctx.translateBy(x: 0, y: size); ctx.scaleBy(x: 1, y: -1)

func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
}
func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// Background tile (macOS icon grid: 824pt body inset 100pt, radius ~185).
let tile = rr(100, 100, 824, 824, 185)
ctx.saveGState()
ctx.addPath(tile); ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                      colors: [color(0x4A86F7), color(0x2459D6)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
ctx.restoreGState()

// App square with the letter L cut out.
let sq = CGRect(x: 236, y: 332, width: 360, height: 360)
ctx.addPath(rr(sq.minX, sq.minY, sq.width, sq.height, 76))
ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
let stroke: CGFloat = 70
ctx.setStrokeColor(color(0x2F6FED))
ctx.setLineWidth(stroke); ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: sq.minX + 128, y: sq.minY + 92))
ctx.addLine(to: CGPoint(x: sq.minX + 128, y: sq.maxY - 96))
ctx.addLine(to: CGPoint(x: sq.maxX - 96, y: sq.maxY - 96))
ctx.strokePath()

// Particles drifting away to the right, shrinking and fading.
let bits: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [ // x, y, side, alpha
    (630, 372, 70, 0.85), (636, 486, 50, 0.6), (726, 432, 40, 0.45),
    (628, 586, 34, 0.35), (716, 556, 26, 0.25), (790, 498, 20, 0.18)
]
for (x, y, s, a) in bits {
    ctx.addPath(rr(x, y, s, s, s * 0.22))
    ctx.setFillColor(color(0xFFFFFF, a)); ctx.fillPath()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
