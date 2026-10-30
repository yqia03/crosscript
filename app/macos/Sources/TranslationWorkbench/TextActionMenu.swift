import AppKit
import SwiftUI

/// The popup itself owns the 34-point hit area and centered symbol. Framing a
/// SwiftUI Menu only frames its wrapper; AppKit can still inset its inner cell.
@MainActor struct TextActionMenu: NSViewRepresentable {
    struct Action {
        let title: String
        var enabled = true
        let perform: () -> Void
    }
    let label: String
    let symbol: String
    let actions: [Action]
    @Environment(\.menuCommandBarrier) private var commands
    func makeCoordinator() -> CommittedPicker<Int>.Coordinator {
        .init(selection: Binding(get: { 0 }, set: { _ in }), options: [])
    }
    func makeNSView(context: Context) -> TextActionPopUpButton {
        let button = TextActionPopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = false
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        button.target = context.coordinator
        button.action = #selector(CommittedPicker<Int>.Coordinator.changed(_:))
        return button
    }
    func updateNSView(_ button: TextActionPopUpButton, context: Context) {
        context.coordinator.options = [("", 0)] + actions.enumerated().map { ($0.element.title, $0.offset + 1) }
        context.coordinator.selection = Binding(get: { 0 }, set: { index in
            guard actions.indices.contains(index - 1), actions[index - 1].enabled else { return }
            actions[index - 1].perform()
        })
        let titles = [""] + actions.map(\.title)
        if button.itemTitles != titles { button.removeAllItems(); button.addItems(withTitles: titles) }
        button.menu?.autoenablesItems = false
        for (index, action) in actions.enumerated() { button.item(at: index + 1)?.isEnabled = action.enabled }
        button.symbol = symbol; button.toolTip = label; button.setAccessibilityLabel(label)
        button.isEnabled = context.environment.isEnabled
        context.coordinator.track(button.menu, commands: commands)
        button.needsDisplay = true
    }
    static func dismantleNSView(_ button: TextActionPopUpButton, coordinator: CommittedPicker<Int>.Coordinator) { coordinator.track(nil, commands: nil) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TextActionPopUpButton, context: Context) -> CGSize? { NSSize(width: 34, height: 34) }
}

final class TextActionPopUpButton: NSPopUpButton {
    var symbol = "ellipsis"
    // NSPopUpButton normally reserves five points to the left for its native
    // bezel. This control draws its own bezel across bounds, so that inset
    // would make AppKit expand it beyond SwiftUI's reserved 34-point frame.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    override var intrinsicContentSize: NSSize { NSSize(width: 34, height: 34) }
    override func draw(_ dirtyRect: NSRect) {
        let tint = NSColor(red: 0.16, green: 0.47, blue: 0.53, alpha: 1)
        let opacity: CGFloat = isEnabled ? 1 : 0.45
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        NSColor.white.withAlphaComponent((isHighlighted ? 0.96 : 0.7) * opacity).setFill(); shape.fill()
        tint.withAlphaComponent(0.17 * opacity).setStroke(); shape.lineWidth = 1; shape.stroke()
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) {
            let colored = image.withSymbolConfiguration(.init(paletteColors: [tint])) ?? image
            let size = colored.size
            colored.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: opacity, respectFlipped: true, hints: nil)
        }
        if window?.firstResponder === self { NSFocusRingPlacement.only.set(); shape.fill() }
    }
}
