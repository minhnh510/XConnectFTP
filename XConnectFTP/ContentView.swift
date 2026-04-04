//
//  ContentView.swift
//  XConnectFTP
//
//  Created by Codex on 21/3/26.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @AppStorage(AppLanguage.storageKey) private var selectedLanguageRawValue = AppLanguage.system.rawValue
    @ObservedObject private var appleSyncController: AppleSyncController
    @StateObject private var viewModel: SessionViewModel
    @Namespace private var localDragNamespace
    @Namespace private var remoteDragNamespace
    @State private var localPaneDropActive = false
    @State private var remotePaneDropActive = false
    @State private var localDropTargetID: LocalItem.ID?
    @State private var remoteDropTargetID: RemoteItem.ID?

    private var selectedLanguageLocale: Locale {
        let language = AppLanguage(rawValue: selectedLanguageRawValue) ?? .system
        return language.locale
    }

    init(appleSyncController: AppleSyncController) {
        self.appleSyncController = appleSyncController
        _viewModel = StateObject(wrappedValue: SessionViewModel(appleSyncController: appleSyncController))
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailContent
        }
        .sheet(isPresented: $viewModel.isPresentingSiteEditor) {
            SiteEditorView(draft: viewModel.siteEditorDraft) { draft in
                viewModel.saveSiteEditor(draft)
            }
        }
        .alert("Lỗi".localized, isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { newValue in
                if !newValue {
                    viewModel.errorMessage = nil
                }
            }
        )) {
            Button("OK".localized, role: .cancel) {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onDeleteCommand {
            viewModel.deleteFocusedSelection()
        }
        .onCommand(#selector(NSResponder.selectAll(_:))) {
            viewModel.selectAllInFocusedPane()
        }
        .onCommand(#selector(NSResponder.insertNewline(_:))) {
            viewModel.handleReturnKey()
        }
        .onCommand(#selector(NSResponder.cancelOperation(_:))) {
            viewModel.cancelInlineRename()
        }
        .onCommand(#selector(NSText.copy(_:))) {
            viewModel.copyFocusedSelection()
        }
        .onCommand(#selector(NSText.paste(_:))) {
            viewModel.pasteIntoFocusedPane()
        }
        .background(
            BrowserWindowKeyFallback(
                isInlineRenaming: viewModel.isInlineRenaming,
                canHandleReturn: viewModel.canHandleRenameReturnKey,
                canHandleEscape: viewModel.isInlineRenaming,
                onReturn: viewModel.handleReturnKey,
                onEscape: viewModel.cancelInlineRename
            )
        )
        .focusedSceneValue(\.browserCommandActions, BrowserCommandActions(
            handleReturn: viewModel.handleReturnKey,
            canHandleReturn: viewModel.canHandleRenameReturnKey
        ))
        .environment(\.locale, selectedLanguageLocale)
        .onChange(of: selectedLanguageRawValue) { _ in
            viewModel.handleLanguageChange()
        }
        .onChange(of: viewModel.selectedProfileID) { _ in
            viewModel.handleSelectedProfileChange()
        }
        .onChange(of: appleSyncController.syncGeneration) { _ in
            Task {
                await viewModel.handleAppleSyncConfigurationChange()
            }
        }
        .task {
            await viewModel.bootstrap()
        }
        .frame(minWidth: 1260, minHeight: 800)
    }

    private var sidebar: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Saved Sites".localized)
                    .font(.title3.weight(.semibold))
                Spacer()
            }

            Button {
                viewModel.openAddSiteEditor()
            } label: {
                Label("New Site".localized, systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            List(selection: $viewModel.selectedProfileID) {
                ForEach(viewModel.profiles) { profile in
                    SavedSiteRow(
                        profile: profile,
                        isConnected: viewModel.isProfileConnected(profile),
                        isConnecting: viewModel.isProfileConnecting(profile),
                        onEdit: { viewModel.openEditSiteEditor(for: profile) },
                        onDelete: { viewModel.deleteProfile(profile) }
                    )
                    .tag(profile.id)
                    .contextMenu {
                        Button("Connect".localized) {
                            viewModel.connect(to: profile)
                        }
                        .disabled(!viewModel.canConnect(profile: profile))

                        Button("Disconnect".localized) {
                            viewModel.disconnect(profile: profile)
                        }
                        .disabled(!viewModel.canDisconnect(profile: profile))

                        Divider()

                        Button("Edit".localized) {
                            viewModel.openEditSiteEditor(for: profile)
                        }

                        Button("Delete".localized, role: .destructive) {
                            viewModel.deleteProfile(profile)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .background(
                ListDoubleClickBridge {
                    viewModel.connect()
                }
            )
        }
        .padding()
        .navigationSplitViewColumnWidth(min: 260, ideal: 300)
    }

    private var detailContent: some View {
        VStack(spacing: 16) {
            actionBar

            HSplitView {
                localPane
                remotePane
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footerBar
        }
        .padding()
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.displayProfile?.name ?? "Chưa chọn site".localized)
                        .font(.title3.weight(.semibold))
                    if let profile = viewModel.displayProfile {
                        Text("\(profile.host):\(profile.port) • \(profile.username) • \(profile.protocolMode.localizedDisplayName)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if let localRootSummary = viewModel.localRootSummary {
                            Text(localRootSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } else {
                        Text("Chọn hoặc tạo saved site để bắt đầu kết nối.".localized)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                HStack {
                    SettingsToolbarButton()

                    Button("Choose Local Root".localized) {
                        viewModel.chooseLocalRoot()
                    }
                    .disabled(!viewModel.canChooseLocalRoot)

                    Button {
                        viewModel.connect()
                    } label: {
                        HStack(spacing: 8) {
                            Text("Connect".localized)
                            if viewModel.isConnecting {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                    .disabled(!viewModel.canConnect)

                    Button("Disconnect".localized) {
                        viewModel.disconnect()
                    }
                    .disabled(!viewModel.canDisconnect)
                }
            }

            if let progressMessage = viewModel.actionBarProgressMessage {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)

                    Text(progressMessage)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if let warning = viewModel.insecureFTPWarningMessage {
                HStack(alignment: .top, spacing: 10) {
                    Label("Insecure FTP".localized, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.orange.opacity(0.12))
                        .clipShape(Capsule())

                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Refresh".localized) {
                    viewModel.refreshRemoteDirectory()
                }
                .disabled(!viewModel.isConnected || viewModel.isBusy)

                Button("Upload".localized) {
                    viewModel.uploadSelectedLocalItems()
                }
                .disabled(!viewModel.canUpload)

                Button("Download".localized) {
                    viewModel.downloadSelectedRemoteItems()
                }
                .disabled(!viewModel.canDownload)

                Button("New Folder".localized) {
                    viewModel.createRemoteFolder()
                }
                .disabled(!viewModel.isConnected || viewModel.isBusy)

                Button("Rename".localized) {
                    viewModel.renameFocusedSelection()
                }
                .disabled(!viewModel.canRenameFocusedSelection)

                Button("Delete".localized, role: .destructive) {
                    viewModel.deleteFocusedSelection()
                }
                .disabled(!viewModel.canDeleteFocusedSelection)

                if viewModel.isTransferActive {
                    Button("Cancel Transfer".localized, role: .destructive) {
                        viewModel.cancelTransfer()
                    }
                    .disabled(viewModel.isBusy == false)
                }
            }
        }
        .padding(16)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var localPane: some View {
        BrowserPane(
            title: "Local".localized,
            itemCount: viewModel.localRows.count,
            selectionCount: viewModel.selectedLocalItemIDs.count,
            isDropTargeted: localPaneDropActive || localDropTargetID != nil
        ) {
            if let currentURL = viewModel.localCurrentURL {
                paneHeader(
                    path: currentURL.path,
                    searchText: $viewModel.localSearchText,
                    onUp: viewModel.goToLocalParent,
                    canGoUp: viewModel.localRootURL != nil && currentURL != viewModel.localRootURL
                )

                LocalBrowserTable(
                    viewModel: viewModel,
                    currentURL: currentURL,
                    dragNamespace: localDragNamespace,
                    paneDropActive: $localPaneDropActive,
                    dropTargetID: $localDropTargetID
                )
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            } else {
                PaneUnavailableView(
                    title: "Chưa có thư mục local".localized,
                    systemImage: "folder.badge.questionmark",
                    description: viewModel.localPaneEmptyDescription
                )
            }
        }
        .background(
            BrowserPaneKeyHandler(
                isActive: viewModel.focusedPane == .local,
                isInlineRenaming: viewModel.isInlineRenaming,
                canHandleReturn: viewModel.canHandleRenameReturnKey,
                canHandleEscape: viewModel.isInlineRenaming,
                onReturn: viewModel.handleReturnKey,
                onEscape: viewModel.cancelInlineRename
            )
        )
        .onTapGesture {
            viewModel.setFocusedPane(.local)
        }
    }

    private var remotePane: some View {
        BrowserPane(
            title: "Remote".localized,
            itemCount: viewModel.remoteRows.count,
            selectionCount: viewModel.selectedRemoteItemIDs.count,
            isDropTargeted: remotePaneDropActive || remoteDropTargetID != nil
        ) {
            if viewModel.isConnected {
                paneHeader(
                    path: viewModel.remoteCurrentPath,
                    searchText: $viewModel.remoteSearchText,
                    onUp: viewModel.goToRemoteParent,
                    canGoUp: viewModel.remoteCurrentPath != "/"
                )

                RemoteBrowserTable(
                    viewModel: viewModel,
                    dragNamespace: remoteDragNamespace,
                    paneDropActive: $remotePaneDropActive,
                    dropTargetID: $remoteDropTargetID
                )
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            } else {
                PaneUnavailableView(
                    title: "Chưa kết nối remote".localized,
                    systemImage: "network.slash",
                    description: "Kết nối tới một site FTP hoặc FTPS để duyệt file remote.".localized
                )
            }
        }
        .background(
            BrowserPaneKeyHandler(
                isActive: viewModel.focusedPane == .remote,
                isInlineRenaming: viewModel.isInlineRenaming,
                canHandleReturn: viewModel.canHandleRenameReturnKey,
                canHandleEscape: viewModel.isInlineRenaming,
                onReturn: viewModel.handleReturnKey,
                onEscape: viewModel.cancelInlineRename
            )
        )
        .onTapGesture {
            viewModel.setFocusedPane(.remote)
        }
    }

    private func paneHeader(
        path: String,
        searchText: Binding<String>,
        onUp: @escaping () -> Void,
        canGoUp: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(path)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    onUp()
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(!canGoUp || viewModel.isBusy)
            }

            BrowserPaneSearchField(text: searchText)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    private var footerBar: some View {
        TransferFooterView(
            isConnected: viewModel.isConnected,
            isBusy: viewModel.isBusy,
            statusMessage: viewModel.statusMessage,
            progressModel: viewModel.transferProgressModel
        )
    }
}

private struct SettingsToolbarButton: View {
    var body: some View {
        if #available(macOS 14.0, *) {
            ModernSettingsToolbarButton()
        } else {
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Image(systemName: "gearshape")
                    .imageScale(.medium)
            }
            .help("Settings".localized)
        }
    }
}

@available(macOS 14.0, *)
private struct ModernSettingsToolbarButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            openSettings()
        } label: {
            Image(systemName: "gearshape")
                .imageScale(.medium)
        }
        .help("Settings".localized)
    }
}

private func currentModifierFlags() -> NSEvent.ModifierFlags {
    NSApp.currentEvent?.modifierFlags ?? []
}

private struct LocalBrowserTable: View {
    @ObservedObject var viewModel: SessionViewModel
    let currentURL: URL
    let dragNamespace: Namespace.ID
    @Binding var paneDropActive: Bool
    @Binding var dropTargetID: LocalItem.ID?

    var body: some View {
        let selection = $viewModel.selectedLocalItemIDs

        return Table(viewModel.localRows, selection: selection, sortOrder: $viewModel.localSortOrder) {
            TableColumn("Name".localized, sortUsing: BrowserRowComparator<LocalBrowserRowModel>(.name)) { row in
                LocalTableNameCell(
                    viewModel: viewModel,
                    row: row,
                    dragNamespace: dragNamespace,
                    dropTargetID: $dropTargetID
                )
            }
            TableColumn("Size".localized, sortUsing: BrowserRowComparator<LocalBrowserRowModel>(.size)) { row in
                BrowserMetadataCell(
                    text: row.sizeText,
                    alignment: .trailing
                )
            }
                .width(min: 90, ideal: 110, max: 140)
            TableColumn("Modified".localized, sortUsing: BrowserRowComparator<LocalBrowserRowModel>(.modified)) { row in
                BrowserMetadataCell(
                    text: row.modifiedText,
                    alignment: .leading
                )
            }
                .width(min: 160, ideal: 190)
        }
        .onDrop(of: [.browserTransferBatch, .browserTransferItem, .fileURL], isTargeted: $paneDropActive) { providers in
            viewModel.handleDropProviders(
                providers,
                resolution: DropResolution(
                    pane: .local,
                    destinationLocalDirectory: currentURL,
                    destinationRemoteDirectory: nil
                )
            )
        }
        .contextMenu(forSelectionType: LocalItem.ID.self) { selectedIDs in
            let effectiveIDs = effectiveSelection(from: selectedIDs)

            Button("Open".localized) {
                applySelection(effectiveIDs)
                viewModel.openPrimarySelection()
            }
            .disabled(!canOpen(effectiveIDs))

            Button("Open in Finder".localized) {
                applySelection(effectiveIDs)
                viewModel.openLocalSelectionInFinder()
            }
            .disabled(!canOpenInFinder(effectiveIDs))

            Button("Copy".localized) {
                applySelection(effectiveIDs)
                viewModel.copyFocusedSelection()
            }
            .disabled(effectiveIDs.isEmpty)

            Button("Paste".localized) {
                viewModel.paste(into: .local)
            }
            .disabled(!viewModel.canPaste(into: .local))

            Button("Rename".localized) {
                applySelection(effectiveIDs)
                viewModel.renameFocusedSelection()
            }
            .disabled(effectiveIDs.count != 1)

            Button("Delete".localized, role: .destructive) {
                applySelection(effectiveIDs)
                viewModel.deleteFocusedSelection()
            }
            .disabled(effectiveIDs.isEmpty)
        } primaryAction: { selectedIDs in
            applySelection(selectedIDs)
            viewModel.openPrimarySelection()
        }
        .onChange(of: viewModel.selectedLocalItemIDs) { _ in
            viewModel.handleLocalSelectionChange()
        }
    }

    private func applySelection(_ ids: Set<LocalItem.ID>) {
        viewModel.setFocusedPane(.local)
        if !ids.isEmpty {
            viewModel.selectedLocalItemIDs = ids
        }
    }

    private func canOpen(_ ids: Set<LocalItem.ID>) -> Bool {
        let selectedItems = viewModel.localItems(for: ids)
        return selectedItems.count == 1 && selectedItems[0].isDirectory
    }

    private func canOpenInFinder(_ ids: Set<LocalItem.ID>) -> Bool {
        !viewModel.isBusy
    }

    private func effectiveSelection(from ids: Set<LocalItem.ID>) -> Set<LocalItem.ID> {
        ids.isEmpty ? viewModel.selectedLocalItemIDs : ids
    }
}

private struct RemoteBrowserTable: View {
    @ObservedObject var viewModel: SessionViewModel
    let dragNamespace: Namespace.ID
    @Binding var paneDropActive: Bool
    @Binding var dropTargetID: RemoteItem.ID?

    var body: some View {
        let selection = $viewModel.selectedRemoteItemIDs

        return Table(viewModel.remoteRows, selection: selection, sortOrder: $viewModel.remoteSortOrder) {
            TableColumn("Name".localized, sortUsing: BrowserRowComparator<RemoteBrowserRowModel>(.name)) { row in
                RemoteTableNameCell(
                    viewModel: viewModel,
                    row: row,
                    dragNamespace: dragNamespace,
                    dropTargetID: $dropTargetID
                )
            }
            TableColumn("Size".localized, sortUsing: BrowserRowComparator<RemoteBrowserRowModel>(.size)) { row in
                BrowserMetadataCell(
                    text: row.sizeText,
                    alignment: .trailing
                )
            }
                .width(min: 90, ideal: 110, max: 140)
            TableColumn("Modified".localized, sortUsing: BrowserRowComparator<RemoteBrowserRowModel>(.modified)) { row in
                BrowserMetadataCell(
                    text: row.modifiedText,
                    alignment: .leading
                )
            }
                .width(min: 160, ideal: 190)
        }
        .onDrop(of: [.browserTransferBatch, .browserTransferItem, .fileURL], isTargeted: $paneDropActive) { providers in
            viewModel.handleDropProviders(
                providers,
                resolution: DropResolution(
                    pane: .remote,
                    destinationLocalDirectory: nil,
                    destinationRemoteDirectory: viewModel.remoteCurrentPath
                )
            )
        }
        .contextMenu(forSelectionType: RemoteItem.ID.self) { selectedIDs in
            let effectiveIDs = effectiveSelection(from: selectedIDs)

            Button("Open".localized) {
                applySelection(effectiveIDs)
                viewModel.openPrimarySelection()
            }
            .disabled(!canOpen(effectiveIDs))

            Button("Copy".localized) {
                applySelection(effectiveIDs)
                viewModel.copyFocusedSelection()
            }
            .disabled(effectiveIDs.isEmpty)

            Button("Paste".localized) {
                viewModel.paste(into: .remote)
            }
            .disabled(!viewModel.canPaste(into: .remote))

            Button("Download".localized) {
                applySelection(effectiveIDs)
                viewModel.downloadSelectedRemoteItems()
            }
            .disabled(effectiveIDs.isEmpty)

            Button("Rename".localized) {
                applySelection(effectiveIDs)
                viewModel.renameFocusedSelection()
            }
            .disabled(effectiveIDs.count != 1)

            Button("Delete".localized, role: .destructive) {
                applySelection(effectiveIDs)
                viewModel.deleteFocusedSelection()
            }
            .disabled(effectiveIDs.isEmpty)
        } primaryAction: { selectedIDs in
            applySelection(selectedIDs)
            viewModel.openPrimarySelection()
        }
        .onChange(of: viewModel.selectedRemoteItemIDs) { _ in
            viewModel.handleRemoteSelectionChange()
        }
    }

    private func applySelection(_ ids: Set<RemoteItem.ID>) {
        viewModel.setFocusedPane(.remote)
        if !ids.isEmpty {
            viewModel.selectedRemoteItemIDs = ids
        }
    }

    private func canOpen(_ ids: Set<RemoteItem.ID>) -> Bool {
        let selectedItems = viewModel.remoteItems(for: ids)
        return selectedItems.count == 1 && selectedItems[0].isDirectory
    }

    private func effectiveSelection(from ids: Set<RemoteItem.ID>) -> Set<RemoteItem.ID> {
        ids.isEmpty ? viewModel.selectedRemoteItemIDs : ids
    }
}

private struct LocalTableNameCell: View {
    @ObservedObject var viewModel: SessionViewModel
    let row: LocalBrowserRowModel
    let dragNamespace: Namespace.ID
    @Binding var dropTargetID: LocalItem.ID?
    @State private var activateEnclosingTable: (() -> Void)?

    var body: some View {
        let item = row.item
        if viewModel.isInlineRenamingLocalItem(item) {
            InlineRenameBrowserNameCell(
                iconName: row.iconName,
                isDropTarget: false,
                text: Binding(
                    get: { viewModel.inlineRenameText(for: .local, itemID: item.id) },
                    set: { viewModel.updateInlineRenameText($0, for: .local, itemID: item.id) }
                ),
                activationID: item.id,
                selectsNameStem: viewModel.shouldSelectNameStemForInlineRename(in: .local, itemID: item.id),
                onSubmit: viewModel.handleReturnKey,
                onCancel: viewModel.cancelInlineRename
            )
        } else {
            let destination = DropResolution(
                pane: .local,
                destinationLocalDirectory: item.url,
                destinationRemoteDirectory: nil
            )

            let baseCell = BrowserNameCell(
                name: row.name,
                iconName: row.iconName,
                isDropTarget: dropTargetID == item.id
            )
            .contextMenu {
                Button("Open".localized) {
                    viewModel.selectOnlyLocalItem(item)
                    viewModel.openPrimarySelection()
                }
                .disabled(!item.isDirectory)

                Button("Open in Finder".localized) {
                    viewModel.selectOnlyLocalItem(item)
                    viewModel.openLocalSelectionInFinder()
                }
                .disabled(viewModel.isBusy)

                Button("Copy".localized) {
                    viewModel.selectOnlyLocalItem(item)
                    viewModel.copyFocusedSelection()
                }
                .disabled(viewModel.isBusy)

                Button("Paste".localized) {
                    viewModel.paste(into: .local)
                }
                .disabled(!viewModel.canPaste(into: .local))

                Button("Rename".localized) {
                    viewModel.selectOnlyLocalItem(item)
                    viewModel.renameFocusedSelection()
                }
                .disabled(viewModel.isBusy)

                Button("Delete".localized, role: .destructive) {
                    viewModel.selectOnlyLocalItem(item)
                    viewModel.deleteFocusedSelection()
                }
                .disabled(viewModel.isBusy)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture().onEnded {
                    activateEnclosingTable?()
                    viewModel.handleLocalPrimaryClick(on: item, modifiers: currentModifierFlags())
                }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    activateEnclosingTable?()
                    viewModel.selectOnlyLocalItem(item)
                    viewModel.openPrimarySelection()
                }
            )
            .background(
                TableFirstResponderBridge(activate: $activateEnclosingTable)
            )

            if item.isDirectory {
                draggableCell(baseCell)
                    .dropDestination(for: BrowserTransferBatch.self, action: { batchItems, _ in
                        for batch in batchItems {
                            viewModel.handleDrop(batch.items, resolution: destination)
                        }
                        return !batchItems.isEmpty
                    }, isTargeted: { isTargeted in
                        updateDropTarget(isTargeted)
                    })
                    .dropDestination(for: BrowserTransferItem.self, action: { items, _ in
                        viewModel.handleDrop(items, resolution: destination)
                        return true
                    }, isTargeted: { isTargeted in
                        updateDropTarget(isTargeted)
                    })
                    .dropDestination(for: URL.self, action: { urls, _ in
                        viewModel.handleExternalURLDrop(urls, resolution: destination)
                        return true
                    }, isTargeted: { isTargeted in
                        updateDropTarget(isTargeted)
                    })
            } else {
                draggableCell(baseCell)
            }
        }
    }

    private func updateDropTarget(_ isTargeted: Bool) {
        if isTargeted {
            dropTargetID = row.id
        } else if dropTargetID == row.id {
            dropTargetID = nil
        }
    }

    @ViewBuilder
    private func draggableCell<Content: View>(_ cell: Content) -> some View {
        if viewModel.selectedLocalItemIDs.contains(row.id), viewModel.selectedLocalItemIDs.count > 1 {
            cell.draggable(viewModel.transferBatch(for: row.item))
        } else {
            cell.draggable(viewModel.transferItem(for: row.item))
        }
    }
}

private struct RemoteTableNameCell: View {
    @ObservedObject var viewModel: SessionViewModel
    let row: RemoteBrowserRowModel
    let dragNamespace: Namespace.ID
    @Binding var dropTargetID: RemoteItem.ID?
    @State private var activateEnclosingTable: (() -> Void)?

    var body: some View {
        let item = row.item
        if viewModel.isInlineRenamingRemoteItem(item) {
            InlineRenameBrowserNameCell(
                iconName: row.iconName,
                isDropTarget: false,
                text: Binding(
                    get: { viewModel.inlineRenameText(for: .remote, itemID: item.id) },
                    set: { viewModel.updateInlineRenameText($0, for: .remote, itemID: item.id) }
                ),
                activationID: item.id,
                selectsNameStem: viewModel.shouldSelectNameStemForInlineRename(in: .remote, itemID: item.id),
                onSubmit: viewModel.handleReturnKey,
                onCancel: viewModel.cancelInlineRename
            )
        } else {
            let destination = DropResolution(
                pane: .remote,
                destinationLocalDirectory: nil,
                destinationRemoteDirectory: item.path
            )

            let baseCell = BrowserNameCell(
                name: row.name,
                iconName: row.iconName,
                isDropTarget: dropTargetID == item.id
            )
            .contextMenu {
                Button("Open".localized) {
                    viewModel.selectOnlyRemoteItem(item)
                    viewModel.openPrimarySelection()
                }
                .disabled(!item.isDirectory)

                Button("Copy".localized) {
                    viewModel.selectOnlyRemoteItem(item)
                    viewModel.copyFocusedSelection()
                }
                .disabled(viewModel.isBusy || !viewModel.isConnected)

                Button("Paste".localized) {
                    viewModel.paste(into: .remote)
                }
                .disabled(!viewModel.canPaste(into: .remote))

                Button("Download".localized) {
                    viewModel.selectOnlyRemoteItem(item)
                    viewModel.downloadSelectedRemoteItems()
                }
                .disabled(viewModel.isBusy || !viewModel.isConnected)

                Button("Rename".localized) {
                    viewModel.selectOnlyRemoteItem(item)
                    viewModel.renameFocusedSelection()
                }
                .disabled(viewModel.isBusy || !viewModel.isConnected)

                Button("Delete".localized, role: .destructive) {
                    viewModel.selectOnlyRemoteItem(item)
                    viewModel.deleteFocusedSelection()
                }
                .disabled(viewModel.isBusy || !viewModel.isConnected)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture().onEnded {
                    activateEnclosingTable?()
                    viewModel.handleRemotePrimaryClick(on: item, modifiers: currentModifierFlags())
                }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    activateEnclosingTable?()
                    viewModel.selectOnlyRemoteItem(item)
                    viewModel.openPrimarySelection()
                }
            )
            .background(
                TableFirstResponderBridge(activate: $activateEnclosingTable)
            )

            if item.isDirectory {
                draggableCell(baseCell)
                    .dropDestination(for: BrowserTransferBatch.self, action: { batchItems, _ in
                        for batch in batchItems {
                            viewModel.handleDrop(batch.items, resolution: destination)
                        }
                        return !batchItems.isEmpty
                    }, isTargeted: { isTargeted in
                        updateDropTarget(isTargeted)
                    })
                    .dropDestination(for: BrowserTransferItem.self, action: { items, _ in
                        viewModel.handleDrop(items, resolution: destination)
                        return true
                    }, isTargeted: { isTargeted in
                        updateDropTarget(isTargeted)
                    })
                    .dropDestination(for: URL.self, action: { urls, _ in
                        viewModel.handleExternalURLDrop(urls, resolution: destination)
                        return true
                    }, isTargeted: { isTargeted in
                        updateDropTarget(isTargeted)
                    })
            } else {
                draggableCell(baseCell)
            }
        }
    }

    private func updateDropTarget(_ isTargeted: Bool) {
        if isTargeted {
            dropTargetID = row.id
        } else if dropTargetID == row.id {
            dropTargetID = nil
        }
    }

    @ViewBuilder
    private func draggableCell<Content: View>(_ cell: Content) -> some View {
        if viewModel.selectedRemoteItemIDs.contains(row.id), viewModel.selectedRemoteItemIDs.count > 1 {
            cell.draggable(viewModel.transferBatch(for: row.item))
        } else {
            cell.draggable(viewModel.transferItem(for: row.item))
        }
    }
}

private struct BrowserMetadataCell: View {
    let text: String
    let alignment: Alignment

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}

private struct BrowserPaneSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search".localized, text: $text)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        }
    }
}

private struct BrowserPane<Content: View>: View {
    let title: String
    let itemCount: Int
    let selectionCount: Int
    let isDropTargeted: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(L10n.format("%lld selected • %lld items", selectionCount, itemCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct PaneUnavailableView: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .medium))
            Text(title)
                .font(.headline)
            Text(description)
                .font(.callout)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct SavedSiteRow: View {
    let profile: ConnectionProfile
    let isConnected: Bool
    let isConnecting: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(.headline)

                    if isConnecting {
                        ProgressView()
                            .controlSize(.small)
                    } else if isConnected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                Text("\(profile.host):\(profile.port) • \(profile.protocolMode.localizedDisplayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Button(action: onEdit) {
                    Image(systemName: "square.and.pencil")
                        .symbolVariant(.fill)
                }
                .buttonStyle(.borderless)
                .help("Edit".localized)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete".localized)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(profile.name))
        .accessibilityHint(Text("Saved Site".localized))
    }
}

private struct BrowserNameCell: View {
    let name: String
    let iconName: String
    let isDropTarget: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            Text(name)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isDropTarget ? Color.accentColor.opacity(0.18) : Color.clear)
        )
    }
}

private struct InlineRenameBrowserNameCell: View {
    let iconName: String
    let isDropTarget: Bool
    @Binding var text: String
    let activationID: String
    let selectsNameStem: Bool
    let onSubmit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            InlineRenameTextField(
                text: $text,
                activationID: activationID,
                selectsNameStem: selectsNameStem,
                onSubmit: onSubmit,
                onCancel: onCancel
            )
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isDropTarget ? Color.accentColor.opacity(0.18) : Color.clear)
        )
    }
}

private struct InlineRenameTextField: NSViewRepresentable {
    @Binding var text: String
    let activationID: String
    let selectsNameStem: Bool
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField(string: text)
        textField.delegate = context.coordinator
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .default
        textField.font = .preferredFont(forTextStyle: .body)
        textField.cell?.lineBreakMode = .byClipping
        textField.cell?.usesSingleLineMode = true
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        context.coordinator.activateIfNeeded(for: nsView)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineRenameTextField
        private var currentActivationID: String?
        private var didHandleCommand = false

        init(parent: InlineRenameTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            parent.text = textField.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            if didHandleCommand {
                didHandleCommand = false
                return
            }
            parent.onSubmit()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                didHandleCommand = true
                parent.onSubmit()
                return true
            }

            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                didHandleCommand = true
                parent.onCancel()
                return true
            }

            return false
        }

        func activateIfNeeded(for textField: NSTextField) {
            guard currentActivationID != parent.activationID else { return }
            currentActivationID = parent.activationID

            DispatchQueue.main.async {
                guard let window = textField.window else { return }
                window.makeFirstResponder(textField)

                let selectionRange = Self.selectionRange(
                    for: textField.stringValue,
                    selectsNameStem: self.parent.selectsNameStem
                )

                if let editor = window.fieldEditor(true, for: textField) as? NSTextView {
                    editor.selectedRange = selectionRange
                } else {
                    textField.currentEditor()?.selectedRange = selectionRange
                }
            }
        }

        private static func selectionRange(for name: String, selectsNameStem: Bool) -> NSRange {
            let fullLength = (name as NSString).length
            guard selectsNameStem else {
                return NSRange(location: 0, length: fullLength)
            }

            let fileExtension = ((name as NSString).pathExtension as NSString)
            let extensionLength = fileExtension.length
            guard extensionLength > 0 else {
                return NSRange(location: 0, length: fullLength)
            }

            return NSRange(location: 0, length: max(0, fullLength - extensionLength - 1))
        }
    }
}

private struct TableFirstResponderBridge: NSViewRepresentable {
    @Binding var activate: (() -> Void)?

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            activate = { [weak nsView] in
                guard let nsView,
                      let window = nsView.window,
                      let tableView = nsView.enclosingTableView else {
                    return
                }

                window.makeFirstResponder(tableView)
            }
        }
    }
}

private struct ListDoubleClickBridge: NSViewRepresentable {
    let onDoubleClick: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDoubleClick: onDoubleClick)
    }

    func makeNSView(context: Context) -> ListDoubleClickHostingView {
        let view = ListDoubleClickHostingView(frame: .zero)
        view.coordinator = context.coordinator
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: ListDoubleClickHostingView, context: Context) {
        context.coordinator.onDoubleClick = onDoubleClick
        nsView.coordinator = context.coordinator
        context.coordinator.attach(to: nsView)
    }

    final class Coordinator: NSObject {
        var onDoubleClick: () -> Void
        private weak var tableView: NSTableView?
        private weak var previousTarget: AnyObject?
        private var previousDoubleAction: Selector?

        init(onDoubleClick: @escaping () -> Void) {
            self.onDoubleClick = onDoubleClick
        }

        deinit {
            detach()
        }

        func attach(to view: NSView) {
            guard let tableView = view.nearbyTableView else {
                return
            }

            guard tableView !== self.tableView else {
                if tableView.target !== self || tableView.doubleAction != #selector(handleDoubleClick(_:)) {
                    tableView.target = self
                    tableView.doubleAction = #selector(handleDoubleClick(_:))
                }
                return
            }

            detach()
            previousTarget = tableView.target as AnyObject?
            previousDoubleAction = tableView.doubleAction
            tableView.target = self
            tableView.doubleAction = #selector(handleDoubleClick(_:))
            self.tableView = tableView
        }

        private func detach() {
            guard let tableView else {
                return
            }

            if tableView.target === self {
                tableView.target = previousTarget
                tableView.doubleAction = previousDoubleAction
            }

            self.tableView = nil
            self.previousTarget = nil
            self.previousDoubleAction = nil
        }

        @objc private func handleDoubleClick(_ sender: Any?) {
            _ = sender
            onDoubleClick()
        }
    }
}

private final class ListDoubleClickHostingView: NSView {
    weak var coordinator: ListDoubleClickBridge.Coordinator?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        coordinator?.attach(to: self)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        coordinator?.attach(to: self)
    }

    override func layout() {
        super.layout()
        coordinator?.attach(to: self)
    }
}

private extension NSView {
    var enclosingTableView: NSTableView? {
        var ancestor = superview
        while let current = ancestor {
            if let tableView = current as? NSTableView {
                return tableView
            }
            ancestor = current.superview
        }
        return nil
    }

    var nearbyTableView: NSTableView? {
        if let enclosingTableView {
            return enclosingTableView
        }

        if let enclosingScrollView,
           let tableView = enclosingScrollView.firstDescendant(of: NSTableView.self) {
            return tableView
        }

        var ancestor = superview
        while let current = ancestor {
            if let tableView = current.firstDescendant(of: NSTableView.self) {
                return tableView
            }
            ancestor = current.superview
        }

        return nil
    }

    var enclosingScrollView: NSScrollView? {
        var ancestor = superview
        while let current = ancestor {
            if let scrollView = current as? NSScrollView {
                return scrollView
            }
            ancestor = current.superview
        }
        return nil
    }

    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        for subview in subviews {
            if let typedSubview = subview as? T {
                return typedSubview
            }

            if let descendant = subview.firstDescendant(of: type) {
                return descendant
            }
        }

        return nil
    }
}

private struct BrowserPaneKeyHandler: NSViewRepresentable {
    let isActive: Bool
    let isInlineRenaming: Bool
    let canHandleReturn: Bool
    let canHandleEscape: Bool
    let onReturn: () -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> BrowserPaneKeyHandlingView {
        let view = BrowserPaneKeyHandlingView(frame: .zero)
        context.coordinator.configure(view)
        return view
    }

    func updateNSView(_ nsView: BrowserPaneKeyHandlingView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.configure(nsView)
        context.coordinator.syncFirstResponderIfNeeded(for: nsView)
    }

    final class Coordinator {
        var parent: BrowserPaneKeyHandler

        init(parent: BrowserPaneKeyHandler) {
            self.parent = parent
        }

        func configure(_ view: BrowserPaneKeyHandlingView) {
            view.canHandleReturn = parent.canHandleReturn
            view.canHandleEscape = parent.canHandleEscape
            view.onReturn = parent.onReturn
            view.onEscape = parent.onEscape
        }

        func syncFirstResponderIfNeeded(for view: BrowserPaneKeyHandlingView) {
            _ = view
        }
    }
}

private final class BrowserPaneKeyHandlingView: NSView {
    var canHandleReturn = false
    var canHandleEscape = false
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isEmpty else {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 36, 76:
            guard canHandleReturn else {
                super.keyDown(with: event)
                return
            }
            onReturn?()
        case 53:
            guard canHandleEscape else {
                super.keyDown(with: event)
                return
            }
            onEscape?()
        default:
            super.keyDown(with: event)
        }
    }
}

private struct BrowserWindowKeyFallback: NSViewRepresentable {
    let isInlineRenaming: Bool
    let canHandleReturn: Bool
    let canHandleEscape: Bool
    let onReturn: () -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.attach(to: nsView)
    }

    final class Coordinator {
        var parent: BrowserWindowKeyFallback
        private weak var view: NSView?
        private var monitor: Any?

        init(parent: BrowserWindowKeyFallback) {
            self.parent = parent
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func attach(to view: NSView) {
            self.view = view
            guard monitor == nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let view,
                  let window = view.window,
                  window.isKeyWindow else {
                return event
            }

            if window.firstResponder is NSTextView, parent.isInlineRenaming {
                return event
            }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !modifiers.isEmpty {
                return event
            }

            switch event.keyCode {
            case 36, 76:
                guard parent.canHandleReturn else { return event }
                parent.onReturn()
                return nil
            case 53:
                guard parent.canHandleEscape else { return event }
                parent.onEscape()
                return nil
            default:
                return event
            }
        }
    }
}

private struct TransferFooterView: View {
    let isConnected: Bool
    let isBusy: Bool
    let statusMessage: String
    @ObservedObject var progressModel: TransferProgressModel

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(isConnected ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                Text(statusMessage)
                    .font(.callout)
                Spacer()
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let transferSnapshot = progressModel.snapshot {
                VStack(alignment: .leading, spacing: 6) {
                    Text(transferSnapshot.title)
                        .font(.footnote.weight(.medium))
                    if let fractionCompleted = transferSnapshot.fractionCompleted {
                        ProgressView(value: fractionCompleted)
                    } else {
                        ProgressView()
                    }
                    Text(transferDescription(for: transferSnapshot))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func transferDescription(for snapshot: TransferSnapshot) -> String {
        let transferred = Self.byteCountFormatter.string(fromByteCount: snapshot.transferredBytes)
        if let total = snapshot.totalBytes {
            let totalString = Self.byteCountFormatter.string(fromByteCount: total)
            return "\(transferred) / \(totalString)"
        }
        return transferred
    }
}
