import Cocoa
import Carbon.HIToolbox

/// A small settings panel: launch-at-login toggle, summon-shortcut recorder,
/// and the side-button switch. Opening it pauses the event tap so shortcut
/// recording sees the real key events; closing resumes interception.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    private var window: NSWindow?
    private var shortcutButton: NSButton!
    private var launchCheckbox: NSButton!
    private var sideCheckbox: NSButton!

    private var recording = false {
        didSet { refreshShortcutButton() }
    }

    // MARK: Show / hide

    func show() {
        if window == nil { build() }
        guard let window else { return }
        syncFromSettings()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.center()
    }

    func windowWillClose(_ notification: Notification) {
        stopRecording()
    }

    // MARK: Build

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "AppRing 设置"
        w.isReleasedWhenClosed = false
        w.delegate = self
        let content = NSView(frame: w.contentLayoutRect)
        content.autoresizingMask = [.width, .height]
        w.contentView = content

        // Section: summon shortcut
        addLabel("呼出快捷键", to: content, y: 218, bold: true)
        shortcutButton = NSButton(frame: NSRect(x: 20, y: 182, width: 250, height: 30))
        shortcutButton.bezelStyle = .roundRect
        shortcutButton.target = self
        shortcutButton.action = #selector(shortcutClicked)
        content.addSubview(shortcutButton)

        let reset = NSButton(frame: NSRect(x: 280, y: 182, width: 80, height: 30))
        reset.title = "重置"
        reset.bezelStyle = .roundRect
        reset.target = self
        reset.action = #selector(resetShortcut)
        content.addSubview(reset)

        addLabel("按住修饰键、点按呼出键唤出圆环；松开即切换到选中的 App。",
                 to: content, y: 158, size: 11, color: .secondaryLabelColor)
        addLabel("默认 ⌘Tab —— 与系统切换器相同的按键，直接接管它。",
                 to: content, y: 140, size: 11, color: .secondaryLabelColor)

        // Section: behaviour toggles
        addLabel("常规", to: content, y: 110, bold: true)
        launchCheckbox = NSButton(checkboxWithTitle: "开机自启", target: self, action: #selector(toggleLaunch))
        launchCheckbox.frame = NSRect(x: 20, y: 76, width: 320, height: 24)
        content.addSubview(launchCheckbox)

        sideCheckbox = NSButton(checkboxWithTitle: "鼠标侧键呼出（按键 4 / 5）", target: self, action: #selector(toggleSide))
        sideCheckbox.frame = NSRect(x: 20, y: 48, width: 320, height: 24)
        content.addSubview(sideCheckbox)

        window = w
    }

    private func addLabel(_ s: String, to parent: NSView, y: CGFloat,
                          bold: Bool = false, size: CGFloat = 13,
                          color: NSColor = .labelColor) {
        let label = NSTextField(labelWithString: s)
        label.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        label.textColor = color
        label.frame = NSRect(x: 20, y: y, width: 340, height: size + 8)
        parent.addSubview(label)
    }

    private func syncFromSettings() {
        if #available(macOS 13.0, *) {
            launchCheckbox.state = Settings.launchAtLogin ? .on : .off
        } else {
            launchCheckbox.state = .off
            launchCheckbox.isEnabled = false
            launchCheckbox.title = "开机自启（需要 macOS 13+）"
        }
        sideCheckbox.state = Settings.sideButtonEnabled ? .on : .off
        refreshShortcutButton()
    }

    private func refreshShortcutButton() {
        if recording {
            shortcutButton.title = "按下新快捷键…  (Esc 取消)"
        } else {
            shortcutButton.title = "呼出：  \(Settings.summonShortcutLabel)"
        }
    }

    // MARK: Actions

    /// Start recording through the event tap itself: while active, the tap
    /// swallows every keyDown, so even ⌘Tab never reaches the system
    /// switcher. Esc cancels; a valid chord is captured immediately.
    @objc private func shortcutClicked() {
        if recording { stopRecording(); return }
        recording = true
        RingController.shared.setShortcutRecorder { [weak self] keyCode, flags in
            Task { @MainActor in self?.handleKey(keyCode, flags) }
        }
    }

    private func handleKey(_ keyCode: Int, _ flags: CGEventFlags) {
        guard recording else { return }
        if keyCode == kVK_Escape {
            stopRecording()
            return
        }
        let mods = flags.intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand])
        // Require a modifier chord, or a bare function key.
        guard !mods.isEmpty || Settings.functionKeyCodes.contains(keyCode) else { return }

        Settings.summonModifiers = mods
        Settings.summonKeyCode = keyCode
        stopRecording()
        NSSound.beep()
    }

    private func stopRecording() {
        guard recording else { return }
        recording = false
        RingController.shared.setShortcutRecorder(nil)
    }

    @objc private func resetShortcut() {
        Settings.resetSummonShortcut()
        refreshShortcutButton()
    }

    @objc private func toggleLaunch() {
        let want = launchCheckbox.state == .on
        if let err = Settings.setLaunchAtLogin(want) {
            launchCheckbox.state = Settings.launchAtLogin ? .on : .off
            presentError(err)
        }
    }

    @objc private func toggleSide() {
        let on = sideCheckbox.state == .on
        Settings.sideButtonEnabled = on
        RingController.shared.sideButtonEnabled = on
    }

    private func presentError(_ msg: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "设置失败"
        alert.informativeText = msg
        alert.runModal()
        _ = window
    }
}
