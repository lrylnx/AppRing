import Cocoa
import Carbon.HIToolbox
import CoreGraphics

/// High-level events the ring reacts to. All delivered on the main thread
/// (the tap's run-loop source is attached to the main run loop).
/// `consume` return value: true = swallow the event (don't deliver it to the
/// system / frontmost app), false = let it through.
@MainActor
protocol EventTapDelegate: AnyObject {
    /// Cmd+Tab (or plain Tab while the ring is up) was pressed.
    func eventTapDidTab(shift: Bool, ringVisible: Bool) -> Bool
    /// The Command modifier was released (flagsChanged with no Cmd flag).
    func eventTapDidReleaseCommand()
    /// A mouse side button (4/5) went down.
    func eventTapDidPressSideButton(_ button: Int) -> Bool
    /// Any other key went down while the ring is up — the delegate decides
    /// whether to consume it (arrows, return, escape).
    func eventTapOtherKeyDown(_ keyCode: Int) -> Bool
}

/// A session-level *active* event tap. It intercepts Cmd+Tab (swallowing the
/// first Tab keyDown so the system switcher never appears), the mouse side
/// buttons, and — while the ring is visible — the navigation keys.
///
/// Requires the Accessibility permission. The CFMachPort run-loop source is
/// attached to the main run loop, so the C callback runs on the main thread
/// and can touch AppKit state directly and synchronously.
@MainActor
final class EventTap {
    weak var delegate: EventTapDelegate?

    /// Set while the ring is on screen; tells the tap to route navigation keys.
    var ringVisible = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Whether side buttons should be captured as a summon trigger.
    var sideButtonEnabled = true

    /// While set, every keyDown is swallowed and forwarded here instead of
    /// reaching the system — the settings window uses this to record a new
    /// shortcut without ⌘Tab popping the system switcher.
    var recordingHandler: ((Int, CGEventFlags) -> Void)?

    /// Tracks a swallowed side-button press so its up event is balanced.
    private var sideDownConsumed = false

    /// The four primary modifier flags we match shortcuts against.
    private static let primaryMods: CGEventFlags =
        [.maskControl, .maskAlternate, .maskShift, .maskCommand]

    /// True while at least one of the summon shortcut's modifiers is held —
    /// so we only report "released" when it actually was pressed.
    private var summonModWasDown = false

    /// Set while a modifier-free summon key (F8-style) is down; its keyUp
    /// commits the ring.
    private var visibleSummonKey = false

    var isActive: Bool {
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    @discardableResult
    func install() -> Bool {
        guard tap == nil else { return isActive }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
                // Safe: the run-loop source below is attached to the main
                // run loop, so this callback always executes on main.
                return MainActor.assumeIsolated { me.handle(type: type, event: event) }
            },
            userInfo: selfPtr
        ) else {
            NSLog("AppRing: CGEvent.tapCreate failed — Accessibility permission required.")
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func uninstall() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        runLoopSource = nil
        tap = nil
    }

    // Runs on the main thread (the run-loop source is on the main run loop).
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Self-heal: the system disables a tap that stalls or after a login
        // / sleep transition. Re-arm and keep going.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        // Paused (settings window recording a shortcut): swallow every keyDown
        // and hand it to the recorder — the system never sees ⌘Tab, so its
        // switcher can't pop over the settings window.
        if let handler = recordingHandler, type == .keyDown {
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            handler(keyCode, event.flags)
            return nil
        }

        switch type {
        case .flagsChanged:
            // "Commit on modifier release" generalises to whichever modifiers
            // the summon shortcut uses (⌘ by default): once none of them is
            // held anymore, the chord is over.
            let held = event.flags.intersection(EventTap.primaryMods)
            let mods = Settings.summonModifiers.intersection(EventTap.primaryMods)
            if !held.isEmpty {
                if !held.intersection(mods).isEmpty { summonModWasDown = true }
            } else if summonModWasDown {
                summonModWasDown = false
                delegate?.eventTapDidReleaseCommand()
            }
            return Unmanaged.passUnretained(event)  // never swallow modifier changes

        case .keyUp:
            // A modifier-free summon key (e.g. F8) has no modifier-release to
            // commit on — the key's own up event closes the ring instead. The
            // matching keyDown was swallowed, so swallow this one too.
            if Settings.summonModifiers.isEmpty,
               Int(event.getIntegerValueField(.keyboardEventKeycode)) == Settings.summonKeyCode {
                if visibleSummonKey {
                    visibleSummonKey = false
                    delegate?.eventTapDidReleaseCommand()
                }
                return nil
            }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let shift = event.flags.contains(.maskShift)
            let mods = Settings.summonModifiers
            let summon: Bool
            if mods.isEmpty {
                // A modifier-free key (e.g. F8) fires on the bare key press.
                summon = keyCode == Settings.summonKeyCode
            } else {
                // Match on the primary flags, tolerating an *extra* Shift —
                // ⇧⌘Tab must still summon (and reports shift for reverse
                // cycling), matching the system switcher's muscle memory.
                let held = event.flags.intersection(EventTap.primaryMods)
                let want = mods.intersection(EventTap.primaryMods)
                summon = keyCode == Settings.summonKeyCode
                    && held.subtracting(.maskShift) == want.subtracting(.maskShift)
                    && (!want.contains(.maskShift) || held.contains(.maskShift))
            }

            if summon {
                if mods.isEmpty { visibleSummonKey = true }
                let consumed = delegate?.eventTapDidTab(shift: shift, ringVisible: ringVisible) ?? false
                return consumed ? nil : Unmanaged.passUnretained(event)
            }

            // Plain Tab cycles once the ring is up (as before).
            let otherMods = event.flags.contains(.maskControl) || event.flags.contains(.maskAlternate)
                || event.flags.contains(.maskSecondaryFn)
            if ringVisible, keyCode == kVK_Tab, !otherMods, let delegate {
                let consumed = delegate.eventTapDidTab(shift: shift, ringVisible: true)
                return consumed ? nil : Unmanaged.passUnretained(event)
            }

            if ringVisible, let delegate {
                return delegate.eventTapOtherKeyDown(keyCode) ? nil : Unmanaged.passUnretained(event)
            }
            return Unmanaged.passUnretained(event)

        case .otherMouseDown:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            if sideButtonEnabled, button == 4 || button == 5 {
                let consumed = delegate?.eventTapDidPressSideButton(button) ?? false
                sideDownConsumed = consumed
                return consumed ? nil : Unmanaged.passUnretained(event)
            }
            return Unmanaged.passUnretained(event)

        case .otherMouseUp:
            // Balance a swallowed side-button press so no app sees a stray up.
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            if sideDownConsumed, button == 4 || button == 5 {
                sideDownConsumed = false
                return nil
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
