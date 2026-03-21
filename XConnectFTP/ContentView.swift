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
    @StateObject private var viewModel = SessionViewModel()
    @Namespace private var localDragNamespace
    @Namespace private var remoteDragNamespace
    @State private var localPaneDropActive = false
    @State private var remotePaneDropActive = false
    @State private var localDropTargetID: LocalItem.ID?
    @State private var remoteDropTargetID: RemoteItem.ID?

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
        .alert("Lỗi", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { newValue in
                if !newValue {
                    viewModel.errorMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {
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
            viewModel.openPrimarySelection()
        }
        .onCommand(#selector(NSText.copy(_:))) {
            viewModel.copyFocusedSelection()
        }
        .onCommand(#selector(NSText.paste(_:))) {
            viewModel.pasteIntoFocusedPane()
        }
        .task {
            await viewModel.bootstrap()
        }
        .frame(minWidth: 1260, minHeight: 800)
    }

    private var sidebar: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Saved Sites")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    viewModel.openAddSiteEditor()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
            }

            List(viewModel.profiles, selection: $viewModel.selectedProfileID) { profile in
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name)
                        .font(.headline)
                    Text("\(profile.host):\(profile.port) • \(profile.protocolMode.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            HStack {
                Button("Edit") {
                    viewModel.openEditSiteEditor()
                }
                .disabled(viewModel.selectedProfile == nil)

                Button("Delete", role: .destructive) {
                    viewModel.deleteSelectedProfile()
                }
                .disabled(viewModel.selectedProfile == nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
                    Text(viewModel.displayProfile?.name ?? "Chưa chọn site")
                        .font(.title3.weight(.semibold))
                    if let profile = viewModel.displayProfile {
                        Text("\(profile.host):\(profile.port) • \(profile.username) • \(profile.protocolMode.displayName)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Chọn hoặc tạo saved site để bắt đầu kết nối.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                HStack {
                    AppLanguagePicker(showsLabel: false)
                        .frame(width: 170)

                    Button("Choose Local Root") {
                        viewModel.chooseLocalRoot()
                    }

                    Button("Connect") {
                        viewModel.connect()
                    }
                    .disabled(!viewModel.canConnect)

                    Button("Disconnect") {
                        viewModel.disconnect()
                    }
                    .disabled(!viewModel.canDisconnect)
                }
            }

            if let warning = viewModel.insecureFTPWarningMessage {
                HStack(alignment: .top, spacing: 10) {
                    Label("Insecure FTP", systemImage: "exclamationmark.triangle.fill")
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
                Button("Refresh") {
                    viewModel.refreshRemoteDirectory()
                }
                .disabled(!viewModel.isConnected || viewModel.isBusy)

                Button("Upload") {
                    viewModel.uploadSelectedLocalItems()
                }
                .disabled(!viewModel.canUpload)

                Button("Download") {
                    viewModel.downloadSelectedRemoteItems()
                }
                .disabled(!viewModel.canDownload)

                Button("New Folder") {
                    viewModel.createRemoteFolder()
                }
                .disabled(!viewModel.isConnected || viewModel.isBusy)

                Button("Rename") {
                    viewModel.renameFocusedSelection()
                }
                .disabled(!viewModel.canRenameFocusedSelection)

                Button("Delete", role: .destructive) {
                    viewModel.deleteFocusedSelection()
                }
                .disabled(!viewModel.canDeleteFocusedSelection)

                if viewModel.isTransferActive {
                    Button("Cancel Transfer", role: .destructive) {
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
            title: "Local",
            itemCount: viewModel.localRows.count,
            selectionCount: viewModel.selectedLocalItemIDs.count,
            isDropTargeted: localPaneDropActive || localDropTargetID != nil
        ) {
            if let currentURL = viewModel.localCurrentURL {
                paneHeader(
                    path: currentURL.path,
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
                ContentUnavailableView(
                    "Chưa có thư mục local",
                    systemImage: "folder.badge.questionmark",
                    description: Text("Chọn một thư mục local root để duyệt và upload/download.")
                )
            }
        }
        .onTapGesture {
            viewModel.setFocusedPane(.local)
        }
    }

    private var remotePane: some View {
        BrowserPane(
            title: "Remote",
            itemCount: viewModel.remoteRows.count,
            selectionCount: viewModel.selectedRemoteItemIDs.count,
            isDropTargeted: remotePaneDropActive || remoteDropTargetID != nil
        ) {
            if viewModel.isConnected {
                paneHeader(
                    path: viewModel.remoteCurrentPath,
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
                ContentUnavailableView(
                    "Chưa kết nối remote",
                    systemImage: "network.slash",
                    description: Text("Kết nối tới một site FTP hoặc FTPS để duyệt file remote.")
                )
            }
        }
        .onTapGesture {
            viewModel.setFocusedPane(.remote)
        }
    }

    private func paneHeader(path: String, onUp: @escaping () -> Void, canGoUp: Bool) -> some View {
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

        return Table(viewModel.localRows, selection: selection) {
            TableColumn("Name") { row in
                LocalTableNameCell(
                    viewModel: viewModel,
                    row: row,
                    dragNamespace: dragNamespace,
                    dropTargetID: $dropTargetID
                )
            }
            TableColumn("Size") { row in
                BrowserMetadataCell(
                    text: row.sizeText,
                    alignment: .trailing
                )
            }
                .width(min: 90, ideal: 110, max: 140)
            TableColumn("Modified") { row in
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
            Button("Open") {
                applySelection(selectedIDs)
                viewModel.openPrimarySelection()
            }
            .disabled(!canOpen(selectedIDs))

            Button("Copy") {
                applySelection(selectedIDs)
                viewModel.copyFocusedSelection()
            }
            .disabled(selectedIDs.isEmpty)

            Button("Paste") {
                viewModel.paste(into: .local)
            }
            .disabled(!viewModel.canPaste(into: .local))

            Button("Rename") {
                applySelection(selectedIDs)
                viewModel.renameFocusedSelection()
            }
            .disabled(selectedIDs.count != 1)

            Button("Delete", role: .destructive) {
                applySelection(selectedIDs)
                viewModel.deleteFocusedSelection()
            }
            .disabled(selectedIDs.isEmpty)
        } primaryAction: { selectedIDs in
            applySelection(selectedIDs)
            viewModel.openPrimarySelection()
        }
        .onChange(of: viewModel.selectedLocalItemIDs) { _, _ in
            viewModel.setFocusedPane(.local)
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
}

private struct RemoteBrowserTable: View {
    @ObservedObject var viewModel: SessionViewModel
    let dragNamespace: Namespace.ID
    @Binding var paneDropActive: Bool
    @Binding var dropTargetID: RemoteItem.ID?

    var body: some View {
        let selection = $viewModel.selectedRemoteItemIDs

        return Table(viewModel.remoteRows, selection: selection) {
            TableColumn("Name") { row in
                RemoteTableNameCell(
                    viewModel: viewModel,
                    row: row,
                    dragNamespace: dragNamespace,
                    dropTargetID: $dropTargetID
                )
            }
            TableColumn("Size") { row in
                BrowserMetadataCell(
                    text: row.sizeText,
                    alignment: .trailing
                )
            }
                .width(min: 90, ideal: 110, max: 140)
            TableColumn("Modified") { row in
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
            Button("Open") {
                applySelection(selectedIDs)
                viewModel.openPrimarySelection()
            }
            .disabled(!canOpen(selectedIDs))

            Button("Copy") {
                applySelection(selectedIDs)
                viewModel.copyFocusedSelection()
            }
            .disabled(selectedIDs.isEmpty)

            Button("Paste") {
                viewModel.paste(into: .remote)
            }
            .disabled(!viewModel.canPaste(into: .remote))

            Button("Download") {
                applySelection(selectedIDs)
                viewModel.downloadSelectedRemoteItems()
            }
            .disabled(selectedIDs.isEmpty)

            Button("Rename") {
                applySelection(selectedIDs)
                viewModel.renameFocusedSelection()
            }
            .disabled(selectedIDs.count != 1)

            Button("Delete", role: .destructive) {
                applySelection(selectedIDs)
                viewModel.deleteFocusedSelection()
            }
            .disabled(selectedIDs.isEmpty)
        } primaryAction: { selectedIDs in
            applySelection(selectedIDs)
            viewModel.openPrimarySelection()
        }
        .onChange(of: viewModel.selectedRemoteItemIDs) { _, _ in
            viewModel.setFocusedPane(.remote)
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
}

private struct LocalTableNameCell: View {
    @ObservedObject var viewModel: SessionViewModel
    let row: LocalBrowserRowModel
    let dragNamespace: Namespace.ID
    @Binding var dropTargetID: LocalItem.ID?

    var body: some View {
        let item = row.item
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
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                viewModel.handleLocalPrimaryClick(on: item, modifiers: currentModifierFlags())
            }
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

    var body: some View {
        let item = row.item
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
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                viewModel.handleRemotePrimaryClick(on: item, modifiers: currentModifierFlags())
            }
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
        .background(.background.secondary.opacity(0.35))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isDropTarget ? Color.accentColor.opacity(0.18) : Color.clear)
        )
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
