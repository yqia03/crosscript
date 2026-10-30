import SwiftUI
import WorkbenchCore

/// A retained form object gives commands and older control bindings the same
/// current draft. Each projected write rereads the whole group before mutation.
@MainActor struct PDFSettingsAccess<Value> {
    let read: () -> Value
    let write: (Value) -> Void
    init(read: @escaping () -> Value, write: @escaping (Value) -> Void) { self.read = read; self.write = write }
    init(_ binding: Binding<Value>) { read = { binding.wrappedValue }; write = { binding.wrappedValue = $0 } }
    func binding<Field>(_ keyPath: WritableKeyPath<Value, Field>) -> Binding<Field> {
        Binding(get: { read()[keyPath: keyPath] }, set: { field in
            var current = read(); current[keyPath: keyPath] = field; write(current)
        })
    }
}

@MainActor final class PDFSubmissionDraft: ObservableObject {
    private var defaultsInitialized = false
    @Published var profileID: UUID?
    @Published var direction: TextTranslationDirection = .englishToChinese
    @Published var outputSettings = PDFOutputSettings()
    @Published var contentSettings = PDFContentSettings()
    @Published var layoutSettings = PDFLayoutSettings()
    @Published var performanceSettings = PDFPerformanceSettings()
    @Published var resourceSelection = TranslationResourceSelection()
    @Published var autoExtractGlossary = true
    @Published var saveExtractedGlossary = false
    @Published var termProviderID: UUID?
    @Published var termReasoning = ""
    @Published private(set) var removedProviderSelection = false
    func initializeDefaults(profileID: UUID?, resourceSelection: TranslationResourceSelection) {
        guard !defaultsInitialized else { return }
        defaultsInitialized = true
        self.profileID = profileID; self.resourceSelection = resourceSelection
    }
    /// Only the unsent form follows configuration deletion. Existing queued
    /// tasks own their provider snapshots and are never rewritten here.
    func reconcileProviders(_ profiles: [ProviderProfile]) {
        let available = Set(profiles.map(\.id))
        if let profileID, !available.contains(profileID) {
            self.profileID = nil; removedProviderSelection = true
        }
        if let termProviderID, !available.contains(termProviderID) {
            self.termProviderID = nil; termReasoning = ""
            // nil means use the main service. Disable extraction as well so
            // deletion cannot silently switch its requests to another service.
            autoExtractGlossary = false; removedProviderSelection = true
        }
    }
    func dismissProviderRemovalNotice() { removedProviderSelection = false }
    func access<Value>(_ keyPath: ReferenceWritableKeyPath<PDFSubmissionDraft, Value>) -> PDFSettingsAccess<Value> {
        PDFSettingsAccess(read: { self[keyPath: keyPath] }, write: { self[keyPath: keyPath] = $0 })
    }
    func snapshot(profiles: [ProviderProfile], resources: TranslationResourceLibrary?) throws -> (provider: ProviderSnapshot?, options: PDFTranslationOptions) {
        var options = PDFTranslationOptions(direction: direction)
        options.output = outputSettings; options.content = contentSettings; options.layout = layoutSettings; options.performance = performanceSettings
        // This dependency is applied synchronously at the command boundary, so a
        // just-selected parse operation does not depend on an onChange render.
        if options.content.operation == .parseOnly { options.output.watermark = .noWatermark }
        var provider: ProviderSnapshot?
        if options.requiresService {
            guard let profile = profiles.first(where: { $0.id == profileID }) else { throw PDFTranslationError.configuration }
            provider = profile.snapshot
            options.resources = try resources?.snapshot(resourceSelection) ?? .init()
            options.autoExtractGlossary = autoExtractGlossary
            options.saveAutoExtractedGlossary = autoExtractGlossary && saveExtractedGlossary
            if autoExtractGlossary, let termProviderID {
                guard let term = profiles.first(where: { $0.id == termProviderID }) else { throw PDFTranslationError.configuration }
                options.termExtractionProvider = term.snapshot
                if !termReasoning.isEmpty { options.termExtractionReasoning = termReasoning }
            }
        } else { options.autoExtractGlossary = false }
        return (provider, try options.validated())
    }
}
