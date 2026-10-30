import Foundation

/// Bounds queued PCM by its media duration, independent of the device's block
/// size. Small 20 ms system buffers must not exhaust a chunk-count-only queue
/// during a normal connection handshake.
final class LiveAudioBacklog: @unchecked Sendable {
    enum Admission { case accepted, closed, overflow }
    private let lock = NSLock()
    private let maximumFrames: Int64
    private var queuedFrames: Int64 = 0
    private var isClosed = false
    init(maximumFrames: Int64 = 720_000) { self.maximumFrames = maximumFrames }
    func reserve(_ frames: Int64) -> Admission {
        lock.lock(); defer { lock.unlock() }
        guard !isClosed else { return .closed }
        guard frames <= maximumFrames - queuedFrames else { isClosed = true; return .overflow }
        queuedFrames += frames; return .accepted
    }
    func release(_ frames: Int64) { lock.lock(); queuedFrames = max(0, queuedFrames - frames); lock.unlock() }
    func close() { lock.lock(); isClosed = true; lock.unlock() }
}
