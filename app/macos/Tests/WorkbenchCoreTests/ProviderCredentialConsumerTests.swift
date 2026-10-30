import CoreGraphics
import Foundation
import Testing
@testable import WorkbenchCore

@Suite(.serialized) @MainActor struct ProviderCredentialConsumerTests {
    @Test func connectionCheckWaitsForAuthorizationAndCancelRejectsLateKey() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let credentials = WaitingProviderCredentials(), checker = RecordingProviderChecker()
        let app = ProviderConfigurationSession(store: .init(root: root), credentials: credentials, checker: checker)
        let profile = try #require(app.saveProfile(name: "Controlled", baseURL: "https://controlled.test", model: "model", apiKey: ""))
        let check = Task { await app.checkConnection(for: profile.id) }
        try await settle()
        #expect(credentials.isWaiting && credentials.syncReads == 0)
        #expect(await checker.requests.isEmpty)
        app.cancelConnectionCheck(); credentials.release(); await check.value
        #expect(await checker.requests.isEmpty)
        #expect(app.connectionReports.isEmpty && app.checkingProfileID == nil)
    }

    @Test func textWaitsForAuthorizationAndStopCannotSendLateKey() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let credentials = WaitingProviderCredentials(), service = ControlledTextTranslator()
        let app = TextTranslationSession(store: .init(root: root), credentials: credentials, service: service)
        _ = app.setDirection(direction: .englishToChinese)
        #expect(app.updateInput(text: "Immutable source"))
        let profile = try ProviderProfile(name: "Controlled", baseURL: "https://controlled.test", model: "model")
        let task = Task { await app.submit(provider: profile.snapshot, direction: .englishToChinese) }
        for _ in 0..<500 { if credentials.isWaiting { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(credentials.isWaiting && credentials.syncReads == 0)
        #expect(await service.requests.isEmpty)
        app.stop(); credentials.release(); await task.value
        #expect(await service.requests.isEmpty)
        #expect(app.workspace.inputDraft == "Immutable source")
    }

    @Test func pdfWaitsForAuthorizationAndCancelPreventsEngineStart() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let external = root.appendingPathComponent("input.pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = try #require(CGContext(external as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.fill(box); context.endPDFPage(); context.closePDF()
        let credentials = WaitingProviderCredentials(), engine = RejectingProviderPDFEngine(), gate = BackgroundProcessingGate()
        let app = PDFTranslationSession(store: .init(root: root.appendingPathComponent("library")), credentials: credentials, engine: engine, gate: gate)
        let id = try #require(app.importPDF(external))
        let profile = try ProviderProfile(name: "Controlled", baseURL: "https://controlled.test", model: "model")
        let task = try #require(app.submit(materialID: id, provider: profile.snapshot, options: .init()))
        try await settle()
        #expect(credentials.isWaiting && credentials.syncReads == 0)
        #expect(await engine.calls == 0)
        app.cancel(materialID: id, taskID: task); credentials.release()
        try await settle()
        #expect(await engine.calls == 0)
        #expect(app.runningTaskID == nil && gate.activeID == nil)
    }

    @Test func settingsPresentationDoesNotReadKeychainAndCancelledSaveCannotSelectCandidate() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let credentials = WaitingProviderCredentials()
        let app = ProviderConfigurationSession(store: .init(root: root), credentials: credentials, checker: ControlledProviderChecker())
        let original = try #require(app.saveProfile(name: "Original", baseURL: "https://old.test", model: "old", apiKey: ""))
        for _ in 0..<20 {
            #expect(app.credentialAvailability(for: original.id) == .unchecked)
            #expect(!app.hasCredential(for: original.id))
        }
        #expect(credentials.syncReads == 0 && credentials.reads.isEmpty)
        let save = Task { await app.saveProfileAsync(id: original.id, name: "New", baseURL: "https://new.test", model: "new", apiKey: "new-key") }
        try await settle()
        #expect(app.isUpdatingCredentials && app.profiles == [original] && credentials.isWaiting)
        app.cancelCredentialAction(); credentials.release(); #expect(await save.value == nil)
        #expect(app.profiles == [original] && !app.isUpdatingCredentials && credentials.writes.isEmpty)
    }

    @Test func cancelledStartedSettingsWriteRestoresOldScopedKeyAndCannotOverwriteProfile() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let credentials = WaitingProviderCredentials(); credentials.holdReads = false
        let app = ProviderConfigurationSession(store: .init(root: root), credentials: credentials, checker: ControlledProviderChecker())
        let original = try #require(app.saveProfile(name: "Original", baseURL: "https://old.test", model: "old", apiKey: "original-key"))
        credentials.holdWrites = true
        let save = Task { await app.saveProfileAsync(id: original.id, name: "New", baseURL: original.baseURL, model: "new", apiKey: "replacement-key") }
        try await settle()
        #expect(credentials.writeIsWaiting && app.profiles == [original])
        app.cancelCredentialAction()
        #expect(app.isUpdatingCredentials) // Prevent a new write from racing rollback.
        credentials.releaseWrite(); #expect(await save.value == nil)
        #expect(app.profiles == [original] && !app.isUpdatingCredentials)
        #expect(credentials.values[original.credentialReference] == "original-key")
        #expect(credentials.writes.map(\.1) == ["replacement-key", "original-key"])
    }

    @Test func settingsStorageFailureRestoresCredentialWithoutChangingSavedProfile() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let credentials = WaitingProviderCredentials(); credentials.holdReads = false
        let app = ProviderConfigurationSession(store: .init(root: root), credentials: credentials, checker: ControlledProviderChecker())
        let original = try #require(app.saveProfile(name: "Original", baseURL: "https://old.test", model: "old", apiKey: "original-key"))
        let file = root.appendingPathComponent("provider-configurations.json")
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("old.json"))
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        #expect(await app.saveProfileAsync(id: original.id, name: "New", baseURL: original.baseURL, model: "new", apiKey: "replacement-key") == nil)
        #expect(app.error == .storage && app.profiles == [original])
        #expect(credentials.values[original.credentialReference] == "original-key")
    }

    @Test func lateConnectionAuthorizationCannotSendKeyOrMarkChangedTargetAvailable() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let credentials = WaitingProviderCredentials(), checker = RecordingProviderChecker()
        let app = ProviderConfigurationSession(store: .init(root: root), credentials: credentials, checker: checker)
        let original = try #require(app.saveProfile(name: "Original", baseURL: "https://old.test", model: "old", apiKey: ""))
        let check = Task { await app.checkConnection(for: original.id) }; try await settle()
        let changed = try #require(app.saveProfile(id: original.id, name: "Changed", baseURL: "https://new.test", model: "new", apiKey: ""))
        credentials.release(); await check.value
        #expect(app.profiles == [changed] && app.connectionReports.isEmpty)
        #expect(app.credentialAvailability(for: changed.id) == .unchecked)
        #expect(await checker.requests.isEmpty)
    }

    @Test func textAuthorizationCancelsStaleSubmissionAndRetainsDraftEdits() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let credentials = WaitingProviderCredentials(), service = ControlledTextTranslator()
        let app = TextTranslationSession(store: .init(root: root), credentials: credentials, service: service)
        _ = app.setDirection(direction: .englishToChinese)
        #expect(app.updateInput(text: "Submitted source"))
        let profile = try ProviderProfile(name: "Original", baseURL: "https://old.test", model: "old")
        let request = Task { await app.submit(provider: profile.snapshot, direction: .englishToChinese) }
        for _ in 0..<500 { if credentials.isWaiting { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(app.isAuthorizingCredential && app.isRunning)
        #expect(app.updateInput(text: "Edited while authorizing"))
        #expect(credentials.reads.count == 1)
        credentials.release(); await request.value
        #expect(await service.requests.isEmpty)
        #expect(app.workspace.inputDraft == "Edited while authorizing")
        #expect(app.workspace.currentResult == nil)
        #expect(!app.isAuthorizingCredential && !app.isRunning)
    }

    @Test func textDefaultChangeCancelsCredentialAuthorizationBeforeSending() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let credentials = WaitingProviderCredentials(), service = ControlledTextTranslator()
        let app = TextTranslationSession(store: .init(root: root), credentials: credentials, service: service)
        _ = app.setDirection(direction: .englishToChinese)

        let old = try ProviderProfile(name: "Old", baseURL: "https://old.test", model: "old")
        let current = try ProviderProfile(name: "Current", baseURL: "https://current.test", model: "current")
        app.configureDefaultProvider(old.snapshot)
        _ = app.updateInput(text: "Old pending source")
        let request = Task { await app.submit(provider: old.snapshot, direction: .englishToChinese) }
        for _ in 0..<500 { if credentials.isWaiting { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(app.isAuthorizingCredential)
        app.configureDefaultProvider(current.snapshot)
        credentials.release(); await request.value; try await settle()
        #expect(await service.requests.isEmpty && app.workspace.currentResult == nil)
        #expect(credentials.reads == [old.credentialReference])
        credentials.holdReads = false; credentials.values[current.credentialReference] = "current-key"
        _ = app.updateInput(text: "Fresh edit")
        await app.submit(provider: current.snapshot, direction: .englishToChinese)
        #expect(await service.requests.first?.provider == current.snapshot)
        #expect(credentials.reads == [old.credentialReference, current.credentialReference])
        #expect(await app.flushPendingSaves())
    }

    @Test func pdfSecondCredentialScopeCancellationCannotStartEngine() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let external = root.appendingPathComponent("input.pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = try #require(CGContext(external as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.fill(box); context.endPDFPage(); context.closePDF()
        let credentials = WaitingProviderCredentials(), engine = RejectingProviderPDFEngine(), gate = BackgroundProcessingGate()
        let app = PDFTranslationSession(store: .init(root: root.appendingPathComponent("library")), credentials: credentials, engine: engine, gate: gate)
        let id = try #require(app.importPDF(external))
        let main = try ProviderProfile(name: "Main", baseURL: "https://main.test", model: "main")
        let terms = try ProviderProfile(name: "Terms", baseURL: "https://terms.test", model: "terms")
        var options = PDFTranslationOptions(); options.termExtractionProvider = terms.snapshot
        let task = try #require(app.submit(materialID: id, provider: main.snapshot, options: options))
        try await settle(); credentials.release(); try await settle()
        #expect(credentials.reads == [main.credentialReference, terms.credentialReference])
        #expect(app.authorizingTaskID == task)
        #expect(await engine.calls == 0)
        app.cancel(materialID: id, taskID: task); credentials.release(); try await settle()
        #expect(await engine.calls == 0)
        #expect(app.runningTaskID == nil && gate.activeID == nil)
        #expect(app.selectedMaterial?.results.isEmpty == true)
    }

    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("provider-consumer-\(UUID())") }
    private func settle() async throws { try await Task.sleep(for: .milliseconds(20)) }
}

@MainActor private final class WaitingProviderCredentials: ProviderCredentials {
    var syncReads = 0, holdReads = true, holdWrites = false
    var reads: [ProviderCredentialReference] = [], writes: [(ProviderCredentialReference, String)] = []
    var values: [ProviderCredentialReference: String] = [:]
    var pending: CheckedContinuation<String?, Error>?
    var pendingWrite: CheckedContinuation<Void, Error>?
    var isWaiting: Bool { pending != nil }
    var writeIsWaiting: Bool { pendingWrite != nil }
    func release() { pending?.resume(returning: "fixture-only"); pending = nil }
    func releaseWrite() { holdWrites = false; pendingWrite?.resume(); pendingWrite = nil }
    func read(reference: ProviderCredentialReference) throws -> String? { syncReads += 1; return values[reference] ?? "fixture-only" }
    func save(_ value: String, reference: ProviderCredentialReference) throws { values[reference] = value }
    func delete(reference: ProviderCredentialReference) throws { values[reference] = nil }
    func readAsync(reference: ProviderCredentialReference) async throws -> String? {
        reads.append(reference)
        if !holdReads { return values[reference] }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func saveAsync(_ value: String, reference: ProviderCredentialReference) async throws {
        writes.append((reference, value))
        if holdWrites { try await withCheckedThrowingContinuation { pendingWrite = $0 } }
        values[reference] = value
    }
    func deleteAsync(reference: ProviderCredentialReference) async throws { values[reference] = nil }
}
private actor RejectingProviderPDFEngine: PDFTranslating {
    var calls = 0
    func translate(_ request: PDFEngineRequest, apiKey: String, progress: @escaping @Sendable (PDFEngineProgress) -> Void) async throws -> PDFEngineResult {
        calls += 1; throw PDFTranslationError.processing
    }
}
