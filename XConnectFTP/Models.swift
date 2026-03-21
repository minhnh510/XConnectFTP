//
//  Models.swift
//  XConnectFTP
//
//  Created by Codex on 21/3/26.
//

import Foundation

enum ProtocolMode: String, CaseIterable, Codable, Identifiable {
    case ftp
    case ftpsExplicit

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ftp:
            return "FTP".localized
        case .ftpsExplicit:
            return "FTPS (Explicit TLS)".localized
        }
    }

    var defaultPort: Int {
        21
    }
}

struct ConnectionProfile: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var protocolMode: ProtocolMode
    var initialRemotePath: String?
    var localRootPath: String?

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int,
        username: String,
        protocolMode: ProtocolMode,
        initialRemotePath: String? = nil,
        localRootPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.protocolMode = protocolMode
        self.initialRemotePath = initialRemotePath
        self.localRootPath = localRootPath
    }
}

struct ConnectionProfileDraft {
    var name: String = ""
    var host: String = ""
    var portText: String = "21"
    var username: String = ""
    var password: String = ""
    var protocolMode: ProtocolMode = .ftp
    var initialRemotePath: String = ""

    init(profile: ConnectionProfile? = nil, password: String = "") {
        guard let profile else { return }
        name = profile.name
        host = profile.host
        portText = String(profile.port)
        username = profile.username
        self.password = password
        protocolMode = profile.protocolMode
        initialRemotePath = profile.initialRemotePath ?? ""
    }

    func buildProfile(existingID: UUID?, existingLocalRootPath: String? = nil) throws -> ConnectionProfile {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRemotePath = initialRemotePath.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            throw ValidationError("Site name cannot be empty.".localized)
        }
        guard !trimmedHost.isEmpty else {
            throw ValidationError("Host or IP cannot be empty.".localized)
        }
        guard let port = Int(portText), (1...65535).contains(port) else {
            throw ValidationError("Port must be a number from 1 to 65535.".localized)
        }
        guard !trimmedUser.isEmpty else {
            throw ValidationError("Username cannot be empty.".localized)
        }
        guard !trimmedPassword.isEmpty else {
            throw ValidationError("Password cannot be empty.".localized)
        }

        return ConnectionProfile(
            id: existingID ?? UUID(),
            name: trimmedName,
            host: trimmedHost,
            port: port,
            username: trimmedUser,
            protocolMode: protocolMode,
            initialRemotePath: trimmedRemotePath.isEmpty ? nil : trimmedRemotePath,
            localRootPath: existingLocalRootPath
        )
    }
}

enum RemoteItemKind: String, Codable, Hashable, Sendable {
    case file
    case directory
    case symbolicLink
}

struct RemoteItem: Identifiable, Hashable, Sendable {
    var path: String
    var name: String
    var kind: RemoteItemKind
    var size: Int64?
    var modifiedAt: Date?

    var id: String { path }
    var isDirectory: Bool { kind == .directory }
}

struct LocalItem: Identifiable, Hashable, Sendable {
    var url: URL
    var name: String
    var isDirectory: Bool
    var size: Int64?
    var modifiedAt: Date?

    var id: String { url.path }
}

struct LocalBrowserRowModel: Identifiable, Hashable, Sendable {
    let item: LocalItem
    let name: String
    let sizeText: String
    let modifiedText: String
    let iconName: String

    init(item: LocalItem) {
        self.item = item
        self.name = item.name
        self.sizeText = BrowserDisplayFormatter.byteCount(item.size)
        self.modifiedText = BrowserDisplayFormatter.modifiedDate(item.modifiedAt)
        self.iconName = item.isDirectory ? "folder.fill" : "doc.fill"
    }

    var id: LocalItem.ID { item.id }
    var isDirectory: Bool { item.isDirectory }
}

struct RemoteBrowserRowModel: Identifiable, Hashable, Sendable {
    let item: RemoteItem
    let name: String
    let sizeText: String
    let modifiedText: String
    let iconName: String

    init(item: RemoteItem) {
        self.item = item
        self.name = item.name
        self.sizeText = BrowserDisplayFormatter.byteCount(item.size)
        self.modifiedText = BrowserDisplayFormatter.modifiedDate(item.modifiedAt)
        self.iconName = item.isDirectory ? "externaldrive.connected.to.line.below.fill" : "doc.text.fill"
    }

    var id: RemoteItem.ID { item.id }
    var isDirectory: Bool { item.isDirectory }
}

struct DirectoryDiff<ID: Hashable & Sendable>: Sendable, Equatable {
    let insertedIDs: [ID]
    let removedIDs: [ID]
    let updatedIDs: [ID]
    let unchangedIDs: [ID]

    var isEmpty: Bool {
        insertedIDs.isEmpty && removedIDs.isEmpty && updatedIDs.isEmpty
    }
}

struct BrowserDirectorySnapshot<
    Item: Identifiable & Hashable & Sendable,
    DisplayRow: Identifiable & Hashable & Sendable
>: Sendable where Item.ID == DisplayRow.ID, Item.ID: Hashable & Sendable {
    let items: [Item]
    let itemsByID: [Item.ID: Item]
    let displayRows: [DisplayRow]
    let version: Int

    init(items: [Item], displayRows: [DisplayRow], version: Int) {
        self.items = items
        self.itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        self.displayRows = displayRows
        self.version = version
    }

    func diff(from previousSnapshot: Self?) -> DirectoryDiff<Item.ID> {
        guard let previousSnapshot else {
            let ids = items.map(\.id)
            return DirectoryDiff(insertedIDs: ids, removedIDs: [], updatedIDs: [], unchangedIDs: [])
        }

        let previousItemsByID = previousSnapshot.itemsByID
        let previousIDs = Set(previousItemsByID.keys)
        let currentIDs = Set(itemsByID.keys)

        let insertedIDs = items
            .map(\.id)
            .filter { !previousIDs.contains($0) }
        let removedIDs = previousSnapshot.items
            .map(\.id)
            .filter { !currentIDs.contains($0) }

        var updatedIDs: [Item.ID] = []
        var unchangedIDs: [Item.ID] = []
        for item in items {
            guard let previousItem = previousItemsByID[item.id] else {
                continue
            }

            if previousItem == item {
                unchangedIDs.append(item.id)
            } else {
                updatedIDs.append(item.id)
            }
        }

        return DirectoryDiff(
            insertedIDs: insertedIDs,
            removedIDs: removedIDs,
            updatedIDs: updatedIDs,
            unchangedIDs: unchangedIDs
        )
    }
}

typealias LocalBrowserSnapshot = BrowserDirectorySnapshot<LocalItem, LocalBrowserRowModel>
typealias RemoteBrowserSnapshot = BrowserDirectorySnapshot<RemoteItem, RemoteBrowserRowModel>

struct TransferSnapshot: Sendable, Equatable {
    var title: String
    var transferredBytes: Int64
    var totalBytes: Int64?

    var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return Double(transferredBytes) / Double(totalBytes)
    }
}

struct ValidationError: LocalizedError {
    private let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private enum BrowserDisplayFormatter {
    static func byteCount(_ size: Int64?) -> String {
        guard let size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    static func modifiedDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
