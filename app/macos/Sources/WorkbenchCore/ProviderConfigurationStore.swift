import Foundation

struct ProviderConfigurationDocument: Codable {
    var version = 1
    var profiles: [ProviderProfile] = []
    var defaults = ProviderDefaults()
}

public final class ProviderConfigurationStore {
    private let root: URL
    public init(root: URL) { self.root = root.standardizedFileURL.resolvingSymlinksInPath() }
    private func location() throws -> URL {
        let file = root.appendingPathComponent("provider-configurations.json")
        guard root.standardizedFileURL.resolvingSymlinksInPath().path == root.path,
              file.standardizedFileURL.resolvingSymlinksInPath().path == file.path else { throw ProviderConfigurationError.storage }
        return file
    }
    func load() throws -> ProviderConfigurationDocument {
        let file = try location()
        guard FileManager.default.fileExists(atPath: file.path) else { return ProviderConfigurationDocument() }
        let document = try JSONDecoder().decode(ProviderConfigurationDocument.self, from: Data(contentsOf: file))
        guard document.version == 1, Set(document.profiles.map(\.id)).count == document.profiles.count else {
            throw ProviderConfigurationError.storage
        }
        for profile in document.profiles { _ = try profile.snapshot.validated() }
        for id in [document.defaults.textID, document.defaults.pdfID].compactMap({ $0 }) {
            guard document.profiles.contains(where: { $0.id == id }) else { throw ProviderConfigurationError.storage }
        }
        return document
    }
    func save(_ document: ProviderConfigurationDocument) throws {
        let file = try location()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(document).write(to: file, options: .atomic)
    }
}
