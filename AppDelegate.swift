import Cocoa
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!

    private var statusItem: NSStatusItem!
    private var warningItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)

        MRUModel.shared.start()
        RingController.shared.start()
        setupStatusItem()
        promptPermissionsIfNeeded()
    }

    // MARK: - Status item (quit hatch — the app has no Dock tile)

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "circle.hexagongrid", accessibilityDescription: "AppRing")
            image?.isTemplate = true
            button.image = image
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let side = NSMenuItem(title: "鼠标侧键呼出", action: #selector(toggleSideButton), keyEquivalent: "")
        side.target = self
        side.state = Settings.sideButtonEnabled ? .on : .off
        menu.addItem(side)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 AppRing", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func openSettings() {
        SettingsWindow.shared.show()
    }

    @objc private func toggleSideButton() {
        let on = !Settings.sideButtonEnabled
        Settings.sideButtonEnabled = on
        RingController.shared.sideButtonEnabled = on
        rebuildMenu()
    }

    private func rebuildMenu() {
        statusItem.menu?.item(at: 1)?.state = Settings.sideButtonEnabled ? .on : .off
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Permissions

    /// Active CGEvent taps need Accessibility; window thumbnails need Screen
    /// Recording. Prompt for both up front and warn in the menu bar if the
    /// tap failed to install.
    private func promptPermissionsIfNeeded() {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        }
        if !WindowThumbnails.hasScreenCapturePermission {
            CGRequestScreenCaptureAccess()
        }
        // The tap may fail until Accessibility is granted; retry periodically
        // and surface a warning while it's dead.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkTap() }
        }
    }

    private func checkTap() {
        let ok = RingController.shared.ensureTap()
        if ok {
            if let item = warningItem {
                NSStatusBar.system.removeStatusItem(item)
                warningItem = nil
            }
        } else if warningItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.title = "⚠️"
            let menu = NSMenu()
            let info = NSMenuItem(title: "请在 系统设置 → 隐私与安全性 → 辅助功能 中勾选 AppRing", action: nil, keyEquivalent: "")
            menu.addItem(info)
            warningItem = item
            item.menu = menu
        }
    }
}
