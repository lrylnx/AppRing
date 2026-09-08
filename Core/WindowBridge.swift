import Cocoa
import ApplicationServices

/// Bridges to the window server (window enumeration) and the Accessibility
/// API (titles, focus). Ported from Waybar's WindowBridge. Every AX call
/// carries a short messaging timeout so a hung app can never stall the ring.
enum WindowBridge {
    // MARK: - Window enumeration (no special permission required)

    /// On-screen, normal-layer window ids of a process, front-to-back.
    static func onScreenWindowIDs(of pid: pid_t) -> [UInt32] {
        onScreenWindows().filter { $0.pid == pid }.map(\.id)
    }

    /// All on-screen normal-layer windows grouped by owner pid, front-to-back.
    static func onScreenWindows() -> [(pid: pid_t, id: UInt32)] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [(pid_t, UInt32)] = []
        for info in infoList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let windowID = info[kCGWindowNumber as String] as? UInt32,
                  let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0.01,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let w = bounds["Width"] as? Double, let h = bounds["Height"] as? Double,
                  w > 1, h > 1
            else { continue }
            out.append((ownerPID, windowID))
        }
        return out
    }

    /// Visible window count per pid in a single window-list pass.
    static func visibleWindowCounts() -> [pid_t: Int] {
        var counts: [pid_t: Int] = [:]
        for (pid, _) in onScreenWindows() { counts[pid, default: 0] += 1 }
        return counts
    }

    // MARK: - Accessibility

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Titles of an app's windows, ordered front-to-back to pair positionally
    /// with `onScreenWindowIDs`. Falls back to "窗口 N" when AX is unavailable.
    static func windowTitles(of pid: pid_t, matching ids: [UInt32]) -> [String] {
        guard isTrusted else { return ids.indices.map { "窗口 \($0 + 1)" } }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let axWindows = value as? [AXUIElement] else {
            return ids.indices.map { "窗口 \($0 + 1)" }
        }
        var titles: [String] = []
        for win in axWindows {
            var t: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &t) == .success,
               let title = t as? String, !title.isEmpty {
                titles.append(title)
            } else {
                titles.append("窗口")
            }
        }
        // Pair positionally with the on-screen ids (both front-to-back); any
        // missing titles fall back to a generic label.
        return ids.indices.map { $0 < titles.count ? titles[$0] : "窗口 \($0 + 1)" }
    }

    /// Raise + focus a specific window of `pid`. `index` is the position in
    /// the front-to-back AX window list (same order as `windowTitles`).
    static func focusWindow(index: Int, pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], windows.indices.contains(index) else {
            NSRunningApplication(processIdentifier: pid)?.activate()
            return
        }
        let win = windows[index]
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(win, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    /// Bring an app to the front the same way a Dock click does: the
    /// LaunchServices path (`NSWorkspace.openApplication(activates:)`), which
    /// works reliably from a non-active accessory app, unlike the bare
    /// `NSRunningApplication.activate()` / AX-frontmost requests that macOS
    /// often ignores. After the completion we verify frontmost and retry via
    /// AX as a safety net. `then` runs once the app is (or should be) frontmost.
    static func raiseApp(_ app: NSRunningApplication, then: (() -> Void)? = nil) {
        func finish() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                    forceActivate(app)
                }
                then?()
            }
        }
        guard let url = app.bundleURL else {
            forceActivate(app)
            finish()
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.promptsUserIfNeeded = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            DispatchQueue.main.async {
                if error != nil { forceActivate(app) }
                finish()
            }
        }
    }

    /// Last-resort activation: AX frontmost + `activate()`.
    private static func forceActivate(_ app: NSRunningApplication) {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.2)
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        app.activate()
    }
}
