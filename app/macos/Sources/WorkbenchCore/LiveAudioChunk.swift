import Foundation

/// A copy of newly captured audio, emitted only after the local recording write
/// succeeds. The clock is the recording's media timeline, excluding pauses.
/// This is never an excerpt read back from a completed recording.
public struct LiveAudioChunk: Equatable, Sendable {
    public static let sampleRate: Double = 24_000
    public let pcm16: Data
    public let recordingStartFrame: Int64

    public init(pcm16: Data, recordingStartFrame: Int64) throws {
        guard !pcm16.isEmpty, pcm16.count.isMultiple(of: 2),
              pcm16.count <= 48_000, recordingStartFrame >= 0,
              recordingStartFrame <= Int64.max - Int64(pcm16.count / 2) else {
            throw LiveAudioChunkError.invalidChunk
        }
        self.pcm16 = pcm16
        self.recordingStartFrame = recordingStartFrame
    }

    public var frameCount: Int64 { Int64(pcm16.count / 2) }
    public var recordingEndFrame: Int64 { recordingStartFrame + frameCount }
    public var recordingStart: TimeInterval { Double(recordingStartFrame) / Self.sampleRate }
    public var recordingEnd: TimeInterval { Double(recordingEndFrame) / Self.sampleRate }
}

public enum LiveAudioChunkError: Error { case invalidChunk }
