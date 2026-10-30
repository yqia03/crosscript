import Foundation

/// One execution slot shared by durable audio and PDF queues. Journals remain
/// with their material owners; restoring a journal never automatically enqueues.
@MainActor public final class BackgroundProcessingGate {
    public private(set) var activeID: UUID?
    private struct Waiting {
        let id: UUID
        let start: @MainActor () -> Void
    }
    private var waiting: [Waiting] = []
    private var dispatchSuspended = false

    public init() {}

    /// Freeze new work before any owner starts confirmed App shutdown. A
    /// finishing owner must not start another owner's queued request mid-exit.
    public func suspendDispatch() { dispatchSuspended = true }
    public func resumeDispatch() {
        dispatchSuspended = false
        dispatchNext()
    }

    public func enqueue(id: UUID, start: @escaping @MainActor () -> Void) {
        guard activeID != id, !waiting.contains(where: { $0.id == id }) else { return }
        waiting.append(Waiting(id: id, start: start))
        dispatchNext()
    }

    /// Cancelling a running operation does not release its slot. Its owner must
    /// await actual termination and call finish, even when responses arrive late.
    public func cancelWaiting(id: UUID) {
        waiting.removeAll { $0.id == id }
    }

    public func finish(id: UUID) {
        guard activeID == id else { return }
        activeID = nil
        dispatchNext()
    }

    private func dispatchNext() {
        guard !dispatchSuspended, activeID == nil, !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        activeID = next.id
        next.start()
    }
}
