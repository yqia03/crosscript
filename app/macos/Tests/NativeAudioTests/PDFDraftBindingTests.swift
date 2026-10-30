import AppKit
import SwiftUI
import Testing
@testable import TranslationWorkbench
import WorkbenchCore

@Suite @MainActor struct PDFDraftBindingTests {
    @Test func deletedServicesClearOnlyUnsubmittedPDFSelectionsWithoutChoosingAnotherProvider() throws {
        let draft = PDFSubmissionDraft()
        let main = try ProviderProfile(name: "Main", baseURL: "https://main.test", model: "main")
        let terms = try ProviderProfile(name: "Terms", baseURL: "https://terms.test", model: "terms")
        let other = try ProviderProfile(name: "Other", baseURL: "https://other.test", model: "other")
        draft.profileID = main.id; draft.termProviderID = terms.id; draft.termReasoning = "high"
        let submitted = try draft.snapshot(profiles: [main, terms, other], resources: nil)
        draft.reconcileProviders([main, other])
        #expect(draft.profileID == main.id && draft.termProviderID == nil)
        #expect(!draft.autoExtractGlossary && draft.termReasoning.isEmpty && draft.removedProviderSelection)
        #expect(submitted.provider == main.snapshot && submitted.options.termExtractionProvider == terms.snapshot)
        draft.reconcileProviders([other])
        #expect(draft.profileID == nil)
        #expect(throws: PDFTranslationError.configuration) { try draft.snapshot(profiles: [other], resources: nil) }
        draft.reconcileProviders([])
        #expect(draft.profileID == nil && draft.termProviderID == nil)
    }

    @Test func longVersionPickerStaysInsideItsColumnAndKeepsFullMenuTitles() throws {
        _ = NSApplication.shared
        var selected = 1
        let titles = ["Original PDF", "Result 1 · A complete provider name that must remain available in the native menu"]
        let picker = CommittedPicker(title: "Version", selection: Binding(get: { selected }, set: { selected = $0 }), options: titles.enumerated().map { ($0.element, $0.offset) })
        let host = NSHostingView(rootView: picker.frame(width: 160, height: 28))
        host.frame = NSRect(x: 0, y: 0, width: 160, height: 28)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        func findPopup(_ view: NSView) -> NSPopUpButton? {
            if let popup = view as? NSPopUpButton { return popup }
            return view.subviews.lazy.compactMap(findPopup).first
        }
        let popup = try #require(findPopup(host))
        let columnBounds = popup.convert(popup.bounds, to: host)
        #expect(columnBounds.minX >= -1 && columnBounds.maxX <= 161)
        #expect(popup.itemTitles == titles && popup.titleOfSelectedItem == titles[1])
        popup.selectItem(at: 0)
        #expect(popup.sendAction(popup.action, to: popup.target))
        #expect(selected == 0 && popup.itemTitles == titles)
    }
    @Test func returningFromSettingsKeepsTheRetainedDraftInsteadOfReloadingDefaults() {
        let draft = PDFSubmissionDraft(), original = UUID(), edited = UUID()
        let firstResources = TranslationResourceSelection(glossaryIDs: [UUID()], promptID: UUID())
        draft.initializeDefaults(profileID: original, resourceSelection: firstResources)
        #expect(draft.profileID == original && draft.resourceSelection == firstResources)
        draft.profileID = edited; draft.direction = .chineseToEnglish; draft.outputSettings.pages = "2-3"
        draft.resourceSelection = .init()
        draft.initializeDefaults(profileID: original, resourceSelection: firstResources)
        #expect(draft.profileID == edited && draft.resourceSelection == .init())
        #expect(draft.direction == .chineseToEnglish && draft.outputSettings.pages == "2-3")
    }
    @Test func nativeMenuThenOldSiblingBindingsAndSubmitCommitWithoutRerender() throws {
        _ = NSApplication.shared
        let draft = PDFSubmissionDraft()
        draft.contentSettings.operation = .typesetOnly
        let content = draft.access(\.contentSettings), output = draft.access(\.outputSettings)
        let layout = draft.access(\.layoutSettings), performance = draft.access(\.performanceSettings)
        // Hold these before any mutation, just as an existing AX/control/action
        // tree remains reachable while a menu selection is being committed.
        let oldGraphics = content.binding(\.processGraphicElements), oldPages = output.binding(\.pages)
        let oldRichText = layout.binding(\.richText), oldQPS = performance.binding(\.requestsPerSecond)
        let oldSubmit = { try draft.snapshot(profiles: [], resources: nil) }
        try choose(content.binding(\.scanMode), options: [.detect, .automaticWorkaround], index: 1)
        oldGraphics.wrappedValue = false
        try choose(output.binding(\.mode), options: [.bilingual, .both], index: 1)
        oldPages.wrappedValue = "1"
        try choose(layout.binding(\.fontFamily), options: [.automatic, .serif], index: 1)
        oldRichText.wrappedValue = false
        try choose(performance.binding(\.thinking), options: [.automatic, .disabled], index: 1)
        oldQPS.wrappedValue = 2
        let snapshot = try oldSubmit()
        #expect(snapshot.provider == nil)
        #expect(snapshot.options.content.scanMode == .automaticWorkaround && !snapshot.options.content.processGraphicElements)
        #expect(snapshot.options.output.mode == .both && snapshot.options.output.pages == "1")
        #expect(snapshot.options.layout.fontFamily == .serif && !snapshot.options.layout.richText)
        #expect(snapshot.options.performance.thinking == .disabled && snapshot.options.performance.requestsPerSecond == 2)
        // The local-mode watermark dependency is committed at submit, without
        // waiting for SwiftUI's onChange or a fresh rendered button.
        try choose(content.binding(\.operation), options: [.typesetOnly, .parseOnly], index: 1)
        #expect(try oldSubmit().options.output.watermark == .noWatermark)
        #expect(draft.outputSettings.watermark == .watermarked)
    }
    @Test func disabledExtractionHasNoFormErrorAndStillSubmitsTheCurrentDraft() throws {
        let draft = PDFSubmissionDraft()
        let provider = try ProviderProfile(name: "Controlled", baseURL: "https://controlled.test", model: "model")
        draft.profileID = provider.id; draft.performanceSettings.termWorkers = 0; draft.autoExtractGlossary = false
        var view = PDFPerformanceSettingsView(access: draft.access(\.performanceSettings), requiresService: true, extractsTerms: false)
        #expect(view.validationError == nil)
        let snapshot = try draft.snapshot(profiles: [provider], resources: nil)
        #expect(snapshot.options.performance.termWorkers == 0 && snapshot.options.effectivePerformanceSettings["term_pool_max_workers"] == nil)
        draft.autoExtractGlossary = true; view.extractsTerms = true
        #expect(view.validationError == .invalidLimit)
        #expect(throws: PDFPerformanceSettingsError.invalidLimit) { try draft.snapshot(profiles: [provider], resources: nil) }
        #expect(draft.performanceSettings.termWorkers == 0)
    }
    private func choose<Value: Equatable>(_ binding: Binding<Value>, options: [Value], index: Int) throws {
        let picker = CommittedPicker(title: "Controlled choice", selection: binding, options: options.enumerated().map { ("Choice \($0.offset)", $0.element) })
        let coordinator = picker.makeCoordinator()
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: options.indices.map { "Choice \($0)" })
        popup.target = coordinator; popup.action = #selector(CommittedPicker<Value>.Coordinator.changed(_:))
        popup.selectItem(at: index)
        #expect(popup.sendAction(popup.action, to: popup.target))
        #expect(binding.wrappedValue == options[index])
    }
}
