import Foundation

public struct RecordingLoadResult {
    public let recordings: [Recording]
    public let warnings: [String]
}

public enum RecordingStoreError: LocalizedError {
    case unsafePath
    case invalidMetadata(String)

    public var errorDescription: String? {
        switch self {
        case .unsafePath: return coreMessage("录音保存位置包含不安全的链接，或不是文件夹。", "The recording storage location contains an unsafe link or is not a directory.")
        case .invalidMetadata(let name): return coreMessage("无法读取录音信息：\(name)。已有文件已保留。", "The recording metadata could not be read: \(name). The existing files have been kept.")
        }
    }
}

/// Owns only UUID-named material directories underneath its chosen root.
/// Initializing a store neither creates the directory nor changes existing files.
public final class RecordingStore {
    private let root: URL
    private let files = FileManager.default
    private let moveToTrash: (URL) throws -> Void

    public convenience init(root: URL) {
        self.init(root: root, moveToTrash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
    }

    init(root: URL, moveToTrash: @escaping (URL) throws -> Void) {
        self.root = Self.canonicalLocation(root)
        self.moveToTrash = moveToTrash
    }

    public func audioURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("audio.caf", isDirectory: false)
    }

    public func audioURL(for recording: Recording) -> URL {
        guard let ext = recording.importedExtension, AudioImportFormats.extensions.contains(ext) else {
            return audioURL(for: recording.id)
        }
        return directory(for: recording.id).appendingPathComponent("source.\(ext)")
    }

    public func importAudio(from source: URL, using importer: any AudioImporting) async throws -> Recording {
        let ext = source.pathExtension.lowercased()
        guard AudioImportFormats.extensions.contains(ext) else { throw AudioProcessingError.unsupportedAudio }
        try validateRoot()
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID()
        let staging = root.appendingPathComponent(".import-\(id.uuidString)")
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }
        let destination = staging.appendingPathComponent("source.\(ext)")
        let duration = try await importer.copyAudio(from: source, to: destination)
        guard duration.isFinite, duration > 0 else { throw AudioProcessingError.unsupportedAudio }
        let name = source.deletingPathExtension().lastPathComponent
        var recording = Recording(id: id, startedAt: Date(), defaultName: name, name: name, duration: duration, status: .saved)
        recording.importedExtension = ext
        try JSONEncoder().encode(recording).write(to: staging.appendingPathComponent("recording.json"), options: .atomic)
        try validateRoot()
        try files.moveItem(at: staging, to: directory(for: id))
        return recording
    }

    public func load() throws -> RecordingLoadResult {
        try validateRoot()
        guard files.fileExists(atPath: root.path) else {
            return RecordingLoadResult(recordings: [], warnings: [])
        }
        var recordings: [Recording] = []
        var warnings: [String] = []
        for entry in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: entry.lastPathComponent) else { continue }
            do {
                try validateMaterial(id)
                let metadata = metadataURL(for: id)
                let children = try files.contentsOfDirectory(atPath: entry.path)
                guard files.fileExists(atPath: metadata.path) else {
                    if !children.isEmpty { throw RecordingStoreError.invalidMetadata(entry.lastPathComponent) }
                    continue
                }
                var recording = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: metadata))
                guard recording.id == id, recording.duration.isFinite, recording.duration >= 0,
                      recording.importedExtension.map(AudioImportFormats.extensions.contains) ?? true else {
                    throw RecordingStoreError.invalidMetadata(entry.lastPathComponent)
                }
                if recording.needsWorkflowMigration {
                    // A saved result (including an empty deletion journal) or
                    // checkpoint identifies the original live workflow even
                    // when its cloud request never completed.
                    if children.contains("bilingual-results.json") || children.contains("bilingual-draft.json") {
                        recording.workflow = .liveTranslation
                    }
                    recording.needsWorkflowMigration = false
                    do { try save(recording) }
                    catch { warnings.append("\(entry.lastPathComponent): \(error.localizedDescription)") }
                }
                recordings.append(recording)
            } catch {
                warnings.append("\(entry.lastPathComponent): \(error.localizedDescription)")
            }
        }
        recordings.sort { $0.startedAt > $1.startedAt }
        return RecordingLoadResult(recordings: recordings, warnings: warnings)
    }

    public func save(_ recording: Recording) throws {
        try validateRoot()
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        try validateMaterial(recording.id)
        let materialDirectory = directory(for: recording.id)
        if !files.fileExists(atPath: materialDirectory.path) {
            try files.createDirectory(at: materialDirectory, withIntermediateDirectories: false)
        }
        let data = try JSONEncoder().encode(recording)
        try data.write(to: metadataURL(for: recording.id), options: .atomic)
    }

    /// A failed attempt that created no audio is not presented as a completed recording.
    /// Remove only our metadata and an otherwise empty material directory.
    public func discardUnstarted(_ id: UUID) throws {
        try validateMaterial(id)
        guard !files.fileExists(atPath: audioURL(for: id).path) else { return }
        let metadata = metadataURL(for: id)
        if files.fileExists(atPath: metadata.path) { try files.removeItem(at: metadata) }
        let directory = directory(for: id)
        if files.fileExists(atPath: directory.path), try files.contentsOfDirectory(atPath: directory.path).isEmpty {
            try files.removeItem(at: directory)
        }
    }

    public func containsAudio(for id: UUID) -> Bool {
        guard (try? validateMaterial(id)) != nil else { return false }
        return files.fileExists(atPath: audioURL(for: id).path)
    }

    public func loadTranscription(for id: UUID) throws -> TranscriptionMaterial {
        try validateMaterial(id)
        let url = directory(for: id).appendingPathComponent("transcription.json")
        guard files.fileExists(atPath: url.path) else { return TranscriptionMaterial() }
        return try JSONDecoder().decode(TranscriptionMaterial.self, from: Data(contentsOf: url))
    }

    public func saveTranscription(_ material: TranscriptionMaterial, for id: UUID) throws {
        try validateMaterial(id)
        try JSONEncoder().encode(material).write(to: directory(for: id).appendingPathComponent("transcription.json"), options: .atomic)
    }

    /// Move the complete owned directory; never recursively remove individual files.
    /// A failed move leaves the original audio and result files together in history.
    func trashMaterial(_ id: UUID) throws {
        try validateMaterial(id)
        let recording = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: metadataURL(for: id)))
        guard recording.id == id else { throw RecordingStoreError.invalidMetadata(id.uuidString) }
        try moveToTrash(directory(for: id))
    }

    /// Export is a user-selected external copy; it must never replace managed material.
    func exportTranscript(_ text: String, to destination: URL) throws {
        let target = Self.canonicalLocation(destination)
        guard destination.isFileURL, target.path != root.path, !target.path.hasPrefix(root.path + "/") else {
            throw RecordingStoreError.unsafePath
        }
        try Data(text.utf8).write(to: destination, options: .atomic)
    }

    func loadAudioSettings() throws -> AudioServiceSettings {
        let url = try audioConfigurationURL()
        guard files.fileExists(atPath: url.path) else { return AudioServiceSettings() }
        let data = try Data(contentsOf: url)
        if let model = try? JSONDecoder().decode(String.self, from: data) {
            var migrated = AudioServiceSettings()
            migrated.select(try AudioServiceConfiguration(model: model).validated())
            return migrated
        }
        let settings = try JSONDecoder().decode(AudioServiceSettings.self, from: data)
        guard settings.version == 2 else { throw AudioProcessingError.configuration }
        return settings
    }

    func saveAudioSettings(_ settings: AudioServiceSettings) throws {
        let url = try audioConfigurationURL()
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(settings).write(to: url, options: .atomic)
    }

    func loadAudioQueue() throws -> [AudioBackgroundTask] {
        let url = try audioQueueURL()
        guard files.fileExists(atPath: url.path) else { return [] }
        let snapshot = try JSONDecoder().decode(AudioQueueSnapshot.self, from: Data(contentsOf: url))
        guard snapshot.version == 1,
              Set(snapshot.tasks.map(\.id)).count == snapshot.tasks.count,
              snapshot.tasks.allSatisfy({ $0.credentialScope == $0.configuration.credentialScope && $0.completedChunks >= 0 })
        else { throw AudioProcessingError.storage }
        return snapshot.tasks
    }

    func saveAudioQueue(_ tasks: [AudioBackgroundTask]) throws {
        let url = try audioQueueURL()
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(AudioQueueSnapshot(tasks: tasks)).write(to: url, options: .atomic)
    }

    private struct AudioQueueSnapshot: Codable {
        var version = 1
        let tasks: [AudioBackgroundTask]
    }

    private func audioQueueURL() throws -> URL {
        try validateRoot()
        let url = root.appendingPathComponent("audio-task-queue.json")
        guard Self.canonicalLocation(url).path == url.path else { throw RecordingStoreError.unsafePath }
        return url
    }

    private func audioConfigurationURL() throws -> URL {
        try validateRoot()
        let url = root.appendingPathComponent("audio-configuration.json")
        guard Self.canonicalLocation(url).path == url.path else { throw RecordingStoreError.unsafePath }
        return url
    }

    private func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func metadataURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("recording.json", isDirectory: false)
    }

    // Resolve an existing ancestor first: Foundation can otherwise leave /var
    // aliases unresolved until the requested leaf exists. Compare paths rather
    // than URL directory hints, which can change after creating a directory.
    private static func canonicalLocation(_ url: URL) -> URL {
        var ancestor = url.standardizedFileURL
        var missingComponents: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { break }
            missingComponents.append(ancestor.lastPathComponent)
            ancestor = parent
        }
        var resolved = ancestor.resolvingSymlinksInPath().standardizedFileURL
        for component in missingComponents.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL
    }

    private func validateRoot() throws {
        guard Self.canonicalLocation(root).path == root.path else { throw RecordingStoreError.unsafePath }
        if files.fileExists(atPath: root.path) {
            let attributes = try files.attributesOfItem(atPath: root.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw RecordingStoreError.unsafePath }
        }
    }

    private func validateMaterial(_ id: UUID) throws {
        try validateRoot()
        let folder = directory(for: id)
        if let attributes = try? files.attributesOfItem(atPath: folder.path) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw RecordingStoreError.unsafePath }
        }
        guard Self.canonicalLocation(folder).path == folder.path else { throw RecordingStoreError.unsafePath }
        for file in [audioURL(for: id), metadataURL(for: id), directory(for: id).appendingPathComponent("transcription.json")] + AudioImportFormats.extensions.map({ directory(for: id).appendingPathComponent("source.\($0)") }) {
            if let attributes = try? files.attributesOfItem(atPath: file.path), attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw RecordingStoreError.unsafePath
            }
            guard Self.canonicalLocation(file).path == file.path else { throw RecordingStoreError.unsafePath }
        }
    }
}
