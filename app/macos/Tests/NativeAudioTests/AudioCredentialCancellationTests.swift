import Foundation
import Testing
import WorkbenchCore
@testable import TranslationWorkbench

@Suite(.serialized) @MainActor struct AudioCredentialCancellationTests {
    @Test func compatibilityCallsFailFastWhileAuthorizationWorkerIsPending() async throws {
        let began = DispatchSemaphore(value: 0)
        let read = Task {
            try await KeychainAudioCredentials.readOffMain {
                began.signal()
                Thread.sleep(forTimeInterval: 0.35)
                return "isolated-fake-key"
            }
        }
        while began.wait(timeout: .now()) != .success { try await Task.sleep(for: .milliseconds(1)) }
        let credentials = KeychainAudioCredentials(service: "local-test-\(UUID())", allowsAuthenticationUI: false)
        let configuration = AudioServiceConfiguration(provider: .gemini)
        let start = ContinuousClock.now
        #expect(throws: AudioProcessingError.self) { try credentials.read(for: configuration) }
        #expect(throws: AudioProcessingError.self) { try credentials.save("fake", for: configuration) }
        #expect(throws: AudioProcessingError.self) { try credentials.delete(for: configuration) }
        #expect(start.duration(to: .now) < .milliseconds(100))
        _ = try await read.value
    }

    @Test func cancelledAuthorizationReleasesCallerBeforeUncooperativeLookupReturns() async throws {
        let began = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let read = Task {
            try await KeychainAudioCredentials.readOffMain {
                began.signal()
                Thread.sleep(forTimeInterval: 0.35)
                finished.signal()
                return "isolated-fake-key"
            }
        }
        while began.wait(timeout: .now()) != .success { try await Task.sleep(for: .milliseconds(1)) }
        let start = ContinuousClock.now
        read.cancel()
        do { _ = try await read.value; Issue.record("Cancelled lookup returned a key") }
        catch { #expect(error is CancellationError) }
        #expect(start.duration(to: .now) < .milliseconds(100))
        while finished.wait(timeout: .now()) != .success { try await Task.sleep(for: .milliseconds(1)) }
        let next = try await KeychainAudioCredentials.readOffMain { "next-fake-key" }
        #expect(next == "next-fake-key")
    }
}
