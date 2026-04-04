//
//  TransferCoordinator.swift
//  XConnectFTP
//
//  Created by Codex on 21/3/26.
//

import Foundation

private struct ExportedRemoteItem {
    let exportedURL: URL
    let cleanupDirectoryURL: URL
}

actor TransferCoordinator {
    private let ftpClient: FTPClientProtocol
    private let tempTransferStore: TempTransferStore

    init(
        ftpClient: FTPClientProtocol,
        tempTransferStore: TempTransferStore = TempTransferStore()
    ) {
        self.ftpClient = ftpClient
        self.tempTransferStore = tempTransferStore
    }

    func sweepTemporaryArtifacts() async {
        await tempTransferStore.sweepStaleArtifacts()
    }

    func upload(
        items: [LocalItem],
        to remoteDirectory: String,
        progress: @escaping @Sendable (TransferSnapshot) -> Void,
        status: @escaping @Sendable (String) -> Void
    ) async throws {
        try await upload(urls: items.map(\.url), to: remoteDirectory, progress: progress, status: status)
    }

    func upload(
        urls: [URL],
        to remoteDirectory: String,
        progress: @escaping @Sendable (TransferSnapshot) -> Void,
        status: @escaping @Sendable (String) -> Void
    ) async throws {
        let normalizedURLs = pruneContainedURLs(urls)
        let total = normalizedURLs.count

        for (index, url) in normalizedURLs.enumerated() {
            try Task.checkCancellation()
            try await uploadEntry(
                at: url,
                toRemotePath: FTPPath.join(remoteDirectory, child: url.lastPathComponent),
                batchIndex: index + 1,
                batchTotal: total,
                progress: progress,
                status: status
            )
        }
    }

    func download(
        items: [RemoteItem],
        to localDirectory: URL,
        progress: @escaping @Sendable (TransferSnapshot) -> Void,
        status: @escaping @Sendable (String) -> Void
    ) async throws {
        let normalizedItems = pruneContainedRemoteItems(items)
        let total = normalizedItems.count

        for (index, item) in normalizedItems.enumerated() {
            try Task.checkCancellation()
            try await downloadEntry(
                item,
                to: localDirectory,
                batchIndex: index + 1,
                batchTotal: total,
                progress: progress,
                status: status
            )
        }
    }

    func moveRemote(
        items: [RemoteItem],
        to destinationDirectory: String,
        status: @escaping @Sendable (String) -> Void
    ) async throws {
        let normalizedItems = pruneContainedRemoteItems(items)
        let total = normalizedItems.count

        for (index, item) in normalizedItems.enumerated() {
            try Task.checkCancellation()

            let destinationPath = FTPPath.join(destinationDirectory, child: item.name)
            if FTPPath.normalize(destinationPath) == FTPPath.normalize(item.path) {
                continue
            }
            if item.isDirectory && isRemoteDescendant(destinationDirectory, of: item.path) {
                throw BrowserInteractionError.invalidDrop("Cannot move the folder %@ into itself.".localized(item.name))
            }

            status("Moving %lld/%lld: %@".localized(Int64(index + 1), Int64(total), item.name))
            try await ftpClient.moveItem(at: item.path, to: destinationPath)
        }
    }

    func moveLocal(
        items: [LocalItem],
        to destinationDirectory: URL,
        rootURL: URL,
        status: @escaping @Sendable (String) -> Void
    ) async throws {
        try await moveLocal(urls: items.map(\.url), to: destinationDirectory, rootURL: rootURL, status: status)
    }

    func moveLocal(
        urls: [URL],
        to destinationDirectory: URL,
        rootURL: URL,
        status: @escaping @Sendable (String) -> Void
    ) async throws {
        let destinationDirectory = destinationDirectory.standardizedFileURL
        let rootURL = rootURL.standardizedFileURL
        guard isInsideRoot(destinationDirectory, root: rootURL) else {
            throw BrowserInteractionError.externalLocalImportDisallowed
        }

        let fileManager = FileManager.default
        let normalizedURLs = pruneContainedURLs(urls)
        let total = normalizedURLs.count

        for (index, originalURL) in normalizedURLs.enumerated() {
            try Task.checkCancellation()

            let sourceURL = originalURL.standardizedFileURL
            guard isInsideRoot(sourceURL, root: rootURL) else {
                throw BrowserInteractionError.externalLocalImportDisallowed
            }

            let destinationURL = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: isDirectoryURL(sourceURL))
            if destinationURL == sourceURL {
                continue
            }
            if isDirectoryURL(sourceURL), isInsideRoot(destinationDirectory, root: sourceURL) {
                throw BrowserInteractionError.invalidDrop("Cannot move the folder %@ into itself.".localized(sourceURL.lastPathComponent))
            }
            if fileManager.fileExists(atPath: destinationURL.path) {
                throw BrowserInteractionError.invalidDrop("Destination %@ already exists.".localized(destinationURL.lastPathComponent))
            }

            status("Moving %lld/%lld: %@".localized(Int64(index + 1), Int64(total), sourceURL.lastPathComponent))
            do {
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
            } catch {
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                try fileManager.removeItem(at: sourceURL)
            }
        }
    }

    func copyLocal(
        urls: [URL],
        to destinationDirectory: URL,
        rootURL: URL,
        status: @escaping @Sendable (String) -> Void
    ) async throws {
        let destinationDirectory = destinationDirectory.standardizedFileURL
        let rootURL = rootURL.standardizedFileURL
        guard isInsideRoot(destinationDirectory, root: rootURL) else {
            throw BrowserInteractionError.externalLocalImportDisallowed
        }

        let fileManager = FileManager.default
        let normalizedURLs = pruneContainedURLs(urls)
        let existingNames = try existingLocalNames(in: destinationDirectory)
        var reservedNames = Set<String>()

        for (index, originalURL) in normalizedURLs.enumerated() {
            try Task.checkCancellation()

            let sourceURL = originalURL.standardizedFileURL
            guard isInsideRoot(sourceURL, root: rootURL) else {
                throw BrowserInteractionError.externalLocalImportDisallowed
            }
            if isDirectoryURL(sourceURL), isInsideRoot(destinationDirectory, root: sourceURL) {
                throw BrowserInteractionError.invalidDrop("Cannot copy the folder %@ into itself.".localized(sourceURL.lastPathComponent))
            }

            let destinationName = DuplicateNameResolver.uniqueName(
                for: sourceURL.lastPathComponent,
                isDirectory: isDirectoryURL(sourceURL),
                existingNames: existingNames,
                reservedNames: &reservedNames
            )
            let destinationURL = destinationDirectory.appendingPathComponent(destinationName, isDirectory: isDirectoryURL(sourceURL))

            status("Copying %lld/%lld: %@".localized(Int64(index + 1), Int64(normalizedURLs.count), sourceURL.lastPathComponent))
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }
    }

    func copyLocalToRemote(
        urls: [URL],
        to remoteDirectory: String,
        progress: @escaping @Sendable (TransferSnapshot) -> Void,
        status: @escaping @Sendable (String) -> Void
    ) async throws {
        let normalizedURLs = pruneContainedURLs(urls)
        let existingNames = try await existingRemoteNames(in: remoteDirectory)
        var reservedNames = Set<String>()

        for (index, url) in normalizedURLs.enumerated() {
            try Task.checkCancellation()

            let destinationName = DuplicateNameResolver.uniqueName(
                for: url.lastPathComponent,
                isDirectory: isDirectoryURL(url),
                existingNames: existingNames,
                reservedNames: &reservedNames
            )
            let destinationPath = FTPPath.join(remoteDirectory, child: destinationName)

            try await uploadEntry(
                at: url,
                toRemotePath: destinationPath,
                batchIndex: index + 1,
                batchTotal: normalizedURLs.count,
                progress: progress,
                status: status
            )
        }
    }

    func copyRemoteToLocal(
        items: [RemoteItem],
        to localDirectory: URL,
        progress: @escaping @Sendable (TransferSnapshot) -> Void,
        status: @escaping @Sendable (String) -> Void
    ) async throws {
        let fileManager = FileManager.default
        let normalizedItems = pruneContainedRemoteItems(items)
        let existingNames = try existingLocalNames(in: localDirectory)
        var reservedNames = Set<String>()

        for (index, item) in normalizedItems.enumerated() {
            try Task.checkCancellation()

            let destinationName = DuplicateNameResolver.uniqueName(
                for: item.name,
                isDirectory: item.isDirectory,
                existingNames: existingNames,
                reservedNames: &reservedNames
            )
            let destinationURL = localDirectory.appendingPathComponent(destinationName, isDirectory: item.isDirectory)

            status("Copying via temp %lld/%lld: %@".localized(Int64(index + 1), Int64(normalizedItems.count), item.name))
            let exportedItem = try await materialize(remoteItem: item)
            defer { Task {
                await tempTransferStore.cleanupOperationDirectory(exportedItem.cleanupDirectoryURL)
            }
            }

            try fileManager.copyItem(at: exportedItem.exportedURL, to: destinationURL)
        }
    }

    func copyRemote(
        items: [RemoteItem],
        to remoteDirectory: String,
        progress: @escaping @Sendable (TransferSnapshot) -> Void,
        status: @escaping @Sendable (String) -> Void
    ) async throws {
        let normalizedItems = pruneContainedRemoteItems(items)
        let existingNames = try await existingRemoteNames(in: remoteDirectory)
        var reservedNames = Set<String>()

        for (index, item) in normalizedItems.enumerated() {
            try Task.checkCancellation()

            if item.isDirectory && isRemoteDescendant(remoteDirectory, of: item.path) {
                throw BrowserInteractionError.invalidDrop("Cannot copy the folder %@ into itself.".localized(item.name))
            }

            let destinationName = DuplicateNameResolver.uniqueName(
                for: item.name,
                isDirectory: item.isDirectory,
                existingNames: existingNames,
                reservedNames: &reservedNames
            )
            let destinationPath = FTPPath.join(remoteDirectory, child: destinationName)

            status("Copying via temp %lld/%lld: %@".localized(Int64(index + 1), Int64(normalizedItems.count), item.name))
            let exportedItem = try await materialize(remoteItem: item)
            defer { Task {
                await tempTransferStore.cleanupOperationDirectory(exportedItem.cleanupDirectoryURL)
            }
            }

            try await uploadEntry(
                at: exportedItem.exportedURL,
                toRemotePath: destinationPath,
                batchIndex: index + 1,
                batchTotal: normalizedItems.count,
                progress: progress,
                status: status
            )
        }
    }

    func deleteLocal(
        items: [LocalItem],
        status: @escaping @Sendable (String) -> Void
    ) throws {
        let fileManager = FileManager.default
        let orderedItems = items.sorted {
            $0.url.standardizedFileURL.path.count > $1.url.standardizedFileURL.path.count
        }

        for (index, item) in orderedItems.enumerated() {
            status("Deleting %lld/%lld: %@".localized(Int64(index + 1), Int64(orderedItems.count), item.name))
            try fileManager.removeItem(at: item.url)
        }
    }

    func materializeForExport(_ item: BrowserTransferItem) async throws -> URL {
        guard let remotePath = item.remotePath else {
            throw BrowserInteractionError.remoteExportUnavailable
        }

        let exportedItem = try await materialize(remoteItem: RemoteItem(
            path: remotePath,
            name: item.name,
            kind: item.isDirectory ? .directory : .file,
            size: nil,
            modifiedAt: nil
        ))
        return exportedItem.exportedURL
    }

    private func uploadEntry(
        at url: URL,
        toRemotePath destinationPath: String,
        batchIndex: Int,
        batchTotal: Int,
        progress: @escaping @Sendable (TransferSnapshot) -> Void,
        status: @escaping @Sendable (String) -> Void
    ) async throws {
        if isDirectoryURL(url) {
            status("Uploading %lld/%lld: %@".localized(Int64(batchIndex), Int64(batchTotal), url.lastPathComponent))
            try await ftpClient.createDirectory(
                named: FTPPath.name(from: destinationPath),
                in: FTPPath.parent(of: destinationPath)
            )

            for childURL in try sortedChildURLs(of: url) {
                try await uploadEntry(
                    at: childURL,
                    toRemotePath: FTPPath.join(destinationPath, child: childURL.lastPathComponent),
                    batchIndex: batchIndex,
                    batchTotal: batchTotal,
                    progress: progress,
                    status: status
                )
            }
            return
        }

        status("Uploading %lld/%lld: %@".localized(Int64(batchIndex), Int64(batchTotal), url.lastPathComponent))
        try await ftpClient.upload(localURL: url, toRemotePath: destinationPath) { snapshot in
            progress(Self.decorate(snapshot, itemIndex: batchIndex, totalItems: batchTotal))
        }
    }

    private func downloadEntry(
        _ item: RemoteItem,
        to localDirectory: URL,
        batchIndex: Int,
        batchTotal: Int,
        progress: @escaping @Sendable (TransferSnapshot) -> Void,
        status: @escaping @Sendable (String) -> Void
    ) async throws {
        if item.isDirectory {
            status("Downloading %lld/%lld: %@".localized(Int64(batchIndex), Int64(batchTotal), item.name))
            let destinationDirectory = localDirectory.appendingPathComponent(item.name, isDirectory: true)
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            try await downloadDirectoryContents(
                remoteItem: item,
                to: destinationDirectory,
                batchIndex: batchIndex,
                batchTotal: batchTotal,
                displayPath: item.name,
                progress: progress,
                status: status
            )
            return
        }

        status("Downloading %lld/%lld: %@".localized(Int64(batchIndex), Int64(batchTotal), item.name))
        _ = try await ftpClient.download(remotePath: item.path, to: localDirectory) { snapshot in
            progress(Self.decorate(
                snapshot,
                itemIndex: batchIndex,
                totalItems: batchTotal,
                displayName: item.name
            ))
        }
    }

    private func downloadDirectoryContents(remoteItem: RemoteItem, to localDirectory: URL) async throws {
        let children = try await ftpClient.list(path: remoteItem.path, forceRefresh: true)
        for child in children {
            try Task.checkCancellation()
            guard child.name != ".", child.name != ".." else {
                continue
            }
            if child.isDirectory {
                let childDirectory = localDirectory.appendingPathComponent(child.name, isDirectory: true)
                try FileManager.default.createDirectory(at: childDirectory, withIntermediateDirectories: true)
                try await downloadDirectoryContents(remoteItem: child, to: childDirectory)
            } else {
                _ = try await ftpClient.download(remotePath: child.path, to: localDirectory) { _ in }
            }
        }
    }

    private func downloadDirectoryContents(
        remoteItem: RemoteItem,
        to localDirectory: URL,
        batchIndex: Int,
        batchTotal: Int,
        displayPath: String,
        progress: @escaping @Sendable (TransferSnapshot) -> Void,
        status: @escaping @Sendable (String) -> Void
    ) async throws {
        let children = try await ftpClient.list(path: remoteItem.path, forceRefresh: true)
        for child in children {
            try Task.checkCancellation()
            guard child.name != ".", child.name != ".." else {
                continue
            }
            let childDisplayPath = "\(displayPath)/\(child.name)"

            if child.isDirectory {
                let childDirectory = localDirectory.appendingPathComponent(child.name, isDirectory: true)
                try FileManager.default.createDirectory(at: childDirectory, withIntermediateDirectories: true)
                try await downloadDirectoryContents(
                    remoteItem: child,
                    to: childDirectory,
                    batchIndex: batchIndex,
                    batchTotal: batchTotal,
                    displayPath: childDisplayPath,
                    progress: progress,
                    status: status
                )
            } else {
                status("Downloading %lld/%lld: %@".localized(Int64(batchIndex), Int64(batchTotal), childDisplayPath))
                _ = try await ftpClient.download(remotePath: child.path, to: localDirectory) { snapshot in
                    progress(Self.decorate(
                        snapshot,
                        itemIndex: batchIndex,
                        totalItems: batchTotal,
                        displayName: childDisplayPath
                    ))
                }
            }
        }
    }

    private func materialize(remoteItem: RemoteItem) async throws -> ExportedRemoteItem {
        let baseDirectory = try await tempTransferStore.prepareOperationDirectory(prefix: "remote-stage")

        if remoteItem.isDirectory {
            let destinationDirectory = baseDirectory.appendingPathComponent(remoteItem.name, isDirectory: true)
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            try await downloadDirectoryContents(remoteItem: remoteItem, to: destinationDirectory)
            return ExportedRemoteItem(exportedURL: destinationDirectory, cleanupDirectoryURL: baseDirectory)
        }

        let fileURL = try await ftpClient.download(remotePath: remoteItem.path, to: baseDirectory) { _ in }
        return ExportedRemoteItem(exportedURL: fileURL, cleanupDirectoryURL: baseDirectory)
    }

    private func sortedChildURLs(of directoryURL: URL) throws -> [URL] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
            options: [.skipsPackageDescendants]
        )

        return urls.sorted { lhs, rhs in
            if isDirectoryURL(lhs) != isDirectoryURL(rhs) {
                return isDirectoryURL(lhs) && !isDirectoryURL(rhs)
            }
            return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
        }
    }

    private func pruneContainedURLs(_ urls: [URL]) -> [URL] {
        let ordered = Array(Set(urls.map { $0.standardizedFileURL })).sorted {
            $0.path.count < $1.path.count
        }

        var result: [URL] = []
        for url in ordered {
            if result.contains(where: { existing in
                isInsideRoot(url, root: existing) && isDirectoryURL(existing)
            }) {
                continue
            }
            result.append(url)
        }
        return result
    }

    private func pruneContainedRemoteItems(_ items: [RemoteItem]) -> [RemoteItem] {
        let ordered = Array(Set(items)).sorted {
            $0.path.count < $1.path.count
        }

        var result: [RemoteItem] = []
        for item in ordered {
            if result.contains(where: { existing in
                existing.isDirectory && isRemoteDescendant(item.path, of: existing.path)
            }) {
                continue
            }
            result.append(item)
        }
        return result
    }

    private func existingLocalNames(in directoryURL: URL) throws -> Set<String> {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.nameKey],
            options: [.skipsPackageDescendants]
        )
        return normalizedNames(from: urls.map(\.lastPathComponent))
    }

    private func existingRemoteNames(in directory: String) async throws -> Set<String> {
        let items = try await ftpClient.list(path: directory, forceRefresh: true)
        return normalizedNames(from: items.map(\.name))
    }

    private func isDirectoryURL(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private func isInsideRoot(_ candidate: URL, root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        return candidateComponents.starts(with: rootComponents)
    }

    private func isRemoteDescendant(_ candidate: String, of root: String) -> Bool {
        let normalizedCandidate = FTPPath.normalize(candidate)
        let normalizedRoot = FTPPath.normalize(root)
        guard normalizedCandidate != normalizedRoot else { return true }
        return normalizedCandidate.hasPrefix(normalizedRoot == "/" ? "/" : "\(normalizedRoot)/")
    }

    private func normalizedNames(from names: [String]) -> Set<String> {
        Set(names.map {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        })
    }

    private static func decorate(
        _ snapshot: TransferSnapshot,
        itemIndex: Int,
        totalItems: Int,
        displayName: String? = nil
    ) -> TransferSnapshot {
        TransferSnapshot(
            title: "[\(itemIndex)/\(totalItems)] \(displayName.map { "Downloading %@".localized($0) } ?? snapshot.title)",
            transferredBytes: snapshot.transferredBytes,
            totalBytes: snapshot.totalBytes
        )
    }
}
