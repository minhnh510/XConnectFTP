//
//  AppleSync.swift
//  XConnectFTP
//
//  Created by Codex on 21/3/26.
//

import AuthenticationServices
import CloudKit
import Combine
import Foundation

enum AppleAccountSignInState: Equatable {
    case signedOut
    case signedIn(displayName: String?, email: String?)

    var isSignedIn: Bool {
        if case .signedIn = self {
            return true
        }
        return false
    }

    var displayDescription: String {
        switch self {
        case .signedOut:
            return "Not signed in.".localized
        case .signedIn(let displayName, let email):
            if let displayName, !displayName.isEmpty {
                return displayName
            }
            if let email, !email.isEmpty {
                return email
            }
            return "Apple account connected.".localized
        }
    }
}

enum AppleCloudAvailability: Equatable {
    case checking
    case available
    case noAccount
    case restricted
    case temporarilyUnavailable
    case unavailable

    var description: String {
        switch self {
        case .checking:
            return "Checking iCloud availability…".localized
        case .available:
            return "iCloud is available for sync.".localized
        case .noAccount:
            return "No iCloud account is available for sync on this Mac.".localized
        case .restricted:
            return "iCloud sync is restricted on this Mac.".localized
        case .temporarilyUnavailable:
            return "iCloud sync is temporarily unavailable.".localized
        case .unavailable:
            return "iCloud sync status could not be determined.".localized
        }
    }
}

enum AppleSyncError: LocalizedError {
    case productionSchemaUnavailable
    case quotaExceeded

    var errorDescription: String? {
        switch self {
        case .productionSchemaUnavailable:
            return "iCloud sync could not be enabled because the CloudKit production schema for saved sites has not been deployed. Saved sites were kept on this Mac and iCloud sync was turned off.".localized
        case .quotaExceeded:
            return "iCloud storage quota has been exceeded. Saved sites were kept on this Mac and iCloud sync was turned off. Free up iCloud storage, then turn sync on again.".localized
        }
    }
}

enum AppleSyncResolution {
    case noChange
    case applyRemote(ConnectionProfilesSnapshot)
    case uploadedLocal
}

actor SavedSitesCloudSyncService {
    private static let containerIdentifier = "iCloud.vn.xconnect.XConnectFTP"
    private static let recordType = "SavedSitesSnapshot"
    private static let payloadField = "profilesPayload"
    private static let updatedAtField = "updatedAt"

    private let container = CKContainer(identifier: containerIdentifier)
    private let recordID = CKRecord.ID(recordName: "default-saved-sites")

    func accountStatus() async -> CKAccountStatus {
        await withCheckedContinuation { continuation in
            container.accountStatus { status, _ in
                continuation.resume(returning: status)
            }
        }
    }

    func fetchSnapshot() async throws -> ConnectionProfilesSnapshot? {
        let database = container.privateCloudDatabase

        return try await withCheckedThrowingContinuation { continuation in
            database.fetch(withRecordID: recordID) { record, error in
                if let ckError = error as? CKError, ckError.code == .unknownItem {
                    continuation.resume(returning: nil)
                    return
                }

                if let error {
                    continuation.resume(throwing: Self.normalizedCloudError(error))
                    return
                }

                guard let record,
                      let payload = record[Self.payloadField] as? Data,
                      let updatedAt = record[Self.updatedAtField] as? Date else {
                    continuation.resume(returning: nil)
                    return
                }

                do {
                    let profiles = try JSONDecoder().decode([ConnectionProfile].self, from: payload)
                    continuation.resume(
                        returning: ConnectionProfilesSnapshot(
                            profiles: profiles,
                            updatedAt: updatedAt
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func save(snapshot: ConnectionProfilesSnapshot) async throws {
        let database = container.privateCloudDatabase
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record[Self.payloadField] = try JSONEncoder().encode(snapshot.profiles) as NSData
        record[Self.updatedAtField] = snapshot.updatedAt as NSDate

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            database.save(record) { savedRecord, error in
                if let error {
                    continuation.resume(throwing: Self.normalizedCloudError(error))
                    return
                }
                _ = savedRecord
                continuation.resume()
            }
        }
    }

    private static func normalizedCloudError(_ error: Error) -> Error {
        if let ckError = error as? CKError {
            if ckError.isProductionSchemaRejection {
                return AppleSyncError.productionSchemaUnavailable
            }

            if ckError.isQuotaExceeded {
                return AppleSyncError.quotaExceeded
            }
        }

        if error.cloudDiagnosticMessages.contains(where: { message in
            message.localizedCaseInsensitiveContains("quota exceeded")
        }) {
            return AppleSyncError.quotaExceeded
        }

        return error
    }
}

private extension CKError {
    var isProductionSchemaRejection: Bool {
        guard code == .serverRejectedRequest else {
            return false
        }

        return cloudDiagnosticMessages.contains { message in
            message.localizedCaseInsensitiveContains("production schema")
        }
    }

    var isQuotaExceeded: Bool {
        code == .quotaExceeded
    }
}

private extension Error {
    var cloudDiagnosticMessages: [String] {
        let nsError = self as NSError
        return [localizedDescription] + nsError.userInfo.values.compactMap { value in
            if let message = value as? String {
                return message
            }
            if let error = value as? NSError {
                return error.localizedDescription
            }
            return nil
        }
    }
}

@MainActor
final class AppleSyncController: ObservableObject {
    private enum DefaultsKey {
        static let appleUserID = "appleSync.appleUserID"
        static let appleEmail = "appleSync.appleEmail"
        static let appleDisplayName = "appleSync.appleDisplayName"
        static let syncEnabled = "appleSync.syncEnabled"
    }

    private let defaults: UserDefaults
    private let cloudService: SavedSitesCloudSyncService
    private let credentialProvider = ASAuthorizationAppleIDProvider()

    @Published private(set) var signInState: AppleAccountSignInState
    @Published private(set) var cloudAvailability: AppleCloudAvailability = .checking
    @Published private(set) var syncEnabled: Bool
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var syncErrorMessage: String?
    @Published private(set) var syncGeneration = UUID()

    init(
        defaults: UserDefaults = .standard,
        cloudService: SavedSitesCloudSyncService = SavedSitesCloudSyncService()
    ) {
        self.defaults = defaults
        self.cloudService = cloudService
        self.syncEnabled = defaults.bool(forKey: DefaultsKey.syncEnabled)

        let displayName = defaults.string(forKey: DefaultsKey.appleDisplayName)
        let email = defaults.string(forKey: DefaultsKey.appleEmail)
        let userID = defaults.string(forKey: DefaultsKey.appleUserID)
        if let userID, !userID.isEmpty {
            self.signInState = .signedIn(displayName: displayName, email: email)
        } else {
            self.signInState = .signedOut
        }

        Task {
            await restoreState()
        }
    }

    var canEnableSiteSync: Bool {
        signInState.isSignedIn && cloudAvailability == .available
    }

    var syncStatusDescription: String? {
        if isSyncing {
            return "Syncing saved sites…".localized
        }
        if let syncErrorMessage, !syncErrorMessage.isEmpty {
            return syncErrorMessage
        }
        if let lastSyncAt {
            let formatter = DateFormatter()
            formatter.locale = AppLanguage.current.locale
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return L10n.format("Last synced at %@.", formatter.string(from: lastSyncAt))
        }
        return nil
    }

    var syncMetadataDescription: String {
        "Saved site metadata, including the preferred local root path, syncs with iCloud. Passwords remain in the local Keychain on this Mac, and local folder access permission stays on each Mac.".localized
    }

    func configureAppleIDRequest(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.fullName, .email]
    }

    func handleAuthorizationResult(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                syncErrorMessage = "Could not read the Apple account credential.".localized
                return
            }

            let formatter = PersonNameComponentsFormatter()
            let displayName = formatter.string(from: credential.fullName ?? PersonNameComponents())
            let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let storedDisplayName = trimmedName.isEmpty
                ? defaults.string(forKey: DefaultsKey.appleDisplayName)
                : trimmedName
            let storedEmail = credential.email ?? defaults.string(forKey: DefaultsKey.appleEmail)

            defaults.set(credential.user, forKey: DefaultsKey.appleUserID)
            defaults.set(storedDisplayName, forKey: DefaultsKey.appleDisplayName)
            defaults.set(storedEmail, forKey: DefaultsKey.appleEmail)

            signInState = .signedIn(displayName: storedDisplayName, email: storedEmail)
            syncErrorMessage = nil
            updateSyncEnabled(true)

            Task {
                await refreshCloudAvailability()
            }

        case .failure(let error):
            if let authorizationError = error as? ASAuthorizationError, authorizationError.code == .canceled {
                return
            }
            syncErrorMessage = error.localizedDescription
        }
    }

    func signOut() {
        defaults.removeObject(forKey: DefaultsKey.appleUserID)
        defaults.removeObject(forKey: DefaultsKey.appleDisplayName)
        defaults.removeObject(forKey: DefaultsKey.appleEmail)
        defaults.set(false, forKey: DefaultsKey.syncEnabled)

        signInState = .signedOut
        syncEnabled = false
        isSyncing = false
        lastSyncAt = nil
        syncErrorMessage = nil
        syncGeneration = UUID()
    }

    func updateSyncEnabled(_ isEnabled: Bool) {
        let nextValue = isEnabled && signInState.isSignedIn
        guard syncEnabled != nextValue else {
            return
        }

        syncEnabled = nextValue
        defaults.set(nextValue, forKey: DefaultsKey.syncEnabled)
        syncErrorMessage = nil
        syncGeneration = UUID()
    }

    func restoreState() async {
        if let userID = defaults.string(forKey: DefaultsKey.appleUserID), !userID.isEmpty {
            let credentialState = await credentialState(for: userID)
            if credentialState != .authorized {
                signOut()
                return
            }
        } else {
            signInState = .signedOut
        }

        await refreshCloudAvailability()
    }

    func refreshCloudAvailability() async {
        let status = await cloudService.accountStatus()
        switch status {
        case .available:
            cloudAvailability = .available
        case .noAccount:
            cloudAvailability = .noAccount
        case .restricted:
            cloudAvailability = .restricted
        case .temporarilyUnavailable:
            cloudAvailability = .temporarilyUnavailable
        case .couldNotDetermine:
            fallthrough
        @unknown default:
            cloudAvailability = .unavailable
        }
    }

    func syncIfNeeded(localSnapshot: ConnectionProfilesSnapshot) async throws -> AppleSyncResolution {
        guard signInState.isSignedIn else {
            return .noChange
        }

        await refreshCloudAvailability()
        guard syncEnabled, cloudAvailability == .available else {
            return .noChange
        }

        isSyncing = true
        syncErrorMessage = nil
        defer {
            isSyncing = false
        }

        do {
            let remoteSnapshot = try await cloudService.fetchSnapshot()

            if let remoteSnapshot {
                if remoteSnapshot.updatedAt > localSnapshot.updatedAt {
                    lastSyncAt = remoteSnapshot.updatedAt
                    return .applyRemote(remoteSnapshot)
                }

                if localSnapshot.updatedAt > remoteSnapshot.updatedAt {
                    try await cloudService.save(snapshot: localSnapshot)
                    lastSyncAt = Date()
                    return .uploadedLocal
                }

                lastSyncAt = remoteSnapshot.updatedAt
                return .noChange
            }

            guard localSnapshot.updatedAt > .distantPast else {
                return .noChange
            }

            try await cloudService.save(snapshot: localSnapshot)
            lastSyncAt = Date()
            return .uploadedLocal
        } catch let error as AppleSyncError {
            disableSyncAfterRecoverableError(error)
            return .noChange
        } catch {
            syncErrorMessage = error.localizedDescription
            throw error
        }
    }

    private func disableSyncAfterRecoverableError(_ error: LocalizedError) {
        syncEnabled = false
        defaults.set(false, forKey: DefaultsKey.syncEnabled)
        syncErrorMessage = error.errorDescription ?? "iCloud sync is temporarily unavailable.".localized
        syncGeneration = UUID()
    }

    private func credentialState(for userID: String) async -> ASAuthorizationAppleIDProvider.CredentialState {
        await withCheckedContinuation { continuation in
            credentialProvider.getCredentialState(forUserID: userID) { state, _ in
                continuation.resume(returning: state)
            }
        }
    }
}
