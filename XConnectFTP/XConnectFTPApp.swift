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

    private var appLocale: Locale {
        let language = AppLanguage(rawValue: selectedLanguageRawValue) ?? .system
        return language.locale
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .environment(\.locale, appLocale)
        .commands {
            AppSupportCommands()
        }
        Window("About XConnectFTP", id: AppSupportWindowID.about) {
            AboutWindowView()
        }
        .environment(\.locale, appLocale)
        .windowResizability(.contentSize)

        Window("Help", id: AppSupportWindowID.help) {
            HelpWindowView()
        }
        .environment(\.locale, appLocale)
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
        }
        .environment(\.locale, appLocale)
    }
}
