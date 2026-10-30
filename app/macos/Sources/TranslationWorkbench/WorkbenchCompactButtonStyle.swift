import SwiftUI

/// Shared compact native actions used beside document and reading controls.
struct WorkbenchCompactButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var iconOnly = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, iconOnly ? 8 : 12)
            .frame(minWidth: iconOnly ? 32 : nil, minHeight: 34)
            .foregroundStyle(.tint)
            .background(.white.opacity(configuration.isPressed ? 0.96 : 0.7), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.tint.opacity(0.17)))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}
