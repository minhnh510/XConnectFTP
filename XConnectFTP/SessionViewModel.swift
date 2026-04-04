//
//  SessionViewModel.swift
//  XConnectFTP
//
//  Created by Codex on 21/3/26.
//

import AppKit
import Combine
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

private struct ClipboardSnapshot {
    let sourcePane: BrowserPaneKind
    let batch: BrowserTransferBatch
    let copiedAt: Date

    var localURLs: [URL] {
        batch.items.compactMap(\.localURL)
    }

    var remoteItems: [RemoteItem] {
        batch.items.compactMap { item in
            guard let remotePath = item.remotePath else { return nil }
            return RemoteItem(
                path: remotePath,
                name: item.name,
                kind: item.isDirectory ? .directory : .file,
                size: nil,
                modifiedAt: nil
            )
        }
    }
}

private final class ClipboardService {
    private var cachedChangeCount: Int = -1
    private var cachedSnapshot: ClipboardSnapshot?
    private var cachedFileURLs: [URL] = []

    func write(_ snapshot: ClipboardSnapshot) {
        guard snapshot.sourcePane == .local else {
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        var pasteboardItems: [NSPasteboardItem] = []
        if let data = try? JSONEncoder().encode(snapshot.batch) {
            let item = NSPasteboardItem()
            item.setData(data, forType: NSPasteboard.PasteboardType(UTType.browserTransferBatch.identifier))
            pasteboardItems.append(item)
        }

        for url in snapshot.localURLs {
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            pasteboardItems.append(item)
        }

        if !pasteboardItems.isEmpty {
            pasteboard.writeObjects(pasteboardItems)
        }

        cachedChangeCount = pasteboard.changeCount
        cachedSnapshot = snapshot
        cachedFileURLs = Self.uniqueStandardizedURLs(snapshot.localURLs)
    }

    func currentSnapshot() -> ClipboardSnapshot? {
        refreshIfNeeded()
        return cachedSnapshot
    }

    func fileURLs() -> [URL] {
        refreshIfNeeded()
        return cachedFileURLs
    }

    private func refreshIfNeeded() {
        let pasteboard = NSPasteboard.general
        guard cachedChangeCount != pasteboard.changeCount else {
            return
        }

        cachedChangeCount = pasteboard.changeCount
        cachedSnapshot = nil

        if let pasteboardItems = pasteboard.pasteboardItems {
            for item in pasteboardItems {
                guard let data = item.data(forType: NSPasteboard.PasteboardType(UTType.browserTransferBatch.identifier)),
                      let batch = try? JSONDecoder().decode(BrowserTransferBatch.self, from: data),
                      let sourcePane = batch.sourcePane,
                      sourcePane == .local else {
                    continue
                }

                cachedSnapshot = ClipboardSnapshot(sourcePane: sourcePane, batch: batch, copiedAt: Date())
                break
            }
        }

        var urls: [URL] = []
        if let objects = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            urls.append(contentsOf: objects)
        }
        if let pasteboardItems = pasteboard.pasteboardItems {
            urls.append(contentsOf: pasteboardItems.compactMap { item in
                guard let fileURLString = item.string(forType: .fileURL) else { return nil }
                return URL(string: fileURLString)
            })
        }

        cachedFileURLs = Self.uniqueStandardizedURLs(urls)
    }

    private static func uniqueStandardizedURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []

        for url in urls {
            let normalizedURL = url.standardizedFileURL
            if seen.insert(normalizedURL.path).inserted {
                result.append(normalizedURL)
            }
        }

        return result
    }
}

private final class RemoteExportCoordinator {
    private var isRegistered = false

    func ensureRegistered(token: UUID, transferCoordinator: TransferCoordinator) {
        guard !isRegistered else {
            return
        }

        isRegistered = true
        Task {
            await RemoteFilePromiseRegistry.shared.register(token: token) { item in
                try await transferCoordinator.materializeForExport(item)
            }
        }
    }

    func unregisterIfNeeded(token: UUID) {
        guard isRegistered else {
            return
        }

        isRegistered = false
        Task {
            await RemoteFilePromiseRegistry.shared.unregister(token: token)
        }
    }
}

private struct InlineRenameSession {
    let pane: BrowserPaneKind
    let itemID: String
    let originalName: String
    let isDirectory: Bool
    var draftName: String

    var shouldSelectNameStem: Bool {
        guard !isDirectory else { return false }
        let fileExtension = (originalName as NSString).pathExtension
        guard !fileExtension.isEmpty else { return false }
        return originalName != ".\(fileExtension)"
    }
}

private struct CachedRemoteBrowserState {
    let path: String
    let snapshot: RemoteBrowserSnapshot
}

@MainActor
final class SessionViewModel: ObservableObject {
    private static let lastConnectedProfileIDStorageKey = "lastConnectedProfileID"

    @Published var profiles: [ConnectionProfile]
    @Published var selectedProfileID: ConnectionProfile.ID?
    @Published var remoteCurrentPath: String = "/"
    @Published var remoteItems: [RemoteItem] = []
    @Published var remoteRows: [RemoteBrowserRowModel] = []
    @Published var remoteSearchText = "" {
        didSet {
            handleRemoteSearchTextChange(from: oldValue)
        }
    }
    @Published var remoteSortOrder: [BrowserRowComparator<RemoteBrowserRowModel>] = [BrowserRowComparator(.name)] {
        didSet {
            handleRemoteSortOrderChange(from: oldValue)
        }
    }
    @Published var selectedRemoteItemIDs: Set<RemoteItem.ID> = []
    @Published var localRootURL: URL?
    @Published var localCurrentURL: URL?
    @Published var localItems: [LocalItem] = []
    @Published var localRows: [LocalBrowserRowModel] = []
    @Published var localSearchText = "" {
        didSet {
            handleLocalSearchTextChange(from: oldValue)
        }
    }
    @Published var localSortOrder: [BrowserRowComparator<LocalBrowserRowModel>] = [BrowserRowComparator(.name)] {
        didSet {
            handleLocalSortOrderChange(from: oldValue)
        }
    }
    @Published var selectedLocalItemIDs: Set<LocalItem.ID> = []
    @Published var focusedPane: BrowserPaneKind = .local
    @Published var isConnected = false
    @Published var isBusy = false
    @Published var isTransferActive = false
    @Published private(set) var connectingProfileID: ConnectionProfile.ID?
    @Published private(set) var connectionProgressMessage: String?
    @Published private(set) var isRemoteDirectoryLoading = false
    @Published var isPresentingSiteEditor = false
    @Published var siteEditorDraft = ConnectionProfileDraft()
    @Published var errorMessage: String?
    @Published var statusMessage = "Not connected.".localized
    @Published private var inlineRenameSession: InlineRenameSession?

    private let connectionStore: ConnectionStore
    private let appleSyncController: AppleSyncController
    private let bookmarkStore: BookmarkStore
    private let userDefaults: UserDefaults
    private let localDirectoryService: LocalDirectoryService
    private let localDirectoryWatcher = LocalDirectoryWatcher()
    private let transferCoordinator: TransferCoordinator
    private let ftpClient: FTPClientProtocol
    private let clipboardService = ClipboardService()
    private let remoteExportCoordinator = RemoteExportCoordinator()
    private let remoteExporterToken = UUID()
    private var editingProfileID: UUID?
    private var activeRootAccessURL: URL?
    private var connectedProfileID: UUID?
    private var selectedProfileRestoreTask: Task<Void, Never>?
    private var hasBootstrapped = false
    private var localLoadGeneration = 0
    private var localSelectionAnchorID: LocalItem.ID?
    private var localDirectorySnapshot: LocalBrowserSnapshot?
    private var localSnapshot: LocalBrowserSnapshot?
    private var pendingLocalSelectionID: LocalItem.ID?
    private var remoteSelectionAnchorID: RemoteItem.ID?
    private var remoteDirectorySnapshot: RemoteBrowserSnapshot?
    private var remoteSnapshot: RemoteBrowserSnapshot?
    private var pendingRemoteSelectionID: RemoteItem.ID?
    private var queuedInlineRenameRestart = false
    private var clipboardSnapshot: ClipboardSnapshot?
    private var cachedRemoteBrowserStates: [ConnectionProfile.ID: CachedRemoteBrowserState] = [:]

    let transferProgressModel = TransferProgressModel()

    init(
        appleSyncController: AppleSyncController,
        connectionStore: ConnectionStore = ConnectionStore(),
        bookmarkStore: BookmarkStore = BookmarkStore(),
        userDefaults: UserDefaults = .standard,
        localDirectoryService: LocalDirectoryService = LocalDirectoryService(),
        ftpClient: FTPClientProtocol = FTPStreamClient(trustPrompt: { host, reason in
            await MainActor.run {
                CertificatePrompt.presentTrustDialog(host: host, reason: reason)
            }
        })
    ) {
        self.appleSyncController = appleSyncController
        self.connectionStore = connectionStore
        self.bookmarkStore = bookmarkStore
        self.userDefaults = userDefaults
        self.localDirectoryService = localDirectoryService
        self.ftpClient = ftpClient
        self.transferCoordinator = TransferCoordinator(ftpClient: ftpClient)
        self.profiles = []
        self.selectedProfileID = nil
    }

    deinit {
        selectedProfileRestoreTask?.cancel()
        localDirectoryWatcher.stopWatching()
        activeRootAccessURL?.stopAccessingSecurityScopedResource()
        let ftpClient = self.ftpClient
        let remoteExporterToken = self.remoteExporterToken
        Task {
            await ftpClient.disconnect()
        }
        remoteExportCoordinator.unregisterIfNeeded(token: remoteExporterToken)
    }

    var selectedProfile: ConnectionProfile? {
        profiles.first { $0.id == selectedProfileID }
    }

    var connectedProfile: ConnectionProfile? {
        profiles.first { $0.id == connectedProfileID }
    }

    var displayProfile: ConnectionProfile? {
        connectedProfile ?? selectedProfile
    }

    var activeLocalRootProfile: ConnectionProfile? {
        connectedProfile ?? selectedProfile
    }

    var selectedRemoteItems: [RemoteItem] {
        selectedRemoteItemIDs.compactMap { remoteSnapshot?.itemsByID[$0] }
    }

    var selectedLocalItems: [LocalItem] {
        selectedLocalItemIDs.compactMap { localSnapshot?.itemsByID[$0] }
    }

    var primarySelectedRemoteItem: RemoteItem? {
        selectedRemoteItems.count == 1 ? selectedRemoteItems.first : nil
    }

    var primarySelectedLocalItem: LocalItem? {
        selectedLocalItems.count == 1 ? selectedLocalItems.first : nil
    }

    var isInlineRenaming: Bool {
        inlineRenameSession != nil
    }

    var canHandleRenameReturnKey: Bool {
        isInlineRenaming || canRenameFocusedSelection || hasPendingRenameSelectionTransition
    }

    var canConnect: Bool {
        guard let selectedProfile else {
            return false
        }

        return canConnect(profile: selectedProfile)
    }

    var isConnecting: Bool {
        connectingProfileID != nil
    }

    var actionBarProgressMessage: String? {
        if let connectionProgressMessage {
            return connectionProgressMessage
        }

        if isRemoteDirectoryLoading {
            return "Refreshing remote folder...".localized
        }

        return nil
    }

    var canCopy: Bool {
        canCopy(from: focusedPane)
    }

    var canPaste: Bool {
        canPaste(into: focusedPane)
    }

    var canDisconnect: Bool {
        isConnected && !isBusy
    }

    var canChooseLocalRoot: Bool {
        !isBusy && activeLocalRootProfile != nil
    }

    var insecureFTPWarningMessage: String? {
        guard displayProfile?.protocolMode == .ftp else {
            return nil
        }

        if isConnected {
            return "Current connection uses unencrypted FTP. Username, password, and data may be observed in transit.".localized
        }

        return "FTP is unencrypted for username, password, and data. Use it only when the server does not support FTPS or when you accept the risk.".localized
    }

    var localRootSummary: String? {
        if let localRootURL {
            return "Local root: %@".localized(localRootURL.path)
        }
        if let savedPath = activeLocalRootProfile?.localRootPath {
            return "Saved local root for this site: %@".localized(savedPath)
        }
        return nil
    }

    var localPaneEmptyDescription: String {
        guard let activeLocalRootProfile else {
            return "Choose or create a saved site, then choose a local root folder.".localized
        }

        if let savedPath = activeLocalRootProfile.localRootPath {
            return "Saved local root for this site: %@. Choose Local Root to grant access on this Mac.".localized(savedPath)
        }

        return "Choose a local root folder for this site to browse and upload/download.".localized
    }

    var canUpload: Bool {
        isConnected && !isBusy && !selectedLocalItems.isEmpty
    }

    var canDownload: Bool {
        isConnected && !isBusy && !selectedRemoteItems.isEmpty && localCurrentURL != nil
    }

    var canRenameFocusedSelection: Bool {
        guard !isBusy else { return false }
        switch focusedPane {
        case .local:
            return primarySelectedLocalItem != nil
        case .remote:
            return isConnected && primarySelectedRemoteItem != nil
        }
    }

    var canDeleteFocusedSelection: Bool {
        guard !isBusy else { return false }
        switch focusedPane {
        case .local:
            return !selectedLocalItemIDs.isEmpty
        case .remote:
            return isConnected && !selectedRemoteItemIDs.isEmpty
        }
    }

    func bootstrap() async {
        guard !hasBootstrapped else {
            return
        }

        hasBootstrapped = true
        await Task.yield()

        let loadedProfiles = connectionStore.loadProfiles(forceRefresh: true)
        profiles = loadedProfiles
        selectedProfileID = preferredSavedSiteSelection(
            in: loadedProfiles,
            currentSelection: selectedProfileID
        )
        clearLastConnectedProfileIfMissing(in: loadedProfiles)

        await syncSavedSitesIfNeeded()

        restoreLocalRootForCurrentProfile()
        await transferCoordinator.sweepTemporaryArtifacts()
    }

    func handleLanguageChange() {
        guard !isBusy else {
            objectWillChange.send()
            return
        }

        statusMessage = localizedStatusMessageForCurrentState()
    }

    func handleAppleSyncConfigurationChange() async {
        await syncSavedSitesIfNeeded()
    }

    func handleSelectedProfileChange() {
        guard hasBootstrapped else {
            return
        }

        guard connectedProfileID == nil else {
            return
        }

        selectedProfileRestoreTask?.cancel()
        let selectedProfileID = self.selectedProfileID
        selectedProfileRestoreTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  !Task.isCancelled,
                  self.connectedProfileID == nil,
                  self.selectedProfileID == selectedProfileID else {
                return
            }
            self.restoreLocalRootForCurrentProfile()
        }
    }

    private func handleLocalSearchTextChange(from previousValue: String) {
        guard localSearchText != previousValue else {
            return
        }

        rebuildLocalBrowserState(previousSelection: selectedLocalItemIDs)
    }

    private func handleRemoteSearchTextChange(from previousValue: String) {
        guard remoteSearchText != previousValue else {
            return
        }

        rebuildRemoteBrowserState(previousSelection: selectedRemoteItemIDs)
    }

    private func handleLocalSortOrderChange(from previousValue: [BrowserRowComparator<LocalBrowserRowModel>]) {
        let normalized = Self.normalizedSortOrder(localSortOrder)
        if localSortOrder != normalized {
            localSortOrder = normalized
            return
        }
        guard localSortOrder != previousValue else {
            return
        }

        rebuildLocalBrowserState(previousSelection: selectedLocalItemIDs)
    }

    private func handleRemoteSortOrderChange(from previousValue: [BrowserRowComparator<RemoteBrowserRowModel>]) {
        let normalized = Self.normalizedSortOrder(remoteSortOrder)
        if remoteSortOrder != normalized {
            remoteSortOrder = normalized
            return
        }
        guard remoteSortOrder != previousValue else {
            return
        }

        rebuildRemoteBrowserState(previousSelection: selectedRemoteItemIDs)
    }

    private static func normalizedSortOrder<RowValue: BrowserSortableRow>(
        _ order: [BrowserRowComparator<RowValue>]
    ) -> [BrowserRowComparator<RowValue>] {
        if order.isEmpty {
            return [BrowserRowComparator(.name)]
        }
        return order
    }

    private static func sortedRows<RowValue: BrowserSortableRow>(
        _ rows: [RowValue],
        using order: [BrowserRowComparator<RowValue>]
    ) -> [RowValue] {
        let comparators = normalizedSortOrder(order)
        return rows.sorted { lhs, rhs in
            for comparator in comparators {
                switch comparator.compare(lhs, rhs) {
                case .orderedAscending:
                    return true
                case .orderedDescending:
                    return false
                case .orderedSame:
                    continue
                }
            }

            return false
        }
    }

    func canCopy(from pane: BrowserPaneKind) -> Bool {
        guard !isBusy else { return false }
        switch pane {
        case .local:
            return !selectedLocalItemIDs.isEmpty
        case .remote:
            return isConnected && !selectedRemoteItemIDs.isEmpty
        }
    }

    func canPaste(into pane: BrowserPaneKind) -> Bool {
        guard !isBusy else { return false }

        if let snapshot = preferredClipboardSnapshot() {
            switch (snapshot.sourcePane, pane) {
            case (.local, .local):
                return localCurrentURL != nil && localRootURL != nil && !snapshot.localURLs.isEmpty
            case (.local, .remote):
                return isConnected && !snapshot.localURLs.isEmpty
            case (.remote, .local):
                return isConnected && localCurrentURL != nil && !snapshot.remoteItems.isEmpty
            case (.remote, .remote):
                return isConnected && !snapshot.remoteItems.isEmpty
            }
        }

        switch pane {
        case .local:
            return localCurrentURL != nil && !pasteboardFileURLs().isEmpty
        case .remote:
            return isConnected && !pasteboardFileURLs().isEmpty
        }
    }

    func openAddSiteEditor() {
        editingProfileID = nil
        siteEditorDraft = ConnectionProfileDraft()
        isPresentingSiteEditor = true
    }

    func openEditSiteEditor() {
        guard let selectedProfile else { return }
        openEditSiteEditor(for: selectedProfile)
    }

    func openEditSiteEditor(for profile: ConnectionProfile) {
        selectedProfileID = profile.id
        do {
            let password = try connectionStore.password(for: profile)
            editingProfileID = profile.id
            siteEditorDraft = ConnectionProfileDraft(profile: profile, password: password)
            isPresentingSiteEditor = true
        } catch {
            present(error)
        }
    }

    @discardableResult
    func saveSiteEditor(_ draft: ConnectionProfileDraft) -> Bool {
        do {
            let profile = try draft.buildProfile(
                existingID: editingProfileID,
                existingLocalRootPath: profiles.first(where: { $0.id == editingProfileID })?.localRootPath
            )
            let updatedProfiles = try connectionStore.save(profile: profile, password: draft.password)
            profiles = updatedProfiles
            selectedProfileID = profile.id
            isPresentingSiteEditor = false
            statusMessage = "Saved site %@.".localized(profile.name)
            restoreLocalRootForCurrentProfile()
            Task {
                await self.syncSavedSitesIfNeeded()
            }
            return true
        } catch {
            present(error)
            return false
        }
    }

    func deleteSelectedProfile() {
        guard let selectedProfile else { return }
        deleteProfile(selectedProfile)
    }

    func deleteProfile(_ profile: ConnectionProfile) {
        selectedProfileID = profile.id
        guard CertificatePrompt.presentDeleteDialog(
            title: "Delete Saved Site".localized,
            message: "Are you sure you want to delete the saved site %@?".localized(profile.name)
        ) else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            if self.connectedProfileID == profile.id {
                await self.ftpClient.disconnect()
                self.resetRemoteSessionState()
            }

            do {
                self.profiles = try self.connectionStore.delete(profile: profile)
                self.bookmarkStore.clearRootBookmark(for: profile.id)
                self.cachedRemoteBrowserStates.removeValue(forKey: profile.id)
                if self.lastConnectedProfileID == profile.id {
                    self.persistLastConnectedProfileID(nil)
                }
                self.selectedProfileID = self.preferredSavedSiteSelection(
                    in: self.profiles,
                    currentSelection: self.selectedProfileID == profile.id ? nil : self.selectedProfileID
                )
                self.statusMessage = "Deleted site %@.".localized(profile.name)
                self.restoreLocalRootForCurrentProfile()
                await self.syncSavedSitesIfNeeded()
            } catch {
                self.present(error)
            }
        }
    }

    func connect() {
        guard let selectedProfile else { return }
        connect(to: selectedProfile)
    }

    func connect(to profile: ConnectionProfile) {
        guard canConnect(profile: profile) else { return }
        selectedProfileID = profile.id
        let previousProfile = connectedProfile
        let connectionStatus = previousProfile.map {
            "Switching from %@ to %@...".localized($0.host, profile.host)
        } ?? "Connecting to %@...".localized(profile.host)

        runTask(status: connectionStatus) { viewModel in
            viewModel.connectingProfileID = profile.id
            viewModel.connectionProgressMessage = connectionStatus
            defer {
                viewModel.connectingProfileID = nil
                viewModel.connectionProgressMessage = nil
                viewModel.isRemoteDirectoryLoading = false
            }

            if viewModel.isConnected, viewModel.connectedProfileID != profile.id {
                await viewModel.ftpClient.disconnect()
                viewModel.resetRemoteSessionState()
                viewModel.restoreLocalRootForCurrentProfile()
            }

            await viewModel.transferCoordinator.sweepTemporaryArtifacts()
            let password = try viewModel.connectionStore.password(for: profile)
            let workingDirectory = try await viewModel.ftpClient.connect(profile: profile, password: password)
            viewModel.connectedProfileID = profile.id
            viewModel.persistLastConnectedProfileID(profile.id)
            viewModel.isConnected = true
            viewModel.remoteCurrentPath = workingDirectory
            viewModel.restoreLocalRootForCurrentProfile()
            viewModel.statusMessage = viewModel.localizedConnectedStatusMessage(for: profile)
            viewModel.connectingProfileID = nil
            viewModel.connectionProgressMessage = nil

            if let cachedSnapshot = viewModel.cachedRemoteSnapshot(for: profile.id, path: workingDirectory) {
                viewModel.applyRemoteSnapshot(cachedSnapshot, isSameDirectory: false)
            }

            viewModel.isRemoteDirectoryLoading = true
            try await viewModel.refreshRemoteDirectory(path: workingDirectory, forceRefresh: true)
        }
    }

    func disconnect() {
        runTask(status: "Disconnecting...".localized) { viewModel in
            await viewModel.ftpClient.disconnect()
            viewModel.resetRemoteSessionState()
            viewModel.restoreLocalRootForCurrentProfile()
            viewModel.statusMessage = "Disconnected.".localized
        }
    }

    func disconnect(profile: ConnectionProfile) {
        guard canDisconnect(profile: profile) else { return }
        selectedProfileID = profile.id
        disconnect()
    }

    func canConnect(profile: ConnectionProfile) -> Bool {
        !isBusy && (!isConnected || connectedProfileID != profile.id)
    }

    func canDisconnect(profile: ConnectionProfile) -> Bool {
        !isBusy && isConnected && connectedProfileID == profile.id
    }

    func isProfileConnected(_ profile: ConnectionProfile) -> Bool {
        isConnected && connectedProfileID == profile.id
    }

    func isProfileConnecting(_ profile: ConnectionProfile) -> Bool {
        connectingProfileID == profile.id
    }

    func chooseLocalRoot() {
        guard let profile = activeLocalRootProfile else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder".localized
        panel.message = "Choose the local root folder to browse inside the app.".localized

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try activateLocalRoot(url, persistBookmark: true, for: profile.id)
                try updateLocalRootPath(url.path, for: profile.id)
                statusMessage = "Selected local root: %@".localized(url.path)
                Task {
                    await self.syncSavedSitesIfNeeded()
                }
            } catch {
                present(error)
            }
        }
    }

    func goToLocalParent() {
        guard let rootURL = localRootURL,
              let currentURL = localCurrentURL,
              currentURL.standardizedFileURL != rootURL.standardizedFileURL else {
            return
        }

        let parentURL = currentURL.deletingLastPathComponent()
        guard isInsideRoot(parentURL, root: rootURL) else { return }
        focusedPane = .local
        requestLocalDirectoryLoad(parentURL)
    }

    func enterLocalItem(_ item: LocalItem) {
        guard item.isDirectory else { return }
        focusedPane = .local
        requestLocalDirectoryLoad(item.url)
    }

    func openLocalSelectionInFinder() {
        guard !isBusy else { return }

        focusedPane = .local
        let urls = selectedLocalItems.map(\.url)

        if !urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
            statusMessage = localizedSingleOrMany(
                count: urls.count,
                name: urls[0].lastPathComponent,
                singularKey: "Opened %@ in Finder.",
                pluralKey: "Opened %lld items in Finder."
            )
            return
        }

        guard let currentURL = localCurrentURL else { return }
        NSWorkspace.shared.open(currentURL)
        statusMessage = "Opened %@ in Finder.".localized(currentURL.lastPathComponent)
    }

    func goToRemoteParent() {
        guard isConnected, remoteCurrentPath != "/" else { return }
        focusedPane = .remote
        let parentPath = FTPPath.parent(of: remoteCurrentPath)
        runTask(status: "Opening parent folder...".localized) { viewModel in
            let resolvedPath = try await viewModel.ftpClient.changeDirectory(to: parentPath)
            try await viewModel.refreshRemoteDirectory(path: resolvedPath)
        }
    }

    func enterRemoteItem(_ item: RemoteItem) {
        guard item.isDirectory else { return }
        focusedPane = .remote
        runTask(status: "Opening %@...".localized(item.name)) { viewModel in
            let resolvedPath = try await viewModel.ftpClient.changeDirectory(to: item.path)
            try await viewModel.refreshRemoteDirectory(path: resolvedPath)
        }
    }

    func refreshRemoteDirectory() {
        guard isConnected else { return }
        focusedPane = .remote
        runTask(status: "Refreshing remote folder...".localized) { viewModel in
            try await viewModel.refreshRemoteDirectory(path: viewModel.remoteCurrentPath, forceRefresh: true)
        }
    }

    func uploadSelectedLocalItems(destinationDirectory: String? = nil) {
        let items = selectedLocalItems
        guard isConnected, !items.isEmpty else { return }

        let targetDirectory = destinationDirectory ?? remoteCurrentPath
        focusedPane = .local
        runTransferTask(status: "Uploading %lld item(s)...".localized(Int64(items.count))) { viewModel in
            try await viewModel.transferCoordinator.upload(
                items: items,
                to: targetDirectory,
                progress: viewModel.progressReporter(),
                status: viewModel.statusReporter()
            )
            viewModel.statusMessage = viewModel.localizedSingleOrMany(
                count: items.count,
                name: items[0].name,
                singularKey: "Uploaded %@.",
                pluralKey: "Uploaded %lld items."
            )
            try await viewModel.refreshRemoteDirectory(path: viewModel.remoteCurrentPath, forceRefresh: true)
        }
    }

    func downloadSelectedRemoteItems(destinationDirectory: URL? = nil) {
        let items = selectedRemoteItems
        let targetDirectory = destinationDirectory ?? localCurrentURL
        guard isConnected, !items.isEmpty, let targetDirectory else { return }

        focusedPane = .remote
        runTransferTask(status: "Downloading %lld item(s)...".localized(Int64(items.count))) { viewModel in
            try await viewModel.transferCoordinator.download(
                items: items,
                to: targetDirectory,
                progress: viewModel.progressReporter(),
                status: viewModel.statusReporter()
            )
            await viewModel.invalidateLocalDirectories([targetDirectory])
            viewModel.refreshCurrentLocalDirectoryIfNeeded(affectedDirectories: [targetDirectory])
            viewModel.statusMessage = viewModel.localizedSingleOrMany(
                count: items.count,
                name: items[0].name,
                singularKey: "Downloaded %@.",
                pluralKey: "Downloaded %lld items."
            )
        }
    }

    func createRemoteFolder() {
        guard isConnected else { return }
        guard let folderName = CertificatePrompt.presentTextInputDialog(
            title: "Create Remote Folder".localized,
            message: "Enter a name for the new folder in %@.".localized(remoteCurrentPath),
            defaultValue: ""
        ) else {
            return
        }

        focusedPane = .remote
        runTask(status: "Creating folder %@...".localized(folderName)) { viewModel in
            try await viewModel.ftpClient.createDirectory(named: folderName, in: viewModel.remoteCurrentPath)
            viewModel.statusMessage = "Created folder %@.".localized(folderName)
            try await viewModel.refreshRemoteDirectory(path: viewModel.remoteCurrentPath, forceRefresh: true)
        }
    }

    @discardableResult
    func renameFocusedSelection() -> Bool {
        guard !isBusy else { return false }
        switch focusedPane {
        case .local:
            return beginInlineRenameForSelectedLocalItem()
        case .remote:
            return beginInlineRenameForSelectedRemoteItem()
        }
    }

    func handleReturnKey() {
        if isInlineRenaming {
            commitInlineRename()
            return
        }

        if renameFocusedSelection() {
            return
        }

        if hasPendingRenameSelectionTransition {
            queuedInlineRenameRestart = true
        }
    }

    func cancelInlineRename() {
        inlineRenameSession = nil
    }

    func inlineRenameText(for pane: BrowserPaneKind, itemID: String) -> String {
        guard let inlineRenameSession,
              inlineRenameSession.pane == pane,
              inlineRenameSession.itemID == itemID else {
            return ""
        }
        return inlineRenameSession.draftName
    }

    func updateInlineRenameText(_ text: String, for pane: BrowserPaneKind, itemID: String) {
        guard var inlineRenameSession,
              inlineRenameSession.pane == pane,
              inlineRenameSession.itemID == itemID else {
            return
        }
        inlineRenameSession.draftName = text
        self.inlineRenameSession = inlineRenameSession
    }

    func isInlineRenamingLocalItem(_ item: LocalItem) -> Bool {
        inlineRenameSession?.pane == .local && inlineRenameSession?.itemID == item.id
    }

    func isInlineRenamingRemoteItem(_ item: RemoteItem) -> Bool {
        inlineRenameSession?.pane == .remote && inlineRenameSession?.itemID == item.id
    }

    func shouldSelectNameStemForInlineRename(in pane: BrowserPaneKind, itemID: String) -> Bool {
        guard let inlineRenameSession,
              inlineRenameSession.pane == pane,
              inlineRenameSession.itemID == itemID else {
            return false
        }
        return inlineRenameSession.shouldSelectNameStem
    }

    func handleLocalSelectionChange() {
        focusedPane = .local
        guard let inlineRenameSession, inlineRenameSession.pane == .local else { return }
        if selectedLocalItemIDs != [inlineRenameSession.itemID] {
            cancelInlineRename()
        }
    }

    func handleRemoteSelectionChange() {
        focusedPane = .remote
        guard let inlineRenameSession, inlineRenameSession.pane == .remote else { return }
        if selectedRemoteItemIDs != [inlineRenameSession.itemID] {
            cancelInlineRename()
        }
    }

    @discardableResult
    private func beginInlineRenameForSelectedLocalItem() -> Bool {
        guard let item = primarySelectedLocalItem else { return false }
        ensureLocalSelection(for: item)
        inlineRenameSession = InlineRenameSession(
            pane: .local,
            itemID: item.id,
            originalName: item.name,
            isDirectory: item.isDirectory,
            draftName: item.name
        )
        return true
    }

    @discardableResult
    private func beginInlineRenameForSelectedRemoteItem() -> Bool {
        guard let item = primarySelectedRemoteItem else { return false }
        ensureRemoteSelection(for: item)
        inlineRenameSession = InlineRenameSession(
            pane: .remote,
            itemID: item.id,
            originalName: item.name,
            isDirectory: item.isDirectory,
            draftName: item.name
        )
        return true
    }

    private func commitInlineRename() {
        guard let inlineRenameSession else { return }

        let newName = inlineRenameSession.draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else {
            cancelInlineRename()
            return
        }

        if newName == inlineRenameSession.originalName {
            cancelInlineRename()
            return
        }

        switch inlineRenameSession.pane {
        case .local:
            commitInlineRenameForLocalItem(session: inlineRenameSession, newName: newName)
        case .remote:
            commitInlineRenameForRemoteItem(session: inlineRenameSession, newName: newName)
        }
    }

    private func commitInlineRenameForLocalItem(session: InlineRenameSession, newName: String) {
        guard let item = localSnapshot?.itemsByID[session.itemID] else {
            cancelInlineRename()
            return
        }

        let destinationURL = item.url
            .deletingLastPathComponent()
            .appendingPathComponent(newName, isDirectory: item.isDirectory)
            .standardizedFileURL

        guard destinationURL.path != item.url.standardizedFileURL.path else {
            cancelInlineRename()
            return
        }

        focusedPane = .local
        cancelInlineRename()
        pendingLocalSelectionID = destinationURL.path
        queuedInlineRenameRestart = false
        runTask(status: "Renaming %@...".localized(item.name)) { viewModel in
            do {
                guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
                    throw BrowserInteractionError.invalidDrop("Destination %@ already exists.".localized(newName))
                }

                try FileManager.default.moveItem(at: item.url, to: destinationURL)
                let parentDirectory = item.url.deletingLastPathComponent().standardizedFileURL
                await viewModel.invalidateLocalDirectories([parentDirectory])
                viewModel.requestLocalDirectoryLoad(parentDirectory, forceRefresh: true)
                viewModel.statusMessage = "Renamed %@ to %@.".localized(item.name, newName)
            } catch {
                viewModel.pendingLocalSelectionID = nil
                viewModel.queuedInlineRenameRestart = false
                throw error
            }
        }
    }

    private func commitInlineRenameForRemoteItem(session: InlineRenameSession, newName: String) {
        guard let item = remoteSnapshot?.itemsByID[session.itemID] else {
            cancelInlineRename()
            return
        }

        let destinationPath = FTPPath.join(FTPPath.parent(of: item.path), child: newName)
        guard FTPPath.normalize(destinationPath) != FTPPath.normalize(item.path) else {
            cancelInlineRename()
            return
        }

        focusedPane = .remote
        cancelInlineRename()
        pendingRemoteSelectionID = destinationPath
        queuedInlineRenameRestart = false
        runTask(status: "Renaming %@...".localized(item.name)) { viewModel in
            do {
                try await viewModel.ftpClient.moveItem(at: item.path, to: destinationPath)
                viewModel.statusMessage = "Renamed %@ to %@.".localized(item.name, newName)
                try await viewModel.refreshRemoteDirectory(path: viewModel.remoteCurrentPath, forceRefresh: true)
            } catch {
                viewModel.pendingRemoteSelectionID = nil
                viewModel.queuedInlineRenameRestart = false
                throw error
            }
        }
    }

    func deleteFocusedSelection() {
        switch focusedPane {
        case .local:
            deleteSelectedLocalItems()
        case .remote:
            deleteSelectedRemoteItems()
        }
    }

    func copyFocusedSelection() {
        guard canCopy else { return }

        let snapshot: ClipboardSnapshot
        switch focusedPane {
        case .local:
            let items = selectedLocalItems
            let batch = BrowserTransferBatch(items: items.map(transferItem(for:)))
            snapshot = ClipboardSnapshot(sourcePane: .local, batch: batch, copiedAt: Date())
            statusMessage = localizedSingleOrMany(
                count: items.count,
                name: items[0].name,
                singularKey: "Copied %@.",
                pluralKey: "Copied %lld items."
            )
        case .remote:
            let items = selectedRemoteItems
            let batch = BrowserTransferBatch(items: items.map(transferItem(for:)))
            snapshot = ClipboardSnapshot(sourcePane: .remote, batch: batch, copiedAt: Date())
            statusMessage = localizedSingleOrMany(
                count: items.count,
                name: items[0].name,
                singularKey: "Copied %@.",
                pluralKey: "Copied %lld items."
            )
        }

        clipboardSnapshot = snapshot
        writeClipboardToPasteboard(snapshot)
    }

    func pasteIntoFocusedPane() {
        paste(into: focusedPane)
    }

    func paste(into pane: BrowserPaneKind) {
        guard canPaste(into: pane) else { return }
        focusedPane = pane

        if let snapshot = preferredClipboardSnapshot() {
            paste(snapshot, into: pane)
            return
        }

        let urls = pasteboardFileURLs()
        guard !urls.isEmpty else { return }

        switch pane {
        case .local:
            guard let destination = localCurrentURL,
                  let rootURL = localRootURL else { return }
            runTask(status: "Pasting local items...".localized) { viewModel in
                try await viewModel.transferCoordinator.copyLocal(
                    urls: urls,
                    to: destination,
                    rootURL: rootURL,
                    status: viewModel.statusReporter()
                )
                await viewModel.invalidateLocalDirectories([destination])
                viewModel.refreshCurrentLocalDirectoryIfNeeded(affectedDirectories: [destination])
                viewModel.statusMessage = viewModel.localizedSingleOrMany(
                    count: urls.count,
                    name: urls[0].lastPathComponent,
                    singularKey: "Pasted %@.",
                    pluralKey: "Pasted %lld items."
                )
            }
        case .remote:
            let destination = remoteCurrentPath
            runTransferTask(status: "Pasting to remote...".localized) { viewModel in
                try await viewModel.transferCoordinator.copyLocalToRemote(
                    urls: urls,
                    to: destination,
                    progress: viewModel.progressReporter(),
                    status: viewModel.statusReporter()
                )
                viewModel.statusMessage = viewModel.localizedSingleOrMany(
                    count: urls.count,
                    name: urls[0].lastPathComponent,
                    singularKey: "Pasted %@ to remote.",
                    pluralKey: "Pasted %lld items to remote."
                )
                try await viewModel.refreshRemoteDirectory(path: viewModel.remoteCurrentPath, forceRefresh: true)
            }
        }
    }

    func deleteSelectedRemoteItems() {
        let items = selectedRemoteItems
        guard !items.isEmpty else { return }

        let itemDescription = localizedSelectionDescription(count: items.count, name: items[0].name)
        guard CertificatePrompt.presentDeleteDialog(
            title: "Delete Remote Item".localized,
            message: "Are you sure you want to delete %@?".localized(itemDescription)
        ) else {
            return
        }

        focusedPane = .remote
        runTask(status: "Deleting %@...".localized(itemDescription)) { viewModel in
            let orderedItems = items.sorted { $0.path.count > $1.path.count }
            for (index, item) in orderedItems.enumerated() {
                viewModel.statusMessage = "Deleting %lld/%lld: %@".localized(Int64(index + 1), Int64(orderedItems.count), item.name)
                try await viewModel.ftpClient.deleteItem(at: item.path, isDirectory: item.isDirectory)
            }
            viewModel.statusMessage = viewModel.localizedSingleOrMany(
                count: items.count,
                name: items[0].name,
                singularKey: "Deleted %@.",
                pluralKey: "Deleted %lld items."
            )
            try await viewModel.refreshRemoteDirectory(path: viewModel.remoteCurrentPath, forceRefresh: true)
        }
    }

    func deleteSelectedLocalItems() {
        let items = selectedLocalItems
        guard !items.isEmpty else { return }

        let itemDescription = localizedSelectionDescription(count: items.count, name: items[0].name)
        guard CertificatePrompt.presentDeleteDialog(
            title: "Delete Local Item".localized,
            message: "Are you sure you want to delete %@?".localized(itemDescription)
        ) else {
            return
        }

        focusedPane = .local
        runTask(status: "Deleting %@...".localized(itemDescription)) { viewModel in
            try await viewModel.transferCoordinator.deleteLocal(items: items, status: viewModel.statusReporter())
            let affectedDirectories = items.map { $0.url.deletingLastPathComponent().standardizedFileURL }
            await viewModel.invalidateLocalDirectories(affectedDirectories)
            viewModel.refreshCurrentLocalDirectoryIfNeeded(affectedDirectories: affectedDirectories)
            viewModel.statusMessage = viewModel.localizedSingleOrMany(
                count: items.count,
                name: items[0].name,
                singularKey: "Deleted %@.",
                pluralKey: "Deleted %lld items."
            )
        }
    }

    func cancelTransfer() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.ftpClient.cancelCurrentTransfer()
            self.isTransferActive = false
            self.transferProgressModel.clear()
            self.statusMessage = "Canceled the current transfer.".localized
        }
    }

    func setFocusedPane(_ pane: BrowserPaneKind) {
        focusedPane = pane
    }

    func selectAllInFocusedPane() {
        switch focusedPane {
        case .local:
            selectedLocalItemIDs = Set(localItems.map(\.id))
        case .remote:
            selectedRemoteItemIDs = Set(remoteItems.map(\.id))
        }
    }

    func openPrimarySelection() {
        switch focusedPane {
        case .local:
            if let item = primarySelectedLocalItem, item.isDirectory {
                enterLocalItem(item)
            }
        case .remote:
            if let item = primarySelectedRemoteItem, item.isDirectory {
                enterRemoteItem(item)
            }
        }
    }

    func handleDrop(_ items: [BrowserTransferItem], resolution: DropResolution) {
        guard !items.isEmpty, !isBusy else { return }

        let sourcePanes = Set(items.map(\.sourcePane))
        guard sourcePanes.count == 1, let sourcePane = sourcePanes.first else {
            present(BrowserInteractionError.invalidDrop("Cannot handle a mixed drag payload.".localized))
            return
        }

        switch (sourcePane, resolution.pane) {
        case (.local, .remote):
            guard let destination = resolution.destinationRemoteDirectory else { return }
            runTransferTask(status: "Uploading from local to remote...".localized) { viewModel in
                try await viewModel.transferCoordinator.upload(
                    urls: items.compactMap(\.localURL),
                    to: destination,
                    progress: viewModel.progressReporter(),
                    status: viewModel.statusReporter()
                )
                viewModel.statusMessage = "Uploaded %lld item(s).".localized(Int64(items.count))
                try await viewModel.refreshRemoteDirectory(path: viewModel.remoteCurrentPath, forceRefresh: true)
            }
        case (.remote, .local):
            guard let destination = resolution.destinationLocalDirectory else { return }
            let remoteItems = items.compactMap(remoteItem(from:))
            runTransferTask(status: "Downloading from remote to local...".localized) { viewModel in
                try await viewModel.transferCoordinator.download(
                    items: remoteItems,
                    to: destination,
                    progress: viewModel.progressReporter(),
                    status: viewModel.statusReporter()
                )
                await viewModel.invalidateLocalDirectories([destination])
                viewModel.refreshCurrentLocalDirectoryIfNeeded(affectedDirectories: [destination])
                viewModel.statusMessage = "Downloaded %lld item(s).".localized(Int64(remoteItems.count))
            }
        case (.local, .local):
            guard let destination = resolution.destinationLocalDirectory,
                  let rootURL = localRootURL else { return }
            runTask(status: "Moving local items...".localized) { viewModel in
                try await viewModel.transferCoordinator.moveLocal(
                    urls: items.compactMap(\.localURL),
                    to: destination,
                    rootURL: rootURL,
                    status: viewModel.statusReporter()
                )
                let sourceURLs = items.compactMap(\.localURL)
                let affectedDirectories = sourceURLs.map { $0.deletingLastPathComponent().standardizedFileURL } + [destination.standardizedFileURL]
                await viewModel.invalidateLocalDirectories(affectedDirectories)
                viewModel.refreshCurrentLocalDirectoryIfNeeded(affectedDirectories: affectedDirectories)
                viewModel.statusMessage = "Moved %lld local item(s).".localized(Int64(items.count))
            }
        case (.remote, .remote):
            guard let destination = resolution.destinationRemoteDirectory else { return }
            let remoteItems = items.compactMap(remoteItem(from:))
            runTask(status: "Moving remote items...".localized) { viewModel in
                try await viewModel.transferCoordinator.moveRemote(
                    items: remoteItems,
                    to: destination,
                    status: viewModel.statusReporter()
                )
                viewModel.statusMessage = "Moved %lld remote item(s).".localized(Int64(remoteItems.count))
                try await viewModel.refreshRemoteDirectory(path: viewModel.remoteCurrentPath, forceRefresh: true)
            }
        }
    }

    func handleDropProviders(_ providers: [NSItemProvider], resolution: DropResolution) -> Bool {
        guard !providers.isEmpty, !isBusy else { return false }

        let supportedProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.browserTransferBatch.identifier) ||
            $0.hasItemConformingToTypeIdentifier(UTType.browserTransferItem.identifier) ||
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !supportedProviders.isEmpty else { return false }

        Task { [weak self] in
            guard let self else { return }

            do {
                let decodedPayload = try await Self.decodeDropPayload(from: supportedProviders)
                await MainActor.run {
                    let allItems = decodedPayload.batches.flatMap(\.items) + decodedPayload.items
                    let remoteItems = allItems.filter { $0.sourcePane == .remote }
                    let localURLs = Self.uniqueStandardizedURLs(
                        decodedPayload.urls + allItems.compactMap { item in
                            item.sourcePane == .local ? item.localURL : nil
                        }
                    )

                    if !remoteItems.isEmpty {
                        self.handleDrop(remoteItems, resolution: resolution)
                    } else if !localURLs.isEmpty {
                        self.handleExternalURLDrop(localURLs, resolution: resolution)
                    } else if !allItems.isEmpty {
                        self.handleDrop(allItems, resolution: resolution)
                    } else {
                        self.present(BrowserInteractionError.invalidDrop("Could not read a valid drag and drop payload.".localized))
                    }
                }
            } catch {
                await MainActor.run {
                    self.present(error)
                }
            }
        }

        return true
    }

    func handleExternalURLDrop(_ urls: [URL], resolution: DropResolution) {
        guard !urls.isEmpty, !isBusy else { return }

        switch resolution.pane {
        case .local:
            guard let destination = resolution.destinationLocalDirectory,
                  let rootURL = localRootURL else { return }
            runTask(status: "Importing local drag...".localized) { viewModel in
                try await viewModel.transferCoordinator.moveLocal(
                    urls: urls,
                    to: destination,
                    rootURL: rootURL,
                    status: viewModel.statusReporter()
                )
                let affectedDirectories = urls.map { $0.deletingLastPathComponent().standardizedFileURL } + [destination.standardizedFileURL]
                await viewModel.invalidateLocalDirectories(affectedDirectories)
                viewModel.refreshCurrentLocalDirectoryIfNeeded(affectedDirectories: affectedDirectories)
                viewModel.statusMessage = "Processed %lld local item(s).".localized(Int64(urls.count))
            }
        case .remote:
            guard let destination = resolution.destinationRemoteDirectory, isConnected else { return }
            runTransferTask(status: "Uploading from Finder to remote...".localized) { viewModel in
                try await viewModel.transferCoordinator.upload(
                    urls: urls,
                    to: destination,
                    progress: viewModel.progressReporter(),
                    status: viewModel.statusReporter()
                )
                viewModel.statusMessage = "Uploaded %lld item(s) from Finder.".localized(Int64(urls.count))
                try await viewModel.refreshRemoteDirectory(path: viewModel.remoteCurrentPath, forceRefresh: true)
            }
        }
    }

    func ensureLocalSelection(for item: LocalItem) {
        focusedPane = .local
        if !selectedLocalItemIDs.contains(item.id) {
            selectedLocalItemIDs = [item.id]
        }
        localSelectionAnchorID = item.id
    }

    func selectOnlyLocalItem(_ item: LocalItem) {
        focusedPane = .local
        selectedLocalItemIDs = [item.id]
        localSelectionAnchorID = item.id
    }

    func ensureRemoteSelection(for item: RemoteItem) {
        focusedPane = .remote
        if !selectedRemoteItemIDs.contains(item.id) {
            selectedRemoteItemIDs = [item.id]
        }
        remoteSelectionAnchorID = item.id
    }

    func selectOnlyRemoteItem(_ item: RemoteItem) {
        focusedPane = .remote
        selectedRemoteItemIDs = [item.id]
        remoteSelectionAnchorID = item.id
    }

    func handleLocalPrimaryClick(on item: LocalItem, modifiers: NSEvent.ModifierFlags) {
        focusedPane = .local

        if modifiers.contains(.shift),
           let anchorID = localSelectionAnchorID,
           let rangeSelection = selectionRange(
            from: anchorID,
            to: item.id,
            in: localItems.map(\.id)
           ) {
            selectedLocalItemIDs = rangeSelection
            return
        }

        if modifiers.contains(.command) {
            if selectedLocalItemIDs.contains(item.id) {
                selectedLocalItemIDs.remove(item.id)
            } else {
                selectedLocalItemIDs.insert(item.id)
            }
            localSelectionAnchorID = item.id
            return
        }

        if selectedLocalItemIDs.contains(item.id), selectedLocalItemIDs.count > 1 {
            return
        }

        selectedLocalItemIDs = [item.id]
        localSelectionAnchorID = item.id
    }

    func handleRemotePrimaryClick(on item: RemoteItem, modifiers: NSEvent.ModifierFlags) {
        focusedPane = .remote

        if modifiers.contains(.shift),
           let anchorID = remoteSelectionAnchorID,
           let rangeSelection = selectionRange(
            from: anchorID,
            to: item.id,
            in: remoteItems.map(\.id)
           ) {
            selectedRemoteItemIDs = rangeSelection
            return
        }

        if modifiers.contains(.command) {
            if selectedRemoteItemIDs.contains(item.id) {
                selectedRemoteItemIDs.remove(item.id)
            } else {
                selectedRemoteItemIDs.insert(item.id)
            }
            remoteSelectionAnchorID = item.id
            return
        }

        if selectedRemoteItemIDs.contains(item.id), selectedRemoteItemIDs.count > 1 {
            return
        }

        selectedRemoteItemIDs = [item.id]
        remoteSelectionAnchorID = item.id
    }

    func transferItem(for item: LocalItem) -> BrowserTransferItem {
        BrowserTransferItem(localItem: item)
    }

    func transferItem(for item: RemoteItem) -> BrowserTransferItem {
        remoteExportCoordinator.ensureRegistered(token: remoteExporterToken, transferCoordinator: transferCoordinator)
        return BrowserTransferItem(remoteItem: item, exporterToken: remoteExporterToken)
    }

    func transferBatch(for item: LocalItem) -> BrowserTransferBatch {
        if selectedLocalItemIDs.contains(item.id), selectedLocalItemIDs.count > 1 {
            return BrowserTransferBatch(items: selectedLocalItems.map(transferItem(for:)))
        }

        return BrowserTransferBatch(items: [transferItem(for: item)])
    }

    func transferBatch(for item: RemoteItem) -> BrowserTransferBatch {
        if selectedRemoteItemIDs.contains(item.id), selectedRemoteItemIDs.count > 1 {
            return BrowserTransferBatch(items: selectedRemoteItems.map(transferItem(for:)))
        }

        return BrowserTransferBatch(items: [transferItem(for: item)])
    }

    func transferItems(forLocalIDs ids: [LocalItem.ID]) -> [BrowserTransferItem] {
        ids.compactMap { localSnapshot?.itemsByID[$0] }.map(transferItem(for:))
    }

    func transferItems(forRemoteIDs ids: [RemoteItem.ID]) -> [BrowserTransferItem] {
        ids.compactMap { remoteSnapshot?.itemsByID[$0] }.map(transferItem(for:))
    }

    func localItems(for ids: Set<LocalItem.ID>) -> [LocalItem] {
        ids.compactMap { localSnapshot?.itemsByID[$0] }
    }

    func remoteItems(for ids: Set<RemoteItem.ID>) -> [RemoteItem] {
        ids.compactMap { remoteSnapshot?.itemsByID[$0] }
    }

    private func paste(_ snapshot: ClipboardSnapshot, into pane: BrowserPaneKind) {
        switch (snapshot.sourcePane, pane) {
        case (.local, .local):
            guard let destination = localCurrentURL,
                  let rootURL = localRootURL else { return }
            let urls = snapshot.localURLs
            runTask(status: "Duplicating local items...".localized) { viewModel in
                try await viewModel.transferCoordinator.copyLocal(
                    urls: urls,
                    to: destination,
                    rootURL: rootURL,
                    status: viewModel.statusReporter()
                )
                await viewModel.invalidateLocalDirectories([destination])
                viewModel.refreshCurrentLocalDirectoryIfNeeded(affectedDirectories: [destination])
                viewModel.statusMessage = viewModel.localizedSingleOrMany(
                    count: urls.count,
                    name: urls[0].lastPathComponent,
                    singularKey: "Duplicated %@.",
                    pluralKey: "Duplicated %lld items."
                )
            }
        case (.local, .remote):
            let urls = snapshot.localURLs
            let destination = remoteCurrentPath
            runTransferTask(status: "Pasting local items to remote...".localized) { viewModel in
                try await viewModel.transferCoordinator.copyLocalToRemote(
                    urls: urls,
                    to: destination,
                    progress: viewModel.progressReporter(),
                    status: viewModel.statusReporter()
                )
                viewModel.statusMessage = viewModel.localizedSingleOrMany(
                    count: urls.count,
                    name: urls[0].lastPathComponent,
                    singularKey: "Pasted %@ to remote.",
                    pluralKey: "Pasted %lld items to remote."
                )
                try await viewModel.refreshRemoteDirectory(path: viewModel.remoteCurrentPath, forceRefresh: true)
            }
        case (.remote, .local):
            guard let destination = localCurrentURL else { return }
            let remoteItems = snapshot.remoteItems
            runTransferTask(status: "Pasting remote items to local...".localized) { viewModel in
                try await viewModel.transferCoordinator.copyRemoteToLocal(
                    items: remoteItems,
                    to: destination,
                    progress: viewModel.progressReporter(),
                    status: viewModel.statusReporter()
                )
                await viewModel.invalidateLocalDirectories([destination])
                viewModel.refreshCurrentLocalDirectoryIfNeeded(affectedDirectories: [destination])
                viewModel.statusMessage = viewModel.localizedSingleOrMany(
                    count: remoteItems.count,
                    name: remoteItems[0].name,
                    singularKey: "Pasted %@ to local.",
                    pluralKey: "Pasted %lld remote items to local."
                )
            }
        case (.remote, .remote):
            let remoteItems = snapshot.remoteItems
            let destination = remoteCurrentPath
            runTransferTask(status: "Copying remote items via temp...".localized) { viewModel in
                try await viewModel.transferCoordinator.copyRemote(
                    items: remoteItems,
                    to: destination,
                    progress: viewModel.progressReporter(),
                    status: viewModel.statusReporter()
                )
                viewModel.statusMessage = viewModel.localizedSingleOrMany(
                    count: remoteItems.count,
                    name: remoteItems[0].name,
                    singularKey: "Pasted %@ on remote.",
                    pluralKey: "Pasted %lld remote items."
                )
                try await viewModel.refreshRemoteDirectory(path: viewModel.remoteCurrentPath, forceRefresh: true)
            }
        }
    }

    private func refreshRemoteDirectory(path: String, forceRefresh: Bool = false) async throws {
        let isSameDirectory = FTPPath.normalize(path) == FTPPath.normalize(remoteCurrentPath)
        let items = try await ftpClient.list(path: path, forceRefresh: forceRefresh)
        let snapshot = makeRemoteSnapshot(from: items, previousSnapshot: isSameDirectory ? remoteDirectorySnapshot : nil)

        remoteCurrentPath = path
        applyRemoteSnapshot(snapshot, isSameDirectory: isSameDirectory)
    }

    private func restoreLocalRootForCurrentProfile() {
        guard let profile = activeLocalRootProfile else {
            clearLocalRoot()
            return
        }

        do {
            guard let resolution = try bookmarkStore.resolveRootBookmark(for: profile.id) else {
                clearLocalRoot()
                return
            }
            try activateLocalRoot(resolution.url, persistBookmark: resolution.isStale, for: profile.id)
        } catch {
            clearLocalRoot()
            present(error)
        }
    }

    private func activateLocalRoot(_ url: URL, persistBookmark: Bool, for profileID: UUID) throws {
        activeRootAccessURL?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        activeRootAccessURL = url

        if persistBookmark {
            try bookmarkStore.saveRootBookmark(for: url, profileID: profileID)
        }

        localRootURL = url
        focusedPane = .local
        requestLocalDirectoryLoad(url, forceRefresh: true)
    }

    private func clearLocalRoot() {
        activeRootAccessURL?.stopAccessingSecurityScopedResource()
        activeRootAccessURL = nil
        localRootURL = nil
        localCurrentURL = nil
        localItems = []
        localRows = []
        localDirectorySnapshot = nil
        localSnapshot = nil
        selectedLocalItemIDs = []
        localSelectionAnchorID = nil
        pendingLocalSelectionID = nil
        if inlineRenameSession?.pane == .local {
            inlineRenameSession = nil
        }
        updateLocalWatcher(for: nil)
    }

    private func updateLocalRootPath(_ path: String?, for profileID: UUID) throws {
        guard let existingProfile = profiles.first(where: { $0.id == profileID }) else {
            return
        }
        guard existingProfile.localRootPath != path else {
            return
        }

        var updatedProfile = existingProfile
        updatedProfile.localRootPath = path
        profiles = try connectionStore.saveMetadata(profile: updatedProfile)
    }

    private func requestLocalDirectoryLoad(_ url: URL, forceRefresh: Bool = false) {
        localLoadGeneration += 1
        let generation = localLoadGeneration
        let normalizedURL = url.standardizedFileURL
        let sameDirectory = localCurrentURL?.standardizedFileURL == normalizedURL
        let previousSelection = selectedLocalItemIDs
        let previousSnapshot = sameDirectory ? localDirectorySnapshot : nil

        localCurrentURL = normalizedURL
        if !sameDirectory {
            selectedLocalItemIDs = []
            localSelectionAnchorID = nil
            pendingLocalSelectionID = nil
            localItems = []
            localRows = []
            localDirectorySnapshot = nil
            localSnapshot = nil
            if inlineRenameSession?.pane == .local {
                inlineRenameSession = nil
            }
        }
        updateLocalWatcher(for: normalizedURL)

        Task { [weak self, localDirectoryService] in
            do {
                let loadResult = try await localDirectoryService.loadSnapshot(
                    at: normalizedURL,
                    forceRefresh: forceRefresh,
                    previousSnapshot: previousSnapshot
                )
                await MainActor.run {
                    guard let self, self.localLoadGeneration == generation else { return }
                    self.applyLocalSnapshot(
                        loadResult.snapshot,
                        isSameDirectory: sameDirectory,
                        previousSelection: previousSelection
                    )
                }
            } catch {
                await MainActor.run {
                    self?.present(error)
                }
            }
        }
    }

    private func updateLocalWatcher(for url: URL?) {
        guard let url else {
            localDirectoryWatcher.stopWatching()
            return
        }

        do {
            try localDirectoryWatcher.startWatching(directoryURL: url) { [weak self] watchedURL in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.localCurrentURL?.standardizedFileURL == watchedURL.standardizedFileURL else {
                        return
                    }

                    await self.localDirectoryService.invalidateDirectory(at: watchedURL)
                    self.requestLocalDirectoryLoad(watchedURL, forceRefresh: true)
                }
            }
        } catch {
            // Directory watching is best-effort and should not block local browsing.
        }
    }

    private func applyLocalSnapshot(
        _ snapshot: LocalBrowserSnapshot,
        isSameDirectory: Bool,
        previousSelection: Set<LocalItem.ID>
    ) {
        localDirectorySnapshot = snapshot
        rebuildLocalBrowserState(previousSelection: isSameDirectory ? previousSelection : [])
    }

    private func makeRemoteSnapshot(
        from items: [RemoteItem],
        previousSnapshot: RemoteBrowserSnapshot?
    ) -> RemoteBrowserSnapshot {
        let previousVersion = previousSnapshot?.version ?? remoteDirectorySnapshot?.version ?? 0
        return RemoteBrowserSnapshot(
            items: items,
            displayRows: items.map(RemoteBrowserRowModel.init),
            version: previousVersion + 1
        )
    }

    private func applyRemoteSnapshot(
        _ snapshot: RemoteBrowserSnapshot,
        isSameDirectory: Bool
    ) {
        remoteDirectorySnapshot = snapshot
        cacheCurrentRemoteSnapshot(snapshot)
        rebuildRemoteBrowserState(previousSelection: isSameDirectory ? selectedRemoteItemIDs : [])
    }

    private func rebuildLocalBrowserState(previousSelection: Set<LocalItem.ID>? = nil) {
        guard let directorySnapshot = localDirectorySnapshot else {
            localSnapshot = nil
            localItems = []
            localRows = []
            selectedLocalItemIDs = []
            localSelectionAnchorID = nil
            if inlineRenameSession?.pane == .local {
                inlineRenameSession = nil
            }
            triggerQueuedInlineRenameRestartIfPossible()
            return
        }

        let snapshot = makeLocalDisplaySnapshot(from: directorySnapshot.items, version: directorySnapshot.version)
        let validIDs = Set(snapshot.itemsByID.keys)
        var nextSelection = (previousSelection ?? selectedLocalItemIDs).intersection(validIDs)

        if let pendingLocalSelectionID, validIDs.contains(pendingLocalSelectionID) {
            nextSelection = [pendingLocalSelectionID]
            localSelectionAnchorID = pendingLocalSelectionID
            self.pendingLocalSelectionID = nil
        } else if pendingLocalSelectionID != nil {
            self.pendingLocalSelectionID = nil
        }

        localSnapshot = snapshot
        if localItems != snapshot.items {
            localItems = snapshot.items
        }
        if localRows != snapshot.displayRows {
            localRows = snapshot.displayRows
        }
        if selectedLocalItemIDs != nextSelection {
            selectedLocalItemIDs = nextSelection
        }

        if let localSelectionAnchorID, !validIDs.contains(localSelectionAnchorID) {
            self.localSelectionAnchorID = nil
        }
        if let inlineRenameSession, inlineRenameSession.pane == .local, !validIDs.contains(inlineRenameSession.itemID) {
            self.inlineRenameSession = nil
        }
        triggerQueuedInlineRenameRestartIfPossible()
    }

    private func rebuildRemoteBrowserState(previousSelection: Set<RemoteItem.ID>? = nil) {
        guard let directorySnapshot = remoteDirectorySnapshot else {
            remoteSnapshot = nil
            remoteItems = []
            remoteRows = []
            selectedRemoteItemIDs = []
            remoteSelectionAnchorID = nil
            if inlineRenameSession?.pane == .remote {
                inlineRenameSession = nil
            }
            triggerQueuedInlineRenameRestartIfPossible()
            return
        }

        let snapshot = makeRemoteDisplaySnapshot(from: directorySnapshot.items, version: directorySnapshot.version)
        let validIDs = Set(snapshot.itemsByID.keys)
        var nextSelection = (previousSelection ?? selectedRemoteItemIDs).intersection(validIDs)

        if let pendingRemoteSelectionID, validIDs.contains(pendingRemoteSelectionID) {
            nextSelection = [pendingRemoteSelectionID]
            remoteSelectionAnchorID = pendingRemoteSelectionID
            self.pendingRemoteSelectionID = nil
        } else if pendingRemoteSelectionID != nil {
            self.pendingRemoteSelectionID = nil
        }

        remoteSnapshot = snapshot
        if remoteItems != snapshot.items {
            remoteItems = snapshot.items
        }
        if remoteRows != snapshot.displayRows {
            remoteRows = snapshot.displayRows
        }
        if selectedRemoteItemIDs != nextSelection {
            selectedRemoteItemIDs = nextSelection
        }

        if let remoteSelectionAnchorID, !validIDs.contains(remoteSelectionAnchorID) {
            self.remoteSelectionAnchorID = nil
        }
        if let inlineRenameSession, inlineRenameSession.pane == .remote, !validIDs.contains(inlineRenameSession.itemID) {
            self.inlineRenameSession = nil
        }
        triggerQueuedInlineRenameRestartIfPossible()
    }

    private func makeLocalDisplaySnapshot(from items: [LocalItem], version: Int) -> LocalBrowserSnapshot {
        let filteredItems = items.filter { BrowserSearchMatcher.matches($0.name, query: localSearchText) }
        let rows = Self.sortedRows(filteredItems.map(LocalBrowserRowModel.init), using: localSortOrder)
        return LocalBrowserSnapshot(
            items: rows.map(\.item),
            displayRows: rows,
            version: version
        )
    }

    private func makeRemoteDisplaySnapshot(from items: [RemoteItem], version: Int) -> RemoteBrowserSnapshot {
        let filteredItems = items.filter { BrowserSearchMatcher.matches($0.name, query: remoteSearchText) }
        let rows = Self.sortedRows(filteredItems.map(RemoteBrowserRowModel.init), using: remoteSortOrder)
        return RemoteBrowserSnapshot(
            items: rows.map(\.item),
            displayRows: rows,
            version: version
        )
    }

    private func invalidateLocalDirectories(_ directories: [URL]) async {
        let uniqueDirectories = Set(directories.map(\.standardizedFileURL))
        for directory in uniqueDirectories {
            await localDirectoryService.invalidateDirectory(at: directory)
        }
    }

    private func refreshCurrentLocalDirectoryIfNeeded(affectedDirectories: [URL]) {
        guard let currentURL = localCurrentURL?.standardizedFileURL else {
            return
        }

        let affectedPaths = Set(affectedDirectories.map { $0.standardizedFileURL.path })
        if affectedPaths.contains(currentURL.path) {
            requestLocalDirectoryLoad(currentURL, forceRefresh: true)
        }
    }

    private func runTransferTask(status: String, operation: @escaping @MainActor (SessionViewModel) async throws -> Void) {
        runTask(status: status) { viewModel in
            viewModel.isTransferActive = true
            viewModel.transferProgressModel.clear()
            defer {
                viewModel.isTransferActive = false
                viewModel.transferProgressModel.clear()
            }

            try await operation(viewModel)
        }
    }

    private func runTask(status: String, operation: @escaping @MainActor (SessionViewModel) async throws -> Void) {
        Task { @MainActor in
            guard !isBusy else { return }
            isBusy = true
            statusMessage = status
            defer {
                isBusy = false
                if !isTransferActive {
                    transferProgressModel.clear()
                }
                triggerQueuedInlineRenameRestartIfPossible()
            }

            do {
                try await operation(self)
            } catch {
                if case FTPError.ftpsDataSessionResumptionRequired = error {
                    await ftpClient.disconnect()
                    resetRemoteSessionState()
                }
                let hasActiveConnection = await ftpClient.hasActiveConnection()
                if isConnected, !hasActiveConnection {
                    resetRemoteSessionState()
                } else if isConnected, connectedProfileID == nil {
                    isConnected = false
                }
                isTransferActive = false
                transferProgressModel.clear()
                present(error)
            }
        }
    }

    private func progressReporter() -> @Sendable (TransferSnapshot) -> Void {
        let progressModel = transferProgressModel
        return { snapshot in
            Task { @MainActor in
                progressModel.update(snapshot)
            }
        }
    }

    private func statusReporter() -> @Sendable (String) -> Void {
        let viewModel = self
        return { message in
            Task { @MainActor in
                viewModel.statusMessage = message
            }
        }
    }

    private func remoteItem(from transferItem: BrowserTransferItem) -> RemoteItem? {
        guard let remotePath = transferItem.remotePath else { return nil }
        return RemoteItem(
            path: remotePath,
            name: transferItem.name,
            kind: transferItem.isDirectory ? .directory : .file,
            size: nil,
            modifiedAt: nil
        )
    }

    private func present(_ error: Error) {
        queuedInlineRenameRestart = false
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        errorMessage = message
        statusMessage = message
    }

    private var hasPendingRenameSelectionTransition: Bool {
        switch focusedPane {
        case .local:
            return pendingLocalSelectionID != nil
        case .remote:
            return pendingRemoteSelectionID != nil
        }
    }

    private func triggerQueuedInlineRenameRestartIfPossible() {
        guard queuedInlineRenameRestart,
              !isBusy,
              !isInlineRenaming,
              canRenameFocusedSelection else {
            return
        }

        queuedInlineRenameRestart = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.renameFocusedSelection()
        }
    }

    private func resetRemoteSessionState() {
        connectingProfileID = nil
        connectionProgressMessage = nil
        isRemoteDirectoryLoading = false
        connectedProfileID = nil
        isConnected = false
        remoteItems = []
        remoteRows = []
        remoteDirectorySnapshot = nil
        remoteSnapshot = nil
        remoteCurrentPath = "/"
        selectedRemoteItemIDs = []
        remoteSelectionAnchorID = nil
        pendingRemoteSelectionID = nil
        if inlineRenameSession?.pane == .remote {
            inlineRenameSession = nil
        }
        isTransferActive = false
        transferProgressModel.clear()
    }

    private func cacheCurrentRemoteSnapshot(_ snapshot: RemoteBrowserSnapshot) {
        guard let connectedProfileID else {
            return
        }

        cachedRemoteBrowserStates[connectedProfileID] = CachedRemoteBrowserState(
            path: remoteCurrentPath,
            snapshot: snapshot
        )
    }

    private func cachedRemoteSnapshot(for profileID: UUID, path: String) -> RemoteBrowserSnapshot? {
        guard let cachedState = cachedRemoteBrowserStates[profileID],
              FTPPath.normalize(cachedState.path) == FTPPath.normalize(path) else {
            return nil
        }

        return cachedState.snapshot
    }

    private func isInsideRoot(_ candidate: URL, root: URL) -> Bool {
        let rootPathComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        return candidateComponents.starts(with: rootPathComponents)
    }

    private func selectionRange<ID: Hashable>(
        from anchorID: ID,
        to targetID: ID,
        in orderedIDs: [ID]
    ) -> Set<ID>? {
        guard let anchorIndex = orderedIDs.firstIndex(of: anchorID),
              let targetIndex = orderedIDs.firstIndex(of: targetID) else {
            return nil
        }

        let lowerBound = min(anchorIndex, targetIndex)
        let upperBound = max(anchorIndex, targetIndex)
        return Set(orderedIDs[lowerBound...upperBound])
    }

    private func preferredClipboardSnapshot() -> ClipboardSnapshot? {
        clipboardSnapshot ?? clipboardService.currentSnapshot()
    }

    private func writeClipboardToPasteboard(_ snapshot: ClipboardSnapshot) {
        clipboardService.write(snapshot)
    }

    private func pasteboardFileURLs() -> [URL] {
        clipboardService.fileURLs()
    }

    private static func decodeDropPayload(from providers: [NSItemProvider]) async throws -> (batches: [BrowserTransferBatch], items: [BrowserTransferItem], urls: [URL]) {
        var batches: [BrowserTransferBatch] = []
        var items: [BrowserTransferItem] = []
        var urls: [URL] = []

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.browserTransferBatch.identifier),
               let batch = try await loadTransferable(from: provider, as: BrowserTransferBatch.self) {
                batches.append(batch)
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.browserTransferItem.identifier),
               let item = try await loadTransferable(from: provider, as: BrowserTransferItem.self) {
                items.append(item)
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = try await loadTransferable(from: provider, as: URL.self) {
                urls.append(url)
            }
        }

        return (batches, items, urls)
    }

    private static func loadTransferable<T: Transferable>(
        from provider: NSItemProvider,
        as type: T.Type
    ) async throws -> T? {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: type) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func localizedStatusMessageForCurrentState() -> String {
        guard let profile = connectedProfile else {
            return "Not connected.".localized
        }
        return localizedConnectedStatusMessage(for: profile)
    }

    private func localizedConnectedStatusMessage(for profile: ConnectionProfile) -> String {
        if profile.protocolMode == .ftp {
            return L10n.format("Connected to %@ via insecure FTP.", profile.host)
        }
        return L10n.format("Connected to %@.", profile.host)
    }

    private func localizedSelectionDescription(count: Int, name: String) -> String {
        count == 1 ? name : "%lld selected items".localized(Int64(count))
    }

    private func localizedSingleOrMany(count: Int, name: String, singularKey: String, pluralKey: String) -> String {
        count == 1 ? singularKey.localized(name) : pluralKey.localized(Int64(count))
    }

    private func syncSavedSitesIfNeeded() async {
        let localSnapshot = connectionStore.loadSnapshot(forceRefresh: true)

        do {
            let resolution = try await appleSyncController.syncIfNeeded(localSnapshot: localSnapshot)
            guard case .applyRemote(let remoteSnapshot) = resolution else {
                return
            }

            let previousSelectedProfileID = selectedProfileID
            let syncedProfiles = try connectionStore.replaceAll(
                profiles: remoteSnapshot.profiles,
                updatedAt: remoteSnapshot.updatedAt
            )
            profiles = syncedProfiles

            selectedProfileID = preferredSavedSiteSelection(
                in: syncedProfiles,
                currentSelection: previousSelectedProfileID
            )
            clearLastConnectedProfileIfMissing(in: syncedProfiles)

            restoreLocalRootForCurrentProfile()
        } catch {
            present(error)
        }
    }

    private var lastConnectedProfileID: UUID? {
        guard let rawValue = userDefaults.string(forKey: Self.lastConnectedProfileIDStorageKey) else {
            return nil
        }
        return UUID(uuidString: rawValue)
    }

    private func persistLastConnectedProfileID(_ profileID: UUID?) {
        if let profileID {
            userDefaults.set(profileID.uuidString, forKey: Self.lastConnectedProfileIDStorageKey)
        } else {
            userDefaults.removeObject(forKey: Self.lastConnectedProfileIDStorageKey)
        }
    }

    private func preferredSavedSiteSelection(
        in profiles: [ConnectionProfile],
        currentSelection: UUID?
    ) -> UUID? {
        if let currentSelection,
           profiles.contains(where: { $0.id == currentSelection }) {
            return currentSelection
        }

        if let lastConnectedProfileID,
           profiles.contains(where: { $0.id == lastConnectedProfileID }) {
            return lastConnectedProfileID
        }

        return profiles.first?.id
    }

    private func clearLastConnectedProfileIfMissing(in profiles: [ConnectionProfile]) {
        guard let lastConnectedProfileID,
              !profiles.contains(where: { $0.id == lastConnectedProfileID }) else {
            return
        }
        persistLastConnectedProfileID(nil)
    }

    private static func uniqueStandardizedURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []

        for url in urls {
            let normalizedURL = url.standardizedFileURL
            if seen.insert(normalizedURL.path).inserted {
                result.append(normalizedURL)
            }
        }

        return result
    }
}

enum CertificatePrompt {
    @MainActor
    static func presentTrustDialog(host: String, reason: String) -> Bool {
        let alert = NSAlert()
        alert.icon = AppIconProvider.image()
        alert.messageText = "Untrusted FTPS Certificate".localized
        alert.informativeText = "The server %@ returned an invalid or self-signed certificate.\n\n%@\n\nDo you want to trust this certificate for the current session?".localized(host, reason)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Trust Once".localized)
        alert.addButton(withTitle: "Cancel".localized)
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    static func presentDeleteDialog(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.icon = AppIconProvider.image()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete".localized)
        alert.addButton(withTitle: "Cancel".localized)
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    static func presentTextInputDialog(title: String, message: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.icon = AppIconProvider.image()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK".localized)
        alert.addButton(withTitle: "Cancel".localized)

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.stringValue = defaultValue
        alert.accessoryView = input

        let response = alert.runModal()
        let trimmed = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard response == .alertFirstButtonReturn, !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
