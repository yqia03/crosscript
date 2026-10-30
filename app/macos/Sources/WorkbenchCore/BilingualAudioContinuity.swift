import Foundation

/// Media-clock bookkeeping for a future verified bilingual transport. It never
/// retains PCM, so attaching a recovered connection cannot replay old audio.
/// Until a provider proves channel confirmation timing, the safe confirmation
/// boundary stays at the start of that connection (conservative whole range).
public struct BilingualAudioContinuity: Codable, Equatable, Sendable {
    public private(set) var capturedEndFrame: Int64 = 0
    public private(set) var generation: UUID?
    private var confirmed: [BilingualChannel: Int64] = [:]
    private var offlineStart: [BilingualChannel: Int64] = [.source: 0, .translation: 0]
    private var closedGaps: [BilingualChannel: [MissingInterval]] = [:]
    public init() {}
    public mutating func capture(_ chunk: LiveAudioChunk) throws -> UUID? {
        guard chunk.recordingStartFrame == capturedEndFrame else { throw LiveAudioClockError.invalidClock }
        capturedEndFrame = chunk.recordingEndFrame
        return generation
    }
    /// The capture route advances even offline. A saved recording duration can
    /// also close a conversion-failure tail without inventing PCM or replaying it.
    public mutating func captureThroughFrame(_ frame: Int64) throws {
        guard frame >= capturedEndFrame else { throw LiveAudioClockError.invalidClock }
        capturedEndFrame = frame
    }
    /// Source files need not have an integral 24 kHz duration. Both checkpoint
    /// writers and recovery cover the same final fractional media frame.
    static func recordedEndFrame(duration: TimeInterval) throws -> Int64 {
        let frames = (duration * LiveAudioChunk.sampleRate).rounded(.up)
        guard frames.isFinite, frames >= 0, frames < Double(Int64.max) else { throw AudioProcessingError.storage }
        return Int64(frames)
    }
    public mutating func attachCurrent(generation token: UUID = UUID()) -> UUID {
        for channel in BilingualChannel.allCases {
            if let start = offlineStart[channel], capturedEndFrame > start {
                closedGaps[channel] = MissingInterval.normalized((closedGaps[channel] ?? []) + [.init(startFrame: start, endFrame: capturedEndFrame)])
            }
            confirmed[channel] = capturedEndFrame
        }
        offlineStart = [:]
        generation = token; return token
    }
    /// Only use an explicitly confirmed original-media boundary, never elapsed
    /// transcript arrival timestamps or source/target array positions.
    public mutating func confirm(channel: BilingualChannel, throughFrame: Int64, generation token: UUID) {
        guard generation == token, throughFrame >= (confirmed[channel] ?? capturedEndFrame), throughFrame <= capturedEndFrame else { return }
        confirmed[channel] = throughFrame
    }
    public mutating func disconnect(generation token: UUID) {
        guard generation == token else { return }
        for channel in BilingualChannel.allCases { offlineStart[channel] = confirmed[channel] ?? capturedEndFrame }
        generation = nil
    }
    public func missing(_ channel: BilingualChannel) -> [MissingInterval] {
        var value = closedGaps[channel] ?? []
        if let start = offlineStart[channel], capturedEndFrame > start { value.append(.init(startFrame: start, endFrame: capturedEndFrame)) }
        return MissingInterval.normalized(value)
    }
    /// A process can end while its socket is still connected. The last known
    /// confirmation, rather than the last checkpoint frame, bounds that tail.
    func recoveryMissing(_ channel: BilingualChannel, recordedEndFrame: Int64) throws -> [MissingInterval] {
        guard isValid, recordedEndFrame >= capturedEndFrame else { throw AudioProcessingError.storage }
        var value = closedGaps[channel] ?? []
        let start = offlineStart[channel] ?? confirmed[channel] ?? 0
        if recordedEndFrame > start { value.append(.init(startFrame: start, endFrame: recordedEndFrame)) }
        return MissingInterval.normalized(value)
    }
    var isValid: Bool {
        capturedEndFrame >= 0 && confirmed.values.allSatisfy { $0 >= 0 && $0 <= capturedEndFrame } &&
        offlineStart.values.allSatisfy { $0 >= 0 && $0 <= capturedEndFrame } &&
        closedGaps.values.joined().allSatisfy { $0.isValid && $0.endFrame <= capturedEndFrame }
    }
}
