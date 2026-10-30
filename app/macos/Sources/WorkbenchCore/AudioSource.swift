import Foundation

public struct AudioApplication: Codable, Hashable, Identifiable, Sendable {
    public let bundleIdentifier: String
    public let name: String
    public let processID: Int32
    public let launchDate: Date?

    public var id: String {
        "\(bundleIdentifier):\(processID):\(launchDate?.timeIntervalSince1970.description ?? "unknown")"
    }

    public init(bundleIdentifier: String, name: String, processID: Int32, launchDate: Date?) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.processID = processID
        self.launchDate = launchDate
    }
}

/// A persistent hardware identity, rather than a transient Core Audio device ID.
public struct AudioInputDevice: Codable, Hashable, Identifiable, Sendable {
    public let uid: String
    public let name: String
    public var id: String { uid }

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

public enum AudioSource: Codable, Hashable, Sendable {
    case microphone
    case microphoneDevice(AudioInputDevice)
    case system
    case application(AudioApplication)

    public var isMicrophone: Bool {
        switch self {
        case .microphone, .microphoneDevice: return true
        case .system, .application: return false
        }
    }
}
