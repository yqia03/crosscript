import Foundation

public final class TextWorkspaceStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "workbench.text-storage", qos: .utility)
    private let dataRoot: URL
    private let root: URL
    private let files = FileManager.default
    private let beforeWrite: @Sendable () throws -> Void
    public init(root: URL, beforeWrite: @escaping @Sendable () throws -> Void = {}) {
        dataRoot = Self.canonical(root)
        self.root = dataRoot.appendingPathComponent("TextWorkspace", isDirectory: true)
        self.beforeWrite = beforeWrite
    }
    struct LoadResult { var library: TextWorkspaceLibrary; var unreadableIDs: [UUID]; var hasPendingSave: Bool }
    func load() throws -> LoadResult { try queue.sync { try loadOnQueue() } }
    private func loadOnQueue() throws -> LoadResult {
        try validatePaths()
        var library = TextWorkspaceLibrary()
        if files.fileExists(atPath: file.path) {
            library = try JSONDecoder().decode(TextWorkspaceLibrary.self, from: Data(contentsOf: file))
            try validate(library)
        }
        let legacyRoot = dataRoot.appendingPathComponent("TextMaterials", isDirectory: true)
        guard Self.canonical(legacyRoot).path == legacyRoot.path else { throw TextTranslationError.storage }
        var unreadable: [UUID] = [], candidates: [LegacyTextMaterial] = []
        if files.fileExists(atPath: legacyRoot.path) {
            for entry in try files.contentsOfDirectory(at: legacyRoot, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
                guard let id = UUID(uuidString: entry.lastPathComponent), !library.migratedLegacyIDs.contains(id) else { continue }
                // Directory enumeration can expand /var to /private/var on macOS.
                // Keep validation anchored to the already canonical storage root.
                let directory = legacyRoot.appendingPathComponent(entry.lastPathComponent, isDirectory: true)
                do {
                    // Old files and their schema-1 archives remain byte-for-byte untouched.
                    let path = directory.appendingPathComponent("material.json")
                    try regularFile(path); guard Self.canonical(directory).path == directory.path else { throw TextTranslationError.storage }
                    let value = try JSONDecoder().decode(LegacyTextMaterial.self, from: Data(contentsOf: path))
                    guard value.id == id, [1, 2].contains(value.schemaVersion) else { throw TextTranslationError.storage }
                    if let bytes = value.importedMarkdown {
                        let source = directory.appendingPathComponent("source.md"); try regularFile(source)
                        guard try Data(contentsOf: source) == bytes else { throw TextTranslationError.storage }
                    }
                    var results = value.schemaVersion == 1 ? value.results ?? [] : value.currentResult.map { [$0] } ?? []
                    if value.schemaVersion == 1 {
                        guard Set(results.map(\.id)).count == results.count,
                              value.selectedResultID == nil || results.contains(where: { $0.id == value.selectedResultID }) else { throw TextTranslationError.storage }
                        // An earlier upgrade retained all versions in its exact-byte archive.
                    } else {
                        let archive = directory.appendingPathComponent("legacy-schema-1/material.json")
                        if files.fileExists(atPath: archive.path) {
                            try regularFile(archive)
                            let original = try JSONDecoder().decode(LegacyTextMaterial.self, from: Data(contentsOf: archive))
                            guard original.id == id, original.schemaVersion == 1 else { throw TextTranslationError.storage }
                            for result in original.results ?? [] where !results.contains(where: { $0.id == result.id }) { results.append(result) }
                        }
                    }
                    try validateWorkspace(value.workspace)
                    for result in results { try validateResult(result) }
                    for result in results where !library.history.contains(where: { $0.id == result.id }) {
                        library.history.append(.init(result: result, isMarkdown: result.markdown != nil, importedFileName: value.importedFileName, importedMarkdown: value.importedMarkdown))
                    }
                    library.migratedLegacyIDs.append(id); candidates.append(value)
                } catch { unreadable.append(id) }
            }
        }
        if !files.fileExists(atPath: file.path), let newest = candidates.sorted(by: {
            $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt
        }).first { library.workspace = newest.workspace }
        library.history.sort { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
        var interrupted = false
        if library.workspace.currentResult?.status == .generating {
            library.workspace.currentResult?.status = .interrupted; library.workspace.currentResult?.failure = .interrupted; interrupted = true
        }
        for index in library.history.indices where library.history[index].result.status == .generating {
            library.history[index].result.status = .interrupted; library.history[index].result.failure = .interrupted; interrupted = true
        }
        var hasPendingSave = false
        if !candidates.isEmpty || interrupted {
            do { try saveOnQueue(library) } catch { hasPendingSave = true }
        }
        return .init(library: library, unreadableIDs: unreadable, hasPendingSave: hasPendingSave)
    }
    func save(_ value: TextWorkspaceLibrary) throws { try queue.sync { try saveOnQueue(value) } }
    func saveAsync(_ value: TextWorkspaceLibrary) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do { try self.saveOnQueue(value); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func saveOnQueue(_ value: TextWorkspaceLibrary) throws {
        try beforeWrite(); try validatePaths(); try validate(value)
        // Refuse to overwrite corrupt/future data; preserve in-memory edits for retry/export.
        if files.fileExists(atPath: file.path) {
            let existing = try JSONDecoder().decode(TextWorkspaceLibrary.self, from: Data(contentsOf: file)); try validate(existing)
        }
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
    }
    func export(_ text: String, to destination: URL) throws {
        let target = Self.canonical(destination)
        guard destination.isFileURL, target.path != dataRoot.path, !target.path.hasPrefix(dataRoot.path + "/") else { throw TextTranslationError.storage }
        try Data(text.utf8).write(to: destination, options: .atomic)
    }
    private var file: URL { root.appendingPathComponent("workspace.json") }
    private func validate(_ value: TextWorkspaceLibrary) throws {
        guard value.schemaVersion == 3, Set(value.history.map(\.id)).count == value.history.count else { throw TextTranslationError.storage }
        try validateWorkspace(value.workspace)
        for entry in value.history { try validateResult(entry.result); try validateImport(entry.importedMarkdown) }
        for copy in value.imports { try validateImport(copy.bytes) }
    }
    private func validateImport(_ bytes: Data?) throws {
        if let bytes { guard bytes.count <= 10_000_000, String(data: bytes, encoding: .utf8) != nil else { throw TextTranslationError.storage } }
    }
    private func validateWorkspace(_ value: TextWorkspace) throws {
        try validateImport(value.importedMarkdown)
        if let result = value.currentResult { try validateResult(result) }
    }
    private func validateResult(_ result: TextTranslationResult) throws {
        _ = try result.provider.validated()
        if let document = result.markdown {
            try document.validate()
            guard document.source.utf8.elementsEqual(result.input.utf8), document.translated.utf8.elementsEqual(result.currentText.utf8) else { throw TextTranslationError.storage }
        }
    }
    private func regularFile(_ url: URL) throws {
        guard Self.canonical(url).path == url.path,
              try files.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else { throw TextTranslationError.storage }
    }
    private func validatePaths() throws {
        for directory in [dataRoot, root] {
            guard Self.canonical(directory).path == directory.path else { throw TextTranslationError.storage }
            if let attributes = try? files.attributesOfItem(atPath: directory.path), attributes[.type] as? FileAttributeType != .typeDirectory { throw TextTranslationError.storage }
        }
        if files.fileExists(atPath: file.path) { try regularFile(file) }
    }
    private static func canonical(_ url: URL) -> URL {
        var ancestor = url.standardizedFileURL, missing: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent(); guard parent.path != ancestor.path else { break }
            missing.append(ancestor.lastPathComponent); ancestor = parent
        }
        var resolved = ancestor.resolvingSymlinksInPath().standardizedFileURL
        for component in missing.reversed() { resolved.appendPathComponent(component) }
        return resolved.standardizedFileURL
    }
}
