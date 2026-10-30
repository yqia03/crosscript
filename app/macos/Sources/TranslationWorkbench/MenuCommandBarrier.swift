import AppKit
import SwiftUI

/// A native menu can finish tracking before it dispatches the chosen item's
/// action. Commands that consume that choice must wait for both, including when
/// accessibility invokes another button while the menu is still closing.
@MainActor final class MenuCommandBarrier: ObservableObject {
    private var observers: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    private var active: [ObjectIdentifier: UInt64] = [:]
    private var generation: UInt64 = 0
    private var acceptsCommands = false
    private var pending: [@MainActor () -> Void] = []

    func register(_ menu: NSMenu) {
        let id = ObjectIdentifier(menu)
        guard observers[id] == nil else { return }
        let center = NotificationCenter.default
        observers[id] = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: menu, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.generation &+= 1
                    self.active[id] = self.generation
                }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: menu, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let generation = self.active[id] else { return }
                    // didEndTracking precedes willSendAction/didSendAction.
                    // Remain active until their current AppKit turn has finished.
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.active[id] == generation else { return }
                        self.active.removeValue(forKey: id)
                        self.drain()
                    }
                }
            }
        ]
    }

    func unregister(_ menu: NSMenu) {
        let id = ObjectIdentifier(menu)
        observers.removeValue(forKey: id)?.forEach(NotificationCenter.default.removeObserver)
        active.removeValue(forKey: id)
        DispatchQueue.main.async { [weak self] in self?.drain() }
    }

    func perform(_ command: @escaping @MainActor () -> Void) {
        guard acceptsCommands else { return }
        if active.isEmpty && pending.isEmpty { command() }
        else { pending.append(command) }
    }

    /// Leaving the page invalidates the UI intentions that have not executed.
    func activate() { acceptsCommands = true }
    func deactivate() { acceptsCommands = false; pending.removeAll() }

    private func drain() {
        // A command may open another tracked menu or remove the page. Recheck
        // between commands instead of copying a batch that could become stale.
        while active.isEmpty && !pending.isEmpty { pending.removeFirst()() }
    }

    deinit {
        for registrations in observers.values {
            for observer in registrations { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

private struct MenuCommandBarrierKey: EnvironmentKey {
    static let defaultValue: MenuCommandBarrier? = nil
}
extension EnvironmentValues {
    var menuCommandBarrier: MenuCommandBarrier? {
        get { self[MenuCommandBarrierKey.self] }
        set { self[MenuCommandBarrierKey.self] = newValue }
    }
}
