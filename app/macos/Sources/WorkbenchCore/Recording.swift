import Foundation

public enum RecordingWorkflow: String, Codable, CaseIterable, Sendable {
    case transcription, liveTranslation
}

public enum RecordingStatus: String, Codable {
    case recording, paused, saved, interrupted
}

public enum RecordingInterruptionReason: String, Codable {
    case systemSleep, unexpectedTermination, captureFailure
}

public struct Recording: Identifiable, Codable, Equatable {
    public let id: UUID
    public let startedAt: Date
    public let defaultName: String
    public let source: AudioSource
    public var importedExtension: String? = nil
    public var isImported: Bool { importedExtension != nil }
    public var name: String
    public var duration: TimeInterval
    public var status: RecordingStatus
    public var interruptionReason: RecordingInterruptionReason?
    public var workflow: RecordingWorkflow
    // Only legacy metadata needs file-based inference; explicit values win.
    var needsWorkflowMigration = false

    public init(id: UUID, startedAt: Date, defaultName: String, name: String, duration: TimeInterval, status: RecordingStatus, source: AudioSource = .microphone, interruptionReason: RecordingInterruptionReason? = nil, workflow: RecordingWorkflow = .transcription) {
        self.id = id
        self.startedAt = startedAt
        self.defaultName = defaultName
        self.source = source
        self.name = name
        self.duration = duration
        self.status = status
        self.interruptionReason = interruptionReason
        self.workflow = workflow
    }

    private enum CodingKeys: String, CodingKey {
        case id, startedAt, defaultName, source, name, duration, status, interruptionReason, importedExtension, workflow
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        defaultName = try values.decode(String.self, forKey: .defaultName)
        source = try values.decodeIfPresent(AudioSource.self, forKey: .source) ?? .microphone
        importedExtension = try values.decodeIfPresent(String.self, forKey: .importedExtension)
        name = try values.decode(String.self, forKey: .name)
        duration = try values.decode(TimeInterval.self, forKey: .duration)
        status = try values.decode(RecordingStatus.self, forKey: .status)
        interruptionReason = try values.decodeIfPresent(RecordingInterruptionReason.self, forKey: .interruptionReason)
        let storedWorkflow = try values.decodeIfPresent(RecordingWorkflow.self, forKey: .workflow)
        workflow = storedWorkflow ?? .transcription
        needsWorkflowMigration = storedWorkflow == nil
    }
}

@MainActor public protocol AudioRecording: AnyObject {
    var currentTime: TimeInterval { get }
    var power: Float { get }
    var onFailure: ((Error) -> Void)? { get set }
    var onLiveAudio: (@Sendable (LiveAudioChunk) -> Void)? { get set }
    var onLiveAudioFailure: (@Sendable (Error) -> Void)? { get set }
    func requestPermission(for source: AudioSource) async throws
    func start(at url: URL, source: AudioSource) async throws
    func pause() async throws
    func resume() async throws
    func stop() -> TimeInterval
}

public extension AudioRecording {
    var onLiveAudioFailure: (@Sendable (Error) -> Void)? {
        get { nil }
        set { }
    }
    var onLiveAudio: (@Sendable (LiveAudioChunk) -> Void)? {
        get { nil }
        set { }
    }
}
