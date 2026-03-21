//
//  AppSupportViews.swift
//  XConnectFTP
//
//  Created by Codex on 21/3/26.
//

import AppKit
import SwiftUI

enum AppSupportWindowID {
    static let about = "about-window"
    static let help = "help-window"
}

struct AppSupportCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button {
                openWindow(id: AppSupportWindowID.about)
            } label: {
                Label("About XConnectFTP", systemImage: "info.circle")
            }
        }

        CommandGroup(replacing: .help) {
            Button {
                openWindow(id: AppSupportWindowID.help)
            } label: {
                Label("Help", systemImage: "questionmark.circle")
            }
            .keyboardShortcut("/", modifiers: .command)
        }
    }
}

struct AboutWindowView: View {
    private var appIcon: NSImage {
        NSApp.applicationIconImage
    }

    private var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var buildVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)

            VStack(spacing: 6) {
                Text("XConnectFTP")
                    .font(.title.weight(.semibold))

                Text("FTP/FTPS Client for macOS")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text(L10n.format("Version %@ • Build %@", shortVersion, buildVersion))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("A fast dual-pane FTP and explicit FTPS client for connecting, browsing, and transferring files on macOS.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(28)
        .frame(minWidth: 440, minHeight: 320)
    }
}

struct HelpWindowView: View {
    private var appIcon: NSImage {
        NSApp.applicationIconImage
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Help & Shortcuts")
                            .font(.title2.weight(.semibold))
                        Text("XConnectFTP")
                            .foregroundStyle(.secondary)
                    }
                }

                HelpSectionView(
                    title: "Quick Start",
                    rows: [
                        "Create or choose a saved site, then connect with FTP or explicit FTPS.",
                        "Choose a local root folder before browsing or transferring local files."
                    ]
                )

                HelpSectionView(
                    title: "Transfer",
                    rows: [
                        "Drag and drop, copy and paste, or use Upload/Download to move files between panes."
                    ]
                )

                HelpSectionView(
                    title: "Keyboard",
                    rows: [
                        "Double-click or press Return to open the selected folder.",
                        "Use Command-click and Shift-click for multi-selection, Command-A to select all, and Delete to remove selected items."
                    ]
                )

                HelpSectionView(
                    title: "Security",
                    rows: [
                        "FTP is unencrypted. Prefer FTPS whenever the server supports it.",
                        "Self-signed or invalid FTPS certificates require explicit trust for the current session."
                    ]
                )
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}

private struct HelpSectionView: View {
    let title: LocalizedStringKey
    let rows: [LocalizedStringKey]

    init(title: String, rows: [String]) {
        self.title = LocalizedStringKey(title)
        self.rows = rows.map { LocalizedStringKey($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .font(.footnote)
                        .padding(.top, 2)
                    Text(row)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
