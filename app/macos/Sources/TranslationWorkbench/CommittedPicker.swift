import AppKit
import SwiftUI

/// Commits the selected value in AppKit's target-action turn. A surrounding
/// command barrier also covers native accessibility menu activation that is
/// delivered after another button becomes reachable.
@MainActor struct CommittedPicker<Value: Equatable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Value
    let options: [(String, Value)]
    @Environment(\.menuCommandBarrier) private var commands

    init(title: String, selection: Binding<Value>, options: [(String, Value)]) {
        self.title = title; _selection = selection; self.options = options
    }

    @MainActor final class Coordinator: NSObject {
        var selection: Binding<Value>
        var options: [(String, Value)]
        private weak var menu: NSMenu?
        private var commands: MenuCommandBarrier?
        func track(_ menu: NSMenu?, commands: MenuCommandBarrier?) {
            guard self.menu !== menu || self.commands !== commands else { return }
            if let old = self.menu { self.commands?.unregister(old) }
            self.menu = menu; self.commands = commands
            if let menu { commands?.register(menu) }
        }
        init(selection: Binding<Value>, options: [(String, Value)]) {
            self.selection = selection; self.options = options
        }
        @objc func changed(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard options.indices.contains(index) else { return }
            selection.wrappedValue = options[index].1
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection, options: options) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateNSView(button, context: context)
        return button
    }

    static func dismantleNSView(_ button: NSPopUpButton, coordinator: Coordinator) {
        coordinator.track(nil, commands: nil)
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.options = options
        let titles = options.map(\.0)
        if button.itemTitles != titles {
            button.removeAllItems()
            button.addItems(withTitles: titles)
        }
        if let index = options.firstIndex(where: { $0.1 == selection }), button.indexOfSelectedItem != index {
            button.selectItem(at: index)
        }
        context.coordinator.track(button.menu, commands: commands)
        button.setAccessibilityLabel(title)
        button.isEnabled = context.environment.isEnabled
    }
}
