import Combine
import Foundation

@MainActor public final class ProviderConfigurationSession: ObservableObject {
    @Published public private(set) var profiles: [ProviderProfile] = []
    @Published public private(set) var defaults = ProviderDefaults()
    @Published public private(set) var error: ProviderConfigurationError?
    @Published public private(set) var checkingProfileID: UUID?
    @Published public private(set) var authorizingProfileID: UUID?
    @Published public private(set) var isUpdatingCredentials = false
    @Published public private(set) var isCancellingCredentialAction = false
    @Published public private(set) var needsCredentialRecovery = false
    private var pendingCredentialRecovery: (@MainActor () async throws -> Void)?
    public var credentialTransactionsReadyForQuit: Bool { !isUpdatingCredentials && !needsCredentialRecovery }
    public func prepareToQuit() -> Bool { credentialTransactionsReadyForQuit }
    @Published public private(set) var credentialStates: [ProviderCredentialReference: ProviderCredentialAvailability] = [:]
    @Published public private(set) var connectionReports: [UUID: ProviderConnectionReport] = [:]
    private let store: ProviderConfigurationStore
    private let credentials: any ProviderCredentials
    private let checker: any ProviderConnectionChecking
    private var readable = false
    private var checkGeneration: UUID?
    private var credentialGeneration: UUID?
    private var credentialTask: Task<Void, Error>?
    private var connectionTask: Task<ProviderConnectionReport, Error>?
    public init(store: ProviderConfigurationStore, credentials: any ProviderCredentials, checker: any ProviderConnectionChecking) {
        self.store = store; self.credentials = credentials; self.checker = checker
        reload()
    }
    public func reload() {
        cancelCredentialAction()
        cancelConnectionCheck()
        do { let document = try store.load(); profiles = document.profiles; defaults = document.defaults; readable = true; error = nil }
        catch { self.error = .storage; readable = false }
    }
    /// Noninteractive compatibility entry point. Production settings use saveProfileAsync.
    @discardableResult public func saveProfile(id: UUID? = nil, name: String, baseURL: String, model: String, apiKey: String) -> ProviderProfile? {
        guard readable else { error = .storage; return nil }
        guard credentialTransactionsReadyForQuit else { return nil }
        do {
            let profile = try ProviderProfile(id: id ?? UUID(), name: name, baseURL: baseURL, model: model)
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else {
                throw ProviderConfigurationError.credential
            }
            var previousKey: String?
            if !key.isEmpty {
                do {
                    previousKey = try credentials.read(reference: profile.credentialReference)
                    try credentials.save(key, reference: profile.credentialReference)
                } catch { throw ProviderConfigurationError.credential }
            }
            var next = profiles
            if let index = next.firstIndex(where: { $0.id == profile.id }) { next[index] = profile }
            else { next.append(profile) }
            do { try store.save(ProviderConfigurationDocument(profiles: next, defaults: defaults)) }
            catch {
                if !key.isEmpty {
                    do {
                        if let previousKey { try credentials.save(previousKey, reference: profile.credentialReference) }
                        else { try credentials.delete(reference: profile.credentialReference) }
                    } catch { throw ProviderConfigurationError.credential }
                }
                throw ProviderConfigurationError.storage
            }
            if checkingProfileID == profile.id { cancelConnectionCheck() }
            connectionReports[profile.id] = nil
            profiles = next; error = nil
            if !key.isEmpty { credentialStates[profile.credentialReference] = .available }
            return profile
        } catch { self.error = error as? ProviderConfigurationError ?? .storage; return nil }
    }
    public func setDefault(_ id: UUID?, for use: ProviderUse) {
        guard readable else { error = .storage; return }
        guard id == nil || profiles.contains(where: { $0.id == id }) else { error = .configuration; return }
        var next = defaults
        switch use { case .text: next.textID = id; case .pdf: next.pdfID = id }
        do { try store.save(ProviderConfigurationDocument(profiles: profiles, defaults: next)); defaults = next; error = nil }
        catch { self.error = .storage }
    }
    /// Remove a selectable configuration atomically with its default references.
    /// Credentials remain target-bound in Keychain: already submitted tasks may
    /// still need them, and deleting a profile must not revoke those requests.
    @discardableResult public func deleteProfile(_ id: UUID, submittedSnapshot: ProviderSnapshot? = nil) -> Bool {
        guard readable else { error = .storage; return false }
        guard credentialTransactionsReadyForQuit else { return false }
        guard let current = profiles.first(where: { $0.id == id }),
              submittedSnapshot == nil || submittedSnapshot == current.snapshot else { error = .configuration; return false }
        let nextProfiles = profiles.filter { $0.id != id }
        var nextDefaults = defaults
        if nextDefaults.textID == id { nextDefaults.textID = nil }
        if nextDefaults.pdfID == id { nextDefaults.pdfID = nil }
        do { try store.save(.init(profiles: nextProfiles, defaults: nextDefaults)) }
        catch { self.error = .storage; return false }
        if checkingProfileID == id { cancelConnectionCheck() }
        connectionReports[id] = nil
        // Publish defaults before profiles so consumers invalidate a selected
        // default before observing that its profile disappeared.
        defaults = nextDefaults; profiles = nextProfiles; error = nil
        return true
    }
    public func snapshot(for id: UUID) throws -> ProviderSnapshot {
        guard readable, let profile = profiles.first(where: { $0.id == id }) else { throw ProviderConfigurationError.configuration }
        return profile.snapshot
    }
    /// Presentation only: opening settings must never trigger a Keychain read.
    public func credentialAvailability(for id: UUID) -> ProviderCredentialAvailability {
        guard let snapshot = try? snapshot(for: id) else { return .unchecked }
        return credentialStates[snapshot.credentialReference] ?? .unchecked
    }
    public func hasCredential(for id: UUID) -> Bool { credentialAvailability(for: id) == .available }
    /// Noninteractive compatibility entry point. Production settings use the async operation.
    public func removeCredential(for id: UUID) {
        guard credentialTransactionsReadyForQuit else { return }
        do {
            let snapshot = try snapshot(for: id)
            try credentials.delete(reference: snapshot.credentialReference)
            if checkingProfileID == id { cancelConnectionCheck() }
            connectionReports[id] = nil; credentialStates[snapshot.credentialReference] = .missing
            error = nil
        } catch { self.error = .credential }
    }
    @discardableResult public func saveProfileAsync(id: UUID? = nil, name: String, baseURL: String, model: String, apiKey: String) async -> ProviderProfile? {
        guard readable, credentialTransactionsReadyForQuit, !Task.isCancelled else { return nil }
        let profile: ProviderProfile
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            profile = try ProviderProfile(id: id ?? UUID(), name: name, baseURL: baseURL, model: model)
            guard key.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else { throw ProviderConfigurationError.credential }
        } catch { self.error = error as? ProviderConfigurationError ?? .configuration; return nil }
        let original = profiles.first { $0.id == profile.id }
        let generation = UUID(), credentials = credentials
        credentialGeneration = generation; isUpdatingCredentials = true; isCancellingCredentialAction = false; error = nil
        if checkingProfileID == profile.id { cancelConnectionCheck() }
        let work = Task { [self] in
            var previousKey: String?, wroteKey = false
            do {
                if !key.isEmpty {
                    previousKey = try await credentials.readAsync(reference: profile.credentialReference)
                    try Task.checkCancellation()
                    guard credentialGeneration == generation else { throw CancellationError() }
                    try await credentials.saveAsync(key, reference: profile.credentialReference)
                    wroteKey = true
                }
                try Task.checkCancellation()
                guard credentialGeneration == generation, readable, profiles.first(where: { $0.id == profile.id }) == original else { throw CancellationError() }
                var next = profiles
                if let index = next.firstIndex(where: { $0.id == profile.id }) { next[index] = profile } else { next.append(profile) }
                do { try store.save(.init(profiles: next, defaults: defaults)) }
                catch { throw ProviderConfigurationError.storage }
                profiles = next; connectionReports[profile.id] = nil
                if !key.isEmpty { credentialStates[profile.credentialReference] = .available }
            } catch {
                // A started system write cannot be interrupted. Restore its old
                // scoped value before allowing another settings transaction.
                if wroteKey {
                    let restore: @MainActor () async throws -> Void = { [weak self] in
                        if let previousKey { try await credentials.saveAsync(previousKey, reference: profile.credentialReference) }
                        else { try await credentials.deleteAsync(reference: profile.credentialReference) }
                        self?.credentialStates[profile.credentialReference] = previousKey?.isEmpty == false ? .available : .missing
                    }
                    pendingCredentialRecovery = restore; needsCredentialRecovery = true
                    let recovery = Task { try await restore() }
                    do { try await recovery.value; pendingCredentialRecovery = nil; needsCredentialRecovery = false }
                    catch { credentialStates[profile.credentialReference] = .inaccessible; throw ProviderConfigurationError.credential }
                }
                throw error
            }
        }
        credentialTask = work
        defer { credentialTask = nil; credentialGeneration = nil; isUpdatingCredentials = false; isCancellingCredentialAction = false }
        do {
            try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            error = nil; return profile
        } catch {
            self.error = needsCredentialRecovery ? .credential : (error is CancellationError || Task.isCancelled ? .interrupted : (error as? ProviderConfigurationError ?? .credential))
            return nil
        }
    }
    public func removeCredentialAsync(for id: UUID, submittedSnapshot: ProviderSnapshot? = nil) async {
        guard credentialTransactionsReadyForQuit, !Task.isCancelled, let current = try? snapshot(for: id) else { return }
        let submitted = submittedSnapshot ?? current
        guard submitted == current else { error = .configuration; return }
        let generation = UUID(), credentials = credentials
        credentialGeneration = generation; isUpdatingCredentials = true; isCancellingCredentialAction = false; error = nil
        if checkingProfileID == id { cancelConnectionCheck() }
        let work = Task { try await credentials.deleteAsync(reference: submitted.credentialReference) }
        credentialTask = work
        defer { credentialTask = nil; credentialGeneration = nil; isUpdatingCredentials = false; isCancellingCredentialAction = false }
        do {
            try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, credentialGeneration == generation else { credentialStates[submitted.credentialReference] = .unchecked; return }
            credentialStates[submitted.credentialReference] = .missing
            if (try? snapshot(for: id)) == submitted { connectionReports[id] = nil }
            error = nil
        } catch { self.error = error is CancellationError || Task.isCancelled ? .interrupted : .credential }
    }
    public func cancelCredentialAction() {
        guard isUpdatingCredentials, !needsCredentialRecovery else { return }
        isCancellingCredentialAction = true
        credentialGeneration = nil; credentialTask?.cancel(); error = .interrupted
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
    public func checkConnection(for id: UUID, submittedSnapshot: ProviderSnapshot? = nil) async {
        guard checkingProfileID == nil, credentialTransactionsReadyForQuit, !Task.isCancelled else { return }
        do {
            let current = try snapshot(for: id), generation = UUID()
            let submitted = submittedSnapshot ?? current
            guard submitted == current else { throw ProviderConfigurationError.configuration }
            checkGeneration = generation; checkingProfileID = id; authorizingProfileID = id
            connectionReports[id] = nil; error = nil
            let checker = checker, credentials = credentials
            let work = Task { [self] in
                let key: String
                do {
                    guard let value = try await credentials.readAsync(reference: submitted.credentialReference), !value.isEmpty else {
                        if checkGeneration == generation, !Task.isCancelled { credentialStates[submitted.credentialReference] = .missing }
                        throw ProviderConfigurationError.credential
                    }
                    key = value
                } catch {
                    if error is CancellationError { throw error }
                    throw ProviderConfigurationError.credential
                }
                try Task.checkCancellation()
                guard checkGeneration == generation, (try? snapshot(for: id)) == submitted else { throw CancellationError() }
                authorizingProfileID = nil; credentialStates[submitted.credentialReference] = .available
                return try await checker.check(snapshot: submitted, apiKey: key)
            }
            connectionTask = work
            defer {
                if checkGeneration == generation { checkingProfileID = nil; authorizingProfileID = nil; checkGeneration = nil; connectionTask = nil }
            }
            do {
                let report = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard checkGeneration == generation else { return }
                try Task.checkCancellation()
                connectionReports[id] = report
            } catch {
                guard checkGeneration == generation else { return }
                self.error = error is CancellationError || Task.isCancelled ? .interrupted : (error as? ProviderConfigurationError ?? .network)
            }
        } catch { self.error = error as? ProviderConfigurationError ?? .network }
    }
    public func cancelConnectionCheck() {
        guard checkingProfileID != nil else { return }
        connectionTask?.cancel()
        connectionTask = nil
        checkGeneration = nil
        checkingProfileID = nil; authorizingProfileID = nil
        error = .interrupted
    }
    public func dismissError() { error = nil }
}
