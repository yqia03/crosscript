import Combine
import Foundation

@MainActor public protocol AudioCredentials: AnyObject {
    func read(for configuration: AudioServiceConfiguration) throws -> String?
    func save(_ value: String, for configuration: AudioServiceConfiguration) throws
    func delete(for configuration: AudioServiceConfiguration) throws
    func readAsync(for configuration: AudioServiceConfiguration) async throws -> String?
    func saveAsync(_ value: String, for configuration: AudioServiceConfiguration) async throws
    func deleteAsync(for configuration: AudioServiceConfiguration) async throws
}

public extension AudioCredentials {
    func readAsync(for configuration: AudioServiceConfiguration) async throws -> String? {
        try Task.checkCancellation()
        return try read(for: configuration)
    }
    func saveAsync(_ value: String, for configuration: AudioServiceConfiguration) async throws {
        try Task.checkCancellation()
        try save(value, for: configuration)
    }
    func deleteAsync(for configuration: AudioServiceConfiguration) async throws {
        try Task.checkCancellation()
        try delete(for: configuration)
    }
}

public protocol FileTranscribing: Sendable {
    func transcribe(audio: URL, configuration: AudioServiceConfiguration, apiKey: String,
                    progress: @escaping @Sendable (Int) async -> Void) async throws -> String
    func transcribeDocument(audio: URL, configuration: AudioServiceConfiguration, apiKey: String, requestTimestamps: Bool,
                            progress: @escaping @Sendable (Int) async -> Void) async throws -> TranscribedAudio
}

public extension FileTranscribing {
    func transcribeDocument(audio: URL, configuration: AudioServiceConfiguration, apiKey: String, requestTimestamps: Bool,
                            progress: @escaping @Sendable (Int) async -> Void) async throws -> TranscribedAudio {
        guard !requestTimestamps else { throw AudioProcessingError.configuration }
        return try await TranscribedAudio(text: transcribe(audio: audio, configuration: configuration, apiKey: apiKey, progress: progress))
    }
}

public struct TranscriptResult: Identifiable, Codable, Equatable {
    public let id: UUID
    public let createdAt: Date
    public let model: String
    public var text: String
    public var service: AudioServiceConfiguration? = nil
    public var document: TranscriptDocument? = nil
    public var configuration: AudioServiceConfiguration { service ?? AudioServiceConfiguration(model: model) }
    public var currentDocument: TranscriptDocument {
        guard let document, document.text == text else { return TranscriptDocument(text: text) }
        return TranscriptDocument(text: text, anchors: document.anchors, missingIntervals: document.missingIntervals)
    }
    public var paragraphs: [TranscriptParagraph] { currentDocument.paragraphs }
}

public struct TranscriptionAttempt: Codable, Equatable {
    public enum Status: String, Codable { case running, completed, failed, interrupted }
    public let id: UUID
    public let model: String
    public var status: Status
    public var completedChunks: Int = 0
    public var failure: AudioProcessingError?
    public var diagnostics: AudioFailureDiagnostics? = nil
    public var service: AudioServiceConfiguration? = nil
    public var requestedTimestamps: Bool? = nil
    public var configuration: AudioServiceConfiguration { service ?? AudioServiceConfiguration(model: model) }
}

public struct TranscriptionMaterial: Codable, Equatable {
    public var results: [TranscriptResult] = []
    public var attempt: TranscriptionAttempt?
    public init() {}
}

/// Application commands for completed audio. Recording remains an independent use case.
@MainActor public final class PostRecordingSession: ObservableObject {
    /// Last credential check for the selected service target, performed only by an explicit action.
    public enum CredentialAvailability: Equatable { case unchecked, available, missing, inaccessible }
    @Published public private(set) var materials: [UUID: TranscriptionMaterial] = [:]
    @Published public private(set) var runningID: UUID?
    @Published public private(set) var backgroundTasks: [AudioBackgroundTask] = []
    @Published public private(set) var queueNeedsSave = false
    private var queueReadable = true
    private var isShuttingDown = false
    private var worker: Task<Void, Never>?
    @Published public private(set) var isUpdatingCredentials = false
    @Published public private(set) var isCancellingCredentialAction = false
    @Published public private(set) var needsCredentialRecovery = false
    private var pendingCredentialRecovery: (@MainActor () async throws -> Void)?
    public var credentialTransactionsReadyForQuit: Bool { !isUpdatingCredentials && !needsCredentialRecovery }
    @Published public private(set) var authorizingSubmissionID: UUID?
    @Published public private(set) var authorizingTaskID: UUID?
    private var credentialActionTask: Task<String?, Error>?
    private var credentialActionGeneration = UUID()
    private var submissionCredentialTask: Task<String?, Error>?
    private var submissionGeneration = UUID()
    private var configurationRevision = UUID()
    private var taskWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    @Published public private(set) var configuration = AudioServiceConfiguration()
    public var model: String { configuration.model }
    public var canEnqueueTranscription: Bool { authorizingSubmissionID == nil && queueReadable && !queueNeedsSave && pendingSaveID == nil && !isShuttingDown }
    public var isAudioQueueReadable: Bool { queueReadable }
    public func recordingName(for id: UUID) -> String? { recordings.recordings.first(where: { $0.id == id })?.name }
    @Published public private(set) var credentialAvailability: CredentialAvailability = .unchecked
    public var hasCredential: Bool { credentialAvailability == .available }
    @Published public private(set) var error: AudioProcessingError?
    @Published public private(set) var pendingSaveID: UUID?
    @Published public private(set) var pendingSaveIDs: [UUID] = []
    @Published public private(set) var pendingDeletion: MaterialDeletionConfirmation?
    @Published public private(set) var deletionError: MaterialDeletionError?
    @Published private var selectedResultIDs: [UUID: UUID] = [:]
    /// Other owners of this recording must finish or cancel before either deletion scope.
    public var relatedOperationBlocksDeletion: (UUID) -> Bool = { _ in false }
    /// A recovered result cannot be deleted until its legacy checkpoint is
    /// durably marked consumed, otherwise the next launch could recreate it.
    @Published var pendingLegacyRecovery = Set<UUID>()
    /// Clears related readers only after the managed material was moved successfully.
    public var didDeleteMaterial: (UUID) -> Void = { _ in }
    private let recordings: RecordingSession
    private let store: RecordingStore
    private let credentials: any AudioCredentials
    private let service: any FileTranscribing
    private let backgroundGate: BackgroundProcessingGate
    private struct PendingTranscriptSave {
        var material: TranscriptionMaterial
        var editingResultID: UUID?
    }
    private var pendingSaves: [UUID: PendingTranscriptSave] = [:]
    private var unreadableMaterials: Set<UUID> = []
    private var settings = AudioServiceSettings()
    private var configurationReadable = true

    public init(recordings: RecordingSession, store: RecordingStore, credentials: any AudioCredentials, service: any FileTranscribing,
                gate: BackgroundProcessingGate? = nil) {
        self.recordings = recordings
        self.store = store
        self.credentials = credentials
        self.service = service
        self.backgroundGate = gate ?? BackgroundProcessingGate()
        do {
            settings = try store.loadAudioSettings()
            configuration = try settings.configuration(for: settings.selected).validated()
        } catch {
            configurationReadable = false
            self.error = error as? AudioProcessingError ?? .storage
        }
        for recording in recordings.recordings {
            do {
                var material = try store.loadTranscription(for: recording.id)
                if material.attempt?.status == .running {
                    material.attempt?.status = .interrupted
                    material.attempt?.failure = .interrupted
                    _ = persistTranscriptMaterial(material, recordingID: recording.id, editingResultID: material.results.last?.id)
                } else { materials[recording.id] = material }
            } catch {
                unreadableMaterials.insert(recording.id)
                self.error = .storage
            }
        }
        do {
            backgroundTasks = try store.loadAudioQueue()
            for index in backgroundTasks.indices {
                let task = backgroundTasks[index]
                if [.running, .awaitingLocalSave, .interrupted].contains(task.status),
                   materials[task.recordingID]?.results.contains(where: { $0.id == task.attemptID }) == true {
                    backgroundTasks[index].status = .completed
                    backgroundTasks[index].failure = nil
                } else {
                    switch task.status {
                    case .running, .awaitingLocalSave: backgroundTasks[index].status = .interrupted
                    case .queued: backgroundTasks[index].status = .awaitingResume
                    default: break
                    }
                }
                backgroundTasks[index].completionAfterSaving = nil
            }
            if !backgroundTasks.isEmpty { _ = persistQueue() }
        } catch {
            queueReadable = false
            self.error = .storage
        }
    }

    public func configuration(for provider: AudioServiceProvider) -> AudioServiceConfiguration {
        settings.configuration(for: provider)
    }

    /// Noninteractive compatibility command; production settings use saveConfigurationAsync.
    public func saveConfiguration(provider: AudioServiceProvider = .openAI, baseURL: String? = nil, model: String, apiKey: String) {
        guard credentialTransactionsReadyForQuit else { return }
        let candidate: AudioServiceConfiguration
        do { candidate = try AudioServiceConfiguration(provider: provider, baseURL: baseURL, model: model).validated() }
        catch { self.error = .configuration; return }
        guard candidate.supportsSegmentTimestamps else { error = .unsupportedConfiguration; return }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            guard key.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else { error = .configuration; return }
            do { try credentials.save(key, for: candidate) }
            catch {
                if candidate.credentialScope == configuration.credentialScope { credentialAvailability = .inaccessible }
                self.error = .credential
                return
            }
        }
        var next = settings
        next.select(candidate)
        do { try store.saveAudioSettings(next) }
        catch { self.error = .storage; return }
        settings = next
        configuration = candidate
        configurationRevision = UUID()
        configurationReadable = true
        credentialAvailability = .unchecked
        do { _ = try readCredential(for: candidate); error = nil }
        catch { self.error = .credential }
    }

    /// Noninteractive compatibility command; production settings use removeCredentialAsync.
    public func removeCredential() {
        guard credentialTransactionsReadyForQuit else { return }
        do { try credentials.delete(for: configuration); credentialAvailability = .missing; error = nil }
        catch { credentialAvailability = .inaccessible; self.error = .credential }
    }

    /// Interactive production settings use this path; the synchronous entry
    /// remains available for noninteractive compatibility clients and fixtures.
    @discardableResult public func saveConfigurationAsync(provider: AudioServiceProvider = .openAI, baseURL: String? = nil,
                                                          model: String, apiKey: String) async -> Bool {
        guard credentialTransactionsReadyForQuit, !isShuttingDown, !Task.isCancelled else { return false }
        let candidate: AudioServiceConfiguration
        do { candidate = try AudioServiceConfiguration(provider: provider, baseURL: baseURL, model: model).validated() }
        catch { self.error = .configuration; return false }
        guard candidate.supportsSegmentTimestamps else { error = .unsupportedConfiguration; return false }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.isEmpty || key.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else { error = .configuration; return false }
        let token = UUID(), revision = configurationRevision, credentials = credentials
        credentialActionGeneration = token; isUpdatingCredentials = true; isCancellingCredentialAction = false; error = nil
        let operation = Task { [self] () throws -> String? in
            var previousKey: String?, wroteKey = false
            do {
                var stored: String?, readFailed = false
                if key.isEmpty {
                    do { stored = try await credentials.readAsync(for: candidate) }
                    catch { if error is CancellationError { throw error }; readFailed = true }
                } else {
                    previousKey = try await credentials.readAsync(for: candidate)
                    try Task.checkCancellation()
                    guard credentialActionGeneration == token, configurationRevision == revision else { throw CancellationError() }
                    try await credentials.saveAsync(key, for: candidate)
                    wroteKey = true; stored = key
                }
                try Task.checkCancellation()
                guard !isShuttingDown, credentialActionGeneration == token, configurationRevision == revision else { throw CancellationError() }
                var next = settings; next.select(candidate)
                do { try store.saveAudioSettings(next) }
                catch { throw AudioProcessingError.storage }
                settings = next; configuration = candidate; configurationRevision = UUID(); configurationReadable = true
                credentialAvailability = readFailed ? .inaccessible : (stored?.isEmpty == false ? .available : .missing)
                if readFailed { throw AudioProcessingError.credential }
                return stored
            } catch {
                if wroteKey {
                    let restore: @MainActor () async throws -> Void = { [weak self] in
                        do {
                            if let previousKey { try await credentials.saveAsync(previousKey, for: candidate) }
                            else { try await credentials.deleteAsync(for: candidate) }
                        } catch {
                            if self?.configuration.credentialScope == candidate.credentialScope { self?.credentialAvailability = .inaccessible }
                            throw error
                        }
                        if self?.configuration.credentialScope == candidate.credentialScope {
                            self?.credentialAvailability = previousKey?.isEmpty == false ? .available : .missing
                        }
                    }
                    pendingCredentialRecovery = restore; needsCredentialRecovery = true
                    let recovery = Task { try await restore() }
                    do { try await recovery.value; pendingCredentialRecovery = nil; needsCredentialRecovery = false }
                    catch { throw AudioProcessingError.credential }
                }
                throw error
            }
        }
        credentialActionTask = operation
        defer { finishCredentialAction(token) }
        do {
            _ = try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
            error = nil; return true
        } catch {
            self.error = needsCredentialRecovery ? .credential : (error is CancellationError || Task.isCancelled ? .interrupted : (error as? AudioProcessingError ?? .credential))
            return false
        }
    }

    @discardableResult public func removeCredentialAsync(submittedConfiguration: AudioServiceConfiguration? = nil) async -> Bool {
        guard credentialTransactionsReadyForQuit, !isShuttingDown, !Task.isCancelled else { return false }
        let target = submittedConfiguration ?? configuration, token = UUID()
        guard (try? target.validated()) == target else { error = .configuration; return false }
        credentialActionGeneration = token; isUpdatingCredentials = true; isCancellingCredentialAction = false; error = nil
        let operation = Task { [credentials] () throws -> String? in
            try await credentials.deleteAsync(for: target)
            return nil
        }
        credentialActionTask = operation
        defer { finishCredentialAction(token) }
        do {
            _ = try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
            guard !Task.isCancelled, !isShuttingDown, credentialActionGeneration == token,
                  target.credentialScope == configuration.credentialScope else { return false }
            credentialAvailability = .missing; error = nil; return true
        } catch {
            guard !Task.isCancelled, credentialActionGeneration == token,
                  target.credentialScope == configuration.credentialScope else { return false }
            credentialAvailability = .inaccessible; self.error = .credential; return false
        }
    }
    public func cancelCredentialAction() {
        guard isUpdatingCredentials, !needsCredentialRecovery else { return }
        isCancellingCredentialAction = true; credentialActionTask?.cancel()
    }
    private func finishCredentialAction(_ token: UUID) {
        guard credentialActionGeneration == token else { return }
        credentialActionTask = nil; isUpdatingCredentials = false; isCancellingCredentialAction = false
    }
    public func retryCredentialRecovery() async {
        guard !isUpdatingCredentials, let restore = pendingCredentialRecovery else { return }
        isUpdatingCredentials = true
        defer { isUpdatingCredentials = false }
        let recovery = Task { try await restore() }
        do {
            try await recovery.value
            pendingCredentialRecovery = nil; needsCredentialRecovery = false; error = nil
        } catch { self.error = .credential }
    }
    private func readCredentialAsync(for target: AudioServiceConfiguration) async throws -> String? {
        do {
            let key = try await credentials.readAsync(for: target)
            try Task.checkCancellation()
            if target.credentialScope == configuration.credentialScope { credentialAvailability = key?.isEmpty == false ? .available : .missing }
            return key
        } catch {
            if !Task.isCancelled, target.credentialScope == configuration.credentialScope { credentialAvailability = .inaccessible }
            throw error
        }
    }

    private func readCredential(for target: AudioServiceConfiguration) throws -> String? {
        do {
            let key = try credentials.read(for: target)
            if target.credentialScope == configuration.credentialScope {
                credentialAvailability = key?.isEmpty == false ? .available : .missing
            }
            return key
        } catch {
            if target.credentialScope == configuration.credentialScope { credentialAvailability = .inaccessible }
            throw error
        }
    }

    public func dismissError() { error = nil }

    /// Local recovery and interval repair contribute an independent recording result.
    /// The stable result ID makes retrying local persistence idempotent.
    @discardableResult public func saveTranscriptResult(recordingID: UUID, resultID: UUID, createdAt: Date,
        configuration: AudioServiceConfiguration, document: TranscriptDocument) -> Bool {
        guard recordings.recordings.contains(where: { $0.id == recordingID && $0.workflow == .transcription }),
              !unreadableMaterials.contains(recordingID),
              (try? configuration.validated()) == configuration else { error = .storage; return false }
        var material = materials[recordingID] ?? TranscriptionMaterial()
        if !material.results.contains(where: { $0.id == resultID }) {
            material.results.append(TranscriptResult(id: resultID, createdAt: createdAt, model: configuration.model,
                text: document.text, service: configuration, document: document))
        }
        let editingID = pendingSaves[recordingID]?.editingResultID ?? resultID
        selectedResultIDs[recordingID] = editingID
        return persistTranscriptMaterial(material, recordingID: recordingID, editingResultID: editingID)
    }

    public func selectedResult(recordingID: UUID) -> TranscriptResult? {
        let results = materials[recordingID]?.results ?? []
        return results.first { $0.id == selectedResultIDs[recordingID] } ?? results.last
    }

    @discardableResult public func selectResult(recordingID: UUID, resultID: UUID) -> Bool {
        guard materials[recordingID]?.results.contains(where: { $0.id == resultID }) == true,
              pendingSaves[recordingID] == nil || selectedResult(recordingID: recordingID)?.id == resultID else { return false }
        selectedResultIDs[recordingID] = resultID
        return true
    }

    public func deletionBlockReason(for target: MaterialDeletionTarget) -> MaterialDeletionError? {
        let recordingID = target.recordingID
        guard recordings.recordings.contains(where: { $0.id == recordingID }),
              !unreadableMaterials.contains(recordingID) else { return .unavailable }
        if relatedOperationBlocksDeletion(recordingID) || !recordings.canCreateProject || runningID == recordingID ||
            backgroundTasks.contains(where: { $0.recordingID == recordingID && $0.status.occupiesMaterial }) { return .busy }
        if pendingSaves[recordingID] != nil { return .unsavedChanges }
        if case .result = target, pendingLegacyRecovery.contains(recordingID) { return .unsavedChanges }
        if case .result(_, let resultID) = target,
           materials[recordingID]?.results.contains(where: { $0.id == resultID }) != true { return .unavailable }
        return nil
    }

    @discardableResult public func requestDeletion(_ target: MaterialDeletionTarget) -> Bool {
        if let reason = deletionBlockReason(for: target) { deletionError = reason; return false }
        guard let recording = recordings.recordings.first(where: { $0.id == target.recordingID }) else { return false }
        do {
            let bilingualResults = try BilingualResultStore(recordings: store).load(target.recordingID)
            pendingDeletion = MaterialDeletionConfirmation(target: target, recording: recording,
                material: materials[target.recordingID] ?? TranscriptionMaterial(), bilingualResults: bilingualResults)
        } catch { deletionError = .storage; return false }
        deletionError = nil
        return true
    }

    public func cancelDeletion() { pendingDeletion = nil; deletionError = nil }
    public func dismissDeletionError() { deletionError = nil }

    @discardableResult public func confirmDeletion() -> Bool {
        guard let confirmation = pendingDeletion else { return false }
        let target = confirmation.target
        let recordingID = target.recordingID
        if let reason = deletionBlockReason(for: target) { deletionError = reason; return false }
        do {
            guard try BilingualResultStore(recordings: store).load(recordingID) == confirmation.bilingualResults else {
                deletionError = .staleConfirmation; return false
            }
        } catch { deletionError = .storage; return false }
        guard recordings.recordings.first(where: { $0.id == recordingID }) == confirmation.recording,
              (materials[recordingID] ?? TranscriptionMaterial()) == confirmation.material else {
            deletionError = .staleConfirmation
            return false
        }
        switch target {
        case .result(_, let resultID):
            var remaining = confirmation.material
            remaining.results.removeAll { $0.id == resultID }
            do { try store.saveTranscription(remaining, for: recordingID) }
            catch { deletionError = .storage; return false }
            materials[recordingID] = remaining
            if selectedResultIDs[recordingID] == resultID { selectedResultIDs[recordingID] = nil }
        case .material:
            do { try recordings.trashMaterial(confirmation.recording) }
            catch { deletionError = .storage; return false }
            materials[recordingID] = nil
            selectedResultIDs[recordingID] = nil
            didDeleteMaterial(recordingID)
        }
        cancelDeletion()
        return true
    }

    @discardableResult public func saveTranscriptText(recordingID: UUID, resultID: UUID, text: String) -> Bool {
        guard let result = materials[recordingID]?.results.first(where: { $0.id == resultID }) else { return false }
        var document = result.currentDocument
        document.replaceText(with: text)
        return saveTranscriptDocument(recordingID: recordingID, resultID: resultID, document: document)
    }

    public func canEditTranscript(recordingID: UUID, resultID: UUID) -> Bool {
        !unreadableMaterials.contains(recordingID) &&
        materials[recordingID]?.results.contains(where: { $0.id == resultID }) == true &&
        (pendingSaves[recordingID] == nil || pendingSaves[recordingID]?.editingResultID == resultID)
    }

    public func hasUnsavedTranscript(recordingID: UUID) -> Bool { pendingSaves[recordingID] != nil }

    @discardableResult public func replaceTranscriptText(recordingID: UUID, resultID: UUID, range: NSRange, replacement: String) -> Bool {
        guard let result = materials[recordingID]?.results.first(where: { $0.id == resultID }) else { return false }
        var document = result.currentDocument
        guard document.replace(range: range, with: replacement) else { return false }
        return saveTranscriptDocument(recordingID: recordingID, resultID: resultID, document: document)
    }

    private func saveTranscriptDocument(recordingID: UUID, resultID: UUID, document: TranscriptDocument) -> Bool {
        guard canEditTranscript(recordingID: recordingID, resultID: resultID),
              var material = materials[recordingID],
              let index = material.results.firstIndex(where: { $0.id == resultID }) else { return false }
        material.results[index].text = document.text
        material.results[index].document = document
        return persistTranscriptMaterial(material, recordingID: recordingID, editingResultID: resultID)
    }

    @discardableResult private func persistTranscriptMaterial(_ material: TranscriptionMaterial, recordingID: UUID, editingResultID: UUID?) -> Bool {
        materials[recordingID] = material
        do {
            try store.saveTranscription(material, for: recordingID)
            pendingSaves[recordingID] = nil
            refreshPendingSaves()
            error = pendingSaves.isEmpty ? nil : .storage
            return true
        } catch {
            pendingSaves[recordingID] = PendingTranscriptSave(material: material, editingResultID: editingResultID)
            refreshPendingSaves()
            self.error = .storage
            return false
        }
    }

    public func transcriptText(recordingID: UUID, resultID: UUID) -> String? {
        materials[recordingID]?.results.first(where: { $0.id == resultID })?.text
    }

    @discardableResult public func exportTranscript(recordingID: UUID, resultID: UUID, format: TranscriptExportFormat,
                                                   includeTimestamps: Bool = false, language: AppLanguage = .english, to destination: URL) -> Bool {
        guard let result = materials[recordingID]?.results.first(where: { $0.id == resultID }) else { return false }
        let text = result.currentDocument.exportText(includeTimestamps: includeTimestamps, language: language)
        do { try store.exportTranscript(text, to: destination); error = pendingSaves.isEmpty ? nil : .storage; return true }
        catch { self.error = .storage; return false }
    }

    public func playbackStart(recordingID: UUID, resultID: UUID, paragraphRange: NSRange) -> TimeInterval? {
        guard let result = materials[recordingID]?.results.first(where: { $0.id == resultID }) else { return nil }
        return result.paragraphs.first(where: { $0.range == paragraphRange })?.playbackStart
    }

    /// Noninteractive compatibility command. Production actions use the async
    /// authorization entry below; queued work is always owned by this session.
    @discardableResult public func enqueueTranscription(_ id: UUID, requestTimestamps: Bool = true) -> UUID? {
        guard authorizingSubmissionID == nil, pendingSaveID == nil, queueReadable, !queueNeedsSave, !isShuttingDown else { return nil }
        guard configurationReadable else { error = .configuration; return nil }
        guard configuration.supportsSegmentTimestamps else { error = .unsupportedConfiguration; return nil }
        guard !unreadableMaterials.contains(id) else { error = .storage; return nil }
        guard let recording = recordings.recordings.first(where: { $0.id == id }),
              recording.workflow == .transcription,
              recording.status == .saved || recording.status == .interrupted,
              recordings.activeID != id else { return nil }
        do {
            guard try readCredential(for: configuration)?.isEmpty == false else {
                error = .configuration; return nil
            }
        } catch { self.error = .credential; return nil }
        return enqueuePrepared(id, configuration: configuration, requestTimestamps: requestTimestamps)
    }

    private func enqueuePrepared(_ id: UUID, configuration: AudioServiceConfiguration, requestTimestamps: Bool) -> UUID? {
        let task = AudioBackgroundTask(recordingID: id, configuration: configuration, requestTimestamps: requestTimestamps)
        backgroundTasks.append(task)
        guard persistQueue() else {
            backgroundTasks.removeLast()
            return nil
        }
        dispatchNext()
        return task.id
    }

    /// Authorization may outlive a view or a setting change. Both the material
    /// and immutable submitted target are checked again before durable enqueue.
    @discardableResult public func enqueueTranscriptionAsync(_ id: UUID, requestTimestamps: Bool = true, submittedConfiguration: AudioServiceConfiguration? = nil) async -> UUID? {
        guard authorizingSubmissionID == nil, !Task.isCancelled else { return nil }
        let target = submittedConfiguration ?? configuration
        guard canPrepareSubmission(id, target: target) else { return nil }
        let token = UUID(); submissionGeneration = token; authorizingSubmissionID = id
        let operation = Task { [weak self] in try await self?.readCredentialAsync(for: target) }
        submissionCredentialTask = operation
        defer {
            if submissionGeneration == token { submissionCredentialTask = nil; authorizingSubmissionID = nil }
        }
        do {
            let key = try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
            guard !Task.isCancelled, submissionGeneration == token, canPrepareSubmission(id, target: target) else { return nil }
            guard key?.isEmpty == false else { error = .configuration; return nil }
            return enqueuePrepared(id, configuration: target, requestTimestamps: requestTimestamps)
        } catch {
            if !Task.isCancelled, submissionGeneration == token { self.error = .credential }
            return nil
        }
    }
    public func cancelPendingSubmission() {
        submissionGeneration = UUID(); submissionCredentialTask?.cancel(); submissionCredentialTask = nil
        authorizingSubmissionID = nil
    }
    private func canPrepareSubmission(_ id: UUID, target: AudioServiceConfiguration) -> Bool {
        guard pendingSaveID == nil, queueReadable, !queueNeedsSave, !isShuttingDown else { return false }
        guard configurationReadable else { error = .configuration; return false }
        guard (try? target.validated()) == target, target.supportsSegmentTimestamps else { error = .unsupportedConfiguration; return false }
        guard !unreadableMaterials.contains(id) else { error = .storage; return false }
        guard let recording = recordings.recordings.first(where: { $0.id == id }),
              recording.workflow == .transcription,
              [.saved, .interrupted].contains(recording.status), recordings.activeID != id else { return false }
        return true
    }

    /// Compatibility command for callers that need to await their submitted work.
    public func transcribe(_ id: UUID, requestTimestamps: Bool = true) async {
        guard !Task.isCancelled else { return }
        guard let taskID = await enqueueTranscriptionAsync(id, requestTimestamps: requestTimestamps) else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let task = backgroundTasks.first(where: { $0.id == taskID }), [.queued, .running].contains(task.status) {
                    taskWaiters[taskID, default: []].append(continuation)
                } else { continuation.resume() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.interruptTask(taskID) }
        }
    }

    private func dispatchNext() {
        guard pendingSaveID == nil, queueReadable, !queueNeedsSave, !isShuttingDown else { return }
        for task in backgroundTasks where task.status == .queued {
            backgroundGate.enqueue(id: task.id) { [weak self, backgroundGate] in
                guard let self else { backgroundGate.finish(id: task.id); return }
                self.startGrantedTask(task.id)
            }
        }
    }

    private func startGrantedTask(_ taskID: UUID) {
        guard worker == nil, pendingSaveID == nil, queueReadable, !queueNeedsSave, !isShuttingDown,
              let index = backgroundTasks.firstIndex(where: { $0.id == taskID && $0.status == .queued }) else {
            backgroundGate.finish(id: taskID)
            return
        }
        backgroundTasks[index].status = .running
        guard persistQueue() else {
            backgroundTasks[index].status = .queued
            backgroundGate.finish(id: taskID)
            return
        }
        let task = backgroundTasks[index]
        var material = materials[task.recordingID] ?? TranscriptionMaterial()
        material.attempt = TranscriptionAttempt(id: task.attemptID, model: task.configuration.model, status: .running,
            service: task.configuration, requestedTimestamps: task.requestTimestamps)
        do { try store.saveTranscription(material, for: task.recordingID) }
        catch {
            self.error = .storage
            updateTask(task.id, status: .failed, failure: .storage)
            finishWaiting(task.id)
            backgroundGate.finish(id: taskID)
            return
        }
        materials[task.recordingID] = material
        runningID = task.recordingID
        worker = Task { [weak self] in
            guard let self else { return }
            await self.execute(task)
            self.runningID = nil
            self.worker = nil
            self.finishWaiting(task.id)
            self.backgroundGate.finish(id: task.id)
            self.dispatchNext()
        }
    }

    @discardableResult public func resumeBackgroundTask(_ taskID: UUID) -> Bool {
        requeue(taskID, allowed: [.interrupted, .awaitingResume])
    }

    @discardableResult public func retryBackgroundTask(_ taskID: UUID) -> Bool {
        requeue(taskID, allowed: [.failed, .cancelled])
    }

    private func requeue(_ taskID: UUID, allowed: [AudioBackgroundTask.Status]) -> Bool {
        guard queueReadable, !queueNeedsSave, !isShuttingDown, pendingSaveID == nil,
              let index = backgroundTasks.firstIndex(where: { $0.id == taskID }),
              allowed.contains(backgroundTasks[index].status) else { return false }
        var task = backgroundTasks[index]
        guard recordings.recordings.contains(where: { $0.id == task.recordingID }),
              recordings.activeID != task.recordingID, !unreadableMaterials.contains(task.recordingID) else { return false }
        guard (try? task.configuration.validated()) == task.configuration,
              task.configuration.supportsSegmentTimestamps,
              task.credentialScope == task.configuration.credentialScope else { error = .unsupportedConfiguration; return false }
        let previous = backgroundTasks
        task.attemptID = UUID()
        task.status = .queued
        task.completedChunks = 0
        task.failure = nil
        task.diagnostics = nil
        task.completionAfterSaving = nil
        backgroundTasks.remove(at: index)
        backgroundTasks.append(task)
        guard persistQueue() else { backgroundTasks = previous; return false }
        dispatchNext()
        return true
    }

    /// Continue already-submitted work after a local-save-only quit preflight is cancelled.
    public func continueAfterCancelledQuit() {
        // Another material may veto termination after confirmed shutdown. The
        // interrupted jobs remain manual, but new/resumed work is usable again.
        isShuttingDown = false
        dispatchNext()
    }

    /// Interrupt work only after the user has confirmed quitting and recordings are saved.
    public func prepareForConfirmedQuit() -> Bool {
        guard prepareToQuit() else { return false }
        // An unreadable existing journal is preserved and never dispatched or overwritten.
        guard queueReadable else {
            isShuttingDown = true; cancelPendingSubmission(); cancelCredentialAction(); return true
        }
        let previous = backgroundTasks
        for index in backgroundTasks.indices {
            if backgroundTasks[index].status == .running { backgroundTasks[index].status = .interrupted }
            else if backgroundTasks[index].status == .queued { backgroundTasks[index].status = .awaitingResume }
        }
        guard persistQueue() else { backgroundTasks = previous; return false }
        isShuttingDown = true
        cancelPendingSubmission(); cancelCredentialAction()
        for task in backgroundTasks { backgroundGate.cancelWaiting(id: task.id) }
        worker?.cancel()
        for task in backgroundTasks where task.status == .awaitingResume { finishWaiting(task.id) }
        return true
    }

    public func cancelBackgroundTask(_ taskID: UUID) {
        stopTask(taskID, status: .cancelled)
    }

    private func interruptTask(_ taskID: UUID) {
        stopTask(taskID, status: .interrupted)
    }

    private func stopTask(_ taskID: UUID, status: AudioBackgroundTask.Status) {
        guard let index = backgroundTasks.firstIndex(where: { $0.id == taskID }),
              [.queued, .running, .interrupted, .awaitingResume].contains(backgroundTasks[index].status) else { return }
        let wasRunning = backgroundTasks[index].status == .running
        backgroundTasks[index].status = status
        _ = persistQueue()
        if wasRunning { worker?.cancel() } else {
            backgroundGate.cancelWaiting(id: taskID)
            finishWaiting(taskID)
        }
    }

    private func acceptsResponse(for task: AudioBackgroundTask) -> Bool {
        backgroundTasks.contains { $0.id == task.id && $0.attemptID == task.attemptID && $0.status == .running }
    }

    private func finishWaiting(_ taskID: UUID) {
        for waiter in taskWaiters.removeValue(forKey: taskID) ?? [] { waiter.resume() }
    }

    private func execute(_ task: AudioBackgroundTask) async {
        guard !Task.isCancelled, acceptsResponse(for: task) else { return }
        let id = task.recordingID
        let attempt = TranscriptionAttempt(id: task.attemptID, model: task.configuration.model, status: .running,
                                          service: task.configuration, requestedTimestamps: task.requestTimestamps)
        var material = materials[id] ?? TranscriptionMaterial()
        error = nil
        var finalStatus: AudioBackgroundTask.Status = .completed
        do {
            authorizingTaskID = task.id
            let key: String?
            do { key = try await readCredentialAsync(for: task.configuration) }
            catch { authorizingTaskID = nil; throw error }
            authorizingTaskID = nil
            try Task.checkCancellation()
            guard let key, !key.isEmpty else { throw AudioProcessingError.credential }
            guard acceptsResponse(for: task) else { return }
            let response = try await service.transcribeDocument(audio: recordings.audioURL(for: id), configuration: task.configuration,
                apiKey: key, requestTimestamps: task.requestTimestamps) { [weak self] count in
                await self?.reportProgress(count, id: id, attemptID: attempt.id)
            }
            try Task.checkCancellation()
            guard acceptsResponse(for: task) else { return }
            guard !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AudioProcessingError.processing }
            material = materials[id] ?? material
            if !material.results.contains(where: { $0.id == attempt.id }) {
                material.results.append(TranscriptResult(id: attempt.id, createdAt: Date(), model: attempt.model, text: response.text,
                    service: attempt.configuration, document: TranscriptDocument(text: response.text, anchors: response.anchors)))
            }
            selectedResultIDs[id] = pendingSaves[id]?.editingResultID ?? attempt.id
            material.attempt?.status = .completed
        } catch {
            material = materials[id] ?? material
            let requestFailure = error as? AudioRequestFailure
            material.attempt?.status = Task.isCancelled ? .interrupted : .failed
            material.attempt?.failure = Task.isCancelled ? .interrupted : (requestFailure?.category ?? error as? AudioProcessingError ?? .processing)
            material.attempt?.diagnostics = Task.isCancelled ? nil : requestFailure?.diagnostics
            finalStatus = acceptsResponse(for: task) ? (Task.isCancelled ? .interrupted : .failed)
                : (backgroundTasks.first(where: { $0.id == task.id })?.status ?? .interrupted)
        }
        let editableResultID = pendingSaves[id]?.editingResultID ?? selectedResultIDs[id] ?? material.results.last?.id
        // Result persistence precedes completion. The stable attempt ID closes the crash window.
        let saved = persistTranscriptMaterial(material, recordingID: id, editingResultID: editableResultID)
        if let index = backgroundTasks.firstIndex(where: { $0.id == task.id && $0.attemptID == task.attemptID }) {
            backgroundTasks[index].completionAfterSaving = saved ? nil : finalStatus
            backgroundTasks[index].diagnostics = material.attempt?.diagnostics
            updateTask(task.id, status: saved ? finalStatus : .awaitingLocalSave,
                       failure: saved ? material.attempt?.failure : .storage)
        }
    }

    private func updateTask(_ id: UUID, status: AudioBackgroundTask.Status, failure: AudioProcessingError? = nil) {
        guard let index = backgroundTasks.firstIndex(where: { $0.id == id }) else { return }
        backgroundTasks[index].status = status
        backgroundTasks[index].failure = failure
        _ = persistQueue()
    }

    @discardableResult private func persistQueue() -> Bool {
        do {
            try store.saveAudioQueue(backgroundTasks)
            queueNeedsSave = false
            return true
        } catch {
            queueNeedsSave = true
            self.error = .storage
            return false
        }
    }

    public func retrySaving() {
        retryLocalSaving(startQueuedWork: true)
    }

    private func retryLocalSaving(startQueuedWork: Bool) {
        for id in pendingSaveIDs {
            guard let pending = pendingSaves[id] else { continue }
            let material = materials[id] ?? pending.material
            _ = persistTranscriptMaterial(material, recordingID: id, editingResultID: pending.editingResultID)
        }
        var queueChanged = false
        for index in backgroundTasks.indices where backgroundTasks[index].status == .awaitingLocalSave {
            let id = backgroundTasks[index].recordingID
            if pendingSaves[id] == nil {
                backgroundTasks[index].status = backgroundTasks[index].completionAfterSaving ?? .interrupted
                backgroundTasks[index].completionAfterSaving = nil
                backgroundTasks[index].failure = materials[id]?.attempt?.failure
                queueChanged = true
            }
        }
        if (queueNeedsSave || queueChanged) && queueReadable { _ = persistQueue() }
        if pendingSaves.isEmpty && !queueNeedsSave && queueReadable { error = nil }
        if startQueuedWork { dispatchNext() }
    }

    /// Retry only local persistence. Unsaved drafts must remain visible if quitting is refused.
    public func prepareToQuit() -> Bool {
        guard credentialTransactionsReadyForQuit else { return false }
        retryLocalSaving(startQueuedWork: false)
        return pendingSaves.isEmpty && !queueNeedsSave
    }

    private func refreshPendingSaves() {
        pendingSaveIDs = pendingSaves.keys.sorted { $0.uuidString < $1.uuidString }
        pendingSaveID = pendingSaveIDs.first
    }

    private func reportProgress(_ count: Int, id: UUID, attemptID: UUID) {
        guard runningID == id, materials[id]?.attempt?.id == attemptID,
              materials[id]?.attempt?.status == .running,
              let index = backgroundTasks.firstIndex(where: { $0.recordingID == id && $0.attemptID == attemptID && $0.status == .running }) else { return }
        materials[id]?.attempt?.completedChunks = max(0, count)
        backgroundTasks[index].completedChunks = max(0, count)
    }
}
