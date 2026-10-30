import Combine
import Foundation

/// Meter samples change independently of recording ownership and lifecycle.
/// Only clocks and meters observe these values.
@MainActor public final class RecordingTelemetry: ObservableObject {
    @Published public internal(set) var elapsed: TimeInterval = 0
    @Published public internal(set) var inputLevel: Double = 0
    public init() {}
}
