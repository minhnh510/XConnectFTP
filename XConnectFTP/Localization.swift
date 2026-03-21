//
//  Localization.swift
//  XConnectFTP
//
//  Created by Codex on 21/3/26.
//

import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case vietnamese

    static let storageKey = "selectedAppLanguage"

    var id: String { rawValue }

    var locale: Locale {
        switch self {
        case .system:
            return .autoupdatingCurrent
        case .english:
            return Locale(identifier: "en")
        case .vietnamese:
            return Locale(identifier: "vi")
        }
    }

    var localizationCode: String? {
        switch self {
        case .system:
            return nil
        case .english:
            return "en"
        case .vietnamese:
            return "vi"
        }
    }

    var displayName: String {
        switch self {
        case .system:
            return L10n.tr("Use System Language")
        case .english:
            return L10n.tr("English")
        case .vietnamese:
            return L10n.tr("Vietnamese")
        }
    }

    static var current: AppLanguage {
        let storedValue = UserDefaults.standard.string(forKey: storageKey) ?? AppLanguage.system.rawValue
        return AppLanguage(rawValue: storedValue) ?? .system
    }
}

enum L10n {
    private static var bundle: Bundle {
        guard let code = AppLanguage.current.localizationCode,
              let bundlePath = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: bundlePath) else {
            return .main
        }
        return bundle
    }

    static func tr(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: tr(key), locale: AppLanguage.current.locale, arguments: arguments)
    }
}
