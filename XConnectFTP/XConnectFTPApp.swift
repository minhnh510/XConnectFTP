//
//  XConnectFTPApp.swift
//  XConnectFTP
//
//  Created by Minh Nguyen on 21/3/26.
//

import SwiftUI

@main
struct XConnectFTPApp: App {
    @AppStorage(AppLanguage.storageKey) private var selectedLanguageRawValue = AppLanguage.system.rawValue
    @StateObject private var appleSyncController = AppleSyncController()

    private var appLocale: Locale {
        let language = AppLanguage(rawValue: selectedLanguageRawValue) ?? .system
        return language.locale
    }

    var body: some Scene {
        WindowGroup {
            ContentView(appleSyncController: appleSyncController)
                .environmentObject(appleSyncController)
        }
        .environment(\.locale, appLocale)
        .commands {
            AppSupportCommands()
        }
        Window("About XConnectFTP".localized, id: AppSupportWindowID.about) {
            AboutWindowView()
        }
        .environment(\.locale, appLocale)
        .restorationBehavior(.disabled)
        .windowResizability(.contentSize)

        Window("Help".localized, id: AppSupportWindowID.help) {
            HelpWindowView()
        }
        .environment(\.locale, appLocale)
        .restorationBehavior(.disabled)
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(appleSyncController)
        }
        .environment(\.locale, appLocale)
    }
}
