/// Connection state shared by the bilingual presentation and its audio owner.
public enum LiveCloudState: String, Sendable { case idle, connecting, reconnecting, connected, finishing, completed, failed }

public enum LiveCloudFailureReason: String, Sendable {
    case captureConversion, audioBacklog, credentials, connection, protocolFailure, cancelled, responseTimeout, uploadTimeout
}

public enum LiveAudioClockError: Error { case invalidClock }
