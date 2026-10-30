import Foundation

/// Missing text on the source recording's media clock. The audio itself is
/// retained; wall-clock pauses do not enlarge this interval.
public struct MissingInterval: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let startFrame: Int64
    public let endFrame: Int64
    public var start: TimeInterval { Double(startFrame) / LiveAudioChunk.sampleRate }
    public var end: TimeInterval { Double(endFrame) / LiveAudioChunk.sampleRate }
    public init(id: UUID = UUID(), startFrame: Int64, endFrame: Int64) {
        self.id = id; self.startFrame = startFrame; self.endFrame = endFrame
    }
    var isValid: Bool { startFrame >= 0 && endFrame > startFrame }

    /// Adjacent or overlapping unrecognized regions remain one source interval.
    /// Existing interval identity survives when an offline region grows.
    static func normalized(_ values: [MissingInterval]) -> [MissingInterval] {
        var output: [MissingInterval] = []
        for value in values.filter(\.isValid).sorted(by: { $0.startFrame < $1.startFrame }) {
            if let last = output.last, value.startFrame <= last.endFrame {
                output[output.count - 1] = .init(id: last.id, startFrame: last.startFrame, endFrame: max(last.endFrame, value.endFrame))
            } else { output.append(value) }
        }
        return output
    }
}
