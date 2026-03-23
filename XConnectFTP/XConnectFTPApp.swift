//
//  XConnectFTPApp.swift
//  XConnectFTP
//
//  Created by Minh Nguyen on 21/3/26.
//

import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "selectedAppAppearance"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    var displayName: String {
        switch self {
        case .system:
            return "Use System Appearance".localized
        case .light:
            return "Light".localized
        case .dark:
            return "Dark".localized
        }
    }
}

@main
struct XConnectFTPApp: App {
    @AppStorage(AppLanguage.storageKey) private var selectedLanguageRawValue = AppLanguage.system.rawValue
    @AppStorage(AppAppearance.storageKey) private var selectedAppearanceRawValue = AppAppearance.system.rawValue
    @StateObject private var appleSyncController = AppleSyncController()

    private var appLocale: Locale {
        let language = AppLanguage(rawValue: selectedLanguageRawValue) ?? .system
        return language.locale
    }

    private var appColorScheme: ColorScheme? {
        let appearance = AppAppearance(rawValue: selectedAppearanceRawValue) ?? .system
        return appearance.colorScheme
    }

    var body: some Scene {
        WindowGroup {
            ContentView(appleSyncController: appleSyncController)
                .environmentObject(appleSyncController)
                .preferredColorScheme(appColorScheme)
        }
        .environment(\.locale, appLocale)
        .commands {
            AppSupportCommands()
        }
        Window("About XConnectFTP".localized, id: AppSupportWindowID.about) {
            AboutWindowView()
                .preferredColorScheme(appColorScheme)
        }
        .environment(\.locale, appLocale)
        .restorationBehavior(.disabled)
        .windowResizability(.contentSize)

        Window("Help".localized, id: AppSupportWindowID.help) {
            HelpWindowView()
                .preferredColorScheme(appColorScheme)
        }
        .environment(\.locale, appLocale)
        .restorationBehavior(.disabled)
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(appleSyncController)
                .preferredColorScheme(appColorScheme)
        }
        .environment(\.locale, appLocale)
    }
}
