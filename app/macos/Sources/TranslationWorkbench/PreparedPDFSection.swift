import SwiftUI
import WorkbenchCore

@MainActor struct PreparedPDFSection: View {
    @ObservedObject var session: PDFTranslationSession
    @ObservedObject var runtime: PDFRuntimePreparationSession
    @ObservedObject var providers: ProviderConfigurationSession
    let resources: TranslationResourceLibrary?
    let openSettings: () -> Void
    var draft: PDFSubmissionDraft? = nil

    var body: some View {
        PDFTranslationView(session: session, providers: providers, openSettings: openSettings,
                           resources: resources, runtimeReady: runtime.isReady, runtime: runtime, draft: draft)
        .task { runtime.prepare() }
    }
}
