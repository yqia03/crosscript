import AppKit
import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import TranslationWorkbench
import WorkbenchCore

@Suite(.serialized) @MainActor struct PDFWorkspaceTests {
    @Test func completedRetriesReplaceOldFailuresWithoutHidingOtherFiles() {
        let cancelled = task(.cancelled), retried = task(.completed)
        var first = PDFMaterial(name: "Retried PDF"); first.tasks = [cancelled, retried]
        let failed = task(.failed), completed = task(.completed)
        var second = PDFMaterial(name: "Another PDF"); second.tasks = [failed, completed]
        let untouched = PDFMaterial(name: "Not submitted")

        let rows = PDFWorkspaceImportView.taskEntries(for: [first, second, untouched], runningTaskID: nil)
        #expect(rows.map(\.material.id) == [first.id, second.id])
        #expect(rows.map(\.task.id) == [retried.id, completed.id])
        #expect(rows.map(\.material.tasks) == [[cancelled, retried], [failed, completed]])

        let latestFailure = task(.failed); first.tasks.append(latestFailure)
        let updated = PDFWorkspaceImportView.taskEntries(for: [first, second], runningTaskID: nil)
        #expect(updated.map(\.task.id) == [latestFailure.id, completed.id])
    }

    @Test func workspaceTaskRowsPrioritizeBusyAttemptsAndCancellationCleanup() {
        for status in [PDFBackgroundTask.Status.queued, .running, .awaitingResume, .interrupted, .awaitingLocalSave] {
            let busy = task(status), terminal = task(.completed)
            var material = PDFMaterial(name: "Busy PDF"); material.tasks = [busy, terminal]
            let rows = PDFWorkspaceImportView.taskEntries(for: [material], runningTaskID: nil)
            #expect(rows.map(\.task.id) == [busy.id])
        }
        let cancelling = task(.cancelled), queued = task(.queued)
        var material = PDFMaterial(name: "Cancelling PDF"); material.tasks = [cancelling, queued]
        let draining = PDFWorkspaceImportView.taskEntries(for: [material], runningTaskID: cancelling.id)
        #expect(draining.map(\.task.id) == [cancelling.id])
        let released = PDFWorkspaceImportView.taskEntries(for: [material], runningTaskID: nil)
        #expect(released.map(\.task.id) == [queued.id])
    }

    @Test func successiveNativeDropsKeepTheirOrderAndReportNonPDFInput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-drops-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.pdf"), second = root.appendingPathComponent("second.pdf")
        let invalid = root.appendingPathComponent("notes.txt")
        for url in [first, second] {
            var bounds = CGRect(x: 0, y: 0, width: 300, height: 400)
            let context = try #require(CGContext(url as CFURL, mediaBox: &bounds, nil))
            context.beginPDFPage(nil); context.fill(bounds); context.endPDFPage(); context.closePDF()
        }
        try Data("notes".utf8).write(to: invalid)
        let session = PDFTranslationSession(store: PDFMaterialStore(root: root.appendingPathComponent("library")), credentials: DropForbiddenCredentials(), engine: DropForbiddenEngine())
        let importer = PDFDropImporter()
        importer.append([provider(first, delay: 0.1)], to: session)
        importer.append([provider(second, delay: 0), provider(invalid, delay: 0)], to: session)
        let deadline = Date().addingTimeInterval(5)
        while (session.materials.count != 2 || session.workspaceIssues.isEmpty), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.workspaceMaterials.map(\.name) == ["first", "second"])
        #expect(session.selectedMaterial?.name == "second")
        #expect(session.workspaceIssues.first?.name == "notes.txt")
        #expect(session.workspaceIssues.first?.error == .invalidPDF)
        #expect(session.materials.allSatisfy { $0.tasks.isEmpty && $0.results.isEmpty })
        for file in [first, second, invalid] { #expect(FileManager.default.fileExists(atPath: file.path)) }
    }

    @Test func nativeDropRejectsRemoteURLsWithoutImportingOrReadingCredentials() async {
        let remote = provider(URL(string: "https://example.invalid/source.pdf")!, delay: 0)
        #expect(await PDFDropImporter.fileURL(remote) == nil)
    }

    private func provider(_ url: URL, delay: TimeInterval) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { completion(url.dataRepresentation, nil) }
            return nil
        }
        return provider
    }
    private func task(_ status: PDFBackgroundTask.Status) -> PDFBackgroundTask {
        var options = PDFTranslationOptions()
        options.content.operation = .parseOnly; options.output.watermark = .noWatermark
        var value = PDFBackgroundTask(provider: nil, options: options)
        value.status = status
        return value
    }
}

@MainActor private final class DropForbiddenCredentials: ProviderCredentials {
    func read(reference: ProviderCredentialReference) throws -> String? { Issue.record("Import must not read credentials"); return nil }
    func save(_ value: String, reference: ProviderCredentialReference) throws { Issue.record("Import must not save credentials") }
    func delete(reference: ProviderCredentialReference) throws { Issue.record("Import must not delete credentials") }
}
private struct DropForbiddenEngine: PDFTranslating {
    func translate(_ request: PDFEngineRequest, apiKey: String, progress: @escaping @Sendable (PDFEngineProgress) -> Void) async throws -> PDFEngineResult {
        Issue.record("Import must not invoke PDF processing"); throw PDFTranslationError.processing
    }
}
