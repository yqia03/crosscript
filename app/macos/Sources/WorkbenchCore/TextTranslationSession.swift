import Combine
import Foundation

@MainActor public final class TextTranslationSession: ObservableObject {
    @Published public private(set) var workspace = TextWorkspace()
    @Published public private(set) var workspaceRevision = UUID()
    @Published public private(set) var history: [TextTranslationHistoryEntry] = []
    @Published public private(set) var isRunning = false
    @Published public private(set) var runningResultID: UUID?
    @Published public private(set) var isAuthorizingCredential = false
    @Published public private(set) var hasPendingSave = false
    @Published public private(set) var error: TextTranslationError?
    @Published public private(set) var detectedSourceLanguage: TranslationLanguage?
    @Published public private(set) var isDetectingSourceLanguage = false
    private var detectionTask: Task<Void, Never>?
    private let languageDetector: any TextLanguageDetecting
    @Published public private(set) var unreadableIDs: [UUID] = []
    private var library = TextWorkspaceLibrary()
    private var generation: UUID?
    private var markdownDecoder: MarkdownResponseDecoder?
    private var markdownResponseBuffer = ""
    private var worker: Task<Void, Error>?
    private var credentialTask: Task<String?, Error>?
    private var saveTask: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var dirty = false
    private var configurationRevision: UInt64 = 0
    private var cancellationRevision: UInt64 = 0
    private var sourceRevision: UInt64 = 0
    private var targetRevision: UInt64 = 0
    private var configuredProvider: ProviderSnapshot?
    private var configuredResources: TranslationResourceLibrary?
    private weak var observedResources: TranslationResourceLibrary?
    private var resourceObservation: AnyCancellable?
    private var providerObservation: AnyCancellable?
    private weak var observedProviders: ProviderConfigurationSession?
    private let store: TextWorkspaceStore
    private let credentials: any ProviderCredentials
    private let service: any TextTranslating
    public init(store: TextWorkspaceStore, credentials: any ProviderCredentials, service: any TextTranslating, languageDetector: any TextLanguageDetecting = TextLanguageDetector()) {
        self.store = store; self.credentials = credentials; self.service = service; self.languageDetector = languageDetector
        do {
            let loaded = try store.load(); library = loaded.library
            workspace = library.workspace; history = library.history; unreadableIDs = loaded.unreadableIDs
            hasPendingSave = loaded.hasPendingSave; dirty = loaded.hasPendingSave
            if hasPendingSave || !unreadableIDs.isEmpty { error = .storage }
        } catch { self.error = .storage }
        refreshSourceDetection()
    }
    @discardableResult public func importMarkdown(from url: URL) -> Bool { importText(from: url, markdown: true) }
    /// Keep every imported original independently of later workspace replacement.
    @discardableResult public func importText(from url: URL, markdown: Bool? = nil) -> Bool {
        guard retrySaving() else { return false }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 10_000_000 else { error = .structure; return false }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= 10_000_000, let text = String(data: data, encoding: .utf8) else { error = .structure; return false }
            sourceChanged()
            var value = TextWorkspace(); value.direction = workspace.direction; value.sourceLanguageIsAutomatic = workspace.sourceLanguageIsAutomatic
            value.resourceSelection = workspace.resourceSelection
            value.isMarkdown = markdown ?? ["md", "markdown"].contains(url.pathExtension.lowercased())
            value.importedFileName = url.lastPathComponent; value.importedMarkdown = data; value.inputDraft = text
            library.imports.append(.init(id: UUID(), fileName: url.lastPathComponent, bytes: data))
            workspaceRevision = UUID(); let saved = persist(value, immediately: true); refreshSourceDetection(); return saved
        } catch { self.error = .storage; return false }
    }
    @discardableResult public func openHistory(_ id: UUID) -> Bool {
        guard history.contains(where: { $0.id == id }), retrySaving() else { return false }
        sourceChanged()
        guard let entry = history.first(where: { $0.id == id }) else { return false }
        var value = TextWorkspace(); value.inputDraft = entry.input; value.isMarkdown = entry.isMarkdown
        value.direction = entry.result.direction; value.currentResult = entry.result
        value.sourceLanguageIsAutomatic = entry.result.sourceWasAutomatic ?? false
        value.importedFileName = entry.importedFileName; value.importedMarkdown = entry.importedMarkdown
        value.resourceSelection = workspace.resourceSelection
        workspaceRevision = UUID(); let saved = persist(value); refreshSourceDetection(); return saved
    }
    public func observeDefaultProvider(_ providers: ProviderConfigurationSession, resources: TranslationResourceLibrary? = nil) {
        guard observedProviders !== providers || configuredResources !== resources else { return }
        observedProviders = providers
        providerObservation = providers.$profiles.combineLatest(providers.$defaults).sink { [weak self] profiles, defaults in
            self?.configureDefaultProvider(profiles.first { $0.id == defaults.textID }?.snapshot, resources: resources)
        }
    }
    /// Settings changes invalidate preflight only and never submit a request.
    public func configureDefaultProvider(_ provider: ProviderSnapshot?, resources: TranslationResourceLibrary? = nil) {
        let valid = provider.flatMap { try? $0.validated() }
        guard configuredProvider != valid || configuredResources !== resources else { return }
        providerConfigurationChanged(); configuredProvider = valid; configuredResources = resources
        observeResources(resources)
    }
    public func providerConfigurationChanged() {
        configurationRevision &+= 1
        if isRunning && worker == nil { stop() }
    }
    private func observeResources(_ library: TranslationResourceLibrary?) {
        guard observedResources !== library else { return }
        resourceObservation = nil; observedResources = library
        resourceObservation = library?.objectWillChange.sink { [weak self] _ in
            guard let self else { return }; self.configurationRevision &+= 1
            if self.isRunning && self.worker == nil { self.stop() }
        }
    }
    public func compositionBegan() { sourceChanged(); refreshSourceDetection() }
    private func sourceChanged() { sourceRevision &+= 1; if isRunning { stop() } }
    @discardableResult public func updateInput(text: String) -> Bool {
        sourceChanged(); var value = workspace; value.inputDraft = text; value.updatedAt = Date()
        let saved = persist(value); refreshSourceDetection(); return saved
    }
    @discardableResult public func setMarkdown(enabled: Bool) -> Bool {
        sourceChanged(); var value = workspace
        value.isMarkdown = enabled; let saved = persist(value); refreshSourceDetection(); return saved
    }
    @discardableResult public func setDirection(direction: TextTranslationDirection) -> Bool {
        sourceChanged(); var value = workspace
        value.direction = direction; value.sourceLanguageIsAutomatic = false
        let saved = persist(value); refreshSourceDetection(); return saved
    }
    @discardableResult public func selectResources(selection: TranslationResourceSelection) -> Bool {
        sourceChanged(); var value = workspace
        value.resourceSelection = selection; let saved = persist(value); refreshSourceDetection(); return saved
    }
    /// nil selects local automatic detection; concrete languages override it.
    @discardableResult public func setSourceLanguage(_ language: TranslationLanguage?) -> Bool {
        sourceChanged(); var value = workspace
        value.sourceLanguageIsAutomatic = language == nil
        if let language { value.direction = .init(sourceLanguage: language, targetLanguage: value.direction.targetLanguage) }
        let saved = persist(value); refreshSourceDetection(); return saved
    }
    @discardableResult public func setTargetLanguage(_ language: TranslationLanguage) -> Bool {
        sourceChanged(); var value = workspace
        value.direction = .init(sourceLanguage: value.direction.sourceLanguage, targetLanguage: language)
        let saved = persist(value); refreshSourceDetection(); return saved
    }
    @discardableResult public func swapLanguages() -> Bool {
        let source = workspace.automaticallyDetectsSourceLanguage ? detectedSourceLanguage : workspace.direction.sourceLanguage
        guard let source, !isDetectingSourceLanguage else { error = .languageUndetermined; return false }
        sourceChanged(); var value = workspace
        let old = value.inputDraft; value.inputDraft = value.translation; value.currentResult = nil; value.translationDraft = old
        value.direction = .init(sourceLanguage: value.direction.targetLanguage, targetLanguage: source)
        value.sourceLanguageIsAutomatic = false
        value.updatedAt = Date(); let saved = persist(value); refreshSourceDetection(); return saved
    }
    @discardableResult public func clear() -> Bool {
        sourceChanged(); var value = workspace
        value.inputDraft = ""; value.currentResult = nil; value.translationDraft = ""; workspaceRevision = UUID(); value.updatedAt = Date()
        let saved = persist(value); refreshSourceDetection(); return saved
    }
    private func refreshSourceDetection() {
        detectionTask?.cancel(); detectionTask = nil
        detectedSourceLanguage = nil; isDetectingSourceLanguage = false
        if error == .languageUndetermined { error = nil }
        guard workspace.automaticallyDetectsSourceLanguage, !workspace.inputDraft.isEmpty else { return }
        let revision = sourceRevision, sample = String(workspace.inputDraft.prefix(32_000)), markdown = workspace.isMarkdown
        let detector = languageDetector
        isDetectingSourceLanguage = true
        detectionTask = Task { [weak self] in
            let detected = await Task.detached(priority: .utility) {
                let prose = markdown ? MarkdownDocument(source: sample).leaves.map(\.source).joined(separator: "\n") : sample
                return detector.detectLanguage(in: prose)
            }.value
            guard let self, !Task.isCancelled, self.sourceRevision == revision, self.workspace.automaticallyDetectsSourceLanguage else { return }
            self.detectedSourceLanguage = detected; self.isDetectingSourceLanguage = false
            if let detected {
                var value = self.workspace
                value.direction = .init(sourceLanguage: detected, targetLanguage: value.direction.targetLanguage)
                _ = self.persist(value)
            }
        }
    }
    private func resolvedDirection(_ proposed: TextTranslationDirection) async -> TextTranslationDirection? {
        guard workspace.automaticallyDetectsSourceLanguage else { return proposed }
        let revision = sourceRevision, configuration = configurationRevision, target = targetRevision, cancellation = cancellationRevision
        await detectionTask?.value
        guard sourceRevision == revision, configurationRevision == configuration, targetRevision == target,
              cancellationRevision == cancellation, !Task.isCancelled else { return nil }
        guard let detectedSourceLanguage else { error = workspace.inputDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .emptyInput : .languageUndetermined; return nil }
        return .init(sourceLanguage: detectedSourceLanguage, targetLanguage: proposed.targetLanguage)
    }
    @discardableResult public func updateTranslation(text: String) -> Bool {
        var value = workspace
        if isRunning { stop(); value = workspace }
        targetRevision &+= 1
        if var result = value.currentResult {
            if var document = result.markdown {
                guard document.replaceTranslation(with: text) else { error = .structure; return false }
                result.markdown = document; result.currentText = document.translated
            } else { result.currentText = text }
            value.currentResult = result
        } else { value.translationDraft = text }
        value.updatedAt = Date(); return persist(value)
    }
    @discardableResult public func updateResult(resultID: UUID, text: String) -> Bool {
        guard workspace.currentResult?.id == resultID else { return false }
        return updateTranslation(text: text)
    }
    @discardableResult public func editMarkdownLeaf(resultID: UUID, leafID: UUID, text: String) -> Bool {
        updateMarkdown(resultID) { $0.editLeaf(id: leafID, text: text) }
    }
    @discardableResult public func mergeMarkdownGroup(resultID: UUID, groupID: UUID) -> Bool {
        guard workspace.currentResultMatchesWorkspace == true else { return false }
        return updateMarkdown(resultID) { $0.mergeWithNext(groupID) }
    }
    @discardableResult public func editMarkdownGroup(resultID: UUID, groupID: UUID, text: String) -> Bool {
        updateMarkdown(resultID) { $0.editGroup(id: groupID, text: text) }
    }
    private func updateMarkdown(_ resultID: UUID, edit: (inout MarkdownDocument) -> Bool) -> Bool {
        guard workspace.currentResult?.id == resultID else { return false }
        if isRunning { stop() }
        var value = workspace
        guard var document = value.currentResult?.markdown, edit(&document) else { error = .structure; return false }
        targetRevision &+= 1
        value.currentResult?.markdown = document; value.currentResult?.currentText = document.translated; value.updatedAt = Date()
        return persist(value)
    }
    public func markdownLeafText(resultID: UUID, leafID: UUID) -> String? {
        let leaf = markdownDocument(resultID)?.leaves.first { $0.id == leafID }; return leaf?.translation ?? leaf?.source
    }
    public func markdownGroupText(resultID: UUID, groupID: UUID) -> String? { markdownDocument(resultID)?.groups.first { $0.id == groupID }?.editedTranslation }
    private func markdownDocument(_ resultID: UUID) -> MarkdownDocument? {
        guard let result = workspace.currentResult, result.id == resultID else { return nil }; return result.markdown
    }
    public func text(resultID: UUID) -> String? {
        guard let result = workspace.currentResult, result.id == resultID else { return nil }; return result.currentText
    }
    public func bilingualText(resultID: UUID) -> String? {
        guard workspace.currentResultMatchesWorkspace else { return nil }
        return markdownDocument(resultID)?.bilingual
    }
    @discardableResult public func exportInput(to destination: URL) -> Bool { export(workspace.inputDraft, to: destination) }
    @discardableResult public func exportTranslation(to destination: URL) -> Bool { export(workspace.translation, to: destination) }
    @discardableResult public func exportText(resultID: UUID, to destination: URL) -> Bool { export(text(resultID: resultID), to: destination) }
    @discardableResult public func exportBilingual(resultID: UUID, to destination: URL) -> Bool { export(bilingualText(resultID: resultID), to: destination) }
    private func export(_ value: String?, to destination: URL) -> Bool {
        guard let value else { return false }; do { try store.export(value, to: destination); return true } catch { self.error = .storage; return false }
    }
    public func submit(provider: ProviderSnapshot, direction: TextTranslationDirection, resources: TranslationResourceLibrary? = nil) async {
        guard !Task.isCancelled, generation == nil, let direction = await resolvedDirection(direction) else { return }; let value = workspace
        observeResources(resources)
        let snapshot: TranslationResourceSnapshot?
        do {
            if let resources { snapshot = try resources.snapshot(value.resourceSelection ?? resources.selection(for: .text)) }
            else { guard value.resourceSelection == nil else { error = .resources; return }; snapshot = nil }
        } catch { self.error = .resources; return }
        await perform(input: value.inputDraft, provider: provider, direction: direction, markdown: value.isMarkdown == true, resources: snapshot)
    }
    public func retry() async {
        guard let result = workspace.currentResult, let direction = await resolvedDirection(workspace.direction) else { return }
        await perform(input: workspace.inputDraft, provider: result.provider, direction: direction, markdown: workspace.isMarkdown, resources: result.resources)
    }
    private func perform(input: String, provider: ProviderSnapshot, direction: TextTranslationDirection, markdown: Bool, resources: TranslationResourceSnapshot?) async {
        guard !Task.isCancelled, generation == nil else { return }
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = .emptyInput; return }
        do { _ = try provider.validated() } catch { self.error = .configuration; return }
        let submittedSourceRevision = sourceRevision, submittedTargetRevision = targetRevision, configuration = configurationRevision, cancellation = cancellationRevision
        guard await flushPendingSaves(), !Task.isCancelled, generation == nil, configurationRevision == configuration, cancellationRevision == cancellation,
              sourceRevision == submittedSourceRevision, targetRevision == submittedTargetRevision else { return }
        let token = UUID(); generation = token; isRunning = true; isAuthorizingCredential = true; error = nil
        let credentials = credentials
        let authorization = Task { try await credentials.readAsync(reference: provider.credentialReference) }; credentialTask = authorization
        let key: String
        do {
            let value = try await withTaskCancellationHandler { try await authorization.value } onCancel: { authorization.cancel() }
            guard generation == token else { return }; try Task.checkCancellation()
            guard let value, !value.isEmpty else { throw TextTranslationError.credential }; key = value
        } catch {
            guard generation == token else { return }; invalidateGeneration()
            if !(error is CancellationError || Task.isCancelled) { self.error = .credential }; return
        }
        credentialTask = nil; isAuthorizingCredential = false
        var value = workspace
        guard generation == token, configurationRevision == configuration,
              sourceRevision == submittedSourceRevision, targetRevision == submittedTargetRevision else { invalidateGeneration(); return }
        let document = markdown ? MarkdownDocument(source: input) : nil
        let result = TextTranslationResult(input: input, direction: direction, provider: provider, markdown: document, resources: resources, sourceWasAutomatic: value.automaticallyDetectsSourceLanguage)
        value.currentResult = result; value.translationDraft = ""; value.direction = direction
        runningResultID = result.id
        history.insert(.init(result: result, isMarkdown: markdown, importedFileName: value.importedFileName, importedMarkdown: value.importedMarkdown), at: 0)
        _ = persist(value)
        guard await flushPendingSaves(), generation == token, !Task.isCancelled else {
            if generation == token { invalidateGeneration(); finish(result.id, .failed, .storage) }; return
        }
        if document?.leaves.isEmpty == true { invalidateGeneration(); finish(result.id, .completed, nil); _ = await flushPendingSaves(); return }
        markdownDecoder = markdown ? MarkdownResponseDecoder() : nil; markdownResponseBuffer = ""
        let service = self.service
        let request = TextTranslationRequest(input: document?.requestPayload ?? input, direction: direction, provider: provider, responseContract: markdown ? MarkdownDocument.responseContract : nil, resources: resources)
        let worker = Task { [weak self] in
            try Task.checkCancellation()
            try await service.translate(request, apiKey: key) { [weak self] event in
                await self?.receive(event, result.id, token, submittedSourceRevision, submittedTargetRevision)
            }
        }; self.worker = worker
        do {
            try await withTaskCancellationHandler { try await worker.value } onCancel: { [weak self] in Task { @MainActor in if self?.generation == token { self?.stop() } } }
            guard generation == token else { return }
            let valid = !markdown || receiveMarkdown("", final: true, result.id)
            invalidateGeneration(); finish(result.id, valid ? .completed : .failed, valid ? nil : .structure)
        } catch {
            guard generation == token else { return }; invalidateGeneration()
            finish(result.id, .failed, error as? TextTranslationError ?? .network)
        }
        _ = await flushPendingSaves()
    }
    private func receive(_ event: TextTranslationEvent, _ resultID: UUID, _ token: UUID, _ sourceRevision: UInt64, _ targetRevision: UInt64) {
        guard generation == token, runningResultID == resultID,
              self.sourceRevision == sourceRevision, self.targetRevision == targetRevision,
              workspace.currentResult?.id == resultID else { return }
        var value = workspace
        if case .delta(let text) = event, value.currentResult?.markdown != nil {
            if !receiveMarkdown(text, resultID) { invalidateGeneration(); finish(resultID, .failed, .structure) }; return
        }
        switch event {
        case .delta(let text): value.currentResult?.generatedText += text; value.currentResult?.currentText += text
        case .usage(let usage): value.currentResult?.usage = usage
        }
        value.updatedAt = Date(); updateHistory(value.currentResult); _ = persist(value)
    }
    private func receiveMarkdown(_ delta: String, final: Bool = false, _ resultID: UUID) -> Bool {
        markdownResponseBuffer += delta
        let batch = markdownDecoder?.append(delta, final: final)
        // Incomplete NDJSON bytes do not change visible text or require a full
        // document render/save. A completed leaf, failure or final flush does.
        guard final || batch?.failure != nil || batch?.records.isEmpty == false else { return true }
        var value = workspace
        guard value.currentResult?.id == resultID, var document = value.currentResult?.markdown else { return false }
        var valid = batch?.failure == nil
        for (leafID, text) in batch?.records ?? [] { do { try document.apply(id: leafID, text: text) } catch { valid = false; break } }
        value.currentResult?.markdownResponse = markdownResponseBuffer
        value.currentResult?.markdown = document
        let translated = document.translated
        value.currentResult?.generatedText = translated; value.currentResult?.currentText = translated
        value.updatedAt = Date(); updateHistory(value.currentResult); _ = persist(value); return valid && (!final || document.isComplete)
    }
    public func stop() {
        let resultID = runningResultID
        invalidateGeneration()
        if let resultID { finish(resultID, .stopped, nil) }
    }
    private func finish(_ resultID: UUID, _ status: TextTranslationStatus, _ failure: TextTranslationError?) {
        var value = workspace
        guard value.currentResult?.id == resultID else { return }
        value.currentResult?.status = status; value.currentResult?.failure = failure; value.updatedAt = Date(); updateHistory(value.currentResult); _ = persist(value)
    }
    private func invalidateGeneration() {
        cancellationRevision &+= 1
        if isRunning, workspace.currentResult?.markdown != nil, !markdownResponseBuffer.isEmpty {
            var value = workspace
            value.currentResult?.markdownResponse = markdownResponseBuffer; updateHistory(value.currentResult); _ = persist(value)
        }
        markdownResponseBuffer = ""
        markdownDecoder = nil; credentialTask?.cancel(); credentialTask = nil; isAuthorizingCredential = false
        generation = nil; isRunning = false; runningResultID = nil
        let previous = worker; worker = nil; previous?.cancel()
    }
    private func updateHistory(_ result: TextTranslationResult?) {
        guard let result, let index = history.firstIndex(where: { $0.id == result.id }) else { return }
        history[index].result = result
    }
    public func prepareToQuit() -> Bool { retrySaving() }
    public func prepareForConfirmedQuit() -> Bool {
        guard retrySaving() else { return false }
        let resultID = runningResultID; invalidateGeneration()
        if let resultID { finish(resultID, .interrupted, .interrupted) }
        return retrySaving()
    }
    @discardableResult public func retrySaving() -> Bool {
        saveTask?.cancel(); saveTask = nil
        guard dirty || hasPendingSave else { return true }
        let savedRevision = revision
        do { try store.save(snapshot()); saved(savedRevision) }
        catch { hasPendingSave = true; self.error = .storage }
        return !hasPendingSave
    }
    @discardableResult public func flushPendingSaves() async -> Bool {
        saveTask?.cancel(); saveTask = nil
        guard dirty || hasPendingSave else { return true }
        let savedRevision = revision, value = snapshot()
        do { try await store.saveAsync(value); saved(savedRevision) }
        catch { if revision == savedRevision { hasPendingSave = true; self.error = .storage } }
        return !hasPendingSave && !dirty
    }
    private func snapshot() -> TextWorkspaceLibrary {
        var value = library; value.workspace = workspace; value.history = history; return value
    }
    @discardableResult private func persist(_ value: TextWorkspace, immediately: Bool = false) -> Bool {
        workspace = value; revision &+= 1; dirty = true
        if immediately { return retrySaving() }
        if saveTask == nil {
            saveTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                guard let self else { return }; self.saveTask = nil
                _ = await self.flushPendingSaves()
            }
        }
        return true
    }
    private func saved(_ savedRevision: UInt64) {
        guard revision == savedRevision else { return }
        dirty = false; hasPendingSave = false
        if unreadableIDs.isEmpty && error == .storage { error = nil }
    }
}
