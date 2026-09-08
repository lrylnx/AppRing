import Cocoa

// Entry point. AppRing is a menu-bar-only (accessory) tool: no Dock tile,
// no main window. The radial switcher lives in a borderless overlay panel.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
