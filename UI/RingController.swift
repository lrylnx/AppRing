import Cocoa
import Carbon.HIToolbox

/// Orchestrates the radial switcher: summon at the pointer, hover/keyboard
/// navigation, window petals, commit/cancel semantics per trigger.
@MainActor
final class RingController: NSObject, EventTapDelegate {
    enum Trigger { case cmdTab, sideButton }

    static let shared = RingController()

    /// Initial corner radius before the first show() sizes the backdrop from
    /// the live (app-count-driven) disc radius.
    private static let startingDiscR: CGFloat = 118

    private let panel = RingPanel()
    private let ringView = RingView()
    private let container = NSView()
    /// Circular frosted-glass disk behind the ring. Sized dynamically from
    /// `ringView.discR` (which scales with the app count); the glass rim
    /// stroke is drawn by RingView on top, so no layer border here.
    private let backdrop: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.material = .menu
        v.state = .active
        v.blendingMode = .behindWindow
        v.wantsLayer = true
        return v
    }()
    /// Pure shadow caster sitting under the backdrop (the backdrop clips its
    /// own shadow via masksToBounds, so the drop shadow needs its own layer).
    private let shadowDisk = NSView()
    private let tap = EventTap()

    private(set) var visible = false
    private var trigger: Trigger = .cmdTab
    private var idleTimer: Timer?
    private var dwellTimer: Timer?
    private var pendingFanApp: Int?
    private var fanToken = 0

    private override init() {
        super.init()
        if let layer = backdrop.layer {
            layer.cornerRadius = Self.startingDiscR
            layer.masksToBounds = true
            // Coloured tint underneath: gives the frosted glass a cool,
            // "dense glass" cast instead of the neutral menu default.
            layer.backgroundColor = NSColor(white: 0.18, alpha: 0.12).cgColor
        }
        shadowDisk.wantsLayer = true
        if let sl = shadowDisk.layer {
            sl.cornerRadius = Self.startingDiscR
            sl.backgroundColor = NSColor.black.withAlphaComponent(0.001).cgColor
            sl.shadowColor = NSColor.black.withAlphaComponent(0.45).cgColor
            sl.shadowOpacity = 1
            sl.shadowRadius = 34
            sl.shadowOffset = CGSize(width: 0, height: -14)
        }
        container.addSubview(shadowDisk)
        container.addSubview(backdrop)
        container.addSubview(ringView)
        container.wantsLayer = true
        panel.contentView = container
        // No entry animation: the ring must appear the instant it is summoned.
        container.alphaValue = 1
        tap.delegate = self
        ringView.onHoverApp = { [weak self] in self?.appHovered($0) }
        ringView.onClickApp = { [weak self] in self?.appClicked($0) }
        ringView.onClickCard = { [weak self] in self?.cardClicked($0) }
        ringView.onClickEmpty = { [weak self] in self?.cancel() }
    }

    // MARK: - Lifecycle

    var sideButtonEnabled: Bool {
        get { tap.sideButtonEnabled }
        set { tap.sideButtonEnabled = newValue }
    }

    /// Install a shortcut recorder on the tap; pass nil to restore normal
    /// dispatch. While set, every keyDown is swallowed and routed to it.
    func setShortcutRecorder(_ handler: ((Int, CGEventFlags) -> Void)?) {
        tap.recordingHandler = handler
    }

    func start() {
        tap.sideButtonEnabled = Settings.sideButtonEnabled
        tap.install()
    }

    /// Retry tap installation (e.g. after the user grants Accessibility).
    @discardableResult
    func ensureTap() -> Bool {
        tap.install()
    }

    var tapInstalled: Bool { tap.isActive }

    // MARK: - Show / hide

    private func show(trigger: Trigger) {
        self.trigger = trigger
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else { return }

        panel.setFrame(screen.frame, display: false)
        container.frame = NSRect(origin: .zero, size: screen.frame.size)
        ringView.frame = NSRect(origin: .zero, size: screen.frame.size)

        // Populate the ring first — geometry (disc radius, orbit) scales with
        // the app count, and the backdrop is sized from the resulting discR.
        let apps = MRUModel.shared.order
        let counts = WindowBridge.visibleWindowCounts()   // single window-list pass
        ringView.cardHighlight = nil
        ringView.cards = []
        ringView.apps = apps
        ringView.windowCounts = apps.map { counts[$0.processIdentifier] ?? 0 }
        IconCache.shared.prefetch(apps, size: RingView.iconSize)

        // No default highlight: the ring just appears and *waits*. Selection
        // is pointer-driven — keep hammering Cmd+Tab to hold it open, but it
        // never walks the list on its own. Releasing Command without having
        // pointed at anything simply dismisses (commitHighlight cancels).
        ringView.highlight = nil

        // Disc center = pointer, clamped so the disc *and* the petal fan
        // stay on screen.
        let margin = ringView.fanOuterExtent
        let cx = min(max(mouse.x - screen.frame.minX, margin),
                     max(margin, screen.frame.width - margin))
        let cy = min(max(mouse.y - screen.frame.minY, margin),
                     max(margin, screen.frame.height - margin))
        let c = NSPoint(x: cx, y: cy)
        let r = ringView.discR
        // Keep the frosted disc and its shadowcaster rounded to the live size.
        backdrop.layer?.cornerRadius = r
        shadowDisk.layer?.cornerRadius = r
        backdrop.frame = NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        shadowDisk.frame = backdrop.frame
        ringView.center = c

        visible = true
        WindowThumbnails.ensurePermissionRequested()
        tap.ringVisible = true
        panel.orderFrontRegardless()
        resetIdleTimer()
    }

    private func hide() {
        visible = false
        tap.ringVisible = false
        panel.orderOut(nil)
        ringView.cards = []
        ringView.cardHighlight = nil
        WindowThumbnails.shared.purge()
        idleTimer?.invalidate()
        dwellTimer?.invalidate()
    }

    private func resetIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        }
    }

    // MARK: - Actions

    /// Commit order matters: kick off the activation request *first* so it is
    /// already in flight before `hide()` changes the window-server state, then
    /// dismiss the panel. Doing it the other way round leaves a frontmost-app
    /// gap that races with (and often cancels) the activation.
    private func commitApp(_ index: Int) {
        let apps = ringView.apps
        guard apps.indices.contains(index) else { cancel(); return }
        WindowBridge.raiseApp(apps[index])
        hide()
    }

    private func commitCard(_ index: Int) {
        let apps = ringView.apps
        guard ringView.cards.indices.contains(index),
              let h = ringView.highlight, apps.indices.contains(h) else { cancel(); return }
        let card = ringView.cards[index]
        let app = apps[h]
        let pid = app.processIdentifier
        // Window-level focus only lands reliably once the app is frontmost,
        // so raise the app first and focus the window in the completion.
        WindowBridge.raiseApp(app) {
            WindowBridge.focusWindow(index: card.axIndex, pid: pid)
        }
        hide()
    }

    private func commitHighlight() {
        if let c = ringView.cardHighlight, !ringView.cards.isEmpty {
            commitCard(c)
        } else if let h = ringView.highlight {
            commitApp(h)
        } else {
            cancel()
        }
    }

    func cancel() { hide() }

    // MARK: - Window petals (dwell then expand)

    private func appHovered(_ index: Int?) {
        dwellTimer?.invalidate()
        pendingFanApp = index
        guard let index, ringView.apps.indices.contains(index) else {
            fanToken += 1
            ringView.cards = []
            return
        }
        // Apps with at most one visible window can never grow a fan — clear
        // the previous app's petals immediately instead of letting them linger
        // through the dwell window (they'd otherwise read as "still the old
        // app" while the cursor is already on the next icon).
        let count = ringView.windowCounts.indices.contains(index) ? ringView.windowCounts[index] : 0
        if count <= 1 {
            fanToken += 1
            ringView.cards = []
            return
        }
        // Dwell 80ms so sweeping past icons doesn't thrash the fan.
        dwellTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.pendingFanApp == index else { return }
                self.expandCards(for: index)
            }
        }
    }

    private func expandCards(for appIndex: Int) {
        fanToken += 1
        let token = fanToken
        let app = ringView.apps[appIndex]
        let pid = app.processIdentifier
        // AX calls carry a 0.2s timeout; run off-main to keep hover snappy.
        DispatchQueue.global(qos: .userInitiated).async {
            let ids = WindowBridge.onScreenWindowIDs(of: pid)
            let titles = WindowBridge.windowTitles(of: pid, matching: ids)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.visible, self.fanToken == token,
                      self.ringView.highlight == appIndex else { return }
                if ids.count > 1 {
                    self.ringView.cards = ids.enumerated().map { off, id in
                        WindowCard(windowID: id, axIndex: off, title: titles[off])
                    }
                } else {
                    self.ringView.cards = []
                }
            }
        }
    }

    private func cycle(_ delta: Int) {
        let n = ringView.apps.count
        guard n > 0 else { return }
        let cur = ringView.highlight ?? 0
        ringView.highlight = ((cur + delta) % n + n) % n
        appHovered(ringView.highlight)
    }

    private func cycleCard(_ delta: Int) {
        let n = ringView.cards.count
        guard n > 1 else { return }
        let cur = ringView.cardHighlight ?? -1
        ringView.cardHighlight = ((cur + delta) % n + n) % n
    }

    // MARK: - EventTapDelegate

    func eventTapDidTab(shift: Bool, ringVisible: Bool) -> Bool {
        if !visible {
            show(trigger: .cmdTab)
            return true
        }
        // Ring already up: holding/hammering Cmd+Tab simply keeps it alive.
        // No auto-cycling — the pointer (or explicit arrow keys) is the only
        // thing that moves the highlight.
        resetIdleTimer()
        return true
    }

    func eventTapDidReleaseCommand() {
        guard visible, trigger == .cmdTab else { return }
        commitHighlight()
    }

    func eventTapDidPressSideButton(_ button: Int) -> Bool {
        if visible { cancel(); return true }
        show(trigger: .sideButton)
        return true
    }

    func eventTapOtherKeyDown(_ keyCode: Int) -> Bool {
        guard visible else { return false }
        switch Int32(keyCode) {
        case Int32(kVK_Return), Int32(kVK_ANSI_KeypadEnter):
            commitHighlight()
        case Int32(kVK_Escape):
            cancel()
        case Int32(kVK_LeftArrow), Int32(kVK_DownArrow):
            if !ringView.cards.isEmpty, ringView.cardHighlight != nil { cycleCard(-1) }
            else { cycle(-1) }
        case Int32(kVK_RightArrow), Int32(kVK_UpArrow):
            if !ringView.cards.isEmpty, ringView.cardHighlight != nil { cycleCard(1) }
            else { cycle(1) }
        default:
            // Unknown key while the switcher is up: dismiss (the system
            // Cmd+Tab behaves the same) and let the key through to the app.
            cancel()
            return false
        }
        resetIdleTimer()
        return true
    }

    // Mouse clicks (from RingView callbacks).
    private func appClicked(_ index: Int) {
        resetIdleTimer()
        if trigger == .cmdTab, index == 0 {
            // Clicking the current app = no switch, just dismiss.
            cancel()
        } else {
            commitApp(index)
        }
    }

    private func cardClicked(_ index: Int) {
        resetIdleTimer()
        commitCard(index)
    }
}
