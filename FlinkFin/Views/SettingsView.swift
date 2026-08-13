import SwiftUI

// Settings sheet presented from Overview gear icon.
// Manages app language, Spreadsheet ID, and Keychain disconnection.
struct SettingsView: View {
    @EnvironmentObject var lm: LanguageManager
    @Environment(\.dismiss) private var dismiss

    var onDisconnect: (() -> Void)? = nil

    @State private var spreadsheetId: String = SecureCredentialStore.spreadsheetID
    @State private var isSaved = false

    private var serviceAccountEmail: String? {
        SecureCredentialStore.loadServiceAccount()?.client_email
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(lm["settings.language"]) {
                    Picker(lm["settings.language"], selection: $lm.language) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section(lm["settings.google_sheets"]) {
                    if let email = serviceAccountEmail {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(lm["settings.service_account"])
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(email)
                                .font(.footnote.weight(.medium))
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(lm["settings.spreadsheet_id"])
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Spreadsheet ID", text: $spreadsheetId)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.footnote)
                    }

                    Button {
                        SecureCredentialStore.spreadsheetID = spreadsheetId.trimmingCharacters(in: .whitespacesAndNewlines)
                        isSaved = true
                    } label: {
                        HStack {
                            Text(lm["settings.save_sheet_id"])
                            if isSaved {
                                Spacer()
                                Image(systemName: "checkmark").foregroundStyle(.green)
                            }
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        SecureCredentialStore.delete()
                        dismiss()
                        onDisconnect?()
                    } label: {
                        Label(lm["settings.reset_credentials"], systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle(lm["settings.title"])
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(lm["settings.done"]) { dismiss() }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(LanguageManager.shared)
}
