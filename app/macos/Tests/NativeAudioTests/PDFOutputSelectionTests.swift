import AppKit
import SwiftUI
import CoreGraphics
import Foundation
import Testing
@testable import TranslationWorkbench
@testable import WorkbenchCore

@Suite @MainActor struct PDFOutputSelectionTests {
    @Test func exportSnapshotSurvivesBackgroundCompletionAndFailedSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("export-snapshot-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.pdf")
        try snapshotPDF(original, width: 300)
        let originalBytes = try Data(contentsOf: original)
        let store = PDFMaterialStore(root: root.appendingPathComponent("library"))
        let material = try store.importPDF(original)
        let engine = SelectionDelayedEngine()
        let session = PDFTranslationSession(store: store, credentials: SelectionCredentials(), engine: engine)
        var options = PDFTranslationOptions()
        options.content.operation = .typesetOnly
        options.autoExtractGlossary = false
        let selection = PDFOutputSelection()
        selection.kind = .mono
        for version in 1...2 {
            #expect(session.submit(materialID: material.id, provider: nil, options: options) != nil)
            let deadline = Date().addingTimeInterval(5)
            while !(await engine.started), Date() < deadline { await Task.yield() }
            #expect(await engine.started)
            if version == 1 {
                await engine.release()
                while session.runningTaskID != nil, Date() < deadline { await Task.yield() }
                #expect(session.selectedMaterial?.results.count == 1)
                continue
            }
            // Save enters before the second job completes. runModal permits
            // that completion and selects its result while the panel is open.
            let selectedPDF = try #require(selection.pdf(in: session))
            let selectedCSV = try #require(selection.glossary(in: session))
            let pdfBytes = try Data(contentsOf: selectedPDF.url)
            let csvBytes = try Data(contentsOf: selectedCSV.url)
            await engine.release()
            while session.runningTaskID != nil, Date() < deadline { await Task.yield() }
            #expect(session.runningTaskID == nil)
            #expect(session.selectedMaterial?.results.count == 2)
            let newerPDF = try #require(selection.pdf(in: session))
            let newerCSV = try #require(selection.glossary(in: session))
            #expect(newerPDF.url != selectedPDF.url && newerCSV.url != selectedCSV.url)
            #expect(try Data(contentsOf: newerPDF.url) != pdfBytes)
            #expect(try Data(contentsOf: newerCSV.url) != csvBytes)
            let exportedPDF = root.appendingPathComponent("chosen.pdf")
            let exportedCSV = root.appendingPathComponent("chosen.csv")
            #expect(session.export(selectedPDF.url, to: exportedPDF))
            #expect(session.export(selectedCSV.url, to: exportedCSV))
            #expect(try Data(contentsOf: exportedPDF) == pdfBytes)
            #expect(try Data(contentsOf: exportedCSV) == csvBytes)
            // A file cannot serve as the destination's parent directory.
            let invalidDestination = exportedPDF.appendingPathComponent("cannot-save.pdf")
            #expect(!session.export(selectedPDF.url, to: invalidDestination))
            #expect(try Data(contentsOf: selectedPDF.url) == pdfBytes)
            #expect(try Data(contentsOf: selectedCSV.url) == csvBytes)
            #expect(try Data(contentsOf: original) == originalBytes)
            #expect(try Data(contentsOf: #require(session.originalURL(material.id))) == originalBytes)
            #expect(try store.load().materials.first?.results.count == 2)
        }
    }
    @Test func retainedActionsUseImmediateOutputAndHistorySelectionWithoutRerender() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("selection-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func pdf(_ url: URL, width: Double) throws {
            var bounds = CGRect(x: 0, y: 0, width: width, height: 500)
            let context = try #require(CGContext(url as CFURL, mediaBox: &bounds, nil))
            context.beginPDFPage(nil); context.fill(CGRect(x: 20, y: 20, width: width / 2, height: 40)); context.endPDFPage(); context.closePDF()
        }
        let original = root.appendingPathComponent("original.pdf"); try pdf(original, width: 400)
        let store = PDFMaterialStore(root: root.appendingPathComponent("library"))
        var material = try store.importPDF(original)
        let provider = try ProviderProfile(name: "Controlled", baseURL: "https://controlled.test", model: "model").snapshot
        for index in 1...2 {
            let task = PDFBackgroundTask(provider: provider, options: .init())
            let staging = try store.stagingDirectory(task.id, materialID: material.id)
            let mono = staging.appendingPathComponent("mono.pdf"), dual = staging.appendingPathComponent("dual.pdf"), csv = staging.appendingPathComponent("terms.csv")
            try pdf(mono, width: Double(index * 300)); try pdf(dual, width: Double(index * 600))
            try "source,target\nversion,\(index)\n".write(to: csv, atomically: true, encoding: .utf8)
            let result = try store.install(.init(outputs: [.init(kind: .mono, url: mono), .init(kind: .dual, url: dual), .init(kind: .glossaryCSV, url: csv)]), task: task, material: material, resultID: UUID())
            material.results.append(result); material.selectedResultID = result.id
        }
        try store.save(material)
        let session = PDFTranslationSession(store: store, credentials: SelectionCredentials(), engine: SelectionEngine())
        let selection = PDFOutputSelection()
        // These actions are retained while the selection changes, matching the
        // old rendered buttons that remained briefly reachable through AX.
        let currentPDF = { selection.pdf(in: session) }
        let currentCSV = { selection.glossary(in: session) }
        let dual = try #require(currentPDF())
        #expect(dual.suggestedFilename == "original-en_cn.pdf")
        _ = NSApplication.shared
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        let picker = CommittedPicker(title: "Output", selection: Binding(get: { selection.kind }, set: { selection.kind = $0 }), options: [("Bilingual", .dual), ("Translated", .mono)])
        let coordinator = picker.makeCoordinator()
        popup.addItems(withTitles: ["Bilingual", "Translated"]); popup.target = coordinator
        popup.action = #selector(CommittedPicker<PDFOutputKind>.Coordinator.changed(_:))
        popup.selectItem(at: 1)
        #expect(popup.sendAction(popup.action, to: popup.target))
        let mono = try #require(currentPDF())
        #expect(mono.suggestedFilename == "original-cn.pdf")
        #expect(mono.url != dual.url)
        let export = root.appendingPathComponent("selected.pdf")
        #expect(session.export(mono.url, to: export))
        #expect(try Data(contentsOf: export) == Data(contentsOf: mono.url))
        #expect(try Data(contentsOf: export) != Data(contentsOf: dual.url))
        let secondCSV = try #require(currentCSV())
        #expect(session.selectResult(materialID: material.id, resultID: material.results[0].id))
        let firstPDF = try #require(currentPDF()), firstCSV = try #require(currentCSV())
        #expect(firstPDF.url != mono.url && firstCSV.url != secondCSV.url)
        #expect(try String(contentsOf: firstCSV.url, encoding: .utf8).contains("version,1"))
        #expect(session.selectResult(materialID: material.id, resultID: nil))
        #expect(currentCSV() == nil)
        #expect(currentPDF()?.suggestedFilename == "original.pdf")
        #expect(try Data(contentsOf: #require(currentPDF()).url) == Data(contentsOf: original))
    }
}
@MainActor private final class SelectionCredentials: ProviderCredentials {
    func read(reference: ProviderCredentialReference) throws -> String? { Issue.record("Selection read a credential"); return nil }
    func save(_ value: String, reference: ProviderCredentialReference) throws {}
    func delete(reference: ProviderCredentialReference) throws {}
}
private struct SelectionEngine: PDFTranslating {
    func translate(_ request: PDFEngineRequest, apiKey: String, progress: @escaping @Sendable (PDFEngineProgress) -> Void) async throws -> PDFEngineResult { throw PDFTranslationError.processing }
}

private func snapshotPDF(_ url: URL, width: Double) throws {
    var bounds = CGRect(x: 0, y: 0, width: width, height: 500)
    let context = try #require(CGContext(url as CFURL, mediaBox: &bounds, nil))
    context.beginPDFPage(nil)
    context.fill(CGRect(x: 20, y: 20, width: width / 2, height: 40))
    context.endPDFPage(); context.closePDF()
}
private actor SelectionDelayedEngine: PDFTranslating {
    private var continuation: CheckedContinuation<Void, Never>?
    private var version = 0
    var started: Bool { continuation != nil }
    func release() { continuation?.resume(); continuation = nil }
    func translate(_ request: PDFEngineRequest, apiKey: String, progress: @escaping @Sendable (PDFEngineProgress) -> Void) async throws -> PDFEngineResult {
        await withCheckedContinuation { continuation = $0 }
        version += 1
        let pdf = request.outputDirectory.appendingPathComponent("mono.pdf")
        let csv = request.outputDirectory.appendingPathComponent("terms.csv")
        try snapshotPDF(pdf, width: Double(version * 300))
        try "source,target\nversion,\(version)\n".write(to: csv, atomically: true, encoding: .utf8)
        return .init(outputs: [.init(kind: .mono, url: pdf), .init(kind: .glossaryCSV, url: csv)])
    }
}
