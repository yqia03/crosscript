import Foundation
import Testing
@testable import WorkbenchCore

@Suite(.serialized) @MainActor struct CredentialTransactionTests {
    @Test func audioCancelledStartedWriteMustRetainBusyAndPreventQuitUntilOldKeyIsRestored() async throws {
        let f = try await PostRecordingFixture(); defer { f.remove() }
        let credentials = TransactionAudioCredentials()
        let app = PostRecordingSession(recordings: f.recordings, store: f.store, credentials: credentials, service: ControlledTranscriber())
        app.saveConfiguration(provider: .aiHubMix, model: "whisper-large-v3", apiKey: "original-key")
        let original = app.configuration
        credentials.holdWrites = true
        let save = Task { await app.saveConfigurationAsync(provider: .aiHubMix, model: "whisper-large-v3-turbo", apiKey: "replacement-key") }
        try await settle { credentials.pending != nil }
        app.cancelCredentialAction()
        #expect(app.isUpdatingCredentials)
        #expect(!app.prepareToQuit())
        #expect(!app.prepareForConfirmedQuit())
        credentials.release()
        #expect(!(await save.value))
        #expect(credentials.values[original.credentialScope] == "original-key")
        #expect(app.configuration == original)
        #expect(!app.isUpdatingCredentials && app.prepareToQuit())
    }

    @Test func audioSettingsDiskFailureRestoresSameScopeKey() async throws {
        let f = try await PostRecordingFixture(); defer { f.remove() }
        let credentials = TransactionAudioCredentials()
        let app = PostRecordingSession(recordings: f.recordings, store: f.store, credentials: credentials, service: ControlledTranscriber())
        app.saveConfiguration(provider: .aiHubMix, model: "whisper-large-v3", apiKey: "original-key")
        let original = app.configuration
        let settings = f.root.appendingPathComponent("Recordings/audio-configuration.json")
        try FileManager.default.moveItem(at: settings, to: settings.appendingPathExtension("old"))
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: false)
        #expect(!(await app.saveConfigurationAsync(provider: .aiHubMix, model: "whisper-large-v3-turbo", apiKey: "replacement-key")))
        #expect(app.configuration == original && app.error == .storage)
        #expect(credentials.values[original.credentialScope] == "original-key")
    }
    @Test func audioHeldRollbackAndFailedRecoveryKeepQuitClosedUntilExplicitSuccess() async throws {
        let f = try await PostRecordingFixture(); defer { f.remove() }
        let credentials = TransactionAudioCredentials()
        let app = PostRecordingSession(recordings: f.recordings, store: f.store, credentials: credentials, service: ControlledTranscriber())
        app.saveConfiguration(provider: .aiHubMix, model: "whisper-large-v3", apiKey: "original-key")
        let original = app.configuration
        credentials.holdWrites = true; credentials.keepHolding = true
        let save = Task { await app.saveConfigurationAsync(provider: .aiHubMix, model: "whisper-large-v3-turbo", apiKey: "replacement-key") }
        try await settle { credentials.pending != nil }
        app.cancelCredentialAction(); credentials.release()
        try await settle { credentials.pending != nil }
        #expect(app.needsCredentialRecovery && app.isUpdatingCredentials && !app.prepareToQuit())
        #expect(credentials.values[original.credentialScope] == "replacement-key")
        credentials.release(error: AudioProcessingError.credential)
        #expect(!(await save.value))
        #expect(!app.isUpdatingCredentials && app.needsCredentialRecovery)
        #expect(!app.prepareToQuit() && !app.prepareForConfirmedQuit())
        app.saveConfiguration(model: "whisper-1", apiKey: "must-not-write")
        #expect(app.configuration == original)
        let retry = Task { await app.retryCredentialRecovery() }
        try await settle { credentials.pending != nil }
        #expect(!app.prepareToQuit())
        app.cancelCredentialAction() // Recovery cannot be abandoned midway.
        credentials.release(); await retry.value
        #expect(app.prepareToQuit() && !app.needsCredentialRecovery)
        #expect(credentials.values[original.credentialScope] == "original-key")
    }

    @Test func failedNewTargetSaveDeletesOnlyItsNewKeyAndKeepsOriginalTarget() async throws {
        let f = try await PostRecordingFixture(); defer { f.remove() }
        let credentials = TransactionAudioCredentials()
        let app = PostRecordingSession(recordings: f.recordings, store: f.store, credentials: credentials, service: ControlledTranscriber())
        app.saveConfiguration(model: "whisper-1", apiKey: "original-key")
        let original = app.configuration
        let settings = f.root.appendingPathComponent("Recordings/audio-configuration.json")
        try FileManager.default.moveItem(at: settings, to: settings.appendingPathExtension("old"))
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: false)
        #expect(!(await app.saveConfigurationAsync(provider: .aiHubMix, model: "whisper-large-v3", apiKey: "new-target-key")))
        #expect(app.configuration == original)
        #expect(credentials.values == [original.credentialScope: "original-key"])
        #expect(app.credentialTransactionsReadyForQuit)
    }

    @Test func newTargetRecoveryFailureDoesNotChangeOriginalScopeAvailability() async throws {
        let f = try await PostRecordingFixture(); defer { f.remove() }
        let credentials = TransactionAudioCredentials()
        let app = PostRecordingSession(recordings: f.recordings, store: f.store, credentials: credentials, service: ControlledTranscriber())
        app.saveConfiguration(model: "whisper-1", apiKey: "original-key")
        let original = app.configuration
        #expect(app.hasCredential)
        let settings = f.root.appendingPathComponent("Recordings/audio-configuration.json")
        try FileManager.default.moveItem(at: settings, to: settings.appendingPathExtension("old"))
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: false)
        credentials.failDeletes = true
        #expect(!(await app.saveConfigurationAsync(provider: .aiHubMix, model: "whisper-large-v3", apiKey: "new-target-key")))
        #expect(app.configuration == original && app.needsCredentialRecovery)
        #expect(app.hasCredential) // Only the other target's deletion failed.
        await app.retryCredentialRecovery()
        #expect(app.hasCredential && app.needsCredentialRecovery)
        credentials.failDeletes = false
        await app.retryCredentialRecovery()
        #expect(app.hasCredential && !app.needsCredentialRecovery)
        #expect(credentials.values == [original.credentialScope: "original-key"])
    }

    private func settle(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(predicate())
    }
}

@MainActor private final class TransactionAudioCredentials: AudioCredentials {
    var values: [String: String] = [:]
    var holdWrites = false, keepHolding = false, failDeletes = false
    var pending: CheckedContinuation<Void, Error>?
    func release(error: Error? = nil) {
        if !keepHolding { holdWrites = false }
        let value = pending; pending = nil
        if let error { value?.resume(throwing: error) } else { value?.resume() }
    }
    func read(for configuration: AudioServiceConfiguration) throws -> String? { values[configuration.credentialScope] }
    func save(_ value: String, for configuration: AudioServiceConfiguration) throws { values[configuration.credentialScope] = value }
    func delete(for configuration: AudioServiceConfiguration) throws {
        if failDeletes { throw AudioProcessingError.credential }
        values[configuration.credentialScope] = nil
    }
    func saveAsync(_ value: String, for configuration: AudioServiceConfiguration) async throws {
        if holdWrites { try await withCheckedThrowingContinuation { pending = $0 } }
        values[configuration.credentialScope] = value
    }
}
