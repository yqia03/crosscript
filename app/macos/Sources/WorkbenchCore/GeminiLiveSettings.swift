import Combine
import Foundation

/// A separate credential target for Google's native live translation protocol.
/// Opening the app or settings never reads a credential or starts a request.
@MainActor public final class GeminiLiveSettings: ObservableObject {
    public let configuration = AudioServiceConfiguration(provider: .gemini)
    @Published public private(set) var credentialAvailability: PostRecordingSession.CredentialAvailability = .unchecked
    @Published public private(set) var error: AudioProcessingError?
    @Published public private(set) var isUpdating = false
    private let credentials: any AudioCredentials

    public init(credentials: any AudioCredentials) { self.credentials = credentials }

    @discardableResult public func saveCredential(_ value: String) async -> Bool {
        guard !isUpdating else { return false }
        isUpdating = true; defer { isUpdating = false }
        error = nil
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if !key.isEmpty {
                try await credentials.saveAsync(key, for: configuration)
                credentialAvailability = .available
            } else {
                let existing = try await credentials.readAsync(for: configuration)
                credentialAvailability = existing?.isEmpty == false ? .available : .missing
            }
            return true
        } catch {
            credentialAvailability = .inaccessible
            self.error = .credential
            return false
        }
    }

    @discardableResult public func removeCredential() async -> Bool {
        guard !isUpdating else { return false }
        isUpdating = true; defer { isUpdating = false }
        error = nil
        do {
            try await credentials.deleteAsync(for: configuration)
            credentialAvailability = .missing
            return true
        } catch {
            self.error = .credential
            return false
        }
    }
}
