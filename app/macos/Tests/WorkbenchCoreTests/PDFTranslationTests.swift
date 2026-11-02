import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import WorkbenchCore

@Suite(.serialized) @MainActor struct PDFTranslationTests {
    @Test func workspaceAppendsMixedImportsAndRemovalOnlyChangesTheVisibleList() throws {
        let fixture = try PDFFixture(); defer { fixture.remove() }
        let originalBytes = try Data(contentsOf: fixture.external)
        let invalid = fixture.root.appendingPathComponent("not-a-pdf.txt")
        try Data("ordinary text".utf8).write(to: invalid)
        let first = try #require(fixture.app.importPDF(fixture.external))
        let next = fixture.app.importPDFs([fixture.external, invalid, fixture.external])
        #expect(next.count == 2)
        #expect(fixture.app.workspaceMaterialIDs == [first] + next)
        #expect(fixture.app.selectedID == next.last)
        #expect(fixture.app.workspaceIssues.count == 1)
        #expect(fixture.app.workspaceIssues.first?.name == "not-a-pdf.txt")
        #expect(fixture.app.workspaceIssues.first?.error == .invalidPDF)
        #expect(fixture.app.materials.count == 3)
        for id in fixture.app.workspaceMaterialIDs {
            #expect(fixture.app.sourceMetadata[id]?.pageCount == 1)
            #expect(fixture.app.sourceMetadata[id]?.byteCount == Int64(originalBytes.count))
        }
        fixture.app.removeFromWorkspace(first)
        #expect(fixture.app.workspaceMaterialIDs == next && fixture.app.selectedID == next.last)
        fixture.app.removeFromWorkspace(try #require(next.last))
        #expect(fixture.app.selectedID == next.first)
        fixture.app.removeFromWorkspace(try #require(next.first))
        #expect(fixture.app.workspaceMaterialIDs.isEmpty && fixture.app.selectedID == nil)
        #expect(!fixture.app.hasSubmittableWorkspaceMaterials)
        #expect(fixture.app.submitWorkspace(provider: fixture.profile.snapshot, options: .init()).isEmpty)
        #expect(fixture.app.materials.count == 3 && fixture.credentials.reads == 0)
        #expect(try Data(contentsOf: fixture.external) == originalBytes)
        fixture.app.open(first); fixture.app.open(first)
        #expect(fixture.app.workspaceMaterialIDs == [first] && fixture.app.selectedID == first)
        #expect(try fixture.store.load().materials.count == 3)
        let reopened = fixture.reopen()
        #expect(reopened.workspaceMaterialIDs == [try #require(reopened.selectedID)])
        #expect(reopened.materials.count == 3)
    }

    @Test func batchSubmissionSkipsActiveAndCancellingFilesAndRemovalDoesNotStopQueue() async throws {
        let fixture = try PDFFixture(); defer { fixture.remove() }
        let files = fixture.app.importPDFs([fixture.external, fixture.external, fixture.external])
        #expect(files.count == 3)
        let tasks = fixture.app.submitWorkspace(provider: fixture.profile.snapshot, options: .init())
        #expect(tasks.count == 3)
        try await fixture.engine.wait(1)
        #expect(fixture.app.submitWorkspace(provider: fixture.profile.snapshot, options: .init()).isEmpty)
        fixture.app.cancel(materialID: files[0], taskID: tasks[0])
        #expect(fixture.app.hasQueuedOrRunningTask(files[0]))
        #expect(fixture.app.submitWorkspace(provider: fixture.profile.snapshot, options: .init()).isEmpty)
        fixture.app.removeFromWorkspace(files[0]); fixture.app.removeFromWorkspace(files[1])
        #expect(fixture.app.workspaceMaterialIDs == [files[2]])
        #expect(fixture.app.materials.first { $0.id == files[1] }?.tasks.first?.status == .queued)
        #expect(await fixture.engine.count == 1)
        await fixture.engine.finish(0)
        try await fixture.engine.wait(2)
        #expect(await fixture.engine.requests[1].id == tasks[1])
        await fixture.engine.finish(1)
        try await fixture.engine.wait(3)
        #expect(await fixture.engine.requests[2].id == tasks[2])
        await fixture.engine.finish(2)
        try await settle { fixture.app.runningTaskID == nil }
        #expect(fixture.app.materials.first { $0.id == files[0] }?.results.isEmpty == true)
        #expect(fixture.app.materials.first { $0.id == files[1] }?.results.count == 1)
        fixture.app.open(files[1])
        #expect(fixture.app.selectedMaterial?.selectedResult?.taskID == tasks[1])
        #expect(fixture.app.workspaceMaterialIDs == [files[2], files[1]])
        #expect(await fixture.engine.count == 3)
    }

    @Test func batchPageValidationAndSnapshotsRemainBoundToEachFile() async throws {
        let fixture = try PDFFixture(); defer { fixture.remove() }
        let longer = fixture.root.appendingPathComponent("two-pages.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = try #require(CGContext(longer as CFURL, mediaBox: &box, nil))
        for _ in 0..<2 { context.beginPDFPage(nil); context.fill(box); context.endPDFPage() }
        context.closePDF()
        let files = fixture.app.importPDFs([fixture.external, longer])
        var options = PDFTranslationOptions(direction: .chineseToEnglish); options.output.pages = "2"
        let submitted = fixture.app.submitWorkspace(provider: fixture.profile.snapshot, options: options)
        #expect(submitted.count == 1)
        #expect(fixture.app.workspaceIssues.first?.materialID == files[0])
        #expect(fixture.app.workspaceIssues.first?.error == .configuration)
        #expect(fixture.app.materials.first { $0.id == files[0] }?.tasks.isEmpty == true)
        options.direction = .englishToChinese; options.output.pages = "1"
        fixture.app.open(files[0])
        try await fixture.engine.wait(1)
        let request = await fixture.engine.requests[0]
        #expect(request.inputURL == fixture.app.originalURL(files[1]))
        #expect(request.options.direction == .chineseToEnglish && request.options.output.pages == "2")
        #expect(fixture.app.sourceMetadata[files[0]]?.pageCount == 1)
        #expect(fixture.app.sourceMetadata[files[1]]?.pageCount == 2)
        await fixture.engine.finish(0)
        try await settle { fixture.app.runningTaskID == nil }
        #expect(fixture.app.selectedID == files[0])
        #expect(fixture.app.materials.first { $0.id == files[1] }?.selectedResult?.options.direction == .chineseToEnglish)
    }

    @Test func deletingMaterialAlsoRemovesItsWorkspaceCardWithoutDeletingExternalSource() throws {
        let fixture = try PDFFixture(); defer { fixture.remove() }
        let ids = fixture.app.importPDFs([fixture.external, fixture.external])
        #expect(fixture.app.requestDeletion(.material(ids[1])))
        #expect(fixture.app.confirmDeletion())
        #expect(fixture.app.workspaceMaterialIDs == [ids[0]])
        #expect(fixture.app.selectedID == ids[0] && fixture.app.sourceMetadata[ids[1]] == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.external.path))
    }

    @Test func runningLocalTasksPresentLocalProcessingWithoutTranslation() async throws {
        let fixture = try PDFFixture(); defer { fixture.remove() }
        let id = try #require(fixture.app.importPDF(fixture.external))
        for (index, operation) in [PDFContentSettings.Operation.parseOnly, .typesetOnly].enumerated() {
            var options = PDFTranslationOptions()
            options.content.operation = operation; options.output.watermark = .noWatermark
            let taskID = try #require(fixture.app.submit(materialID: id, provider: nil, options: options))
            try await fixture.engine.wait(index + 1)
            let running = try #require(fixture.app.selectedMaterial?.tasks.first { $0.id == taskID })
            #expect(running.status == .running)
            #expect(running.statusDescription(.zhHans) == "本地处理中")
            #expect(running.statusDescription(.english) == "Processing locally")
            await fixture.engine.finish(index)
            try await settle { fixture.app.runningTaskID == nil }
            let completed = try #require(fixture.app.selectedMaterial?.tasks.first { $0.id == taskID })
            #expect(completed.statusDescription(.zhHans) == "本地生成完成 · 未翻译")
            #expect(completed.statusDescription(.english) == "Local generation completed · Untranslated")
        }
        #expect(await fixture.engine.requests.allSatisfy { $0.provider == nil })
    }

    @Test func taskPresentationPreservesServiceAndInactiveStatusLabels() throws {
        let profile = try ProviderProfile(name: "Controlled", baseURL: "https://controlled.test", model: "model")
        for operation in PDFContentSettings.Operation.allCases {
            var options = PDFTranslationOptions(); options.content.operation = operation
            var task = PDFBackgroundTask(provider: options.requiresService ? profile.snapshot : nil, options: options)
            for status in [PDFBackgroundTask.Status.queued, .running, .completed, .failed, .cancelled, .interrupted, .awaitingResume, .awaitingLocalSave] {
                task.status = status
                for language in [AppLanguage.zhHans, .english] {
                    if options.requiresService || (status != .running && status != .completed) {
                        #expect(task.statusDescription(language) == status.description(language))
                    }
                }
            }
        }
    }

    @Test func invalidPageRangeNeverEntersQueueOrReadsCredentials() async throws {
        let f = try PDFFixture(); defer { f.remove() }
        let id = try #require(f.app.importPDF(f.external))
        var options = PDFTranslationOptions(); options.output.pages = "2-4"
        #expect(f.app.submit(materialID: id, provider: f.profile.snapshot, options: options) == nil)
        #expect(f.app.selectedMaterial?.tasks.isEmpty == true)
        #expect(await f.engine.count == 0)
        #expect(f.app.error == .configuration)
        #expect(try Data(contentsOf: #require(f.app.originalURL(id))) == Data(contentsOf: f.external))
    }
    @Test func submittedTerminologySnapshotAndSeparateCredentialsSurviveLibraryEdits() async throws {
        let gate = BackgroundProcessingGate(), blocker = UUID(); gate.enqueue(id: blocker) {}
        let fixture = try PDFFixture(gate: gate); defer { fixture.remove() }
        let library = TranslationResourceLibrary(root: fixture.root.appendingPathComponent("library"))
        var glossary = TranslationGlossary(name: "Primary", entries: [.init(source: "latency", target: "延迟")])
        let second = TranslationGlossary(name: "Other", entries: [.init(source: "cache", target: "缓存")])
        let prompt = TranslationPromptPreset(name: "Precise", instruction: "Use precise prose.")
        #expect(library.saveGlossary(glossary)); #expect(library.saveGlossary(second)); #expect(library.savePrompt(prompt))
        var options = PDFTranslationOptions()
        options.resources = try library.snapshot(.init(glossaryIDs: [glossary.id, second.id], promptID: prompt.id))
        options.saveAutoExtractedGlossary = true
        let term = try ProviderProfile(name: "Term service", baseURL: "https://terms.test/v1", model: "term-model")
        options.termExtractionProvider = term.snapshot; options.termExtractionReasoning = "low"
        fixture.credentials.values[term.credentialReference] = "term-target-key"
        let id = try #require(fixture.app.importPDF(fixture.external))
        _ = fixture.app.submit(materialID: id, provider: fixture.profile.snapshot, options: options)
        glossary.entries[0].target = "later edit"; #expect(library.saveGlossary(glossary)); #expect(library.deletePrompt(prompt.id))
        gate.finish(id: blocker); try await fixture.engine.wait(1)
        let request = await fixture.engine.requests[0]
        #expect(request.options == options)
        #expect(request.options.resources.glossaries[0].entries[0].target == "延迟")
        #expect(request.termExtractionAPIKey == "term-target-key")
        await fixture.engine.finish(0, glossary: "source,target,tgt_lng\nlatency,延迟,zh\n")
        try await settle { fixture.app.runningTaskID == nil }
        let result = try #require(fixture.reopen().selectedMaterial?.selectedResult)
        #expect(result.options == options); #expect(result.outputs.count == 2)
        let extracted = try #require(result.outputs.first { $0.kind == .glossaryCSV })
        let url = try #require(fixture.app.resultURL(materialID: id, resultID: result.id, output: extracted))
        #expect(try TranslationGlossary.importCSV(String(contentsOf: url, encoding: .utf8), name: "Extracted").entries.first?.target == "延迟")
        let bytes = try JSONEncoder().encode(fixture.app.selectedMaterial)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("term-target-key"))
        #expect(!String(decoding: bytes, as: UTF8.self).contains("test-key"))
    }
    @Test func missingExtractionCredentialNeverBorrowsPrimaryKeyAndOldOptionsRemainReadable() async throws {
        let fixture = try PDFFixture(); defer { fixture.remove() }
        let id = try #require(fixture.app.importPDF(fixture.external))
        var options = PDFTranslationOptions()
        options.termExtractionProvider = try ProviderProfile(name: "Missing", baseURL: "https://other.test/v1", model: "terms").snapshot
        _ = fixture.app.submit(materialID: id, provider: fixture.profile.snapshot, options: options)
        try await settle { fixture.app.runningTaskID == nil }
        #expect(fixture.app.selectedMaterial?.tasks.first?.failure == .credential)
        #expect(await fixture.engine.count == 0)
        #expect(try JSONDecoder().decode(PDFTranslationOptions.self, from: Data("{\"direction\":\"englishToChinese\"}".utf8)) == PDFTranslationOptions())
        options.autoExtractGlossary = false
        #expect(fixture.app.submit(materialID: id, provider: fixture.profile.snapshot, options: options) == nil)
        #expect(fixture.app.selectedMaterial?.tasks.count == 1)
    }
    @Test func differentPDFsKeepFailureCancellationAndRetryBoundToTheirOwnCopies() async throws {
        let f = try PDFFixture(); defer { f.remove() }
        let first = try #require(f.app.importPDF(f.external))
        let second = try #require(f.app.importPDF(f.external))
        let third = try #require(f.app.importPDF(f.external))
        let firstTask = try #require(f.app.submit(materialID: first, provider: f.profile.snapshot, options: .init()))
        try await f.engine.wait(1)
        let secondTask = try #require(f.app.submit(materialID: second, provider: f.profile.snapshot, options: .init(direction: .chineseToEnglish)))
        let thirdTask = try #require(f.app.submit(materialID: third, provider: f.profile.snapshot, options: .init()))
        f.app.open(third)
        f.app.cancel(materialID: third, taskID: thirdTask)
        await f.engine.fail(0, .rateLimited)
        try await f.engine.wait(2)
        #expect(f.app.materials.first { $0.id == first }?.tasks.first?.failure == .rateLimited)
        #expect(f.app.materials.first { $0.id == third }?.tasks.first?.status == .cancelled)
        let requests = await f.engine.requests
        #expect(requests[0].id == firstTask && requests[1].id == secondTask)
        #expect(requests[1].options.direction == .chineseToEnglish)
        #expect(requests[0].inputURL != requests[1].inputURL)
        // Removing the old target credential does not substitute a new service.
        f.credentials.values.removeValue(forKey: f.profile.credentialReference)
        let retry = try #require(f.app.retry(materialID: first, taskID: firstTask))
        await f.engine.finish(1)
        try await settle { f.app.runningTaskID == nil }
        #expect(await f.engine.count == 2)
        #expect(f.app.materials.first { $0.id == first }?.tasks.first { $0.id == retry }?.failure == .credential)
        #expect(f.app.materials.first { $0.id == second }?.results.first?.taskID == secondTask)
        #expect(f.app.materials.first { $0.id == third }?.results.isEmpty == true)
        for id in [first, second, third] {
            #expect(try Data(contentsOf: #require(f.app.originalURL(id))) == Data(contentsOf: f.external))
        }
        let reopened = f.reopen()
        #expect(reopened.materials.count == 3)
        #expect(reopened.materials.first { $0.id == second }?.results.count == 1)
        #expect(reopened.materials.first { $0.id == first }?.results.isEmpty == true)
    }

    @Test func actualPDFAndAudioQueuesShareFIFOAndCancelledProcessRetainsItsSlot() async throws {
        let gate = BackgroundProcessingGate()
        let pdf = try PDFFixture(gate: gate); defer { pdf.remove() }
        let transcriber = QueueControlledTranscriber()
        let audio = try await PostRecordingFixture(service: transcriber); defer { audio.remove() }
        let processing = PostRecordingSession(recordings: audio.recordings, store: audio.store,
            credentials: audio.credentials, service: transcriber, gate: gate)
        processing.saveConfiguration(model: "whisper-1", apiKey: "controlled-key")
        let material = try #require(pdf.app.importPDF(pdf.external))
        let firstPDF = try #require(pdf.app.submit(materialID: material, provider: pdf.profile.snapshot, options: .init()))
        try await pdf.engine.wait(1)
        let audioTask = try #require(processing.enqueueTranscription(audio.id))
        let secondPDF = try #require(pdf.app.submit(materialID: material, provider: pdf.profile.snapshot, options: .init()))
        #expect(await transcriber.requestCount == 0)
        #expect(processing.backgroundTasks.first?.status == .queued)
        pdf.app.cancel(materialID: material, taskID: firstPDF)
        #expect(gate.activeID == firstPDF)
        #expect(await transcriber.requestCount == 0)
        await pdf.engine.finish(0)
        await transcriber.waitForRequests(1)
        #expect(gate.activeID == audioTask)
        #expect(await pdf.engine.count == 1)
        #expect(pdf.app.selectedMaterial?.results.isEmpty == true)
        await transcriber.finishAll("Retained audio result after cancelled PDF")
        try await pdf.engine.wait(2)
        #expect(gate.activeID == secondPDF)
        #expect(processing.materials[audio.id]?.results.first?.text == "Retained audio result after cancelled PDF")
        await pdf.engine.finish(1)
        try await settle { gate.activeID == nil }
        #expect(pdf.app.selectedMaterial?.results.count == 1)
        #expect(pdf.app.selectedMaterial?.results.first?.taskID == secondPDF)
        #expect(try Data(contentsOf: #require(pdf.app.originalURL(material))) == Data(contentsOf: pdf.external))
        #expect(FileManager.default.fileExists(atPath: audio.recordings.audioURL(for: audio.id).path))
    }
    @Test func independentCopyVersionsExportAndHistorySurviveOriginalMove() async throws {
        let fixture = try PDFFixture(); defer { fixture.remove() }
        let originalBytes = try Data(contentsOf: fixture.external)
        let id = try #require(fixture.app.importPDF(fixture.external))
        try FileManager.default.moveItem(at: fixture.external, to: fixture.root.appendingPathComponent("moved.pdf"))
        _ = fixture.app.submit(materialID: id, provider: fixture.profile.snapshot, options: .init())
        try await fixture.engine.wait(1); await fixture.engine.finish(0); try await settle { fixture.app.runningTaskID == nil }
        let first = try #require(fixture.app.selectedMaterial?.selectedResult)
        #expect(first.outputs.count == 1)
        #expect(first.provider == fixture.profile.snapshot)
        _ = fixture.app.submit(materialID: id, provider: fixture.profile.snapshot, options: .init(direction: .chineseToEnglish))
        try await fixture.engine.wait(2); await fixture.engine.finish(1); try await settle { fixture.app.runningTaskID == nil }
        #expect(fixture.app.selectedMaterial?.results.count == 2)
        #expect(fixture.app.selectResult(materialID: id, resultID: first.id))
        let reopened = fixture.reopen()
        #expect(reopened.selectedMaterial?.selectedResultID == first.id)
        #expect(try Data(contentsOf: #require(reopened.originalURL(id))) == originalBytes)
        let output = try #require(reopened.resultURL(materialID: id, resultID: first.id, output: first.outputs[0]))
        #expect(PDFDocument(url: output)?.pageCount == 1)
        let exported = fixture.root.appendingPathComponent("export.pdf")
        #expect(reopened.export(output, to: exported))
        #expect(try Data(contentsOf: exported) == Data(contentsOf: output))
    }
    @Test func sharedSlotQueuesAndCancelsWaitingPDFWithoutService() async throws {
        let gate = BackgroundProcessingGate(), otherTask = UUID()
        gate.enqueue(id: otherTask) {}
        let fixture = try PDFFixture(gate: gate); defer { fixture.remove() }
        let id = try #require(fixture.app.importPDF(fixture.external))
        let first = try #require(fixture.app.submit(materialID: id, provider: fixture.profile.snapshot, options: .init()))
        let second = try #require(fixture.app.submit(materialID: id, provider: fixture.profile.snapshot, options: .init()))
        #expect(fixture.app.runningTaskID == nil)
        #expect(await fixture.engine.count == 0)
        fixture.app.cancel(materialID: id, taskID: first)
        gate.finish(id: otherTask)
        try await fixture.engine.wait(1)
        #expect(fixture.app.runningTaskID == second)
        await fixture.engine.finish(0); try await settle { fixture.app.runningTaskID == nil }
        #expect(fixture.app.selectedMaterial?.tasks.map(\.status) == [.cancelled, .completed])
    }
    @Test func runningCancelHoldsSlotUntilActualWorkerReturnsAndRejectsLateResult() async throws {
        let fixture = try PDFFixture(); defer { fixture.remove() }
        let id = try #require(fixture.app.importPDF(fixture.external))
        let first = try #require(fixture.app.submit(materialID: id, provider: fixture.profile.snapshot, options: .init()))
        try await fixture.engine.wait(1)
        let second = try #require(fixture.app.submit(materialID: id, provider: fixture.profile.snapshot, options: .init()))
        fixture.app.cancel(materialID: id, taskID: first)
        #expect(fixture.app.runningTaskID == first)
        #expect(!fixture.app.requestDeletion(.material(id)))
        #expect(await fixture.engine.count == 1)
        await fixture.engine.finish(0); try await fixture.engine.wait(2)
        #expect(fixture.app.runningTaskID == second)
        #expect(fixture.app.selectedMaterial?.results.isEmpty == true)
        await fixture.engine.finish(1); try await settle { fixture.app.runningTaskID == nil }
        #expect(fixture.app.selectedMaterial?.results.count == 1)
        #expect(fixture.app.selectedMaterial?.results.first?.taskID == second)
    }
    @Test func restartRequiresExplicitResumeAndPreservesProviderAndLegacyOutputSnapshot() async throws {
        let gate = BackgroundProcessingGate(); gate.enqueue(id: UUID()) {}
        let fixture = try PDFFixture(gate: gate); defer { fixture.remove() }
        let id = try #require(fixture.app.importPDF(fixture.external))
        let legacyOptions = try JSONDecoder().decode(PDFTranslationOptions.self, from: Data("{\"direction\":\"englishToChinese\"}".utf8))
        let task = try #require(fixture.app.submit(materialID: id, provider: fixture.profile.snapshot, options: legacyOptions))
        let reopened = fixture.reopen()
        #expect(reopened.selectedMaterial?.tasks.first?.status == .awaitingResume)
        #expect(await fixture.engine.count == 0)
        _ = reopened.retry(materialID: id, taskID: task)
        try await fixture.engine.wait(1)
        #expect(await fixture.engine.requests[0].provider == fixture.profile.snapshot)
        #expect(await fixture.engine.requests[0].options.output.mode == .bilingual)
        await fixture.engine.finish(0); try await settle { reopened.runningTaskID == nil }
        #expect(reopened.selectedMaterial?.tasks.map(\.status) == [.cancelled, .completed])
    }
    @Test func failedMetadataSaveRetainsOutputAndRetriesOnlyLocalCommit() async throws {
        let fixture = try PDFFixture(); defer { fixture.remove() }
        let id = try #require(fixture.app.importPDF(fixture.external))
        _ = fixture.app.submit(materialID: id, provider: fixture.profile.snapshot, options: .init())
        try await fixture.engine.wait(1)
        let metadata = fixture.root.appendingPathComponent("library/PDFMaterials/\(id.uuidString)/material.json")
        let backup = fixture.root.appendingPathComponent("metadata-backup")
        try FileManager.default.moveItem(at: metadata, to: backup)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        await fixture.engine.finish(0); try await settle { fixture.app.runningTaskID == nil }
        #expect(fixture.app.pendingSaveIDs.contains(id))
        #expect(!fixture.app.prepareToQuit())
        let result = try #require(fixture.app.selectedMaterial?.selectedResult)
        #expect(PDFDocument(url: try #require(fixture.app.resultURL(materialID: id, resultID: result.id, output: result.outputs[0]))) != nil)
        try FileManager.default.removeItem(at: metadata); try FileManager.default.moveItem(at: backup, to: metadata)
        #expect(fixture.app.retrySaving())
        #expect(fixture.reopen().selectedMaterial?.results.count == 1)
        #expect(await fixture.engine.count == 1)
    }
    @Test func deletionRequiresConfirmationAndRespectsExternalSourceAndOtherResults() async throws {
        let fixture = try PDFFixture(); defer { fixture.remove() }
        let id = try #require(fixture.app.importPDF(fixture.external))
        for count in 1...2 {
            _ = fixture.app.submit(materialID: id, provider: fixture.profile.snapshot, options: .init())
            try await fixture.engine.wait(count); await fixture.engine.finish(count - 1); try await settle { fixture.app.runningTaskID == nil }
        }
        let first = try #require(fixture.app.selectedMaterial?.results.first)
        #expect(fixture.app.requestDeletion(.result(id, first.id)))
        fixture.app.cancelDeletion(); #expect(fixture.app.selectedMaterial?.results.count == 2)
        #expect(fixture.app.requestDeletion(.result(id, first.id))); #expect(fixture.app.confirmDeletion())
        #expect(fixture.reopen().selectedMaterial?.results.count == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.external.path))
        #expect(fixture.app.requestDeletion(.material(id))); #expect(fixture.app.confirmDeletion())
        #expect(fixture.reopen().materials.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.external.path))
    }
    @Test func engineFailureAndInvalidOutputKeepSourceWithoutFalseSuccess() async throws {
        let fixture = try PDFFixture(); defer { fixture.remove() }
        let id = try #require(fixture.app.importPDF(fixture.external))
        _ = fixture.app.submit(materialID: id, provider: fixture.profile.snapshot, options: .init())
        try await fixture.engine.wait(1); await fixture.engine.fail(0, .rateLimited); try await settle { fixture.app.runningTaskID == nil }
        #expect(fixture.app.selectedMaterial?.tasks.first?.failure == .rateLimited)
        _ = fixture.app.submit(materialID: id, provider: fixture.profile.snapshot, options: .init())
        try await fixture.engine.wait(2); await fixture.engine.finish(1, invalid: true); try await settle { fixture.app.runningTaskID == nil }
        #expect(fixture.app.selectedMaterial?.tasks.last?.failure == .invalidOutput)
        #expect(fixture.app.selectedMaterial?.results.isEmpty == true)
        #expect(PDFDocument(url: try #require(fixture.app.originalURL(id))) != nil)
    }
    @Test func invalidInputSymlinkAndManagedExportAreRejected() throws {
        let fixture = try PDFFixture(); defer { fixture.remove() }
        let bad = fixture.root.appendingPathComponent("bad.pdf"); try Data("invalid".utf8).write(to: bad)
        #expect(fixture.app.importPDF(bad) == nil)
        let id = try #require(fixture.app.importPDF(fixture.external))
        let original = try #require(fixture.app.originalURL(id))
        #expect(!fixture.app.export(original, to: original))
        try FileManager.default.removeItem(at: original)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: fixture.external)
        #expect(fixture.reopen().materials.isEmpty)
        #expect(fixture.reopen().unreadableIDs == [id])
        #expect(FileManager.default.fileExists(atPath: fixture.external.path))
    }
    @Test func saveFailurePausesAlreadyQueuedWorkUntilLocalRecovery() async throws {
        let fixture = try PDFFixture(); defer { fixture.remove() }
        let id = try #require(fixture.app.importPDF(fixture.external))
        _ = fixture.app.submit(materialID: id, provider: fixture.profile.snapshot, options: .init())
        try await fixture.engine.wait(1)
        let next = try #require(fixture.app.submit(materialID: id, provider: fixture.profile.snapshot, options: .init()))
        let metadata = fixture.root.appendingPathComponent("library/PDFMaterials/\(id.uuidString)/material.json")
        let backup = fixture.root.appendingPathComponent("backup")
        try FileManager.default.moveItem(at: metadata, to: backup)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        await fixture.engine.finish(0); try await settle { fixture.app.runningTaskID == nil }
        #expect(await fixture.engine.count == 1)
        #expect(fixture.app.selectedMaterial?.tasks.last?.id == next)
        #expect(fixture.app.selectedMaterial?.tasks.last?.status == .queued)
        try FileManager.default.removeItem(at: metadata); try FileManager.default.moveItem(at: backup, to: metadata)
        // A restart can recover the durable result receipt without another request.
        let restored = fixture.reopen()
        #expect(restored.pendingSaveIDs.contains(id))
        #expect(restored.prepareToQuit())
        #expect(await fixture.engine.count == 1)
        #expect(fixture.app.retrySaving())
        try await fixture.engine.wait(2); await fixture.engine.finish(1); try await settle { fixture.app.runningTaskID == nil }
        #expect(fixture.app.selectedMaterial?.results.count == 2)
    }
    @Test func rejectedQuitKeepsWorkerAndConfirmedQuitWaitsForActualCompletion() async throws {
        let fixture = try PDFFixture(); defer { fixture.remove() }
        let id = try #require(fixture.app.importPDF(fixture.external))
        _ = fixture.app.submit(materialID: id, provider: fixture.profile.snapshot, options: .init())
        try await fixture.engine.wait(1)
        let metadata = fixture.root.appendingPathComponent("library/PDFMaterials/\(id.uuidString)/material.json")
        let backup = fixture.root.appendingPathComponent("backup")
        try FileManager.default.moveItem(at: metadata, to: backup)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        #expect(!fixture.app.prepareForConfirmedQuit())
        #expect(fixture.app.selectedMaterial?.tasks.first?.status == .running)
        try FileManager.default.removeItem(at: metadata); try FileManager.default.moveItem(at: backup, to: metadata)
        #expect(fixture.app.prepareForConfirmedQuit())
        var waited = false
        let shutdown = Task { await fixture.app.awaitConfirmedShutdown(); waited = true }
        await Task.yield(); #expect(!waited)
        await fixture.engine.finish(0); await shutdown.value
        #expect(waited)
        #expect(fixture.app.selectedMaterial?.results.isEmpty == true)
        #expect(fixture.reopen().selectedMaterial?.tasks.first?.status == .interrupted)
    }
    @Test func completedAttemptCannotBeRetriedImplicitly() async throws {
        let fixture = try PDFFixture(); defer { fixture.remove() }
        let id = try #require(fixture.app.importPDF(fixture.external))
        let task = try #require(fixture.app.submit(materialID: id, provider: fixture.profile.snapshot, options: .init()))
        try await fixture.engine.wait(1); await fixture.engine.finish(0); try await settle { fixture.app.runningTaskID == nil }
        #expect(fixture.app.retry(materialID: id, taskID: task) == nil)
        #expect(await fixture.engine.count == 1)
    }
    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
}

@MainActor private final class PDFFixture {
    let root: URL, external: URL, store: PDFMaterialStore, profile: ProviderProfile, credentials: PDFCredentials, engine = ControlledPDFEngine()
    let app: PDFTranslationSession
    init(gate: BackgroundProcessingGate? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        external = root.appendingPathComponent("external.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = try #require(CGContext(external as CFURL, mediaBox: &box, nil)); context.beginPDFPage(nil); context.fill(CGRect(x: 20,y: 20,width: 30,height: 30)); context.endPDFPage(); context.closePDF()
        store = PDFMaterialStore(root: root.appendingPathComponent("library"), moveToTrash: { try FileManager.default.moveItem(at: $0, to: $0.deletingLastPathComponent().appendingPathComponent("trash-\(UUID())")) })
        profile = try ProviderProfile(name: "PDF fixture", baseURL: "https://pdf.test/v1", model: "pdf-model")
        credentials = PDFCredentials(); credentials.values[profile.credentialReference] = "test-key"
        app = PDFTranslationSession(store: store, credentials: credentials, engine: engine, gate: gate)
    }
    func reopen() -> PDFTranslationSession { PDFTranslationSession(store: store, credentials: credentials, engine: engine) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
@MainActor private final class PDFCredentials: ProviderCredentials {
    var values: [ProviderCredentialReference: String] = [:]
    var reads = 0
    func read(reference: ProviderCredentialReference) throws -> String? { reads += 1; return values[reference] }
    func save(_ value: String, reference: ProviderCredentialReference) throws { values[reference] = value }
    func delete(reference: ProviderCredentialReference) throws { values.removeValue(forKey: reference) }
}
private actor ControlledPDFEngine: PDFTranslating {
    var requests: [PDFEngineRequest] = []
    private var continuations: [CheckedContinuation<PDFEngineResult, Error>] = []
    var count: Int { requests.count }
    func translate(_ request: PDFEngineRequest, apiKey: String, progress: @escaping @Sendable (PDFEngineProgress) -> Void) async throws -> PDFEngineResult {
        requests.append(request); progress(.init(stage: "Controlled", percent: 10))
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func wait(_ count: Int) async throws {
        for _ in 0..<300 { if requests.count >= count { return }; try await Task.sleep(for: .milliseconds(10)) }
        try #require(requests.count >= count)
    }
    func finish(_ index: Int, invalid: Bool = false, glossary: String? = nil) {
        let request = requests[index], output = requests[index].outputDirectory.appendingPathComponent("generated.pdf")
        do {
            if invalid { try Data("not a pdf".utf8).write(to: output) }
            else { try FileManager.default.copyItem(at: request.inputURL, to: output) }
            var outputs = [PDFGeneratedOutput(kind: .dual, url: output)]
            if let glossary {
                let terms = request.outputDirectory.appendingPathComponent("terms.csv")
                try glossary.write(to: terms, atomically: true, encoding: .utf8)
                outputs.append(.init(kind: .glossaryCSV, url: terms))
            }
            continuations[index].resume(returning: .init(outputs: outputs))
        } catch { continuations[index].resume(throwing: error) }
    }
    func fail(_ index: Int, _ error: PDFTranslationError) { continuations[index].resume(throwing: error) }
}
