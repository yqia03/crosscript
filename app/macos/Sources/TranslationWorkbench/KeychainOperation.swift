import Foundation
import Security

/// Both credential stores share this boundary because the legacy Keychain
/// interaction policy is process-wide. Only the worker may wait for system UI.
enum KeychainOperation {
    private static let queue = DispatchQueue(label: "TranslationWorkbench.Keychain")
    private static let lock = NSLock()
    enum Failure: Error { case unavailable }

    static func compatibility<Value>(_ operation: () throws -> Value) throws -> Value {
        guard lock.try() else { throw Failure.unavailable }
        defer { lock.unlock() }
        var previous = DarwinBoolean(true)
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { throw Failure.unavailable }
        defer { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return try operation()
    }
    static func read(_ operation: @escaping @Sendable () throws -> String?) async throws -> String? {
        let value = try await run(releaseWhileRunning: true, operation)
        try Task.checkCancellation()
        return value
    }
    /// Settings may inspect existence, never secret data. Keep legacy Keychain
    /// UI disabled on the same serialized worker used for credential operations.
    static func metadata(_ operation: @escaping @Sendable () throws -> Bool?) async throws -> Bool? {
        let value = try await run(releaseWhileRunning: true) {
            var previous = DarwinBoolean(true)
            guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
                  SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { throw Failure.unavailable }
            defer { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) }
            return try operation()
        }
        try Task.checkCancellation()
        return value
    }
    /// A started mutation returns its actual completion, allowing the caller to
    /// restore an old value if its encompassing settings transaction was cancelled.
    static func mutate(_ operation: @escaping @Sendable () throws -> Void) async throws {
        try await run(releaseWhileRunning: false, operation)
    }
    private static func run<Value: Sendable>(releaseWhileRunning: Bool, _ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let pending = PendingKeychainOperation<Value>(releaseWhileRunning: releaseWhileRunning)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard pending.begin(continuation) else { return }
                queue.async {
                    lock.lock(); defer { lock.unlock() }
                    guard pending.start() else { return }
                    pending.finish(Result { try operation() })
                }
            }
        } onCancel: { pending.cancel() }
    }
}

private final class PendingKeychainOperation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseWhileRunning: Bool
    private var continuation: CheckedContinuation<Value, Error>?
    private var cancelled = false, started = false, completed = false
    init(releaseWhileRunning: Bool) { self.releaseWhileRunning = releaseWhileRunning }
    func begin(_ value: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if cancelled { lock.unlock(); value.resume(throwing: CancellationError()); return false }
        continuation = value; lock.unlock(); return true
    }
    func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        started = true; return true
    }
    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true; let value = continuation; continuation = nil
        lock.unlock(); value?.resume(with: result)
    }
    func cancel() {
        lock.lock()
        guard !completed, !cancelled else { lock.unlock(); return }
        cancelled = true
        guard !started || releaseWhileRunning else { lock.unlock(); return }
        completed = true; let value = continuation; continuation = nil
        lock.unlock(); value?.resume(throwing: CancellationError())
    }
}
