//
//  AppSupportViews.swift
//  XConnectFTP
//
//  Created by Codex on 21/3/26.
//

import AppKit
import AuthenticationServices
import SwiftUI

enum AppSupportWindowID {
    static let about = "about-window"
    static let help = "help-window"
}

enum AppIconProvider {
    static func image() -> NSImage {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            return icon
        }
        if let assetIcon = NSImage(named: "AppIcon") {
            return assetIcon
        }
        let workspaceIcon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        workspaceIcon.size = NSSize(width: 512, height: 512)
        return workspaceIcon
    }
}

struct AppSupportCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button {
                openWindow(id: AppSupportWindowID.about)
            } label: {
                Label("About XConnectFTP".localized, systemImage: "info.circle")
            }
        }

        CommandGroup(replacing: .help) {
            Button {
                openWindow(id: AppSupportWindowID.help)
            } label: {
                Label("Help".localized, systemImage: "questionmark.circle")
            }
            .keyboardShortcut("/", modifiers: .command)
        }
    }
}

struct AppLanguagePicker: View {
    @AppStorage(AppLanguage.storageKey) private var selectedLanguageRawValue = AppLanguage.system.rawValue
    var showsLabel: Bool = true

    private var selection: Binding<AppLanguage> {
        Binding(
            get: { AppLanguage(rawValue: selectedLanguageRawValue) ?? .system },
            set: { selectedLanguageRawValue = $0.rawValue }
        )
    }

    var body: some View {
        Picker(selection: selection) {
            ForEach(AppLanguage.allCases) { language in
                Text(language.displayName).tag(language)
            }
        } label: {
            if showsLabel {
                Label("Language".localized, systemImage: "globe")
            } else {
                EmptyView()
            }
        }
        .pickerStyle(.menu)
    }
}

struct SettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var selectedLanguageRawValue = AppLanguage.system.rawValue
    @EnvironmentObject private var appleSyncController: AppleSyncController

    private var selectedLanguageLocale: Locale {
        let language = AppLanguage(rawValue: selectedLanguageRawValue) ?? .system
        return language.locale
    }

    var body: some View {
        Form {
            Section("General".localized) {
                AppLanguagePicker()
            }

            Section("Apple Sync".localized) {
                if appleSyncController.signInState.isSignedIn {
                    Label(
                        appleSyncController.signInState.displayDescription,
                        systemImage: "person.crop.circle.badge.checkmark"
                    )

                    Text(appleSyncController.cloudAvailability.description)
                        .foregroundStyle(.secondary)

                    Toggle(
                        "Sync saved sites with iCloud".localized,
                        isOn: Binding(
                            get: { appleSyncController.syncEnabled },
                            set: { appleSyncController.updateSyncEnabled($0) }
                        )
                    )

                    Text(appleSyncController.syncMetadataDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if let syncStatusDescription = appleSyncController.syncStatusDescription {
                        Text(syncStatusDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("Sign Out".localized, role: .destructive) {
                        appleSyncController.signOut()
                    }
                } else {
                    SignInWithAppleButton(.signIn) { request in
                        appleSyncController.configureAppleIDRequest(request)
                    } onCompletion: { result in
                        appleSyncController.handleAuthorizationResult(result)
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 32)

                    Text("Sign in with your Apple account to sync saved sites with iCloud.".localized)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Text(appleSyncController.cloudAvailability.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let syncStatusDescription = appleSyncController.syncStatusDescription {
                        Text(syncStatusDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .environment(\.locale, selectedLanguageLocale)
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 460)
    }
}

struct AboutWindowView: View {
    @AppStorage(AppLanguage.storageKey) private var selectedLanguageRawValue = AppLanguage.system.rawValue

    private var appIcon: NSImage {
        AppIconProvider.image()
    }

    private var companyURL: URL {
        URL(string: "https://xmtg.vn/")!
    }

    private var selectedLanguageLocale: Locale {
        let language = AppLanguage(rawValue: selectedLanguageRawValue) ?? .system
        return language.locale
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

                Text("FTP/FTPS Client for macOS".localized)
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text(L10n.format("Version %@ • Build %@", shortVersion, buildVersion))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("A fast dual-pane FTP and explicit FTPS client for connecting, browsing, and transferring files on macOS.".localized)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            VStack(spacing: 4) {
                Text("Made by XMT Solutions".localized)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Link("https://xmtg.vn/", destination: companyURL)
                    .font(.footnote.weight(.medium))
            }
        }
        .environment(\.locale, selectedLanguageLocale)
        .padding(28)
        .frame(minWidth: 440, minHeight: 320)
    }
}

struct HelpWindowView: View {
    @AppStorage(AppLanguage.storageKey) private var selectedLanguageRawValue = AppLanguage.system.rawValue

    private var appIcon: NSImage {
        AppIconProvider.image()
    }

    private var selectedLanguageLocale: Locale {
        let language = AppLanguage(rawValue: selectedLanguageRawValue) ?? .system
        return language.locale
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
                        Text("Help & Shortcuts".localized)
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
        .environment(\.locale, selectedLanguageLocale)
        .frame(minWidth: 560, minHeight: 420)
    }
}

private struct HelpSectionView: View {
    let title: String
    let rows: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.localized)
                .font(.headline)

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .font(.footnote)
                        .padding(.top, 2)
                    Text(row.localized)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
