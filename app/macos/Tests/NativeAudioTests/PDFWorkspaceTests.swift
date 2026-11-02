import AppKit
import SwiftUI
import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import TranslationWorkbench
import WorkbenchCore

@Suite(.serialized) @MainActor struct PDFWorkspaceTests {
    @Test func productionNewProjectButtonKeepsExplicitDraftAndFitsNarrowAndWideHeaders() async throws {
        _ = NSApplication.shared
        // SwiftUI builds virtual AX children on demand. Activate accessibility
        // only inside this test process; no system preference is changed.
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-new-button-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("retained.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try #require(CGContext(original as CFURL, mediaBox: &bounds, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let credentials = DropForbiddenCredentials()
        let providers = ProviderConfigurationSession(store: ProviderConfigurationStore(root: root), credentials: credentials, checker: DropForbiddenChecker())
        let profile = try #require(providers.saveProfile(name: "Retained service", baseURL: "https://example.invalid", model: "retained", apiKey: ""))
        providers.setDefault(profile.id, for: .pdf)
        let session = PDFTranslationSession(store: PDFMaterialStore(root: root.appendingPathComponent("library")), credentials: credentials, engine: DropForbiddenEngine())
        let runtimeControl = NewProjectRuntime()
        let runtime = PDFRuntimePreparationSession(preparer: runtimeControl)
        let materialID = try #require(session.importPDF(original))
        let draft = PDFSubmissionDraft()
        draft.initializeDefaults(profileID: profile.id, resourceSelection: .init())
        draft.outputSettings.mode = .translated; draft.outputSettings.layout = .alternatingPages
        draft.outputSettings.watermark = .noWatermark
        draft.direction = .chineseToEnglish
        let expected = try draft.snapshot(profiles: providers.profiles, resources: nil)
        let preferences = UserDefaults(suiteName: "PDFNewButton." + UUID().uuidString)!
        for language in ["english", "zhHans"] {
            preferences.set(language, forKey: "interfaceLanguage")
            for width: CGFloat in [430, 1_040] {
                session.open(materialID)
                let host = NSHostingView(rootView: ScrollView {
                    PreparedPDFSection(session: session, runtime: runtime, providers: providers, resources: nil, openSettings: {}, draft: draft)
                }.defaultAppStorage(preferences).background(Color.white)
                    .foregroundStyle(Color(red: 0.15, green: 0.22, blue: 0.28)).preferredColorScheme(.light))
                host.frame = CGRect(x: 0, y: 0, width: width, height: 640)
                let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
                window.contentView = host
                defer { window.contentView = nil }
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
                host.layoutSubtreeIfNeeded()
                _ = try #require(NativeViewTestSupport.element(host, identifier: "pdf-workspace-add"))
                let button = try #require(NativeViewTestSupport.element(host, identifier: "pdf-new-project"))
                let frame = try #require((button as AnyObject).accessibilityFrame?())
                let workspaceFrame = window.convertToScreen(host.convert(host.bounds, to: nil))
                #expect(frame.width > 50 && frame.height >= 30)
                #expect(workspaceFrame.insetBy(dx: -1, dy: -1).contains(frame))
                if let output = ProcessInfo.processInfo.environment["WORKBENCH_PDF_NEW_OUTPUT"] {
                    let folder = URL(fileURLWithPath: output)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(language)-\(Int(width)).png"))
                }
                #expect((button as AnyObject).accessibilityPerformPress?() == true)
                #expect(session.workspaceMaterials.isEmpty && session.selectedID == nil)
                #expect(session.materials.count == 1 && session.materials.first?.tasks.isEmpty == true)
                let actual = try draft.snapshot(profiles: providers.profiles, resources: nil)
                #expect(actual.options == expected.options && actual.provider == expected.provider)
                #expect(runtime.isReady && runtime.receipt?.identifier == "synthetic")
                #expect(await runtimeControl.calls == 1)
                #expect(session.originalURL(materialID) != nil)
                session.open(materialID)
                // A retained action must respect a deletion confirmation even
                // before SwiftUI has rendered the disabled control or sheet.
                #expect(session.requestDeletion(.material(materialID)))
                _ = (button as AnyObject).accessibilityPerformPress?()
                #expect(session.selectedID == materialID)
                session.cancelDeletion()
                try await Task.sleep(for: .milliseconds(30))

            }
        }
    }

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

    @Test func newProjectKeepsLateDropInHistoryWithoutRefillingTheNewWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-stale-drop-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("old-drop.pdf"), next = root.appendingPathComponent("new-drop.pdf")
        let invalid = root.appendingPathComponent("old-invalid.txt")
        for url in [first, next] {
            var bounds = CGRect(x: 0, y: 0, width: 300, height: 400)
            let context = try #require(CGContext(url as CFURL, mediaBox: &bounds, nil))
            context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        }
        try Data("ordinary text".utf8).write(to: invalid)
        let session = PDFTranslationSession(store: PDFMaterialStore(root: root.appendingPathComponent("library")), credentials: DropForbiddenCredentials(), engine: DropForbiddenEngine())
        let importer = PDFDropImporter()
        importer.append([provider(first, delay: 0.1), provider(invalid, delay: 0)], to: session)
        session.newProject()
        let deadline = Date().addingTimeInterval(5)
        while session.materials.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.materials.count == 1)
        #expect(session.workspaceMaterials.isEmpty && session.selectedID == nil)
        #expect(session.workspaceIssues.isEmpty && session.error == nil)
        let old = try #require(session.materials.first)
        #expect(old.name == "old-drop" && old.results.isEmpty && old.tasks.isEmpty)
        importer.append([provider(next, delay: 0)], to: session)
        while session.materials.count < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.workspaceMaterials.map(\.name) == ["new-drop"])
        #expect(session.selectedMaterial?.name == "new-drop")
        session.open(old.id); session.open(old.id)
        #expect(session.workspaceMaterials.map(\.name) == ["new-drop", "old-drop"])
        #expect(session.selectedID == old.id)
        #expect(FileManager.default.fileExists(atPath: first.path))
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

private struct DropForbiddenChecker: ProviderConnectionChecking {
    func check(snapshot: ProviderSnapshot, apiKey: String) async throws -> ProviderConnectionReport {
        Issue.record("New project must not check a provider"); throw ProviderConfigurationError.processing
    }
}

private actor NewProjectRuntime: PDFRuntimePreparing {
    var calls = 0
    func prepare(progress: @escaping @Sendable (PDFRuntimeProgress) -> Void) async throws -> PDFRuntimeReceipt {
        calls += 1
        return .init(identifier: "synthetic", reused: false)
    }
}
