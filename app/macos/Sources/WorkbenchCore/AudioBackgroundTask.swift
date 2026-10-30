import Foundation

/// A submitted audio operation. Contains only non-secret request configuration.
public struct AudioBackgroundTask: Identifiable, Codable, Equatable {
    public enum Status: String, Codable {
        case queued, running, completed, failed, cancelled, interrupted, awaitingResume, awaitingLocalSave
        public var occupiesMaterial: Bool {
            switch self {
            case .queued, .running, .interrupted, .awaitingResume, .awaitingLocalSave: return true
            case .completed, .failed, .cancelled: return false
            }
        }
    }
    public let id: UUID
    public let recordingID: UUID
    public let createdAt: Date
    public let configuration: AudioServiceConfiguration
    public let credentialScope: String
    public let requestTimestamps: Bool
    public var attemptID: UUID
    public var status: Status
    public var completedChunks: Int = 0
    public var failure: AudioProcessingError?
    public var diagnostics: AudioFailureDiagnostics?
    public var completionAfterSaving: Status?

    init(recordingID: UUID, configuration: AudioServiceConfiguration, requestTimestamps: Bool) {
        id = UUID()
        self.recordingID = recordingID
        createdAt = Date()
        self.configuration = configuration
        credentialScope = configuration.credentialScope
        self.requestTimestamps = requestTimestamps
        attemptID = UUID()
        status = .queued
    }
}
