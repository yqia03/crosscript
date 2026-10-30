import Foundation
import Testing
@testable import WorkbenchCore

@Suite(.serialized) @MainActor
struct NightBatchIntegrationTests {
    @Test func textFinishesWhileAudioRunsAndWaitsWithoutBorrowingItsSlotOrChangingItsProvider() async throws {
        let audio = QueueControlledTranscriber()
        let fixture = try await PostRecordingFixture(service: audio)
        defer { fixture.remove() }
        let firstRecording = fixture.id
        await fixture.recordings.importAudio(from: fixture.root.appendingPathComponent("sample.wav"), using: ControlledAudioImporter())
        let secondRecording = fixture.id
        fixture.processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-audio-key")
        let firstJob = try #require(fixture.processing.enqueueTranscription(firstRecording))
        let secondJob = try #require(fixture.processing.enqueueTranscription(secondRecording))
        await audio.waitForRequests(1)
        #expect(fixture.processing.backgroundTasks.map(\.status) == [.running, .queued])

        let credentials = BatchProviderCredentials()
        let providers = ProviderConfigurationSession(store: ProviderConfigurationStore(root: fixture.root),
            credentials: credentials, checker: BatchDirectory())
        let first = try #require(providers.saveProfile(name: "First text provider", baseURL: "https://first.invalid/v1",
            model: "chosen-model", apiKey: "controlled-text-key"))
        let second = try #require(providers.saveProfile(name: "Later default", baseURL: "https://later.invalid",
            model: "later-model", apiKey: "other-controlled-key"))
        providers.setDefault(first.id, for: .text)
        let service = BatchTextService()
        let store = TextWorkspaceStore(root: fixture.root)
        let text = TextTranslationSession(store: store, credentials: credentials, service: service)
        _ = text.updateInput(text: "Keep this input while audio is busy.")
        let submitted = try providers.snapshot(for: first.id)
        let work = Task { await text.submit(provider: submitted, direction: .englishToChinese) }
        await service.waitForRequest()
        providers.setDefault(second.id, for: .text)
        #expect(fixture.processing.backgroundTasks.first { $0.id == firstJob }?.status == .running)
        #expect(fixture.processing.backgroundTasks.first { $0.id == secondJob }?.status == .queued)
        #expect(await audio.requestCount == 1)
        await service.finish()
        await work.value
        let result = try #require(text.workspace.currentResult)
        #expect(text.text(resultID: result.id) == "受控译文完整保存。")
        #expect(await service.providers == [submitted])
        #expect(providers.defaults.textID == second.id)
        #expect(await audio.requestCount == 1)
        let reopened = TextTranslationSession(store: store, credentials: credentials, service: service)
        #expect(reopened.text(resultID: result.id) == "受控译文完整保存。")
        #expect(await service.providers.count == 1)
        await audio.finishAll("Audio finishes after the independent text request")
        while fixture.processing.runningID != nil { await Task.yield() }
        #expect(fixture.processing.backgroundTasks.map(\.status) == [.completed, .completed])
    }
}

@MainActor private final class BatchProviderCredentials: ProviderCredentials {
    private var keys: [ProviderCredentialReference: String] = [:]
    func read(reference: ProviderCredentialReference) throws -> String? { keys[reference] }
    func save(_ value: String, reference: ProviderCredentialReference) throws { keys[reference] = value }
    func delete(reference: ProviderCredentialReference) throws { keys[reference] = nil }
}
private struct BatchDirectory: ProviderConnectionChecking {
    func check(snapshot: ProviderSnapshot, apiKey: String) async throws -> ProviderConnectionReport {
        .directoryAvailable(modelListed: true, modelCount: 1)
    }
}
private actor BatchTextService: TextTranslating {
    private(set) var providers: [ProviderSnapshot] = []
    private var waiting: CheckedContinuation<Void, Never>?
    func translate(_ request: TextTranslationRequest, apiKey: String,
                   onEvent: @escaping @Sendable (TextTranslationEvent) async -> Void) async throws {
        providers.append(request.provider)
        await onEvent(.delta("受控译文"))
        await withCheckedContinuation { waiting = $0 }
        await onEvent(.delta("完整保存。"))
    }
    func waitForRequest() async { while waiting == nil { await Task.yield() } }
    func finish() { waiting?.resume(); waiting = nil }
}
