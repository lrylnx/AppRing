import Cocoa
import CoreGraphics

/// Lazy, per-session window thumbnail capture via the window server.
/// Requires the Screen Recording permission on macOS 14+; without it the
/// fan degrades to title-only cards. The cache is purged when the ring
/// closes — window contents change constantly, cross-session caching is
/// pointless.
@MainActor
final class WindowThumbnails {
    static let shared = WindowThumbnails()

    private let cache = NSCache<NSNumber, CGImage>()

    /// True when we've confirmed the user granted Screen Recording.
    static var hasScreenCapturePermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    private static var permissionRequested = false

    /// Nudge the system's Screen Recording prompt the first time the ring
    /// opens, so window previews work out of the box (macOS 14+ requires the
    /// grant for CGWindowListCreateImage). Idempotent per session; after the
    /// user grants it, restarting the app picks real thumbnails up.
    static func ensurePermissionRequested() {
        guard !permissionRequested else { return }
        permissionRequested = true
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    private init() {
        cache.countLimit = 40
    }

    func image(for windowID: UInt32) -> CGImage? {
        cache.object(forKey: NSNumber(value: windowID))
    }

    /// Capture one window's thumbnail off-main, call back on main.
    func thumbnail(for windowID: UInt32, maxSize: CGSize, completion: @escaping (CGImage?) -> Void) {
        let key = NSNumber(value: windowID)
        if let hit = cache.object(forKey: key) {
            completion(hit)
            return
        }
        guard Self.hasScreenCapturePermission else {
            completion(nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let options: CGWindowImageOption = [.boundsIgnoreFraming, .nominalResolution]
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                      CGWindowID(windowID), options) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            // Downscale to card size to keep the hot draw path cheap.
            let scale = min(maxSize.width / CGFloat(image.width),
                            maxSize.height / CGFloat(image.height), 1.0)
            let result: CGImage
            if scale < 0.999,
               let ctx = CGContext(data: nil,
                                   width: Int(CGFloat(image.width) * scale),
                                   height: Int(CGFloat(image.height) * scale),
                                   bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0,
                                           width: CGFloat(image.width) * scale,
                                           height: CGFloat(image.height) * scale))
                result = ctx.makeImage() ?? image
            } else {
                result = image
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.cache.setObject(result, forKey: key)
                completion(result)
            }
        }
    }

    func purge() {
        cache.removeAllObjects()
    }
}
