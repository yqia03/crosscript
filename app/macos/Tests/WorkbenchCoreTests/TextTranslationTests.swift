import Foundation
import Testing
@testable import WorkbenchCore

@Suite(.serialized) @MainActor
struct TextTranslationTests {
    @Test func currentResultReplacesPriorRequestAndEditsExportReopen() async throws {
        let f = try TextFixture(); defer { f.remove() }; let app = f.app
        #expect(app.updateInput(text: "Hello, 世界 👩🏽‍💻"))
        await app.submit(provider: f.profile.snapshot, direction: .englishToChinese)
        let first = try #require(app.workspace.currentResult)
        #expect(app.updateResult(resultID: first.id, text: "Manual edit"))
        #expect(await app.flushPendingSaves()); #expect(f.reopen().workspace.translation == "Manual edit")
        #expect(app.updateInput(text: "中文")); _ = app.setDirection(direction: .chineseToEnglish)
        await app.retry()
        let current = try #require(app.workspace.currentResult)
        #expect(current.id != first.id && current.input == "中文" && current.direction == .chineseToEnglish)
        #expect(app.text(resultID: first.id) == nil)
        #expect(!app.updateResult(resultID: first.id, text: "Stale edit"))
        let json = try Data(contentsOf: materialFile(f)); let object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(object["results"] == nil && object["selectedResultID"] == nil && object["schemaVersion"] as? Int == 3)
        let url = external("txt"); defer { try? FileManager.default.removeItem(at: url) }
        _ = app.updateTranslation(text: "Current user edit")
        #expect(app.exportTranslation(to: url)); #expect(try String(contentsOf: url) == "Current user edit")
        #expect(f.reopen().workspace.translation == "Current user edit")
    }
    @Test func manualTranslationBeforeAnyRequestPersistsWithoutProvider() throws {
        let f = try TextFixture(); defer { f.remove() };
        #expect(f.app.updateTranslation(text: "Personal draft")); #expect(f.app.workspace.currentResult == nil)
        #expect(f.reopen().workspace.translation == "Personal draft"); #expect(f.credentials.readCount == 0)
    }
    @Test func stopAndManualEditIgnoreLateResponsesAndFailedRetryPreservesPartial() async throws {
        let service = SuspendedTextTranslator(), f = try TextFixture(service: service); defer { f.remove() }
        let app = f.app; _ = app.updateInput(text: "Original")
        let first = Task { await app.submit(provider: f.profile.snapshot, direction: .englishToChinese) }
        await service.waitForRequests(1); let firstID = try #require(app.runningResultID)
        await service.emit(0, .delta("Partial")); #expect(app.updateTranslation(text: "User wins"))
        #expect(!app.isRunning && app.workspace.currentResult?.status == .stopped)
        await service.emit(0, .delta("Late")); await service.finish(0); await first.value
        #expect(app.workspace.translation == "User wins"); #expect(app.history.first { $0.id == firstID }?.translation == "Partial")
        let second = Task { await app.retry() }; await service.waitForRequests(2)
        await service.emit(1, .delta("Failure partial")); await service.finish(1, error: .rateLimited); await second.value
        #expect(app.workspace.translation == "Failure partial")
        #expect(app.workspace.currentResult?.failure == .rateLimited)
        #expect(f.reopen().workspace.translation == "Failure partial")
    }
    @Test func sourceChangeCancelsOldRequestAndLateCallbacksCannotOverwriteNewSource() async throws {
        let service = SuspendedTextTranslator(), f = try TextFixture(service: service); defer { f.remove() }
        let app = f.app; _ = app.updateInput(text: "Old")
        let task = Task { await app.submit(provider: f.profile.snapshot, direction: .englishToChinese) }
        await service.waitForRequests(1); await service.emit(0, .delta("Received"))
        _ = app.updateInput(text: "New 原文")
        await service.emit(0, .delta("Wrong")); await service.finish(0); await task.value
        #expect(app.workspace.inputDraft == "New 原文" && app.workspace.translation == "Received")
        #expect(app.workspace.currentResult?.status == .stopped)
    }
    @Test func saveFailureKeepsCurrentDraftExportableAndRetryNeverTranslates() async throws {
        let service = ControlledTextTranslator(), f = try TextFixture(service: service); defer { f.remove() }
        let app = f.app; _ = app.updateInput(text: "Initial"); #expect(app.retrySaving()); let file = materialFile(f), saved = try Data(contentsOf: file)
        try Data("broken".utf8).write(to: file)
        #expect(app.updateInput(text: "Recover source")); #expect(app.updateTranslation(text: "Recover target"))
        #expect(!(await app.flushPendingSaves())); #expect(app.hasPendingSave)
        await app.submit(provider: f.profile.snapshot, direction: .englishToChinese)
        #expect(await service.requests.isEmpty); #expect(!app.prepareToQuit()); #expect(app.workspace.inputDraft == "Recover source")
        let destination = external("txt"); defer { try? FileManager.default.removeItem(at: destination) }
        #expect(app.exportTranslation(to: destination)); #expect(try String(contentsOf: destination) == "Recover target")
        #expect(app.hasPendingSave); try saved.write(to: file); #expect(app.retrySaving())
        #expect(f.reopen().workspace.translation == "Recover target"); #expect(await service.requests.isEmpty)
    }
    @Test func streamingSaveFailureProtectsQuitAndRetainsPartial() async throws {
        let service = SuspendedTextTranslator(), f = try TextFixture(service: service); defer { f.remove() }
        let app = f.app; _ = app.updateInput(text: "Source")
        let task = Task { await app.submit(provider: f.profile.snapshot, direction: .englishToChinese) }
        await service.waitForRequests(1); let resultID = app.runningResultID
        let file = materialFile(f), saved = try Data(contentsOf: file); try Data("broken".utf8).write(to: file)
        await service.emit(0, .delta("保留部分")); #expect(!(await app.flushPendingSaves()))
        #expect(!app.prepareForConfirmedQuit()); #expect(app.runningResultID == resultID)
        app.stop()
        #expect(app.hasPendingSave)
        _ = app.updateTranslation(text: "停止后修改"); try saved.write(to: file); #expect(app.retrySaving())
        await service.finish(0); await task.value; #expect(f.reopen().workspace.translation == "停止后修改")
    }
    @Test func confirmedQuitAndRestartKeepPartialWithoutAutomaticRequest() async throws {
        let service = SuspendedTextTranslator(), f = try TextFixture(service: service); defer { f.remove() }
        let app = f.app; _ = app.updateInput(text: "Source")
        let task = Task { await app.submit(provider: f.profile.snapshot, direction: .englishToChinese) }
        await service.waitForRequests(1); await service.emit(0, .delta("Partial before quit")); #expect(await app.flushPendingSaves())
        let restarted = TextTranslationSession(store: f.store, credentials: f.credentials, service: service)
        #expect(restarted.workspace.currentResult?.status == .interrupted && restarted.workspace.translation == "Partial before quit")
        #expect(app.prepareForConfirmedQuit()); await service.emit(0, .delta("Late")); await service.finish(0); await task.value
        #expect(app.workspace.translation == "Partial before quit"); #expect(await service.requestCount == 1)
    }
    @Test func successfulBackgroundSaveClearsRecoveredFailureAndUnsavedSourceRemainsExportable() async throws {
        let f = try TextFixture(); defer { f.remove() }; let app = f.app
        _ = app.updateInput(text: "Initial"); #expect(app.retrySaving())
        let file = materialFile(f), saved = try Data(contentsOf: file); try Data("broken".utf8).write(to: file)
        _ = app.updateInput(text: "Unsaved exact e\u{301} 中文")
        #expect(!(await app.flushPendingSaves()))
        let target = external("txt"); defer { try? FileManager.default.removeItem(at: target) }
        #expect(app.exportInput(to: target))
        #expect(try Data(contentsOf: target) == Data("Unsaved exact e\u{301} 中文".utf8))
        #expect(f.credentials.readCount == 0)
        try saved.write(to: file); _ = app.updateInput(text: "Recovered draft")
        try await wait { !app.hasPendingSave }
        #expect(app.error == nil && f.reopen().workspace.inputDraft == "Recovered draft")
    }
    @Test func unknownSchemaAndSymlinkAreNeverOverwritten() throws {
        let f = try TextFixture(); defer { f.remove() }; let app = f.app; _ = app.updateInput(text: "Initial"); #expect(app.retrySaving()); let file = materialFile(f)
        let saved = try Data(contentsOf: file); var object = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any]); object["schemaVersion"] = 999
        let future = try JSONSerialization.data(withJSONObject: object); try future.write(to: file)
        _ = app.updateInput(text: "Memory only"); #expect(!app.retrySaving()); #expect(try Data(contentsOf: file) == future)
        #expect(f.reopen().error == .storage); try saved.write(to: file); #expect(app.retrySaving())
        let outside = external("directory"); defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.moveItem(at: file.deletingLastPathComponent(), to: outside)
        let outsideBytes = try Data(contentsOf: outside.appendingPathComponent("workspace.json"))
        try FileManager.default.createSymbolicLink(at: file.deletingLastPathComponent(), withDestinationURL: outside)
        _ = app.updateInput(text: "Must not escape"); #expect(!app.retrySaving())
        #expect(try Data(contentsOf: outside.appendingPathComponent("workspace.json")) == outsideBytes)
    }
    @Test func exportCannotOverwriteManagedNamespacesAndImportRetainsExactCopy() throws {
        let f = try TextFixture(); defer { f.remove() }; let source = external("md"); defer { try? FileManager.default.removeItem(at: source) }
        let original = Data("# 中文\r\n\nCode `a`".utf8); try original.write(to: source)
        #expect(f.app.importText(from: source)); try FileManager.default.removeItem(at: source)
        #expect(f.app.workspace.importedMarkdown == original)
        _ = f.app.updateInput(text: "Changed source"); _ = f.app.updateTranslation(text: "Manual target")
        let other = f.root.appendingPathComponent("recording.json"); try Data("audio sentinel".utf8).write(to: other)
        #expect(!f.app.exportTranslation(to: other)); #expect(!f.app.exportInput(to: materialFile(f)))
        #expect(try String(contentsOf: other) == "audio sentinel")
        #expect(f.reopen().workspace.importedMarkdown == original)
    }
    @Test func emptyMissingKeyAndCancelledSubmissionNeverCallService() async throws {
        let service = ControlledTextTranslator(), f = try TextFixture(service: service); defer { f.remove() };
        await f.app.submit(provider: f.profile.snapshot, direction: .englishToChinese); #expect(f.app.error == .emptyInput)
        _ = f.app.updateInput(text: "Source"); f.credentials.values.removeAll()
        await f.app.submit(provider: f.profile.snapshot, direction: .englishToChinese); #expect(f.app.error == .credential)
        let reads = f.credentials.readCount
        let task = Task { await f.app.submit(provider: f.profile.snapshot, direction: .englishToChinese) }; task.cancel(); await task.value
        #expect(f.credentials.readCount == reads); #expect(await service.requests.isEmpty)
    }
    @Test func swapAndClearOperateOnCurrentContentAndPersistDirection() throws {
        let f = try TextFixture(); defer { f.remove() };
        _ = f.app.updateInput(text: "English"); _ = f.app.updateTranslation(text: "中文")
        #expect(f.app.swapLanguages()); #expect(f.app.workspace.inputDraft == "中文" && f.app.workspace.translation == "English")
        #expect(f.reopen().workspace.direction == .chineseToEnglish); #expect(f.app.clear())
        #expect(f.reopen().workspace.inputDraft.isEmpty == true && f.reopen().workspace.translation.isEmpty == true)
    }
    @Test func repeatedEditsPersistLatestRevisionAfterBackgroundWrites() async throws {
        let f = try TextFixture(); defer { f.remove() };
        for index in 0..<100 { _ = f.app.updateInput(text: "\(index) 👩🏽‍💻 中文") }
        try await Task.sleep(for: .milliseconds(270)); _ = f.app.updateInput(text: "Latest")
        #expect(await f.app.flushPendingSaves()); try await Task.sleep(for: .milliseconds(300))
        #expect(f.reopen().workspace.inputDraft == "Latest" && !f.app.hasPendingSave)
    }
    @Test func repeatedExplicitSubmissionsAppendHistoryAndRestoringNeverMutatesIt() async throws {
        let service = ControlledTextTranslator(), f = try TextFixture(service: service); defer { f.remove() }
        let app = f.app
        #expect(app.updateInput(text: "Identical source"))
        await app.submit(provider: f.profile.snapshot, direction: .englishToChinese)
        await app.submit(provider: f.profile.snapshot, direction: .englishToChinese)
        #expect(app.history.count == 2 && app.history[0].id != app.history[1].id)
        let history = app.history, entry = try #require(history.last)
        #expect(app.openHistory(entry.id)); #expect(app.updateTranslation(text: "Workspace edit"))
        #expect(app.updateInput(text: "Workspace draft")); #expect(app.history == history)
        #expect(app.retrySaving()); let reopened = f.reopen()
        #expect(reopened.history == history && reopened.workspace.inputDraft == "Workspace draft")
        #expect(reopened.openHistory(entry.id)); #expect(reopened.workspace.translation == entry.translation)
        #expect(await service.requests.count == 2)
        await reopened.submit(provider: f.profile.snapshot, direction: .englishToChinese)
        #expect(reopened.history.count == 3 && reopened.history.dropFirst().elementsEqual(history))
    }
    @Test func editingImportingRestoringAndChangingSettingsNeverSubmits() async throws {
        let service = ControlledTextTranslator(), f = try TextFixture(service: service); defer { f.remove() }
        let app = f.app
        app.configureDefaultProvider(f.profile.snapshot)
        #expect(app.updateInput(text: "n")); app.compositionBegan(); #expect(app.updateInput(text: "你好"))
        #expect(app.setDirection(direction: .chineseToEnglish)); #expect(app.setMarkdown(enabled: true))
        try await Task.sleep(for: .milliseconds(650))
        #expect(await service.requests.isEmpty && f.credentials.readCount == 0 && app.history.isEmpty)
        let source = external("txt"); defer { try? FileManager.default.removeItem(at: source) }
        try Data("Import source".utf8).write(to: source); #expect(app.importText(from: source))
        app.configureDefaultProvider(nil); let reopened = f.reopen(); reopened.configureDefaultProvider(f.profile.snapshot)
        try await Task.sleep(for: .milliseconds(650))
        #expect(await service.requests.isEmpty && reopened.history.isEmpty && reopened.workspace.inputDraft == "Import source")
    }
    @Test func automaticSourceSnapshotsActualLanguageAndRestoresSelectionWithoutRequest() async throws {
        let f = try TextFixture(automaticSource: true); defer { f.remove() }
        let app = f.app
        #expect(app.workspace.automaticallyDetectsSourceLanguage)
        _ = app.updateInput(text: "This is a complete English paragraph about reading books and learning a new language.")
        await app.submit(provider: f.profile.snapshot, direction: app.workspace.direction)
        let entry = try #require(app.history.first)
        #expect(entry.result.direction == .englishToChinese && entry.result.sourceWasAutomatic == true)
        _ = app.setDirection(direction: .chineseToEnglish)
        #expect(app.openHistory(entry.id))
        #expect(app.workspace.automaticallyDetectsSourceLanguage && app.workspace.direction == .englishToChinese)
        #expect(f.credentials.readCount == 1)
        #expect(f.reopen().workspace.automaticallyDetectsSourceLanguage)
    }
    @Test func uncertainAutomaticSourceNeverReadsCredentialsAndManualChoiceOverridesIt() async throws {
        let service = ControlledTextTranslator(), f = try TextFixture(service: service, automaticSource: true); defer { f.remove() }
        for input in ["... 123 👩🏽‍💻", "Hi你好", "https://example.com/english-path"] {
            _ = f.app.updateInput(text: input)
            await f.app.submit(provider: f.profile.snapshot, direction: .englishToChinese)
            #expect(f.app.error == .languageUndetermined && f.app.history.isEmpty)
        }
        let beforeManual = await service.requests
        #expect(f.credentials.readCount == 0 && beforeManual.isEmpty)
        #expect(!f.app.swapLanguages())
        _ = f.app.setSourceLanguage(.english)
        await f.app.submit(provider: f.profile.snapshot, direction: f.app.workspace.direction)
        #expect(f.app.history.first?.result.sourceWasAutomatic == false)
        let afterManual = await service.requests
        #expect(f.credentials.readCount == 1 && afterManual.count == 1)
    }
    @Test func automaticMarkdownDetectionUsesBodyRatherThanCodeAndURLsThenSwapUsesActualDirection() async throws {
        let f = try TextFixture(service: MarkdownControlledTranslator(), automaticSource: true); defer { f.remove() }
        _ = f.app.setMarkdown(enabled: true)
        _ = f.app.setTargetLanguage(.english)
        let source = "这是一段中文正文，介绍如何阅读书籍和学习新的语言，希望能够准确识别原文语言。\n\n```swift\n" + String(repeating: "let englishVariable = \"This is a long English code sample that must not affect detection.\"\n", count: 100) + "```\n\n[阅读说明](https://example.com/english-documentation)\n"
        _ = f.app.updateInput(text: source)
        await f.app.submit(provider: f.profile.snapshot, direction: f.app.workspace.direction)
        let entry = try #require(f.app.history.first)
        #expect(entry.result.direction == .chineseToEnglish && entry.result.sourceWasAutomatic == true)
        let translated = f.app.workspace.translation
        #expect(f.app.swapLanguages())
        #expect(f.app.workspace.direction == .englishToChinese && !f.app.workspace.automaticallyDetectsSourceLanguage)
        #expect(f.app.workspace.inputDraft == translated)
        #expect(f.app.history == [entry])
    }
    @Test func oldSchemaThreeLibraryMissingAutomaticFieldsRetainsItsExplicitDirection() async throws {
        let f = try TextFixture(); defer { f.remove() }
        _ = f.app.updateInput(text: "Source"); _ = f.app.setDirection(direction: .chineseToEnglish)
        await f.app.submit(provider: f.profile.snapshot, direction: .chineseToEnglish)
        #expect(f.app.retrySaving())
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: materialFile(f))) as? [String: Any])
        var workspace = try #require(object["workspace"] as? [String: Any]); workspace.removeValue(forKey: "sourceLanguageIsAutomatic")
        var result = try #require(workspace["currentResult"] as? [String: Any]); result.removeValue(forKey: "sourceWasAutomatic"); workspace["currentResult"] = result; object["workspace"] = workspace
        var history = try #require(object["history"] as? [[String: Any]])
        for index in history.indices { var item = try #require(history[index]["result"] as? [String: Any]); item.removeValue(forKey: "sourceWasAutomatic"); history[index]["result"] = item }
        object["history"] = history
        try JSONSerialization.data(withJSONObject: object).write(to: materialFile(f))
        let restored = TextTranslationSession(store: f.store, credentials: f.credentials, service: f.service)
        #expect(restored.error == nil && restored.workspace.direction == .chineseToEnglish && !restored.workspace.automaticallyDetectsSourceLanguage)
        #expect(restored.openHistory(try #require(restored.history.first?.id)))
        #expect(!restored.workspace.automaticallyDetectsSourceLanguage && restored.workspace.direction == .chineseToEnglish)
        #expect(f.credentials.readCount == 1)
    }
    @Test func lateLocalDetectionCannotOverrideManualSourceChoice() async throws {
        let detector = SuspendedTextLanguageDetector(), f = try TextFixture(automaticSource: true, detector: detector); defer { detector.release(); f.remove() }
        _ = f.app.updateInput(text: "An English paragraph whose detection is deliberately delayed.")
        try await wait { detector.started }
        _ = f.app.setSourceLanguage(.init(rawValue: "fr"))
        detector.release()
        try await Task.sleep(for: .milliseconds(30))
        #expect(f.app.workspace.direction.sourceLanguage.rawValue == "fr" && !f.app.workspace.automaticallyDetectsSourceLanguage)
        #expect(f.app.detectedSourceLanguage == nil && !f.app.isDetectingSourceLanguage && f.credentials.readCount == 0)
    }
    @Test(arguments: ["configuration", "stop", "translationEdit"])
    func sourceDetectionWaitCannotSendAStaleSubmission(change: String) async throws {
        let detector = SuspendedTextLanguageDetector(), service = ControlledTextTranslator()
        let f = try TextFixture(service: service, automaticSource: true, detector: detector)
        defer { detector.release(); f.remove() }
        f.app.configureDefaultProvider(f.profile.snapshot)
        _ = f.app.updateInput(text: "An English paragraph whose detection has not finished yet.")
        var submitted = false
        let submission = Task { submitted = true; await f.app.submit(provider: f.profile.snapshot, direction: .englishToChinese) }
        try await wait { detector.started && submitted }
        switch change {
        case "configuration": f.app.configureDefaultProvider(nil)
        case "stop": f.app.stop()
        default: _ = f.app.updateTranslation(text: "Manual translation while detecting")
        }
        detector.release(); await submission.value
        let requests = await service.requests
        #expect(f.credentials.readCount == 0 && requests.isEmpty && f.app.history.isEmpty)
        #expect(!f.app.isRunning && f.app.workspace.currentResult == nil)
    }
    private func materialFile(_ fixture: TextFixture) -> URL { fixture.root.appendingPathComponent("TextWorkspace/workspace.json") }
    private func external(_ ext: String) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext) }
    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 { if await condition() { return }; try await Task.sleep(for: .milliseconds(2)) }; Issue.record("Controlled request did not arrive")
    }
}

@MainActor final class TextFixture {
    let root: URL
    let profile: ProviderProfile
    let credentials = TextTestCredentials()
    let service: any TextTranslating
    let store: TextWorkspaceStore
    let app: TextTranslationSession
    init(service: any TextTranslating = ControlledTextTranslator(), automaticSource: Bool = false, detector: any TextLanguageDetecting = TextLanguageDetector()) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("text-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        profile = try ProviderProfile(name: "Controlled text", baseURL: "https://text.test/prefix", model: "custom-text-model")
        credentials.values[profile.credentialReference] = "controlled-text-key"
        self.service = service
        store = TextWorkspaceStore(root: root)
        app = TextTranslationSession(store: store, credentials: credentials, service: service, languageDetector: detector)
        if !automaticSource { _ = app.setDirection(direction: .englishToChinese) }
    }
    func reopen() -> TextTranslationSession { _ = app.retrySaving(); return TextTranslationSession(store: store, credentials: credentials, service: service) }
    func remove() { _ = app.prepareForConfirmedQuit(); try? FileManager.default.removeItem(at: root) }
}

@MainActor final class TextTestCredentials: ProviderCredentials {
    var values: [ProviderCredentialReference: String] = [:]
    var readCount = 0
    func read(reference: ProviderCredentialReference) throws -> String? { readCount += 1; return values[reference] }
    func save(_ value: String, reference: ProviderCredentialReference) throws { values[reference] = value }
    func delete(reference: ProviderCredentialReference) throws { values[reference] = nil }
}

actor ControlledTextTranslator: TextTranslating {
    var requests: [TextTranslationRequest] = []
    func translate(_ request: TextTranslationRequest, apiKey: String,
                   onEvent: @escaping @Sendable (TextTranslationEvent) async -> Void) async throws {
        requests.append(request)
        await onEvent(.delta("你好，世界。"))
        await onEvent(.delta("\n第二行。"))
    }
}

actor SuspendedTextTranslator: TextTranslating {
    private var requests: [TextTranslationRequest] = []
    private var callbacks: [@Sendable (TextTranslationEvent) async -> Void] = []
    private var continuations: [CheckedContinuation<Void, Error>] = []
    func translate(_ request: TextTranslationRequest, apiKey: String,
                   onEvent: @escaping @Sendable (TextTranslationEvent) async -> Void) async throws {
        requests.append(request); callbacks.append(onEvent)
        try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    var requestCount: Int { requests.count }
    func request(at index: Int) -> TextTranslationRequest { requests[index] }
    func waitForRequests(_ count: Int) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if requests.count >= count { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for controlled translation request")
    }
    func emit(_ index: Int, _ event: TextTranslationEvent) async { await callbacks[index](event) }
    func finish(_ index: Int, error: TextTranslationError? = nil) {
        if let error { continuations[index].resume(throwing: error) } else { continuations[index].resume() }
    }
}

private struct TextSettingsChecker: ProviderConnectionChecking {
    func check(snapshot: ProviderSnapshot, apiKey: String) async throws -> ProviderConnectionReport { throw ProviderConfigurationError.network }
}

private final class SuspendedTextLanguageDetector: TextLanguageDetecting, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var didStart = false
    var started: Bool { lock.lock(); defer { lock.unlock() }; return didStart }
    func detectLanguage(in text: String) -> TranslationLanguage? {
        lock.lock(); didStart = true; lock.unlock()
        _ = gate.wait(timeout: .now() + 5)
        return .english
    }
    func release() { gate.signal() }
}
