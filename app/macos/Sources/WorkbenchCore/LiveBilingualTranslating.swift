import Foundation

/// Safe provider diagnostics only. Missing counts remain absent rather than zero.
public struct LiveBilingualUsage: Equatable, Sendable {
    public let tokenCounts: [String: Int]
    public let modalityTokenCounts: [String: [String: Int]]
    public init(tokenCounts: [String: Int], modalityTokenCounts: [String: [String: Int]] = [:]) {
        self.tokenCounts = tokenCounts
        self.modalityTokenCounts = modalityTokenCounts
    }
}

public enum LiveBilingualInteractionStatus: String, Equatable, Sendable {
    case unspecified = "INTERACTION_STATUS_UNSPECIFIED"
    case inProgress = "IN_PROGRESS"
    case requiresAction = "REQUIRES_ACTION"
    case idle = "IDLE"
}

/// Transport observations, not proof that all captured audio has been transcribed.
/// Offsets belong to the provider's channel and are not original-media anchors.
public enum LiveBilingualTransportEvent: Equatable, Sendable {
    case configured
    case text(channel: BilingualChannel, eventID: String, delta: String,
              startOffset: TimeInterval?, endOffset: TimeInterval?, finished: Bool?)
    case turnComplete
    case generationComplete
    case interrupted
    case interactionStatus(LiveBilingualInteractionStatus)
    case goAway(timeLeft: TimeInterval?)
    case usage(LiveBilingualUsage)
    case audioDiscarded(byteCount: Int)
    case closed
}

/// One selected live connection. The caller owns capture, persistence and any
/// reconnect decision. No method changes service or retries a paid request.
@MainActor public protocol LiveBilingualTranslating: AnyObject {
    func connect(configuration: AudioServiceConfiguration, direction: TextTranslationDirection,
                 apiKey: String) async throws -> AsyncThrowingStream<LiveBilingualTransportEvent, Error>
    /// Input uses the existing 24 kHz recording media clock. The adapter owns any
    /// provider-specific resampling and bounded packetization.
    func append(_ chunk: LiveAudioChunk) async throws
    /// Flushes captured input and signals its end; this is not an output ACK.
    func finishInput() async throws
    /// Flushes captured input for a pause with a short provider settling tail.
    func pauseInput() async throws
    /// Invalidates this connection and its late events. It does not stop recording.
    func close()
}

public extension LiveBilingualTranslating {
    func pauseInput() async throws { try await finishInput() }
}
