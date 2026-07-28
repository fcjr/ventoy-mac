import AppKit

// Renders the app icon at every size an .iconset needs.
// Usage: swift icon.swift <output-iconset-dir>

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ s: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x * s, y: y * s, width: w * s, height: h * s),
           cornerWidth: r * s, cornerHeight: r * s, transform: nil)
}

func vGradient(_ ctx: CGContext, _ path: CGPath, top: CGColor, bottom: CGColor,
               yTop: CGFloat, yBottom: CGFloat, _ s: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let cs = CGColorSpaceCreateDeviceRGB()
    let grad = CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: 0, y: yTop * s),
                           end: CGPoint(x: 0, y: yBottom * s),
                           options: [])
    ctx.restoreGState()
}

func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

func draw(_ ctx: CGContext, px: Int) {
    let s = CGFloat(px) / 1024.0
    ctx.clear(CGRect(x: 0, y: 0, width: px, height: px))

    let bg = rr(100, 100, 824, 824, 148, s)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 22 * s,
                  color: c(0, 0, 0, 0.30))
    ctx.addPath(bg)
    ctx.setFillColor(c(1, 1, 1))
    ctx.fillPath()
    ctx.restoreGState()

    vGradient(ctx, bg, top: c(0.960, 0.970, 0.980), bottom: c(0.835, 0.865, 0.900),
              yTop: 924, yBottom: 100, s)

    let connector = rr(412, 632, 200, 140, 18, s)
    vGradient(ctx, connector, top: c(0.780, 0.810, 0.850), bottom: c(0.600, 0.640, 0.690),
              yTop: 772, yBottom: 632, s)
    ctx.setFillColor(c(0.420, 0.460, 0.510))
    ctx.addPath(rr(450, 700, 42, 24, 6, s))
    ctx.addPath(rr(532, 700, 42, 24, 6, s))
    ctx.fillPath()

    let body = rr(342, 252, 340, 396, 52, s)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 12 * s,
                  color: c(0, 0, 0, 0.25))
    ctx.addPath(body)
    ctx.setFillColor(c(0.16, 0.19, 0.24))
    ctx.fillPath()
    ctx.restoreGState()
    vGradient(ctx, body, top: c(0.205, 0.245, 0.295), bottom: c(0.120, 0.148, 0.185),
              yTop: 648, yBottom: 252, s)

    let bar = rr(387, 414, 250, 72, 16, s)
    ctx.saveGState()
    ctx.addPath(bar)
    ctx.clip()
    ctx.setFillColor(c(0.10, 0.46, 0.90))
    ctx.fill(CGRect(x: 387 * s, y: 414 * s, width: 196 * s, height: 72 * s))
    ctx.setFillColor(c(0.96, 0.62, 0.26))
    ctx.fill(CGRect(x: 589 * s, y: 414 * s, width: 48 * s, height: 72 * s))
    ctx.restoreGState()
}

func render(px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    draw(gctx.cgContext, px: px)
    gctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let entries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in entries {
    let rep = render(px: px)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("png encode failed for \(name)")
    }
    try! data.write(to: URL(fileURLWithPath: outDir + "/" + name))
}
print("wrote \(entries.count) images to \(outDir)")
