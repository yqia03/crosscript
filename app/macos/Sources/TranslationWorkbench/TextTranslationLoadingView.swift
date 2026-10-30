import SwiftUI

/// Replaces the result visually while the complete translation is prepared.
struct TextTranslationLoadingView: View {
    let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let lineWidths: [CGFloat] = [0.94, 1, 0.84, 0.96, 0.68, 0.88]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                GeometryReader { geometry in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                    bars(width: geometry.size.width)
                        .foregroundStyle(Color.primary.opacity(0.07))
                        .overlay {
                            if !reduceMotion {
                                LinearGradient(colors: [.clear, Color.accentColor.opacity(0.14), .clear],
                                    startPoint: UnitPoint(x: phase * 2 - 0.8, y: 0.5),
                                    endPoint: UnitPoint(x: phase * 2, y: 0.5))
                                    .mask(bars(width: geometry.size.width).foregroundStyle(.white))
                            }
                        }
                }
            }.frame(height: 163)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityIdentifier("textTranslationLoading")
    }

    private func bars(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            ForEach(Array(lineWidths.enumerated()), id: \.offset) { _, fraction in
                RoundedRectangle(cornerRadius: 4)
                    .frame(width: max(0, width * fraction), height: 13)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
