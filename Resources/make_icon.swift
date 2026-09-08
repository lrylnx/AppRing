// Renders the AppRing icon (radial glass disc with orbiting app tiles) at
// 1024px and writes PNGs for every iconset size. Run:
//   swift make_icon.swift /path/to/AppIcon.iconset
import Cocoa

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func drawIcon(size px: CGFloat) -> Data? {
    let S = px
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    guard let ctx = NSGraphicsContext.current?.cgContext else { return nil }
    ctx.clear(CGRect(x: 0, y: 0, width: S, height: S))
    let u = S / 1024.0   // design units (1024-grid)

    // --- Squircle background: deep cool graphite, macOS Big Sur style ---
    let bg = CGRect(x: 0, y: 0, width: S, height: S).insetBy(dx: 60 * u, dy: 60 * u)
    let radius = bg.width * 0.2237
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: bg, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    let bgGrad = NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.19, blue: 0.27, alpha: 1),
                                     NSColor(srgbRed: 0.07, green: 0.08, blue: 0.12, alpha: 1)])
    bgGrad?.draw(in: bg, angle: -90)
    // Soft top-left light bloom.
    let bloom = NSGradient(colors: [NSColor(white: 1, alpha: 0.16), NSColor(white: 1, alpha: 0)],
                           atLocations: [0, 1], colorSpace: .deviceRGB)
    bloom?.draw(in: CGRect(x: bg.minX, y: bg.maxY - bg.height * 0.7,
                           width: bg.width, height: bg.height * 0.7), angle: -90)
    ctx.restoreGState()

    let c = CGPoint(x: bg.midX, y: bg.midY)

    // --- Glass disc ---
    let discR = 300.0 * u
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - discR, y: c.y - discR, width: discR * 2, height: discR * 2))
    ctx.clip()
    let disc = NSGradient(colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0.06),
                                   NSColor(white: 1, alpha: 0.12)],
                          atLocations: [0, 0.55, 1], colorSpace: .deviceRGB)
    disc?.draw(in: CGRect(x: c.x - discR, y: c.y - discR, width: discR * 2, height: discR * 2), angle: -90)
    ctx.restoreGState()
    // Rim.
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.75).cgColor)
    ctx.setLineWidth(10 * u)
    ctx.strokeEllipse(in: CGRect(x: c.x - discR, y: c.y - discR, width: discR * 2, height: discR * 2))
    ctx.setStrokeColor(NSColor(white: 0, alpha: 0.35).cgColor)
    ctx.setLineWidth(6 * u)
    ctx.strokeEllipse(in: CGRect(x: c.x - discR - 5 * u, y: c.y - discR - 5 * u,
                                 width: (discR + 5 * u) * 2, height: (discR + 5 * u) * 2))

    // --- Hub ---
    let hubR = 118.0 * u
    ctx.setFillColor(NSColor(white: 1, alpha: 0.10).cgColor)
    ctx.fillEllipse(in: CGRect(x: c.x - hubR, y: c.y - hubR, width: hubR * 2, height: hubR * 2))
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.35).cgColor)
    ctx.setLineWidth(5 * u)
    ctx.strokeEllipse(in: CGRect(x: c.x - hubR, y: c.y - hubR, width: hubR * 2, height: hubR * 2))

    // --- Orbiting app tiles ---
    let orbit = 218.0 * u
    let tile: CGFloat = 86 * u
    let palette: [NSColor] = [
        NSColor(srgbRed: 0.36, green: 0.56, blue: 0.98, alpha: 1),   // blue
        NSColor(srgbRed: 0.96, green: 0.62, blue: 0.30, alpha: 1),   // amber
        NSColor(srgbRed: 0.40, green: 0.74, blue: 0.50, alpha: 1),   // green
        NSColor(srgbRed: 0.62, green: 0.42, blue: 0.86, alpha: 1),   // violet
        NSColor(srgbRed: 0.28, green: 0.66, blue: 0.78, alpha: 1),   // teal
        NSColor(srgbRed: 0.92, green: 0.46, blue: 0.62, alpha: 1),   // pink
    ]
    let n = palette.count
    for i in 0..<n {
        let ang = .pi / 2 - CGFloat(i) * (2 * .pi / CGFloat(n))
        let p = CGPoint(x: c.x + cos(ang) * orbit, y: c.y + sin(ang) * orbit)
        let rect = CGRect(x: p.x - tile / 2, y: p.y - tile / 2, width: tile, height: tile)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6 * u), blur: 14 * u,
                      color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: tile * 0.24, cornerHeight: tile * 0.24, transform: nil))
        ctx.setFillColor(palette[i].cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        // Gloss.
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: tile * 0.24, cornerHeight: tile * 0.24, transform: nil))
        ctx.clip()
        let gloss = NSGradient(colors: [NSColor(white: 1, alpha: 0.35), NSColor(white: 1, alpha: 0)],
                               atLocations: [0, 1], colorSpace: .deviceRGB)
        gloss?.draw(in: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
        ctx.restoreGState()
    }

    // --- Highlighted tile (top): white halo ring, like the hover state ---
    let hp = CGPoint(x: c.x, y: c.y + orbit)
    let halo = tile * 0.86
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.95).cgColor)
    ctx.setLineWidth(9 * u)
    ctx.strokeEllipse(in: CGRect(x: hp.x - halo, y: hp.y - halo, width: halo * 2, height: halo * 2))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let specs: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in specs {
    guard let data = drawIcon(size: px) else { fatalError("render failed for \(name)") }
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}
print("✓ iconset written to \(outDir)")
