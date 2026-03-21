//
//  SiteEditorView.swift
//  XConnectFTP
//
//  Created by Codex on 21/3/26.
//

import SwiftUI

struct SiteEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ConnectionProfileDraft
    @State private var validationMessage: String?

    let onSave: (ConnectionProfileDraft) -> Bool

    init(draft: ConnectionProfileDraft, onSave: @escaping (ConnectionProfileDraft) -> Bool) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Saved Site")
                .font(.title2.weight(.semibold))

            Form {
                TextField("Tên hiển thị", text: $draft.name)
                TextField("IP / Host", text: $draft.host)

                HStack {
                    Picker("Protocol", selection: $draft.protocolMode) {
                        ForEach(ProtocolMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    TextField("Port", text: $draft.portText)
                        .frame(width: 90)
                }

                TextField("Username", text: $draft.username)
                SecureField("Password", text: $draft.password)
                TextField("Remote path khởi tạo", text: $draft.initialRemotePath)
            }
            .formStyle(.grouped)

            if let validationMessage {
                Text(validationMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }

                Button("Save") {
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
        .padding(20)
        .frame(width: 460)
        .onChange(of: draft.protocolMode) { _, newMode in
            if draft.portText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.portText = String(newMode.defaultPort)
            }
        }
    }
}
