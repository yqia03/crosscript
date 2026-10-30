import Foundation

enum LiveAudioInput { case audio(LiveAudioChunk), commit }

/// Capture owns the media clock even while the cloud is offline. Attaching a
/// fresh destination atomically begins at the newest frame; offline audio is
/// not queued for retransmission ahead of current speech.
final class LiveAudioRoute: @unchecked Sendable {
    private let lock = NSLock()
    private var endFrame: Int64 = 0
    private var destination: (UUID, AsyncStream<LiveAudioInput>.Continuation, LiveAudioBacklog)?
    private let overflow: @Sendable (UUID) -> Void
    init(overflow: @escaping @Sendable (UUID) -> Void) { self.overflow = overflow }
    var capturedEndFrame: Int64 { lock.lock(); defer { lock.unlock() }; return endFrame }
    func receive(_ chunk: LiveAudioChunk) {
        lock.lock()
        endFrame = max(endFrame, chunk.recordingEndFrame)
        let output = destination
        var failed = false
        if let output {
            switch output.2.reserve(chunk.frameCount) {
            case .closed: break
            case .overflow: failed = true
            case .accepted:
                if case .dropped = output.1.yield(.audio(chunk)) { output.2.close(); failed = true }
            }
        }
        lock.unlock()
        if failed, let token = output?.0 { overflow(token) }
    }
    @discardableResult func attach(_ continuation: AsyncStream<LiveAudioInput>.Continuation, token: UUID) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        destination?.2.close(); destination?.1.finish()
        destination = (token, continuation, LiveAudioBacklog())
        return endFrame
    }
    func acknowledge(_ frames: Int64, token: UUID) {
        lock.lock(); defer { lock.unlock() }
        if destination?.0 == token { destination?.2.release(frames) }
    }
    func flush() {
        lock.lock(); let output = destination; let result = output?.1.yield(.commit); lock.unlock()
        if case .dropped = result, let token = output?.0 { overflow(token) }
    }
    func detach() {
        lock.lock(); let old = destination; destination = nil; lock.unlock()
        old?.2.close(); old?.1.finish()
    }
}
