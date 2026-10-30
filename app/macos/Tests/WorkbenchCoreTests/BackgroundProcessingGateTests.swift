import Foundation
import Testing
@testable import WorkbenchCore

@Suite(.serialized) @MainActor
struct BackgroundProcessingGateTests {
    @Test func audioWaitsForOtherMaterialAndCancellationDoesNotReleaseAnExecutingWorker() async throws {
        let service = QueueControlledTranscriber()
        let fixture = try await PostRecordingFixture(service: service)
        defer { fixture.remove() }
        let gate = BackgroundProcessingGate()
        let pdf = UUID()
        gate.enqueue(id: pdf) {}
        let processing = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: fixture.credentials, service: service, gate: gate)
        processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        let job = try #require(processing.enqueueTranscription(fixture.id))
        #expect(processing.backgroundTasks.first?.status == .queued)
        #expect(processing.runningID == nil)
        #expect(await service.requestCount == 0)
        gate.finish(id: pdf)
        await service.waitForRequests(1)
        let nextPDF = UUID()
        var nextStarted = false
        gate.enqueue(id: nextPDF) { nextStarted = true }
        processing.cancelBackgroundTask(job)
        #expect(processing.backgroundTasks.first?.status == .cancelled)
        #expect(!nextStarted)
        await service.finishAll("Late cancelled audio must not become a result")
        while processing.runningID != nil { await Task.yield() }
        #expect(nextStarted)
        #expect(processing.materials[fixture.id]?.results.isEmpty != false)
        // A duplicate completion from the old task cannot free the new owner's slot.
        gate.finish(id: job)
        #expect(gate.activeID == nextPDF)
        gate.finish(id: nextPDF)
    }

    @Test func cancellingWaitingAudioAndRestartingNeverUploadsIt() async throws {
        let service = QueueControlledTranscriber()
        let fixture = try await PostRecordingFixture(service: service)
        defer { fixture.remove() }
        let gate = BackgroundProcessingGate()
        let pdf = UUID()
        gate.enqueue(id: pdf) {}
        let processing = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: fixture.credentials, service: service, gate: gate)
        processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        let job = try #require(processing.enqueueTranscription(fixture.id))
        processing.cancelBackgroundTask(job)
        gate.finish(id: pdf)
        #expect(processing.runningID == nil)
        #expect(await service.requestCount == 0)
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: fixture.credentials, service: service, gate: gate)
        #expect(reopened.backgroundTasks.first?.status == .cancelled)
        #expect(await service.requestCount == 0)
    }

    @Test func confirmedQuitRemovesWaitingAudioFromSharedSlotUntilExplicitResume() async throws {
        let service = QueueControlledTranscriber()
        let fixture = try await PostRecordingFixture(service: service)
        defer { fixture.remove() }
        let gate = BackgroundProcessingGate()
        let pdf = UUID()
        gate.enqueue(id: pdf) {}
        let processing = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: fixture.credentials, service: service, gate: gate)
        processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        let job = try #require(processing.enqueueTranscription(fixture.id))
        #expect(processing.prepareForConfirmedQuit())
        gate.finish(id: pdf)
        #expect(await service.requestCount == 0)
        let reopened = PostRecordingSession(recordings: fixture.recordings, store: fixture.store,
            credentials: fixture.credentials, service: service, gate: gate)
        #expect(reopened.backgroundTasks.first?.status == .awaitingResume)
        #expect(gate.activeID == nil)
        await service.finishAll("Explicitly resumed result")
        #expect(reopened.resumeBackgroundTask(job))
        while reopened.runningID != nil { await Task.yield() }
        #expect(await service.requestCount == 1)
        #expect(reopened.materials[fixture.id]?.results.map(\.text) == ["Explicitly resumed result"])
    }
}
