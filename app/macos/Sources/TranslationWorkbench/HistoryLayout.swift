import SwiftUI

// Observe real card bounds only when a production-view host requests geometry.
struct HistoryGeometryObserverKey: EnvironmentKey {
    static let defaultValue: ((String, CGRect) -> Void)? = nil
}
extension EnvironmentValues {
    var historyGeometryObserver: ((String, CGRect) -> Void)? {
        get { self[HistoryGeometryObserverKey.self] }
        set { self[HistoryGeometryObserverKey.self] = newValue }
    }
}
struct HistoryGeometryObservation: ViewModifier {
    let name: String
    @Environment(\.historyGeometryObserver) private var observe
    func body(content: Content) -> some View {
        if let observe {
            content.background(GeometryReader { geometry in
                Color.clear.onChange(of: geometry.frame(in: .global), initial: true) { _, frame in observe(name, frame) }
            })
        } else { content }
    }
}

// Overlay scrollers occupy the document's trailing edge. Keep the card border
// and every action outside that edge without hiding either scroller style.
extension View {
    func historyScrollGutter() -> some View { padding(.trailing, 20) }
}
