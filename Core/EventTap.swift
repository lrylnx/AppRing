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

    /// Tracks a swallowed side-button press so its up event is balanced.
    private var sideDownConsumed = false

    /// True while Command has been held since the last release — so we only
    /// report "command released" when it actually was pressed.
    private var cmdWasDown = false

    var isActive: Bool {
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    @discardableResult
    func install() -> Bool {
        guard tap == nil else { return isActive }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
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

        switch type {
        case .flagsChanged:
            let cmdDown = event.flags.contains(.maskCommand)
            if cmdDown {
                cmdWasDown = true
            } else if cmdWasDown {
                cmdWasDown = false
                delegate?.eventTapDidReleaseCommand()
            }
            return Unmanaged.passUnretained(event)  // never swallow modifier changes

        case .keyDown:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let shift = event.flags.contains(.maskShift)
            let cmd = event.flags.contains(.maskCommand)
            let otherMods = event.flags.contains(.maskControl) || event.flags.contains(.maskAlternate)
                || event.flags.contains(.maskSecondaryFn)

            if keyCode == kVK_Tab, !otherMods {
                // Cmd+Tab summons; plain Tab cycles once the ring is up.
                if cmd || ringVisible {
                    let consumed = delegate?.eventTapDidTab(shift: shift, ringVisible: ringVisible) ?? false
                    return consumed ? nil : Unmanaged.passUnretained(event)
                }
                return Unmanaged.passUnretained(event)
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
