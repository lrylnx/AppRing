import Cocoa

/// Cached, pre-rendered app icons keyed by pid+size. Cells draw the bitmap at
/// a fixed size so no scaling happens in the hot draw path. The soft drop
/// shadow is *baked into* the cached bitmap at render time — the ring's draw
/// path never pays for a live blur on every frame.
@MainActor
final class IconCache {
    static let shared = IconCache()

    /// Padding around the icon inside the cached bitmap; holds the baked-in
    /// shadow. Draw sites inset the icon rect by this amount.
    static let shadowPad: CGFloat = 6

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 300
    }

    func cachedIcon(for app: NSRunningApplication, size: CGFloat) -> NSImage? {
        cache.object(forKey: cacheKey(app, size))
    }

    func iconAsync(for app: NSRunningApplication, size: CGFloat, completion: @escaping (NSImage) -> Void) {
        let key = cacheKey(app, size)
        if let hit = cache.object(forKey: key) {
            completion(hit)
            return
        }
        let url = app.bundleURL
        let pid = app.processIdentifier
        let path = app.bundleURL?.path ?? ""
        // Icon extraction touches LaunchServices and can block; do it off-main.
        // The bitmap render itself must happen on the main thread (lockFocus).
        DispatchQueue.global(qos: .userInitiated).async {
            let source = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? NSImage(named: NSImage.applicationIconName)!
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let target = Self.render(source, size: size)
                let key = "\(pid)|\(path)|\(Int(size))" as NSString
                self.cache.setObject(target, forKey: key)
                completion(target)
            }
        }
    }

    /// Render `source` at `size` into a bitmap with the drop shadow baked in.
    /// One-time cost per icon; the hot draw path then does a single image draw.
    private static func render(_ source: NSImage, size: CGFloat) -> NSImage {
        let pad = shadowPad
        let target = NSImage(size: NSSize(width: size + pad * 2, height: size + pad * 2))
        target.lockFocus()
        let shadow = NSShadow()
        shadow.shadowOffset = CGSize(width: 0, height: -2)
        shadow.shadowBlurRadius = 7
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
        shadow.set()
        source.draw(in: NSRect(x: pad, y: pad, width: size, height: size),
                    from: .zero, operation: .sourceOver, fraction: 1.0,
                    respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        target.unlockFocus()
        return target
    }

    func prefetch(_ apps: [NSRunningApplication], size: CGFloat) {
        for app in apps {
            iconAsync(for: app, size: size) { _ in }
        }
    }

    private func cacheKey(_ app: NSRunningApplication, _ size: CGFloat) -> NSString {
        "\(app.processIdentifier)|\(app.bundleURL?.path ?? "")|\(Int(size))" as NSString
    }
}
