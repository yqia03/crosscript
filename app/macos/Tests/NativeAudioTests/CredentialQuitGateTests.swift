import Foundation
import Testing
import WorkbenchCore
@testable import TranslationWorkbench

@Suite(.serialized) @MainActor struct CredentialQuitGateTests {
    @Test func quitRemainsBlockedFromStartedWriteThroughCancelledRollback() async throws {
        let fixture = try CredentialQuitFixture()
        defer { fixture.remove() }
        #expect(WorkbenchAppDelegate.credentialTransactionsReadyForQuit)
        fixture.credentials.holdWrites = true
        let save = Task {
            await fixture.providers.saveProfileAsync(id: fixture.original.id, name: "Controlled provider",
                baseURL: fixture.original.baseURL, model: "replacement-model", apiKey: "replacement-key")
        }
        try await settle { fixture.credentials.pendingValue == "replacement-key" }
        #expect(!WorkbenchAppDelegate.credentialTransactionsReadyForQuit)
        fixture.providers.cancelCredentialAction()
        #expect(fixture.providers.isUpdatingCredentials && fixture.providers.isCancellingCredentialAction)
        #expect(!WorkbenchAppDelegate.credentialTransactionsReadyForQuit)
        #expect(!fixture.providers.prepareToQuit())

        fixture.credentials.releaseWrite()
        try await settle { fixture.credentials.pendingValue == "original-key" }
        #expect(fixture.credentials.values[fixture.original.credentialReference] == "replacement-key")
        #expect(!WorkbenchAppDelegate.credentialTransactionsReadyForQuit)
        #expect(!fixture.providers.prepareToQuit())

        fixture.credentials.releaseWrite()
        #expect(await save.value == nil)
        #expect(fixture.credentials.values[fixture.original.credentialReference] == "original-key")
        #expect(fixture.providers.profiles == [fixture.original])
        #expect(WorkbenchAppDelegate.credentialTransactionsReadyForQuit)
        #expect(fixture.providers.prepareToQuit())
    }

    @Test func failedRollbackKeepsQuitBlockedUntilExplicitRecoverySucceeds() async throws {
        let fixture = try CredentialQuitFixture()
        defer { fixture.remove() }
        fixture.credentials.holdWrites = true
        let save = Task {
            await fixture.providers.saveProfileAsync(id: fixture.original.id, name: "Controlled provider",
                baseURL: fixture.original.baseURL, model: "replacement-model", apiKey: "replacement-key")
        }
        try await settle { fixture.credentials.pendingValue == "replacement-key" }
        fixture.providers.cancelCredentialAction()
        fixture.credentials.releaseWrite()
        try await settle { fixture.credentials.pendingValue == "original-key" }
        fixture.credentials.releaseWrite(error: ProviderConfigurationError.credential)
        #expect(await save.value == nil)
        #expect(fixture.providers.needsCredentialRecovery)
        #expect(!fixture.providers.isUpdatingCredentials)
        #expect(!WorkbenchAppDelegate.credentialTransactionsReadyForQuit)
        #expect(!fixture.providers.prepareToQuit())
        #expect(fixture.credentials.values[fixture.original.credentialReference] == "replacement-key")

        let recovery = Task { await fixture.providers.retryCredentialRecovery() }
        try await settle { fixture.credentials.pendingValue == "original-key" }
        #expect(!WorkbenchAppDelegate.credentialTransactionsReadyForQuit)
        fixture.credentials.releaseWrite()
        _ = await recovery.value
        #expect(!fixture.providers.needsCredentialRecovery)
        #expect(fixture.credentials.values[fixture.original.credentialReference] == "original-key")
        #expect(fixture.providers.profiles == [fixture.original])
        #expect(WorkbenchAppDelegate.credentialTransactionsReadyForQuit)
        #expect(fixture.providers.prepareToQuit())
    }

    private func settle(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(predicate())
    }
}

@MainActor private final class CredentialQuitFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("credential-quit-\(UUID())")
    let credentials = QuitGateProviderCredentials()
    let providers: ProviderConfigurationSession
    let original: ProviderProfile
    private let previousProviders = WorkbenchAppDelegate.providers
    private let previousProcessing = WorkbenchAppDelegate.processing

    init() throws {
        let session = ProviderConfigurationSession(store: ProviderConfigurationStore(root: root),
            credentials: credentials, checker: QuitGateProviderChecker())
        original = try #require(session.saveProfile(name: "Controlled provider", baseURL: "https://controlled.test/v1",
            model: "original-model", apiKey: "original-key"))
        providers = session
        WorkbenchAppDelegate.providers = session
        WorkbenchAppDelegate.processing = nil
    }

    func remove() {
        credentials.holdWrites = false
        credentials.releaseWrite()
        WorkbenchAppDelegate.providers = previousProviders
        WorkbenchAppDelegate.processing = previousProcessing
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor private final class QuitGateProviderCredentials: ProviderCredentials {
    var values: [ProviderCredentialReference: String] = [:]
    var holdWrites = false
    private(set) var pendingValue: String?
    private var pending: CheckedContinuation<Void, Error>?
    func read(reference: ProviderCredentialReference) throws -> String? { values[reference] }
    func save(_ value: String, reference: ProviderCredentialReference) throws { values[reference] = value }
    func delete(reference: ProviderCredentialReference) throws { values[reference] = nil }
    func saveAsync(_ value: String, reference: ProviderCredentialReference) async throws {
        // An already-started system mutation may complete after cancellation.
        // Hold each write independently so the rollback can be observed too.
        if holdWrites {
            try await withCheckedThrowingContinuation { pending = $0; pendingValue = value }
        }
        values[reference] = value
    }
    func releaseWrite(error: Error? = nil) {
        let continuation = pending
        pending = nil; pendingValue = nil
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
    }
}

private struct QuitGateProviderChecker: ProviderConnectionChecking {
    func check(snapshot: ProviderSnapshot, apiKey: String) async throws -> ProviderConnectionReport {
        Issue.record("Credential transaction testing must not contact a provider")
        throw ProviderConfigurationError.network
    }
}
