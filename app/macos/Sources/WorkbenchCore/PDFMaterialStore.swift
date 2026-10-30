import Foundation
import PDFKit

public struct PDFMaterialLoadResult {
    public let materials: [PDFMaterial]
    public let unreadableIDs: [UUID]
}

public struct PDFSourceMetadata: Equatable, Sendable {
    public let pageCount: Int
    public let byteCount: Int64
}

/// Every path is derived from UUIDs and validated against symlink escape. External
/// originals are never deleted; generated outputs are copied before metadata commit.
public final class PDFMaterialStore {
    private let dataRoot: URL
    private let root: URL
    private let files = FileManager.default
    private let moveToTrash: (URL) throws -> Void
    public convenience init(root: URL) {
        self.init(root: root, moveToTrash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
    }
    init(root: URL, moveToTrash: @escaping (URL) throws -> Void) {
        dataRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        self.root = dataRoot.appendingPathComponent("PDFMaterials", isDirectory: true)
        self.moveToTrash = moveToTrash
    }
    public func load() throws -> PDFMaterialLoadResult {
        try validate(root)
        guard files.fileExists(atPath: root.path) else { return .init(materials: [], unreadableIDs: []) }
        var materials: [PDFMaterial] = [], unreadable: [UUID] = []
        for url in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: url.lastPathComponent) else { continue }
            do { materials.append(try load(id)) } catch { unreadable.append(id) }
        }
        return .init(materials: materials.sorted { $0.updatedAt > $1.updatedAt }, unreadableIDs: unreadable)
    }
    public func importPDF(_ source: URL) throws -> PDFMaterial {
        guard source.isFileURL, let document = PDFDocument(url: source), !document.isLocked, document.pageCount > 0 else { throw PDFTranslationError.invalidPDF }
        let material = PDFMaterial(name: source.deletingPathExtension().lastPathComponent)
        let target = directory(material.id)
        try validate(target)
        try files.createDirectory(at: target, withIntermediateDirectories: true)
        do {
            try files.copyItem(at: source, to: originalURL(material.id))
            try save(material)
            return material
        } catch {
            // Only this never-published UUID directory is removed on failed import.
            try? files.removeItem(at: target)
            throw PDFTranslationError.storage
        }
    }
    public func originalURL(_ id: UUID) throws -> URL {
        let url = directory(id).appendingPathComponent("original.pdf")
        try validate(url); return url
    }
    public func pageCount(_ id: UUID) throws -> Int {
        guard let document = PDFDocument(url: try originalURL(id)), !document.isLocked, document.pageCount > 0 else { throw PDFTranslationError.invalidPDF }
        return document.pageCount
    }
    public func sourceMetadata(_ id: UUID) throws -> PDFSourceMetadata {
        let url = try originalURL(id)
        return try PDFSourceMetadata(pageCount: pageCount(id), byteCount: Int64(url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
    }
    public func resultURL(materialID: UUID, resultID: UUID, output: PDFOutput) throws -> URL {
        guard output.filename == output.kind.rawValue + "." + output.kind.fileExtension else { throw PDFTranslationError.storage }
        let url = resultDirectory(materialID, resultID).appendingPathComponent(output.filename)
        try validate(url); return url
    }
    public func stagingDirectory(_ taskID: UUID, materialID: UUID) throws -> URL {
        let url = directory(materialID).appendingPathComponent("Staging", isDirectory: true).appendingPathComponent(taskID.uuidString, isDirectory: true)
        try validate(url); try files.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    func savePendingResult(_ receipt: PDFPendingResultReceipt, materialID: UUID) throws {
        let path = try stagingDirectory(receipt.task.id, materialID: materialID).appendingPathComponent("receipt.json")
        try validate(path); try JSONEncoder().encode(receipt).write(to: path, options: .atomic)
    }
    func pendingResult(_ taskID: UUID, materialID: UUID) throws -> PDFPendingResultReceipt? {
        let path = directory(materialID).appendingPathComponent("Staging/\(taskID.uuidString)/receipt.json")
        try validate(path)
        guard files.fileExists(atPath: path.path) else { return nil }
        let result = try JSONDecoder().decode(PDFPendingResultReceipt.self, from: Data(contentsOf: path))
        guard result.task.id == taskID else { throw PDFTranslationError.storage }
        return result
    }
    func clearPendingResult(_ taskID: UUID, materialID: UUID) {
        let path = directory(materialID).appendingPathComponent("Staging/\(taskID.uuidString)")
        if (try? validate(path)) != nil { try? files.removeItem(at: path) }
    }
    func save(_ material: PDFMaterial) throws {
        try validateMaterial(material)
        let url = directory(material.id).appendingPathComponent("material.json")
        try validate(url)
        try JSONEncoder().encode(material).write(to: url, options: .atomic)
    }
    func install(_ generated: PDFEngineResult, task: PDFBackgroundTask, material: PDFMaterial, resultID: UUID) throws -> PDFTranslationResult {
        guard generated.engineVersion == "0.6.4", generated.integrationVersion == 1, generated.outputs.contains(where: { $0.kind.isPDF }),
              Set(generated.outputs.map(\.kind)).count == generated.outputs.count else { throw PDFTranslationError.invalidOutput }
        try generated.diagnostics?.validate()
        let staging = try stagingDirectory(task.id, materialID: material.id)
        let target = resultDirectory(material.id, resultID)
        try validate(target)
        try files.createDirectory(at: target, withIntermediateDirectories: true)
        var outputs: [PDFOutput] = []
        for output in generated.outputs {
            let source = output.url.standardizedFileURL.resolvingSymlinksInPath()
            guard source.path.hasPrefix(staging.path + "/") else { throw PDFTranslationError.invalidOutput }
            if output.kind.isPDF {
                guard let document = PDFDocument(url: source), !document.isLocked, document.pageCount > 0 else { throw PDFTranslationError.invalidOutput }
            } else {
                let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 10_000_000, let text = try? String(contentsOf: source, encoding: .utf8),
                      (try? TranslationGlossary.importCSV(text, name: "Extracted terms")) != nil else { throw PDFTranslationError.invalidOutput }
            }
            let destination = target.appendingPathComponent(output.kind.rawValue + "." + output.kind.fileExtension)
            try validate(destination)
            // Retrying local save reuses already copied bytes, never calls service.
            if files.fileExists(atPath: destination.path) {
                guard try Data(contentsOf: source) == Data(contentsOf: destination) else { throw PDFTranslationError.storage }
            } else { try files.copyItem(at: source, to: destination) }
            outputs.append(.init(kind: output.kind, filename: destination.lastPathComponent))
        }
        return .init(id: resultID, taskID: task.id, createdAt: Date(), provider: task.provider, options: task.options,
            engineVersion: generated.engineVersion, integrationVersion: generated.integrationVersion, outputs: outputs, contentReport: generated.contentReport, diagnostics: generated.diagnostics)
    }
    func deleteResult(_ material: PDFMaterial, resultID: UUID) throws -> PDFMaterial {
        _ = try load(material.id)
        guard material.results.contains(where: { $0.id == resultID }) else { throw PDFTranslationError.storage }
        // Commit metadata first; a failed trash leaves detached managed output,
        // never a history entry pointing at a missing file. Roll back on failure.
        var updated = material
        updated.results.removeAll { $0.id == resultID }
        if updated.selectedResultID == resultID { updated.selectedResultID = updated.results.last?.id }
        updated.updatedAt = Date()
        let path = resultDirectory(material.id, resultID); try validate(path)
        try save(updated)
        do { try moveToTrash(path) }
        catch { try save(material); throw PDFTranslationError.storage }
        return updated
    }
    func trash(_ material: PDFMaterial) throws { _ = try load(material.id); try moveToTrash(directory(material.id)) }
    public func export(_ source: URL, to destination: URL) throws {
        try validate(source)
        let target = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard destination.isFileURL, target.path != dataRoot.path, !target.path.hasPrefix(dataRoot.path + "/") else { throw PDFTranslationError.storage }
        try Data(contentsOf: source).write(to: destination, options: .atomic)
    }
    private func load(_ id: UUID) throws -> PDFMaterial {
        let url = directory(id).appendingPathComponent("material.json"); try validate(url)
        let value = try JSONDecoder().decode(PDFMaterial.self, from: Data(contentsOf: url))
        guard value.id == id else { throw PDFTranslationError.storage }
        try validateMaterial(value)
        guard files.fileExists(atPath: try originalURL(id).path) else { throw PDFTranslationError.storage }
        for result in value.results { for output in result.outputs {
            guard files.fileExists(atPath: try resultURL(materialID: id, resultID: result.id, output: output).path) else { throw PDFTranslationError.storage }
        } }
        return value
    }
    private func validateMaterial(_ material: PDFMaterial) throws {
        guard material.schemaVersion == 1, Set(material.results.map(\.id)).count == material.results.count,
              Set(material.tasks.map(\.id)).count == material.tasks.count,
              material.selectedResultID == nil || material.results.contains(where: { $0.id == material.selectedResultID }) else { throw PDFTranslationError.storage }
        for result in material.results { guard result.options.requiresService == (result.provider != nil) else { throw PDFTranslationError.storage }; _ = try result.provider?.validated(); _ = try result.options.validated(); try result.diagnostics?.validate() }
        for task in material.tasks { guard task.options.requiresService == (task.provider != nil) else { throw PDFTranslationError.storage }; _ = try task.provider?.validated(); _ = try task.options.validated() }
    }
    private func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func resultDirectory(_ materialID: UUID, _ resultID: UUID) -> URL {
        directory(materialID).appendingPathComponent("Results", isDirectory: true).appendingPathComponent(resultID.uuidString, isDirectory: true)
    }
    private func validate(_ url: URL) throws {
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path,
              url.path == root.path || url.path.hasPrefix(root.path + "/") else { throw PDFTranslationError.storage }
        var ancestor = url
        while ancestor.path.count >= root.path.count {
            if let attributes = try? files.attributesOfItem(atPath: ancestor.path), attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw PDFTranslationError.storage }
            ancestor.deleteLastPathComponent()
        }
    }
}
