//
//  XConnectFTPApp.swift
//  XConnectFTP
//
//  Created by Minh Nguyen on 21/3/26.
//

import SwiftUI

@main
struct XConnectFTPApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            AppSupportCommands()
        }
        Window("About XConnectFTP", id: AppSupportWindowID.about) {
            AboutWindowView()
        }
        .windowResizability(.contentSize)

        Window("Help", id: AppSupportWindowID.help) {
            HelpWindowView()
        }
        .windowResizability(.contentSize)
    }
}
