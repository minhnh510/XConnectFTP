//
//  BrowserInteraction.swift
//  XConnectFTP
//
//  Created by Codex on 21/3/26.
//

import CoreTransferable
import Foundation
import UniformTypeIdentifiers

enum BrowserPaneKind: String, Codable, Sendable {
    case local
    case remote
}

enum BrowserTransferKind: String, Codable, Sendable {
    case file
    case directory
}

struct DropResolution: Sendable {
    let pane: BrowserPaneKind
    let destinationLocalDirectory: URL?
    let destinationRemoteDirectory: String?
}

enum BrowserInteractionError: LocalizedError {
    case invalidDrop(String)
    case externalLocalImportDisallowed
    case remoteExportUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidDrop(let message):
            return message
        case .externalLocalImportDisallowed:
            return "Only local files inside the current local root can be dropped here.".localized
        case .remoteExportUnavailable:
            return "The remote item cannot be exported to Finder in the current state.".localized
        }
    }
}

struct BrowserTransferItem: Identifiable, Codable, Hashable, Transferable, Sendable {
    let id: String
    let sourcePane: BrowserPaneKind
    let name: String
    let kind: BrowserTransferKind
    let localURL: URL?
    let remotePath: String?
    let exporterToken: UUID?

    var isDirectory: Bool {
        kind == .directory
    }

    init(localItem: LocalItem) {
        id = localItem.id
        sourcePane = .local
        name = localItem.name
        kind = localItem.isDirectory ? .directory : .file
        localURL = localItem.url
        remotePath = nil
        exporterToken = nil
    }

    init(remoteItem: RemoteItem, exporterToken: UUID) {
        id = remoteItem.id
        sourcePane = .remote
        name = remoteItem.name
        kind = remoteItem.isDirectory ? .directory : .file
        localURL = nil
        remotePath = remoteItem.path
        self.exporterToken = exporterToken
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .browserTransferItem)

        ProxyRepresentation(exporting: { item in
            guard let localURL = item.localURL else {
                throw BrowserInteractionError.invalidDrop("The local URL payload is unavailable.".localized)
            }
            return localURL
        })
        .exportingCondition { $0.localURL != nil }

        FileRepresentation(exportedContentType: .folder) { item in
            try await item.exportTransferredFile()
        }
        .suggestedFileName { $0.name }
        .exportingCondition { $0.isDirectory }

        FileRepresentation(exportedContentType: .item) { item in
            try await item.exportTransferredFile()
        }
        .suggestedFileName { $0.name }
        .exportingCondition { !$0.isDirectory }
    }

    private func exportTransferredFile() async throws -> SentTransferredFile {
        if let localURL {
            return SentTransferredFile(localURL, allowAccessingOriginalFile: true)
        }

        let exportedURL = try await RemoteFilePromiseRegistry.shared.export(self)
        return SentTransferredFile(exportedURL, allowAccessingOriginalFile: false)
    }
}

struct BrowserTransferBatch: Identifiable, Codable, Hashable, Transferable, Sendable {
    let items: [BrowserTransferItem]

    var id: String {
        items.map(\.id).sorted().joined(separator: "|")
    }

    var sourcePane: BrowserPaneKind? {
        let panes = Set(items.map(\.sourcePane))
        guard panes.count == 1 else { return nil }
        return panes.first
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .browserTransferBatch)
    }
}

extension UTType {
    static let browserTransferItem = UTType(exportedAs: "vn.xconnect.ftp.browser-transfer-item")
    static let browserTransferBatch = UTType(exportedAs: "vn.xconnect.ftp.browser-transfer-batch")
}

actor RemoteFilePromiseRegistry {
    static let shared = RemoteFilePromiseRegistry()

    typealias Exporter = @Sendable (BrowserTransferItem) async throws -> URL

    private var exporters: [UUID: Exporter] = [:]

    func register(token: UUID, exporter: @escaping Exporter) {
        exporters[token] = exporter
    }

    func unregister(token: UUID) {
        exporters.removeValue(forKey: token)
    }

    func export(_ item: BrowserTransferItem) async throws -> URL {
        guard let token = item.exporterToken,
              let exporter = exporters[token] else {
            throw BrowserInteractionError.remoteExportUnavailable
        }

        return try await exporter(item)
    }
}
