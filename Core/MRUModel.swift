import Cocoa

/// Most-recently-used stack of regular (Dock-eligible) apps, head = frontmost.
/// Notification-driven; used to order the ring and pick the default highlight
/// (index 1 = "previous app", matching Cmd+Tab semantics).
@MainActor
final class MRUModel {
    static let shared = MRUModel()

    private(set) var order: [NSRunningApplication] = []

    private var observers: [NSObjectProtocol] = []

    private init() {}

    func start() {
        rebuild()
        touch(NSWorkspace.shared.frontmostApplication)
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                        object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.touch(app) }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        })
    }

    /// Move `app` to the head of the stack. Ignores background apps and our
    /// own process (the commit moment fires a didActivate for us otherwise).
    private func touch(_ app: NSRunningApplication?) {
        guard let app, app.activationPolicy == .regular, !isSelf(app) else { return }
        if let idx = order.firstIndex(where: { $0.processIdentifier == app.processIdentifier }) {
            order.remove(at: idx)
        }
        order.insert(app, at: 0)
    }

    private func rebuild() {
        let current = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !isSelf($0)
        }
        let byPID = Dictionary(uniqueKeysWithValues: current.map { ($0.processIdentifier, $0) })
        // Keep prior MRU order for survivors, append newcomers at the tail.
        var next = order.compactMap { byPID[$0.processIdentifier] }
        let seen = Set(next.map(\.processIdentifier))
        next += current.filter { !seen.contains($0.processIdentifier) }
        order = next
    }

    private func isSelf(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier == "local.appring.macos"
    }
}
