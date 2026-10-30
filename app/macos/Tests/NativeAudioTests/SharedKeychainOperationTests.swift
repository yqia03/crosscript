import Foundation
import Testing
import WorkbenchCore
@testable import TranslationWorkbench

@Suite(.serialized) @MainActor struct SharedKeychainOperationTests {
    @Test func providerCompatibilityFailsFastBehindAudioAuthorizationWithoutTouchingKeychain() async throws {
        let began = DispatchSemaphore(value: 0)
        let read = Task {
            try await KeychainAudioCredentials.readOffMain {
                began.signal(); Thread.sleep(forTimeInterval: 0.35); return "fake-only"
            }
        }
        while began.wait(timeout: .now()) != .success { try await Task.sleep(for: .milliseconds(1)) }
        let credentials = KeychainProviderCredentials(service: "test-unused-\(UUID())")
        let reference = ProviderCredentialReference(profileID: UUID(), target: "https://controlled.test")
        let start = ContinuousClock.now
        #expect(throws: ProviderConfigurationError.self) { try credentials.read(reference: reference) }
        #expect(throws: ProviderConfigurationError.self) { try credentials.save("fake", reference: reference) }
        #expect(throws: ProviderConfigurationError.self) { try credentials.delete(reference: reference) }
        #expect(start.duration(to: .now) < .milliseconds(100))
        _ = try await read.value
    }

    @Test func cancelledQueuedMutationNeverExecutesAndStartedMutationReportsCompletion() async throws {
        let began = DispatchSemaphore(value: 0), state = MutationState()
        let read = Task {
            try await KeychainOperation.read {
                began.signal(); Thread.sleep(forTimeInterval: 0.15); return "fake-only"
            }
        }
        while began.wait(timeout: .now()) != .success { try await Task.sleep(for: .milliseconds(1)) }
        let queued = Task { try await KeychainOperation.mutate { state.increment() } }
        try await Task.sleep(for: .milliseconds(5)); queued.cancel()
        do { try await queued.value; Issue.record("Cancelled queued mutation executed") }
        catch { #expect(error is CancellationError) }
        _ = try await read.value
        #expect(state.value == 0)
        let started = DispatchSemaphore(value: 0)
        let write = Task {
            try await KeychainOperation.mutate {
                started.signal(); Thread.sleep(forTimeInterval: 0.1); state.increment()
            }
        }
        while started.wait(timeout: .now()) != .success { try await Task.sleep(for: .milliseconds(1)) }
        write.cancel(); try await write.value
        #expect(state.value == 1)
    }
}
private final class MutationState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
