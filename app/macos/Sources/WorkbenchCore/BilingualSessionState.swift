import Combine
import Foundation

/// One observable presentation and result owner for both windows. Capture and
/// service ownership stay outside this object; opening a window does no work.
@MainActor public final class BilingualSessionState: ObservableObject {
    @Published public private(set) var result: BilingualResult?
    @Published public private(set) var cloudState: LiveCloudState = .idle
    @Published public private(set) var followsLatest = true
    @Published public private(set) var needsSaveRetry = false
    @Published public private(set) var firstSourceLatency: TimeInterval?
    @Published public private(set) var firstTranslationLatency: TimeInterval?
    @Published public var fontSize: Double = 24
    @Published public var visibleChannels: Set<BilingualChannel> = Set(BilingualChannel.allCases)
    private var generation = UUID()
    private var began = Date()
    private var connectionStartFrame: Int64 = 0
    private var historyEditors: [UUID: BilingualHistorySession] = [:]
    private var historyObservations: [UUID: AnyCancellable] = [:]
    private let now: () -> Date
    private let save: (BilingualResult) throws -> BilingualResult
    public init(now: @escaping () -> Date = Date.init, save: @escaping (BilingualResult) throws -> BilingualResult) {
        self.now = now; self.save = save
    }
    /// Editors survive navigation and retain failed writes until explicit save or discard.
    public func history(recordingID: UUID, store: BilingualResultStore) -> BilingualHistorySession {
        if let existing = historyEditors[recordingID] { return existing }
        let editor = BilingualHistorySession(recordingID: recordingID, store: store)
        historyEditors[recordingID] = editor
        historyObservations[recordingID] = editor.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return editor
    }
    public var hasUnsavedHistoryEdits: Bool { historyEditors.values.contains { $0.hasUnsavedChanges } }
    public func hasUnsavedHistoryEdits(for recordingID: UUID) -> Bool { historyEditors[recordingID]?.hasUnsavedChanges == true }
    public func resultWasDeleted(recordingID: UUID, resultID: UUID) {
        historyEditors[recordingID]?.reload()
        guard result?.recordingID == recordingID, result?.id == resultID else { return }
        generation = UUID(); result = nil; cloudState = .idle; needsSaveRetry = false; followsLatest = true
        firstSourceLatency = nil; firstTranslationLatency = nil
    }
    /// Call only after the managed material has been durably removed. Pending
    /// editors and active capture must be checked by the deletion coordinator.
    public func forgetMaterial(_ recordingID: UUID) {
        if let value = result, value.recordingID == recordingID {
            resultWasDeleted(recordingID: recordingID, resultID: value.id)
        }
        historyEditors.removeValue(forKey: recordingID)
        historyObservations.removeValue(forKey: recordingID)
    }
    /// Pre-confirmation save check; an unfinished observation is stopped only
    /// after the owner confirms quitting, never mistaken for a disk failure.
    public func prepareEditsForQuit() -> Bool {
        if needsSaveRetry { retrySave() }
        for editor in historyEditors.values where editor.hasUnsavedChanges {
            if let saved = editor.save(), result?.id == saved.id { reopen(saved) }
        }
        return !needsSaveRetry && !hasUnsavedHistoryEdits
    }
    public func prepareToQuit() -> Bool {
        prepareEditsForQuit() && canReplaceResult
    }
    public var document: BilingualTranscriptDocument { result?.document ?? .init() }
    public var canReplaceResult: Bool { !isActive && !needsSaveRetry && (result == nil || result?.document.isFinished == true) }
    public var isActive: Bool { [.connecting, .connected, .reconnecting, .finishing].contains(cloudState) }
    /// Observes an already-owned audio session. This never starts capture or
    /// opens a connection, and cannot grant a provider verified capability.
    public func beginObservation(recordingID: UUID, configuration: AudioServiceConfiguration,
                                 direction: TextTranslationDirection, connectionStartFrame: Int64 = 0,
                                 generation token: UUID = UUID()) -> UUID? {
        guard !isActive, !needsSaveRetry, result == nil || result?.document.isFinished == true, connectionStartFrame >= 0,
              let validated = try? configuration.validated() else { return nil }
        generation = token; began = now(); self.connectionStartFrame = connectionStartFrame
        result = .init(recordingID: recordingID, createdAt: began, configuration: validated,
                       direction: direction, document: .init())
        cloudState = .connecting; followsLatest = true
        firstSourceLatency = nil; firstTranslationLatency = nil
        return generation
    }
    /// A connection change keeps the same result, text and recording. Only the
    /// capture owner may choose its original-media origin after attaching audio.
    public func beginReconnection(generation token: UUID) {
        guard let result, !result.document.isFinished, !needsSaveRetry else { return }
        generation = token; cloudState = .reconnecting
    }
    public func setConnectionStartFrame(_ frame: Int64, generation token: UUID) {
        guard token == generation, isActive, frame >= 0 else { return }
        connectionStartFrame = frame
    }
    public func receive(_ event: LiveTranslationEvent, generation token: UUID) {
        guard token == generation, isActive, var value = result else { return }
        switch event {
        case .configured: if cloudState == .connecting || cloudState == .reconnecting { cloudState = .connected }
        case let .text(channel, eventID, delta, elapsed):
            value.document.append(delta, channel: channel, eventID: token.uuidString + ":" + eventID,
                                  elapsedMilliseconds: elapsed, connectionStartFrame: connectionStartFrame)
            if !delta.isEmpty {
                if channel == .source, firstSourceLatency == nil { firstSourceLatency = now().timeIntervalSince(began) }
                if channel == .translation, firstTranslationLatency == nil { firstTranslationLatency = now().timeIntervalSince(began) }
            }
            result = value
        case .closed: finish(confirmedChannels: Set(BilingualChannel.allCases))
        case .failed: cloudState = .failed
        case .ignored: break
        }
    }
    public func beginFinishing() { if isActive { cloudState = .finishing } }
    /// Pausing releases the cloud connection without ending or replacing its result.
    func suspendCloud(generation token: UUID) {
        guard generation == token, let result, !result.document.isFinished else { return }
        generation = UUID(); cloudState = .idle
    }
    public func markMissing(_ intervals: [MissingInterval], channel: BilingualChannel) {
        guard var value = result, !value.document.isFinished else { return }
        value.document.addMissing(intervals, channel: channel); result = value
    }
    public func finish(confirmedChannels: Set<BilingualChannel> = []) {
        guard var value = result, !value.document.isFinished else { return }
        generation = UUID(); value.document.finish(completedChannels: cloudState == .failed ? [] : confirmedChannels); result = value
        if cloudState != .failed { cloudState = .completed }
        retrySave()
    }
    public func editPending(_ text: String, channel: BilingualChannel) {
        guard needsSaveRetry, var value = result else { return }
        value.document.edit(text, channel: channel); result = value
    }
    public func retrySave() {
        guard let value = result, value.document.isFinished else { return }
        do { result = try save(value); needsSaveRetry = false }
        catch { needsSaveRetry = true }
    }
    public func reviewEarlierText() { followsLatest = false }
    public func returnToLatest() { followsLatest = true }
    public func reopen(_ saved: BilingualResult?) {
        guard !isActive, !needsSaveRetry, saved == nil || saved?.document.isFinished == true,
              result == nil || result?.document.isFinished == true else { return }
        generation = UUID(); result = saved; cloudState = saved == nil ? .idle : .completed; followsLatest = saved == nil
        firstSourceLatency = nil; firstTranslationLatency = nil
    }
}
