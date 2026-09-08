import Cocoa
import Carbon
import Carbon.HIToolbox
import ServiceManagement

/// Persisted user preferences: the summon hotkey and the launch-at-login flag.
/// Backed by `UserDefaults`; read live by `EventTap` and the settings window.
@MainActor
enum Settings {
    private static let d = UserDefaults.standard
    private static let keyCodeKey = "summonKeyCode"
    private static let modsKey = "summonModifiers"
    private static let sideKey = "sideButtonEnabled"

    // MARK: Summon hotkey (modifier set + key code)

    /// Default trigger is ⌘Tab — identical to the system switcher, so muscle
    /// memory carries over and the tap simply replaces what Cmd+Tab does.
    static let defaultKeyCode = kVK_Tab
    static let defaultModifiers: CGEventFlags = .maskCommand

    static var summonKeyCode: Int {
        get { d.object(forKey: keyCodeKey) as? Int ?? defaultKeyCode }
        set { d.set(newValue, forKey: keyCodeKey) }
    }

    static var summonModifiers: CGEventFlags {
        get {
            guard d.object(forKey: modsKey) != nil else { return defaultModifiers }
            return CGEventFlags(rawValue: UInt64(d.integer(forKey: modsKey)))
        }
        set { d.set(Int(newValue.rawValue), forKey: modsKey) }
    }

    /// Human-readable form of the current trigger, e.g. "⌃⌥ Space".
    static var summonShortcutLabel: String {
        shortcutLabel(modifiers: summonModifiers, keyCode: summonKeyCode)
    }

    static func shortcutLabel(modifiers: CGEventFlags, keyCode: Int) -> String {
        var s = ""
        if modifiers.contains(.maskControl) { s += "⌃" }
        if modifiers.contains(.maskAlternate) { s += "⌥" }
        if modifiers.contains(.maskShift) { s += "⇧" }
        if modifiers.contains(.maskCommand) { s += "⌘" }
        s += keyName(for: keyCode)
        return s
    }

    /// Restore the ⌘Tab default.
    static func resetSummonShortcut() {
        summonKeyCode = defaultKeyCode
        summonModifiers = defaultModifiers
    }

    // MARK: Mouse side button

    static var sideButtonEnabled: Bool {
        get { d.object(forKey: sideKey) as? Bool ?? true }
        set { d.set(newValue, forKey: sideKey) }
    }

    // MARK: Launch at login

    /// Whether the app is currently registered as a login item.
    static var launchAtLogin: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    /// Register/unregister as a login item. Returns nil on success or an error
    /// description on failure (e.g. running on macOS 12, which lacks
    /// `SMAppService`).
    static func setLaunchAtLogin(_ enabled: Bool) -> String? {
        guard #available(macOS 13.0, *) else {
            return "开机自启需要 macOS 13 或更高版本。"
        }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Key code → name

    /// Map a virtual key code to a display glyph / name for the shortcut UI.
    static func keyName(for keyCode: Int) -> String {
        keyNames[keyCode] ?? "Key \(keyCode)"
    }

    private static let keyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "Tab", kVK_Escape: "⎋",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_ANSI_KeypadEnter: "⌤",
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";",
        kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",
        // Function keys (virtual key codes are scattered, not contiguous).
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15",
    ]

    /// Bare function keys are allowed as modifier-free summon triggers.
    static let functionKeyCodes: Set<Int> = [122, 120, 99, 118, 96, 97, 98,
                                             100, 101, 109, 103, 111, 105, 107, 113]
}
