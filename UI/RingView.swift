import Cocoa
import CoreGraphics

/// One window entry in the fan (belongs to the highlighted app).
struct WindowCard {
    let windowID: UInt32
    let axIndex: Int      // position in the AX windows list (for focus)
    let title: String
}

/// Radial switcher: a thick frosted-glass disc carrying the running apps on an
/// orbit; hovering an app that owns several windows blooms a CoverFlow-style
/// row of window cards outward — each card is a real little window (title bar
/// with traffic lights, live thumbnail, glass bevel, cast shadow).
///
/// Performance rules that keep the sweep at 60fps (the old glass-lens variant
/// dropped frames because it repainted dozens of gradients per mouse move):
///   • the draw path stays cheap — flat fills plus a handful of cached gradients
///   • `needsDisplay` fires only over the region that actually changed
///   • thumbnails and icon shadows are built off the draw path and cached
@MainActor
final class RingView: NSView {
    // MARK: Layout constants (view points, origin bottom-left)
    // Scaled to match LumaRing's compact geometry: whole bloom fits inside a
    // ~210 pt radius instead of the old ~290.
    static let iconSize: CGFloat = 38
    /// Cards that can bloom at once; extras are summarised as "+N".
    static let maxPetals = 6
    /// Window card size and the arc spacing between card centers.
    static let cardW: CGFloat = 96
    static let cardH: CGFloat = 66
    static let cardSpacing: CGFloat = 74
    /// How much a card leans as it steps away from the focus (radians).
    static let cardTilt: CGFloat = 2.8 * .pi / 180

    // MARK: Dynamic geometry — the disc breathes with the app count:
    // few apps → tight, small circle; many apps → grows to fit.
    // Recomputed in updateMetrics() whenever `apps` changes.
    private(set) var centerR: CGFloat = 62           // center hub disk radius
    private(set) var orbitR: CGFloat = 88            // app icon orbit
    private(set) var discR: CGFloat = 118            // glass disc outer edge
    /// Card row orbit — always *outside* the disc so the cards bloom around it
    /// instead of covering the icons.
    private(set) var cardOrbitR: CGFloat = 150

    /// Radius that must stay clear of the screen edge so the whole bloom fits.
    var fanOuterExtent: CGFloat {
        let radial = cardOrbitR + Self.cardH / 2 + 22
        let tangential = Self.cardSpacing * CGFloat(Self.maxPetals - 1) / 2
            + Self.cardW / 2 + 26
        return max(radial, tangential)
    }

    // MARK: State
    //
    // The view covers the *whole screen*, so a full-bounds `needsDisplay` on
    // every hover change repaints the entire display — with blurred shadows
    // that blows past one frame and the highlight trails the cursor. State
    // changes therefore invalidate only the affected region:
    //   • discRect — hub + icons (highlight changes)
    //   • fanRect  — card row (cards / cardHighlight changes)
    // AppKit unions the rects; everything outside the clip is skipped early.
    var apps: [NSRunningApplication] = [] {
        didSet {
            updateMetrics()
            needsDisplay = true
        }
    }
    /// Visible-window count per app (index-aligned with `apps`); precomputed
    /// so the draw path never enumerates windows.
    var windowCounts: [Int] = []
    var highlight: Int? = nil {
        didSet {
            guard highlight != oldValue else { return }
            setNeedsDisplay(discRect)          // hub name, icons, halo
            if !cards.isEmpty { setNeedsDisplay(fanRect) }
        }
    }
    var cards: [WindowCard] = [] { didSet { setNeedsDisplay(fanRect) } }
    var cardHighlight: Int? = nil {
        didSet { guard cardHighlight != oldValue else { return }; setNeedsDisplay(fanRect) }
    }
    var center: NSPoint = .zero { didSet { needsDisplay = true } }

    /// Disc region (hub + icon orbit + badges), padded for stroke blur.
    private var discRect: NSRect { circleRect(discR + 12) }
    /// Full card-row region (cards may bloom at any angle around the disc).
    private var fanRect: NSRect { circleRect(fanOuterExtent + 12) }
    private func circleRect(_ r: CGFloat) -> NSRect {
        NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
    }

    // MARK: Cached draw resources (fonts / gradients built once)
    private static let hubFont = NSFont.systemFont(ofSize: 12.5, weight: .bold)
    private static let hubSubFont = NSFont.systemFont(ofSize: 9.5, weight: .medium)
    private static let badgeFont = NSFont.systemFont(ofSize: 11, weight: .bold)
    private static let titleFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
    private static let indexFont = NSFont.systemFont(ofSize: 9, weight: .bold)
    private static let overflowFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let hubParagraph: NSMutableParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.lineBreakMode = .byTruncatingMiddle
        return p
    }()

    /// Thick glass: bright specular band at the very top edge, easing through
    /// clear glass into a cool mid body and a dense base — reads as a solid
    /// lens with real thickness rather than a flat tint.
    private static let glassSheenGradient: CGGradient? = {
        let colors = [NSColor.white.withAlphaComponent(0.46).cgColor,
                      NSColor.white.withAlphaComponent(0.16).cgColor,
                      NSColor.white.withAlphaComponent(0.03).cgColor,
                      NSColor(white: 0.86, alpha: 0.05).cgColor,
                      NSColor.black.withAlphaComponent(0.20).cgColor] as CFArray
        return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors, locations: [0, 0.30, 0.52, 0.78, 1])
    }()
    /// Rim bevel colour: bright where the glass catches the light up top, dark
    /// where it curves away underneath.
    private static let bevelGradient: CGGradient? = {
        let colors = [NSColor.white.withAlphaComponent(0.62).cgColor,
                      NSColor.white.withAlphaComponent(0.10).cgColor,
                      NSColor.black.withAlphaComponent(0.30).cgColor] as CFArray
        return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors, locations: [0, 0.46, 1])
    }()
    /// Radial glow for the hovered app halo — white core fading to nothing.
    private static let highlightGlowGradient: CGGradient? = {
        let colors = [NSColor.white.withAlphaComponent(0.60).cgColor,
                      NSColor.white.withAlphaComponent(0.22).cgColor,
                      NSColor.white.withAlphaComponent(0.0).cgColor] as CFArray
        return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors, locations: [0, 0.52, 1])
    }()
    /// Glass body inside a window card: light top → cool mid → dense bottom.
    private static let cardGlassGradient: CGGradient? = {
        let colors = [NSColor.white.withAlphaComponent(0.34).cgColor,
                      NSColor.white.withAlphaComponent(0.10).cgColor,
                      NSColor.black.withAlphaComponent(0.12).cgColor] as CFArray
        return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors, locations: [0, 0.45, 1])
    }()
    /// Title strip of a window card.
    private static let cardChromeGradient: CGGradient? = {
        let colors = [NSColor.white.withAlphaComponent(0.30).cgColor,
                      NSColor.white.withAlphaComponent(0.08).cgColor] as CFArray
        return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors, locations: [0, 1])
    }()

    // MARK: Callbacks
    var onHoverApp: ((Int?) -> Void)?
    var onClickApp: ((Int) -> Void)?
    var onClickCard: ((Int) -> Void)?
    var onClickEmpty: (() -> Void)?

    private var pendingCaptures: Set<UInt32> = []

    /// Stable colour per app, derived from its pid — used for thumbnail
    /// placeholders so each card has its own brand-like tint.
    private static let placeholderPalette: [NSColor] = [
        NSColor(srgbRed: 0.34, green: 0.55, blue: 0.96, alpha: 1),   // blue
        NSColor(srgbRed: 0.86, green: 0.36, blue: 0.42, alpha: 1),   // crimson
        NSColor(srgbRed: 0.40, green: 0.74, blue: 0.50, alpha: 1),   // green
        NSColor(srgbRed: 0.96, green: 0.62, blue: 0.30, alpha: 1),   // amber
        NSColor(srgbRed: 0.62, green: 0.42, blue: 0.86, alpha: 1),   // violet
        NSColor(srgbRed: 0.28, green: 0.66, blue: 0.78, alpha: 1),   // teal
        NSColor(srgbRed: 0.92, green: 0.46, blue: 0.62, alpha: 1),   // pink
        NSColor(srgbRed: 0.50, green: 0.50, blue: 0.55, alpha: 1),   // graphite
    ]
    private static func placeholderTint(for app: NSRunningApplication, fallback: Int) -> NSColor {
        let pid = Int(app.processIdentifier)
        let idx = abs(pid) ^ abs((app.bundleIdentifier ?? "").hashValue)
        return placeholderPalette[(idx + fallback) % placeholderPalette.count]
    }
    /// Trim a window title so the card's chrome strip stays clean. Split on
    /// common separators first, then char-cap.
    private static func shortTitle(_ s: String, max: Int = 12) -> String {
        let parts = s.split(whereSeparator: { "|·•—|\\/\n".contains($0) })
        let pick = (parts.first.map(String.init) ?? s).trimmingCharacters(in: .whitespaces)
        if pick.isEmpty { return "窗口" }
        if pick.count <= max { return pick }
        return String(pick.prefix(max - 1)) + "…"
    }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Geometry

    /// Fit the ring to the app count. Adjacent icon centers are kept at a
    /// fixed chord (~70pt, a comfortable gap at 38pt icons), so with few apps
    /// the orbit — and the whole disc — shrinks instead of leaving huge gaps.
    /// Clamped to keep icons clear of the hub and readable when packed.
    private func updateMetrics() {
        let n = max(apps.count, 1)
        let chord: CGFloat = 70
        var orbit = chord / (2 * sin(.pi / CGFloat(n)))
        orbit = min(max(orbit, 62), 92)
        orbitR = orbit
        centerR = max(orbit - 26, 40)
        discR = orbit + 30
        // Card row sits just outside the disc with a small gap.
        cardOrbitR = discR + Self.cardH / 2 + 10
    }

    /// Angle of app slot `i`: slot 0 at the top, then clockwise (MRU order).
    private func slotAngle(_ i: Int) -> CGFloat {
        let n = max(apps.count, 1)
        return .pi / 2 - CGFloat(i) * (2 * .pi / CGFloat(n))
    }

    private func point(from angle: CGFloat, radius: CGFloat) -> NSPoint {
        NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }

    private func radius(_ p: NSPoint) -> CGFloat { hypot(p.x - center.x, p.y - center.y) }

    /// One laid-out card: where it sits, how far it leans, its scale and
    /// weight. Shared by the draw path and the hit tester so they can never
    /// disagree.
    private struct CardPlacement {
        let index: Int
        let origin: NSPoint     // bottom-left of the untransformed card rect
        let size: NSSize
        let tilt: CGFloat       // radians, small lean away from the focus
        let alpha: CGFloat
        let focused: Bool
        var rect: NSRect { NSRect(origin: origin, size: size) }
    }

    /// The bloom row, centered on the highlighted app's direction. Cards stay
    /// near-upright (so titles always read) and step along the arc, leaning a
    /// little outward while losing scale/weight — a shallow CoverFlow. The
    /// focused card lifts and grows; neighbours tuck slightly behind it.
    private func cardPlacements() -> [CardPlacement] {
        guard !cards.isEmpty, let h = highlight, apps.indices.contains(h) else { return [] }
        let base = slotAngle(h)
        let shown = min(cards.count, Self.maxPetals)
        let stepAngle = Self.cardSpacing / max(cardOrbitR, 1)
        var out: [CardPlacement] = []
        out.reserveCapacity(shown)
        for k in 0..<shown {
            let t = CGFloat(k) - CGFloat(shown - 1) / 2
            let angle = base + t * stepAngle
            let dist = abs(t)
            let focused = cardHighlight == k
            let radial = cardOrbitR - dist * 9 + (focused ? 14 : 0)
            let scale: CGFloat = focused ? 1.10 : max(0.80, 1 - 0.075 * dist)
            let size = NSSize(width: Self.cardW * scale, height: Self.cardH * scale)
            let c = point(from: angle, radius: radial)
            out.append(CardPlacement(
                index: k,
                origin: NSPoint(x: c.x - size.width / 2, y: c.y - size.height / 2),
                size: size,
                tilt: t * Self.cardTilt * (focused ? 0.25 : 1),
                alpha: focused ? 1 : max(0.62, 1 - 0.13 * dist),
                focused: focused))
        }
        return out
    }

    /// Is `p` inside a (lightly tilted) card? Transform the point into the
    /// card's own frame instead of transforming the geometry.
    private func cardHit(_ p: NSPoint, _ placement: CardPlacement) -> Bool {
        let r = placement.rect
        guard r.insetBy(dx: -3, dy: -3).contains(p) else { return false }
        guard abs(placement.tilt) > 0.002 else { return true }
        let dx = p.x - r.midX, dy = p.y - r.midY
        let cosT = cos(-placement.tilt), sinT = sin(-placement.tilt)
        let lx = dx * cosT - dy * sinT
        let ly = dx * sinT + dy * cosT
        return abs(lx) <= r.width / 2 + 3 && abs(ly) <= r.height / 2 + 3
    }

    private func hit(_ p: NSPoint) -> (app: Int?, card: Int?) {
        // Window cards win first; the row is the topmost layer.
        for placement in cardPlacements().reversed() {
            if cardHit(p, placement) { return (highlight, placement.index) }
        }
        let r = radius(p)
        let theta = atan2(p.y - center.y, p.x - center.x)
        // App ring: only inside the disc; the gap between disc edge and the
        // cards stays a dead zone (keeps the previous highlight).
        guard r > centerR + 12, r < discR else { return (nil, nil) }
        let n = apps.count
        guard n > 0 else { return (nil, nil) }
        let step = 2 * .pi / CGFloat(n)
        var u = (.pi / 2 - theta).truncatingRemainder(dividingBy: 2 * .pi)
        if u < 0 { u += 2 * .pi }
        let idx = Int(floor((u + step / 2) / step)) % n
        return (idx, nil)
    }

    // MARK: - Events

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let h = hit(p)
        let prevApp = highlight
        if let c = h.card {
            cardHighlight = c
        } else if let a = h.app {
            highlight = a
            cardHighlight = nil
        }
        // Gaps keep the previous highlight so the row stays open while the
        // pointer travels between the ring and a card.
        if highlight != prevApp { onHoverApp?(highlight) }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let h = hit(p)
        if let c = h.card {
            onClickCard?(c)
        } else if let a = h.app {
            onClickApp?(a)
        } else if radius(p) > discR {
            onClickEmpty?()
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        drawGlassDisc(ctx)
        drawHub(ctx)
        drawHighlightRing(ctx)
        drawAppRing(ctx)
        drawCardRow(ctx)
    }

    /// Convex glass disc: a vertical sheen clipped to the circle, a beveled
    /// rim that catches the light, a dense outer edge, and a specular arc
    /// across the top — the stack of cues that reads as thick glass.
    private func drawGlassDisc(_ ctx: CGContext) {
        let c = center
        let R = discR
        let disc = NSRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2)

        // 1. Sheen across the whole disc (clipped to the circle). CG origin is
        //    bottom-left, so the gradient runs from the disc top down.
        if let g = Self.glassSheenGradient {
            ctx.saveGState()
            ctx.addEllipse(in: disc.insetBy(dx: 1, dy: 1))
            ctx.clip()
            ctx.beginPath()
            ctx.drawLinearGradient(g,
                                   start: NSPoint(x: c.x, y: c.y + R),
                                   end: NSPoint(x: c.x, y: c.y - R),
                                   options: [])
            ctx.restoreGState()
        }

        // 2. Soft inner glow hugging the rim from underneath.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
        ctx.setLineWidth(8)
        ctx.strokeEllipse(in: disc.insetBy(dx: 4, dy: 4))

        // 3. Beveled edge: the top half of the rim is lit, the bottom half is
        //    the shaded side wall — one clipped gradient stroke does both.
        if let bg = Self.bevelGradient {
            ctx.saveGState()
            ctx.addEllipse(in: disc.insetBy(dx: 1.6, dy: 1.6))
            ctx.clip()
            ctx.beginPath()
            ctx.setLineWidth(3.4)
            ctx.drawLinearGradient(bg,
                                   start: NSPoint(x: c.x, y: c.y + R),
                                   end: NSPoint(x: c.x, y: c.y - R),
                                   options: [])
            ctx.strokeEllipse(in: disc.insetBy(dx: 1.6, dy: 1.6))
            ctx.restoreGState()
        }

        // 4. Hairline bright edge + faint dark outer ring — lifts the disc off
        //    the wallpaper.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: disc.insetBy(dx: 0.5, dy: 0.5))
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.26).cgColor)
        ctx.setLineWidth(1.1)
        ctx.strokeEllipse(in: disc.insetBy(dx: -1.1, dy: -1.1))

        // 5. Specular arc across the upper rim — the "light source" cue.
        ctx.saveGState()
        ctx.addEllipse(in: disc.insetBy(dx: 2, dy: 2))
        ctx.clip()
        ctx.beginPath()
        ctx.addArc(center: c, radius: R - 5,
                   startAngle: .pi * 0.62, endAngle: .pi * 0.90, clockwise: false)
        ctx.setLineCap(.round)
        ctx.setLineWidth(3)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// The hub reads as a solid glass dome pressed into the disc: a dark
    /// trench around it, a denser body, a lit top rim and bounce light along
    /// the bottom rim.
    private func drawHub(_ ctx: CGContext) {
        let r = centerR
        let rect = NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)

        // Trench between hub and ring.
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.16).cgColor)
        ctx.setLineWidth(5)
        ctx.strokeEllipse(in: rect.insetBy(dx: -3, dy: -3))

        // Hub body: slightly denser glass than the surrounding disc.
        ctx.saveGState()
        ctx.addEllipse(in: rect.insetBy(dx: 1, dy: 1))
        ctx.clip()
        ctx.beginPath()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.10).cgColor)
        ctx.fill(rect)
        if let g = Self.glassSheenGradient {
            ctx.drawLinearGradient(g,
                                   start: NSPoint(x: center.x, y: center.y + r),
                                   end: NSPoint(x: center.x, y: center.y - r),
                                   options: [])
        }
        // Lit top rim + bounce light on the bottom rim.
        ctx.addArc(center: center, radius: r - 1.6,
                   startAngle: .pi * 0.16, endAngle: .pi * 0.84, clockwise: false)
        ctx.setLineCap(.round)
        ctx.setLineWidth(1.6)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        ctx.strokePath()
        ctx.addArc(center: center, radius: r - 2.4,
                   startAngle: .pi * 1.18, endAngle: .pi * 1.82, clockwise: false)
        ctx.setLineWidth(1.8)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.34).cgColor)
        ctx.strokePath()
        ctx.restoreGState()

        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.20).cgColor)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))

        guard let h = highlight, apps.indices.contains(h) else { return }
        let name = (apps[h].localizedName ?? "").trimmingCharacters(in: .whitespaces)
        (name as NSString).draw(
            in: NSRect(x: center.x - r + 12, y: center.y - 11, width: (r - 12) * 2, height: 22),
            withAttributes: [
                .font: Self.hubFont,
                .foregroundColor: NSColor(white: 0.10, alpha: 0.96),
                .paragraphStyle: Self.hubParagraph,
            ])
        // Window-count sub-line — hints that a bloom is available.
        let count = windowCounts.indices.contains(h) ? windowCounts[h] : 0
        if count > 1 {
            let sub = "\(count) 个窗口" as NSString
            let ss = sub.size(withAttributes: [.font: Self.hubSubFont])
            sub.draw(at: NSPoint(x: center.x - ss.width / 2, y: center.y - 29),
                     withAttributes: [.font: Self.hubSubFont,
                                      .foregroundColor: NSColor(white: 0.16, alpha: 0.7)])
        }
    }

    /// Frosted halo behind the hovered app's icon — contact shadow underneath,
    /// radial glow, crisp rim — so the selected icon sits *above* the glass.
    private func drawHighlightRing(_ ctx: CGContext) {
        guard let h = highlight, apps.indices.contains(h) else { return }
        let p = point(from: slotAngle(h), radius: orbitR)
        let r = Self.iconSize / 2 + 9
        let rect = NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 12,
                      color: NSColor.black.withAlphaComponent(0.38).cgColor)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.02).cgColor)
        ctx.fillEllipse(in: rect.insetBy(dx: 3, dy: 3))
        ctx.restoreGState()

        if let g = Self.highlightGlowGradient {
            ctx.saveGState()
            ctx.addEllipse(in: rect)
            ctx.clip()
            ctx.beginPath()
            ctx.drawRadialGradient(g,
                                   startCenter: p, startRadius: 0,
                                   endCenter: p, endRadius: r,
                                   options: [])
            ctx.restoreGState()
        }
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.24).cgColor)
        ctx.fillEllipse(in: rect)

        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.16).cgColor)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: rect.insetBy(dx: -0.8, dy: -0.8))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        ctx.setLineWidth(1.6)
        ctx.strokeEllipse(in: rect.insetBy(dx: 0.8, dy: 0.8))
    }

    private func drawAppRing(_ ctx: CGContext) {
        let n = apps.count
        guard n > 0 else { return }
        let s = Self.iconSize
        let hot = highlight
        for i in 0..<n {
            let p = point(from: slotAngle(i), radius: orbitR)
            // Depth cue without animation cost: the hovered icon is drawn
            // bigger and fully opaque, everything else settles back.
            let focused = (i == hot)
            let side = s * (focused ? 1.12 : 0.94)
            let rect = NSRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side)
            ctx.saveGState()
            if !focused { ctx.setAlpha(hot == nil ? 0.95 : 0.72) }
            // The cached bitmap has its soft drop shadow baked in (IconCache),
            // so this stays a single plain image draw.
            if let icon = IconCache.shared.cachedIcon(for: apps[i], size: s) {
                let pad = IconCache.shadowPad
                icon.draw(in: rect.insetBy(dx: -pad, dy: -pad),
                          from: .zero, operation: .sourceOver, fraction: 1)
            } else {
                ctx.setFillColor(NSColor(white: 0.5, alpha: 0.5).cgColor)
                ctx.addRoundedRect(in: rect, cornerSize: NSSize(width: 13, height: 13))
                ctx.fillPath()
                let app = apps[i]
                IconCache.shared.iconAsync(for: app, size: s) { [weak self] _ in
                    guard let self else { return }
                    self.setNeedsDisplay(self.discRect)
                }
            }
            // Glass plinth around the hovered tile: a lit slab the icon sits
            // on, anchoring it to the disc.
            if focused {
                ctx.addRoundedRect(in: rect.insetBy(dx: -2, dy: -2),
                                   cornerSize: NSSize(width: 16, height: 16))
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.30).cgColor)
                ctx.setLineWidth(1)
                ctx.strokePath()
            }
            ctx.restoreGState()

            // Red count badge with a soft glow.
            let count = windowCounts.indices.contains(i) ? windowCounts[i] : 0
            guard count > 1 else { continue }
            let badge = "\(count)" as NSString
            let bf = Self.badgeFont
            let bs = badge.size(withAttributes: [.font: bf])
            let d = max(bs.width + 9, bs.height + 7)
            let br = NSRect(x: rect.maxX - d + 3, y: rect.minY - 3, width: d, height: d)
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 5, color: NSColor.black.withAlphaComponent(0.45).cgColor)
            ctx.setFillColor(NSColor.systemRed.cgColor)
            ctx.addEllipse(in: br)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.addEllipse(in: br.insetBy(dx: 0.5, dy: 0.5))
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
            badge.draw(at: NSPoint(x: br.midX - bs.width / 2, y: br.midY - bs.height / 2),
                       withAttributes: [.font: bf, .foregroundColor: NSColor.white])
        }
    }

    // MARK: Card row (multi-window mode)

    /// A row of miniature windows: chrome strip with traffic lights and title,
    /// live thumbnail below, glass bevel all around, lifted when focused.
    private func drawCardRow(_ ctx: CGContext) {
        let placements = cardPlacements()
        guard !placements.isEmpty, let h = highlight, apps.indices.contains(h) else { return }
        let app = apps[h]

        // Painter's order: outer cards first so the focused one overlaps them.
        let order = placements.sorted { a, b in
            let da = hypot(a.rect.midX - center.x, a.rect.midY - center.y)
            let db = hypot(b.rect.midX - center.x, b.rect.midY - center.y)
            return da > db
        }
        for placement in order {
            drawCard(ctx, placement, app: app)
        }

        if cards.count > placements.count {
            let last = placements[placements.count - 1]
            let r = last.rect
            let overflow = "+\(cards.count - placements.count)" as NSString
            let os = overflow.size(withAttributes: [.font: Self.overflowFont])
            // Dark pill so the hint survives on any wallpaper.
            let pill = NSRect(x: r.maxX + 6, y: r.midY - os.height / 2 - 6,
                              width: os.width + 12, height: os.height + 12)
            ctx.addRoundedRect(in: pill, cornerSize: NSSize(width: 8, height: 8))
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            ctx.fillPath()
            overflow.draw(at: NSPoint(x: pill.midX - os.width / 2, y: pill.midY - os.height / 2),
                          withAttributes: [.font: Self.overflowFont,
                                           .foregroundColor: NSColor.white.withAlphaComponent(0.92)])
        }
    }

    private func drawCard(_ ctx: CGContext, _ placement: CardPlacement, app: NSRunningApplication) {
        let card = cards[placement.index]
        let wid = card.windowID
        let w = placement.size.width, h = placement.size.height
        let corner = min(14, w * 0.13)
        let tint = Self.placeholderTint(for: app, fallback: placement.index)

        ctx.saveGState()
        ctx.setAlpha(placement.alpha)
        ctx.translateBy(x: placement.origin.x + w / 2, y: placement.origin.y + h / 2)
        ctx.rotate(by: placement.tilt)
        let local = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)

        func roundedPath(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
            CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        let path = roundedPath(local, corner)

        // 1. Cast shadow — the card floats above the disc; the focused one
        //    floats higher.
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setShadow(offset: CGSize(width: 0, height: placement.focused ? -9 : -5),
                      blur: placement.focused ? 18 : 11,
                      color: NSColor.black.withAlphaComponent(placement.focused ? 0.5 : 0.32).cgColor)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.9).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // 2. Glass body.
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.beginPath()
        let body = tint.blended(withFraction: 0.42, of: NSColor.black) ?? tint
        ctx.setFillColor(body.withAlphaComponent(0.9).cgColor)
        ctx.fill(local)
        if let g = Self.cardGlassGradient {
            ctx.drawLinearGradient(g,
                                   start: NSPoint(x: 0, y: local.maxY),
                                   end: NSPoint(x: 0, y: local.minY),
                                   options: [])
        }
        ctx.restoreGState()

        // 3. Thumbnail (or monogram placeholder) in the body area.
        let chromeH = min(20, h * 0.26)
        let body0 = CGRect(x: local.minX + 4, y: local.minY + 4,
                           width: local.width - 8, height: local.height - chromeH - 8)
        ctx.saveGState()
        ctx.addPath(roundedPath(body0, corner * 0.55))
        ctx.clip()
        ctx.beginPath()
        if let thumb = WindowThumbnails.shared.image(for: wid) {
            ctx.draw(thumb, in: Self.aspectFill(CGSize(width: thumb.width, height: thumb.height), body0))
            // Faint wash so the white chrome stays the brightest thing.
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.05).cgColor)
            ctx.fill(body0)
        } else {
            // No live capture (permission not yet granted or still in flight):
            // paint a miniature "window preview" — a faux document with text
            // lines and the app's icon centred — instead of a bare letter.
            drawPreviewPlaceholder(ctx, app: app, body: body0, tint: tint)
        }
        ctx.restoreGState()

        // 4. Chrome strip: traffic lights + centred title.
        let strip = CGRect(x: local.minX, y: local.maxY - chromeH,
                           width: local.width, height: chromeH)
        ctx.saveGState()
        ctx.addRect(strip)
        ctx.clip()
        ctx.beginPath()
        if let g = Self.cardChromeGradient {
            ctx.drawLinearGradient(g,
                                   start: NSPoint(x: 0, y: strip.maxY),
                                   end: NSPoint(x: 0, y: strip.minY),
                                   options: [])
        }
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
        ctx.setLineWidth(0.8)
        ctx.move(to: NSPoint(x: strip.minX + 6, y: strip.minY))
        ctx.addLine(to: NSPoint(x: strip.maxX - 6, y: strip.minY))
        ctx.strokePath()

        let dotR: CGFloat = min(2.6, chromeH * 0.15)
        let dotY = strip.midY + 0.5
        let dots: [NSColor] = [
            NSColor(srgbRed: 0.99, green: 0.38, blue: 0.35, alpha: 0.92),
            NSColor(srgbRed: 0.99, green: 0.75, blue: 0.24, alpha: 0.92),
            NSColor(srgbRed: 0.39, green: 0.82, blue: 0.34, alpha: 0.92),
        ]
        for (i, col) in dots.enumerated() {
            let x = strip.minX + 7 + CGFloat(i) * (dotR * 2 + 3)
            ctx.setFillColor(col.cgColor)
            ctx.fillEllipse(in: CGRect(x: x - dotR, y: dotY - dotR, width: dotR * 2, height: dotR * 2))
        }

        let tf = Self.titleFont
        let avail = max(strip.width - (dotR * 2 + 3) * 3 - 24, 20)
        let shownTitle = (Self.shortTitle(card.title) as NSString).clipping(to: avail, font: tf)
        let ts = shownTitle.size(withAttributes: [.font: tf])
        shownTitle.draw(at: NSPoint(x: strip.midX - ts.width / 2 + 8, y: strip.midY - ts.height / 2),
                        withAttributes: [.font: tf,
                                         .foregroundColor: NSColor.white.withAlphaComponent(0.96)])

        // 5. Index pill — mirrors the arrow-key order, so the keyboard path is
        //    legible next to the mouse path.
        let num = "\(placement.index + 1)" as NSString
        let nf = Self.indexFont
        let ns = num.size(withAttributes: [.font: nf])
        let pr = max(ns.width + 7, ns.height + 5) / 2
        let pillRect = CGRect(x: local.maxX - pr * 2 - 5, y: local.minY + 5,
                              width: pr * 2, height: pr * 2)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.fillEllipse(in: pillRect)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(0.8)
        ctx.strokeEllipse(in: pillRect.insetBy(dx: 0.4, dy: 0.4))
        num.draw(at: NSPoint(x: pillRect.midX - ns.width / 2, y: pillRect.midY - ns.height / 2),
                 withAttributes: [.font: nf, .foregroundColor: NSColor.white])

        // 6. Bevel: dark outer edge, bright inner rim; the focused card gets an
        //    extra frosted band so it visibly pops.
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(placement.focused ? 0.34 : 0.24).cgColor)
        ctx.setLineWidth(1.1)
        ctx.strokePath()
        ctx.addPath(roundedPath(local.insetBy(dx: 1, dy: 1), max(corner - 1, 4)))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(placement.focused ? 0.95 : 0.55).cgColor)
        ctx.setLineWidth(placement.focused ? 1.8 : 1)
        ctx.strokePath()
        if placement.focused {
            ctx.addPath(roundedPath(local.insetBy(dx: 3.2, dy: 3.2), max(corner - 3, 3)))
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
            ctx.setLineWidth(3.5)
            ctx.strokePath()
        }
        ctx.restoreGState()

        // 7. Trigger capture off the draw path; the completion repaints just the
        //    row once the real thumbnail lands.
        if WindowThumbnails.shared.image(for: wid) == nil, !pendingCaptures.contains(wid) {
            pendingCaptures.insert(wid)
            WindowThumbnails.shared.thumbnail(
                for: wid,
                maxSize: CGSize(width: Self.cardW * 3, height: Self.cardH * 3)
            ) { [weak self] _ in
                guard let self else { return }
                self.pendingCaptures.remove(wid)
                self.setNeedsDisplay(self.fanRect)
            }
        }
    }

    /// Preview shown until a live capture lands: a mini "document" window —
    /// tinted header bar, greyed text lines, the app icon as a small badge —
    /// so the card reads as a window preview instead of a bare letter.
    private func drawPreviewPlaceholder(_ ctx: CGContext, app: NSRunningApplication,
                                        body: CGRect, tint: NSColor) {
        let paper = body.insetBy(dx: body.width * 0.10, dy: body.height * 0.10)
        let paperCorner: CGFloat = min(6, paper.width * 0.08)
        let paperPath = CGPath(roundedRect: paper, cornerWidth: paperCorner,
                               cornerHeight: paperCorner, transform: nil)

        // Paper sheet with its own soft shadow, so it sits "inside" the card.
        ctx.saveGState()
        ctx.addPath(paperPath)
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 4,
                      color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.setFillColor(NSColor(white: 0.97, alpha: 0.96).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(paperPath)
        ctx.clip()
        ctx.beginPath()

        // Header band in the card's tint, with two faux window dots.
        let headerH = max(8, paper.height * 0.22)
        let header = CGRect(x: paper.minX, y: paper.maxY - headerH,
                            width: paper.width, height: headerH)
        ctx.setFillColor((tint.blended(withFraction: 0.15, of: NSColor.white) ?? tint)
            .withAlphaComponent(0.9).cgColor)
        ctx.fill(header)
        let dot = headerH * 0.22
        for i in 0..<2 {
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
            ctx.fillEllipse(in: CGRect(x: header.minX + 3 + CGFloat(i) * (dot + 2),
                                       y: header.midY - dot / 2, width: dot, height: dot))
        }

        // Faux text lines: full width, then shorter — the eye reads "content".
        let lineH = max(1.6, paper.height * 0.075)
        let lineGap = lineH * 1.9
        let left = paper.minX + paper.width * 0.08
        let usable = paper.width * 0.62
        var y = header.minY - lineGap
        let lineColor = NSColor(white: 0.62, alpha: 0.9).cgColor
        for frac in [1.0, 0.82, 0.55] as [CGFloat] {
            let bar = CGRect(x: left, y: y, width: usable * frac, height: lineH)
            ctx.addRoundedRect(in: bar, cornerSize: NSSize(width: lineH / 2, height: lineH / 2))
            ctx.setFillColor(lineColor)
            ctx.fillPath()
            y -= lineGap
        }

        // App-icon badge, bottom-right of the sheet.
        let badgeS = min(paper.height * 0.42, paper.width * 0.30)
        let badge = CGRect(x: paper.maxX - badgeS - paper.width * 0.06,
                           y: paper.minY + paper.height * 0.08,
                           width: badgeS, height: badgeS)
        ctx.setFillColor(NSColor(white: 1, alpha: 0.55).cgColor)
        ctx.addRoundedRect(in: badge.insetBy(dx: -badgeS * 0.10, dy: -badgeS * 0.10),
                           cornerSize: NSSize(width: badgeS * 0.28, height: badgeS * 0.28))
        ctx.fillPath()
        ctx.interpolationQuality = .high
        if let icon = IconCache.shared.cachedIcon(for: app, size: Self.iconSize) {
            icon.draw(in: badge, from: .zero, operation: .sourceOver, fraction: 0.95)
        } else {
            IconCache.shared.iconAsync(for: app, size: Self.iconSize) { [weak self] _ in
                self?.setNeedsDisplay(self?.fanRect ?? .zero)
            }
        }
        ctx.restoreGState()
    }

    /// Rect that `aspect` fills while covering `into` (centre-anchored).
    private static func aspectFill(_ aspect: CGSize, _ into: CGRect) -> CGRect {
        guard aspect.width > 0, aspect.height > 0 else { return into }
        let scale = max(into.width / aspect.width, into.height / aspect.height)
        let w = aspect.width * scale, hh = aspect.height * scale
        return CGRect(x: into.midX - w / 2, y: into.midY - hh / 2, width: w, height: hh)
    }
}

private extension NSString {
    /// Receiver truncated with an ellipsis so it renders within `width`.
    func clipping(to width: CGFloat, font: NSFont) -> NSString {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        if size(withAttributes: attrs).width <= width { return self }
        var s = ""
        for ch in (self as String) {
            let next = (s + String(ch)) as NSString
            if next.size(withAttributes: attrs).width > width - 8 { break }
            s += String(ch)
        }
        return (s.isEmpty ? "…" : s + "…") as NSString
    }
}

private extension CGContext {
    func addRoundedRect(in rect: NSRect, cornerSize: NSSize) {
        addPath(CGPath(roundedRect: rect,
                       cornerWidth: cornerSize.width,
                       cornerHeight: cornerSize.height,
                       transform: nil))
    }
}
