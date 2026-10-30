import Combine
import Foundation
import WorkbenchCore

/// Actions resolve the current selection when invoked, even before SwiftUI has
/// rendered a newly selected output or history version.
@MainActor final class PDFOutputSelection: ObservableObject {
    @Published var kind: PDFOutputKind = .dual
    struct Output { let materialName: String; let url: URL; let suggestedFilename: String }
    func pdf(in session: PDFTranslationSession) -> Output? {
        guard let material = session.selectedMaterial else { return nil }
        let url: URL?
        var suggestedFilename = ExportFilename.suggested(material.name, extension: "pdf")
        if let result = material.selectedResult {
            guard let output = result.outputs.first(where: { $0.kind == kind && $0.kind.isPDF }) ?? result.outputs.first(where: { $0.kind.isPDF }) else { return nil }
            url = session.resultURL(materialID: material.id, resultID: result.id, output: output)
            if result.options.requiresService {
                suggestedFilename = ExportFilename.pdf(material.name, direction: result.options.direction, kind: output.kind)
            }
        } else { url = session.originalURL(material.id) }
        return url.map { Output(materialName: material.name, url: $0, suggestedFilename: suggestedFilename) }
    }
    func glossary(in session: PDFTranslationSession) -> Output? {
        guard let material = session.selectedMaterial, let result = material.selectedResult,
              let output = result.outputs.first(where: { $0.kind == .glossaryCSV }),
              let url = session.resultURL(materialID: material.id, resultID: result.id, output: output) else { return nil }
        return Output(materialName: material.name, url: url, suggestedFilename: ExportFilename.suggested(material.name + "-terms", extension: "csv"))
    }
}
