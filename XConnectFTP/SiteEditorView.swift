//
//  SiteEditorView.swift
//  XConnectFTP
//
//  Created by Codex on 21/3/26.
//

import SwiftUI

struct SiteEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppLanguage.storageKey) private var selectedLanguageRawValue = AppLanguage.system.rawValue
    @State private var draft: ConnectionProfileDraft
    @State private var validationMessage: String?

    private var selectedLanguageLocale: Locale {
        let language = AppLanguage(rawValue: selectedLanguageRawValue) ?? .system
        return language.locale
    }

    let onSave: (ConnectionProfileDraft) -> Bool

    init(draft: ConnectionProfileDraft, onSave: @escaping (ConnectionProfileDraft) -> Bool) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Saved Site".localized)
                .font(.title2.weight(.semibold))

            Form {
                TextField("Tên hiển thị".localized, text: $draft.name)
                TextField("IP / Host".localized, text: $draft.host)

                HStack {
                    Picker("Protocol".localized, selection: $draft.protocolMode) {
                        ForEach(ProtocolMode.allCases) { mode in
                            Text(mode.localizedDisplayName).tag(mode)
                        }
                    }
                    TextField("Port".localized, text: $draft.portText)
                        .frame(width: 90)
                }

                TextField("Username".localized, text: $draft.username)
                SecureField("Password".localized, text: $draft.password)
                TextField("Remote path khởi tạo".localized, text: $draft.initialRemotePath)
            }
            .formStyle(.grouped)

            if let validationMessage {
                Text(validationMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()

                Button("Cancel".localized) {
                    dismiss()
                }

                Button("Save".localized) {
                    do {
                        _ = try draft.buildProfile(existingID: nil)
                        if onSave(draft) {
                            dismiss()
                        }
                    } catch {
                        validationMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .environment(\.locale, selectedLanguageLocale)
        .padding(20)
        .frame(width: 460)
        .onChange(of: draft.protocolMode) { newMode in
            if draft.portText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.portText = String(newMode.defaultPort)
            }
        }
    }
}
