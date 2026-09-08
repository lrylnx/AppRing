import Cocoa

/// A full-screen, non-activating overlay panel that hosts the radial menu.
/// It never steals focus from the frontmost app; we only activate a target
/// app on commit. The panel covers the entire screen (not just visibleFrame)
/// so the fan-shaped window thumbnails are never clipped.
final class RingPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        animationBehavior = .utilityWindow
        hidesOnDeactivate = false
        isMovable = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performClose(_ sender: Any?) {}
}
