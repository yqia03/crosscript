import Foundation
import Testing
@testable import WorkbenchCore

@Suite(.serialized) @MainActor
struct ProviderConfigurationTests {
    @Test func deletingSharedDefaultAndFinalProfilePersistsWithoutTouchingSubmittedCredentials() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = ControlledProviderCredentials()
        let app = ProviderConfigurationSession(store: .init(root: root), credentials: credentials, checker: ControlledProviderChecker())
        let first = try #require(app.saveProfile(name: "Shared", baseURL: "https://shared.example", model: "first", apiKey: "shared-key"))
        let other = try #require(app.saveProfile(name: "Other", baseURL: first.baseURL, model: "second", apiKey: "other-key"))
        let submitted = try app.snapshot(for: first.id)
        app.setDefault(first.id, for: .text); app.setDefault(first.id, for: .pdf)
        #expect(app.deleteProfile(first.id, submittedSnapshot: submitted))
        #expect(app.profiles == [other] && app.defaults == .init())
        #expect(throws: ProviderConfigurationError.configuration) { try app.snapshot(for: first.id) }
        #expect(try submitted.validated() == submitted)
        #expect(try credentials.read(reference: submitted.credentialReference) == "shared-key")
        #expect(try credentials.read(reference: other.credentialReference) == "other-key")
        let reopened = ProviderConfigurationSession(store: .init(root: root), credentials: credentials, checker: ControlledProviderChecker())
        #expect(reopened.profiles == [other] && reopened.defaults == .init())
        reopened.setDefault(other.id, for: .pdf)
        #expect(reopened.deleteProfile(other.id))
        reopened.reload()
        #expect(reopened.profiles.isEmpty && reopened.defaults == .init() && reopened.error == nil)
    }

    @Test func deleteFailureAndStaleConfirmationPreserveProfilesDefaultsAndCredentials() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = ControlledProviderCredentials()
        let app = ProviderConfigurationSession(store: .init(root: root), credentials: credentials, checker: ControlledProviderChecker())
        let original = try #require(app.saveProfile(name: "Original", baseURL: "https://shared.example", model: "first", apiKey: "retained-key"))
        app.setDefault(original.id, for: .text)
        let changed = try #require(app.saveProfile(id: original.id, name: "Changed", baseURL: original.baseURL, model: "second", apiKey: ""))
        #expect(!app.deleteProfile(original.id, submittedSnapshot: original.snapshot))
        #expect(app.error == .configuration && app.profiles == [changed])
        let path = root.appendingPathComponent("provider-configurations.json")
        let bytes = try Data(contentsOf: path)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        #expect(!app.deleteProfile(changed.id))
        #expect(app.error == .storage && app.profiles == [changed] && app.defaults.textID == changed.id)
        #expect(try credentials.read(reference: changed.credentialReference) == "retained-key")
        try FileManager.default.removeItem(at: path); try bytes.write(to: path)
        #expect(app.deleteProfile(changed.id))
        #expect(app.profiles.isEmpty && app.defaults == .init())
    }

    @Test func deletingOneProfileDoesNotChangeAnotherDefaultAndCancelsItsConnectionCheck() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let checker = SuspendedProviderChecker()
        let app = ProviderConfigurationSession(store: .init(root: root), credentials: ControlledProviderCredentials(), checker: checker)
        let first = try #require(app.saveProfile(name: "First", baseURL: "https://first.example", model: "model", apiKey: "key"))
        let second = try #require(app.saveProfile(name: "Second", baseURL: "https://second.example", model: "model", apiKey: "key"))
        app.setDefault(first.id, for: .text); app.setDefault(second.id, for: .pdf)
        let check = Task { await app.checkConnection(for: first.id) }
        while await checker.requestCount == 0 { await Task.yield() }
        #expect(app.deleteProfile(first.id))
        #expect(app.checkingProfileID == nil && app.defaults.textID == nil && app.defaults.pdfID == second.id)
        await checker.finish(0, report: .directoryAvailable(modelListed: true, modelCount: 1))
        await check.value
        #expect(app.connectionReports[first.id] == nil && app.error == nil)
    }

    @Test(arguments: [
        (" https://EXAMPLE.test:443/ ", "https://example.test/chat/completions"),
        ("https://example.test/prefix", "https://example.test/prefix/chat/completions"),
        ("https://example.test/prefix/v1/chat/completions/", "https://example.test/prefix/v1/chat/completions")
    ])
    func savedEndpointsRetainTheirPrefixWithoutAddingAVersion(address: String, expected: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = ProviderConfigurationSession(store: ProviderConfigurationStore(root: root), credentials: ControlledProviderCredentials(), checker: ControlledProviderChecker())
        let profile = try #require(app.saveProfile(name: "Custom", baseURL: address, model: "model/with:version", apiKey: ""))
        #expect(try app.snapshot(for: profile.id).chatCompletionsURL().absoluteString == expected)
    }

    @Test(arguments: ["http://example.test", "https://user:key@example.test", "https://example.test?key=secret",
                      "https://example.test/#secret", "https://example.test/../v1", "https://example.test/%2e%2e/v1",
                      "https://example.test//prefix", "https://example.test:99999", "https://example.test./v1", "https://example.test/has space"])
    func unsafeTargetsCannotReplaceConfigurationOrStoreTheirKey(address: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = ControlledProviderCredentials()
        let app = ProviderConfigurationSession(store: ProviderConfigurationStore(root: root), credentials: credentials, checker: ControlledProviderChecker())
        let old = try #require(app.saveProfile(name: "Original", baseURL: "https://example.test", model: "model", apiKey: "original-key"))
        #expect(app.saveProfile(id: old.id, name: "Bad target", baseURL: address, model: "model", apiKey: "must-not-store") == nil)
        #expect(app.error == .configuration)
        #expect(app.profiles == [old])
        #expect(try credentials.read(reference: old.credentialReference) == "original-key")
    }

    @Test func corruptConfigurationIsPreservedUntilItCanBeReadAgain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("provider-configurations.json")
        let corrupt = Data("unreadable-existing-configuration".utf8)
        try corrupt.write(to: file)
        let app = ProviderConfigurationSession(store: ProviderConfigurationStore(root: root), credentials: ControlledProviderCredentials(), checker: ControlledProviderChecker())
        #expect(app.error == .storage)
        #expect(app.saveProfile(name: "Must not overwrite", baseURL: "https://example.test", model: "model", apiKey: "") == nil)
        #expect(try Data(contentsOf: file) == corrupt)
        try FileManager.default.removeItem(at: file)
        app.reload()
        #expect(app.error == nil)
        #expect(app.saveProfile(name: "Recovered", baseURL: "https://example.test", model: "model", apiKey: "") != nil)
    }

    @Test func cancelledLateCheckCannotReplaceANewerTargetsReport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SuspendedProviderChecker()
        let app = ProviderConfigurationSession(store: ProviderConfigurationStore(root: root), credentials: ControlledProviderCredentials(), checker: service)
        let profile = try #require(app.saveProfile(name: "Original", baseURL: "https://first.test", model: "first", apiKey: "first-key"))
        let old = Task { await app.checkConnection(for: profile.id) }
        while await service.requestCount < 1 { await Task.yield() }
        app.cancelConnectionCheck()
        #expect(app.checkingProfileID == nil)
        _ = try #require(app.saveProfile(id: profile.id, name: "Changed", baseURL: "https://second.test", model: "second", apiKey: "second-key"))
        let current = Task { await app.checkConnection(for: profile.id) }
        while await service.requestCount < 2 { await Task.yield() }
        await service.finish(0, report: .directoryAvailable(modelListed: true, modelCount: 1))
        await old.value
        #expect(app.checkingProfileID == profile.id)
        #expect(app.connectionReports[profile.id] == nil)
        await service.finish(1, report: .directoryAvailable(modelListed: false, modelCount: 3))
        await current.value
        #expect(app.connectionReports[profile.id] == .directoryAvailable(modelListed: false, modelCount: 3))
        #expect(app.error == nil)
    }

    @Test func connectionCheckIsExplicitAndUnavailableDirectoryDoesNotRejectCustomModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RecordingProviderChecker()
        let app = ProviderConfigurationSession(store: ProviderConfigurationStore(root: root), credentials: ControlledProviderCredentials(), checker: service)
        let profile = try #require(app.saveProfile(name: "Custom", baseURL: "https://example.test/prefix", model: "unlisted-model", apiKey: "controlled-key"))
        #expect(await service.requests.isEmpty)
        await app.checkConnection(for: profile.id)
        #expect(app.connectionReports[profile.id] == .directoryUnsupported(statusCode: 404))
        #expect(app.error == nil)
        #expect(app.profiles.first?.model == "unlisted-model")
        #expect(await service.requests.first?.model == "unlisted-model")
        app.removeCredential(for: profile.id)
        await app.checkConnection(for: profile.id)
        #expect(app.error == .credential)
        #expect(await service.requests.count == 1)
    }

    @Test func failedSavePreservesPreviousConfigurationAndCredentialAndCanRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = ControlledProviderCredentials()
        let app = ProviderConfigurationSession(store: ProviderConfigurationStore(root: root), credentials: credentials,
                                               checker: ControlledProviderChecker())
        let old = try #require(app.saveProfile(name: "Original", baseURL: "https://service.example", model: "model-a", apiKey: "original-key"))
        let file = root.appendingPathComponent("provider-configurations.json")
        let backup = root.appendingPathComponent("controlled-backup.json")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        #expect(app.saveProfile(id: old.id, name: "Changed", baseURL: old.baseURL, model: "model-b", apiKey: "replacement-key") == nil)
        #expect(app.error == .storage)
        #expect(app.profiles == [old])
        #expect(try credentials.read(reference: old.credentialReference) == "original-key")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        #expect(app.saveProfile(id: old.id, name: "Changed", baseURL: old.baseURL, model: "model-b", apiKey: "replacement-key") != nil)
        let reopened = ProviderConfigurationSession(store: ProviderConfigurationStore(root: root), credentials: credentials,
                                                    checker: ControlledProviderChecker())
        #expect(reopened.profiles.first?.name == "Changed")
        #expect(try credentials.read(reference: old.credentialReference) == "replacement-key")
    }

    @Test func changingTargetNeverTransfersCredentialsOrRewritesSubmittedSnapshots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = ControlledProviderCredentials()
        let app = ProviderConfigurationSession(store: ProviderConfigurationStore(root: root), credentials: credentials,
                                               checker: ControlledProviderChecker())
        let original = try #require(app.saveProfile(name: "Service", baseURL: "https://first.example/api/chat/completions", model: "first-model", apiKey: "first-key"))
        let submitted = try app.snapshot(for: original.id)
        let changed = try #require(app.saveProfile(id: original.id, name: "New target", baseURL: "https://other.example/proxy", model: "second-model", apiKey: ""))
        #expect(submitted.baseURL == "https://first.example/api")
        #expect(submitted.model == "first-model")
        #expect(try credentials.read(reference: submitted.credentialReference) == "first-key")
        #expect(try credentials.read(reference: changed.credentialReference) == nil)
        #expect(!app.hasCredential(for: changed.id))
        let restored = try #require(app.saveProfile(id: original.id, name: "Restore", baseURL: "https://first.example/api", model: "next-model", apiKey: ""))
        #expect(restored.credentialReference == submitted.credentialReference)
        app.removeCredential(for: restored.id)
        #expect(try credentials.read(reference: submitted.credentialReference) == nil)
        #expect(app.profiles.first?.model == "next-model")
    }

    @Test func multipleProfilesAndIndependentDefaultsSurviveRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = ControlledProviderCredentials()
        let app = ProviderConfigurationSession(store: ProviderConfigurationStore(root: root), credentials: credentials,
                                               checker: ControlledProviderChecker())
        let first = try #require(app.saveProfile(name: "Writing", baseURL: "https://gateway.example/prefix/v1/", model: "custom-model", apiKey: "test-key"))
        let second = try #require(app.saveProfile(name: "Reading", baseURL: "https://second.example", model: "other-model", apiKey: "second-key"))
        app.setDefault(first.id, for: .text)
        app.setDefault(second.id, for: .pdf)
        let reopened = ProviderConfigurationSession(store: ProviderConfigurationStore(root: root), credentials: credentials,
                                                    checker: ControlledProviderChecker())
        #expect(reopened.profiles.map(\.name) == ["Writing", "Reading"])
        #expect(reopened.defaults.textID == first.id)
        #expect(reopened.defaults.pdfID == second.id)
        let snapshot = try reopened.snapshot(for: first.id)
        #expect(snapshot.baseURL == "https://gateway.example/prefix/v1")
        #expect(try snapshot.chatCompletionsURL().absoluteString == "https://gateway.example/prefix/v1/chat/completions")
        #expect(try credentials.read(reference: snapshot.credentialReference) == "test-key")
        let configurationBytes = try Data(contentsOf: root.appendingPathComponent("provider-configurations.json"))
        #expect(!String(decoding: configurationBytes, as: UTF8.self).contains("test-key"))
        #expect(!String(decoding: configurationBytes, as: UTF8.self).contains("second-key"))
    }
}

@MainActor final class ControlledProviderCredentials: ProviderCredentials {
    var values: [ProviderCredentialReference: String] = [:]
    func read(reference: ProviderCredentialReference) throws -> String? { values[reference] }
    func save(_ value: String, reference: ProviderCredentialReference) throws { values[reference] = value }
    func delete(reference: ProviderCredentialReference) throws { values[reference] = nil }
}

struct ControlledProviderChecker: ProviderConnectionChecking {
    func check(snapshot: ProviderSnapshot, apiKey: String) async throws -> ProviderConnectionReport {
        .directoryAvailable(modelListed: true, modelCount: 1)
    }
}

actor RecordingProviderChecker: ProviderConnectionChecking {
    var requests: [ProviderSnapshot] = []
    func check(snapshot: ProviderSnapshot, apiKey: String) async throws -> ProviderConnectionReport {
        requests.append(snapshot)
        return .directoryUnsupported(statusCode: 404)
    }
}

actor SuspendedProviderChecker: ProviderConnectionChecking {
    var continuations: [CheckedContinuation<ProviderConnectionReport, Error>] = []
    var requestCount: Int { continuations.count }
    func check(snapshot: ProviderSnapshot, apiKey: String) async throws -> ProviderConnectionReport {
        try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func finish(_ index: Int, report: ProviderConnectionReport) { continuations[index].resume(returning: report) }
}
