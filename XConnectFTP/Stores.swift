//
//  Stores.swift
//  XConnectFTP
//
//  Created by Codex on 21/3/26.
//

import Foundation
import Security

struct ConnectionProfilesSnapshot: Codable, Equatable, Sendable {
    var profiles: [ConnectionProfile]
    var updatedAt: Date
}

enum StorageError: LocalizedError {
    case encodingFailed
    case missingPassword
    case keychainFailure(OSStatus)
    case bookmarkFailure

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Could not save the configuration data.".localized
        case .missingPassword:
            return "Could not find the password for the selected site.".localized
        case .keychainFailure(let status):
            return "Keychain returned error: %d.".localized(status)
        case .bookmarkFailure:
            return "Could not read the bookmark for the local folder.".localized
        }
    }
}

final class KeychainPasswordStore {
    private let service = "vn.xconnect.ftp.XConnectFTP.passwords"

    func password(for profileID: UUID) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else {
            throw StorageError.missingPassword
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw StorageError.keychainFailure(status)
        }

        return password
    }

    func savePassword(_ password: String, for profileID: UUID) throws {
        let account = profileID.uuidString
        let data = Data(password.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        let insertQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]

        let insertStatus = SecItemAdd(insertQuery as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw StorageError.keychainFailure(insertStatus)
        }
    }

    func deletePassword(for profileID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StorageError.keychainFailure(status)
        }
    }
}

final class ConnectionStore {
    private let defaults: UserDefaults
    private let key = "savedConnectionProfiles"
    private let updatedAtKey = "savedConnectionProfilesUpdatedAt"
    private let passwordStore: KeychainPasswordStore
    private var cachedProfiles: [ConnectionProfile]?

    init(defaults: UserDefaults = .standard, passwordStore: KeychainPasswordStore = KeychainPasswordStore()) {
        self.defaults = defaults
        self.passwordStore = passwordStore
    }

    func loadProfiles(forceRefresh: Bool = false) -> [ConnectionProfile] {
        if !forceRefresh, let cachedProfiles {
            return cachedProfiles
        }

        guard let data = defaults.data(forKey: key) else {
            cachedProfiles = []
            return []
        }

        do {
            let decoded = try JSONDecoder().decode([ConnectionProfile].self, from: data)
            let sorted = decoded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            cachedProfiles = sorted
            return sorted
        } catch {
            cachedProfiles = []
            return []
        }
    }

    func loadSnapshot(forceRefresh: Bool = false) -> ConnectionProfilesSnapshot {
        ConnectionProfilesSnapshot(
            profiles: loadProfiles(forceRefresh: forceRefresh),
            updatedAt: snapshotUpdatedAt()
        )
    }

    func save(profile: ConnectionProfile, password: String) throws -> [ConnectionProfile] {
        var profiles = loadProfiles()
        if let existingIndex = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[existingIndex] = profile
        } else {
            profiles.append(profile)
        }

        let sorted = try persistProfiles(profiles)
        try passwordStore.savePassword(password, for: profile.id)
        return sorted
    }

    func saveMetadata(profile: ConnectionProfile) throws -> [ConnectionProfile] {
        var profiles = loadProfiles()
        if let existingIndex = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[existingIndex] = profile
        } else {
            profiles.append(profile)
        }

        return try persistProfiles(profiles)
    }

    func delete(profile: ConnectionProfile) throws -> [ConnectionProfile] {
        let filtered = loadProfiles().filter { $0.id != profile.id }
        let persisted = try persistProfiles(filtered)
        try passwordStore.deletePassword(for: profile.id)
        return persisted
    }

    func password(for profile: ConnectionProfile) throws -> String {
        try passwordStore.password(for: profile.id)
    }

    func replaceAll(profiles: [ConnectionProfile], updatedAt: Date) throws -> [ConnectionProfile] {
        try persistProfiles(profiles, updatedAt: updatedAt)
    }

    @discardableResult
    private func persistProfiles(_ profiles: [ConnectionProfile], updatedAt: Date = Date()) throws -> [ConnectionProfile] {
        let sorted = profiles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let data = try JSONEncoder().encode(sorted)
        defaults.set(data, forKey: key)
        defaults.set(updatedAt, forKey: updatedAtKey)
        cachedProfiles = sorted
        return sorted
    }

    private func snapshotUpdatedAt() -> Date {
        defaults.object(forKey: updatedAtKey) as? Date ?? .distantPast
    }
}

struct BookmarkResolution {
    let url: URL
    let isStale: Bool
}

final class BookmarkStore {
    private let defaults: UserDefaults
    private let legacyBookmarkKey = "localRootBookmark"
    private let bookmarkKeyPrefix = "localRootBookmark."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func saveRootBookmark(for url: URL, profileID: UUID) throws {
        let data = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(data, forKey: key(for: profileID))
    }

    func resolveRootBookmark(for profileID: UUID) throws -> BookmarkResolution? {
        if let data = defaults.data(forKey: key(for: profileID)) {
            return try resolveBookmarkData(data)
        }

        guard let legacyData = defaults.data(forKey: legacyBookmarkKey) else {
            return nil
        }

        defaults.set(legacyData, forKey: key(for: profileID))
        defaults.removeObject(forKey: legacyBookmarkKey)
        return try resolveBookmarkData(legacyData)
    }

    func clearRootBookmark(for profileID: UUID) {
        defaults.removeObject(forKey: key(for: profileID))
    }

    private func key(for profileID: UUID) -> String {
        bookmarkKeyPrefix + profileID.uuidString
    }

    private func resolveBookmarkData(_ data: Data) throws -> BookmarkResolution {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return BookmarkResolution(url: url, isStale: isStale)
        } catch {
            throw StorageError.bookmarkFailure
        }
    }
}
