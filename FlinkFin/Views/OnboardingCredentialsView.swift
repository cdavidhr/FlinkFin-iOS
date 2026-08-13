import SwiftUI
import UniformTypeIdentifiers

/// Onboarding screen presented when no credentials are found in Keychain.
/// Allows the user to import their Google service account `service_account.json`
/// via the iOS file picker, enter their Spreadsheet ID, and save to Keychain.
struct OnboardingCredentialsView: View {
    var onSaved: () -> Void

    @EnvironmentObject private var lm: LanguageManager
    @State private var spreadsheetId: String = SecureCredentialStore.spreadsheetID
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var importedEmail: String? = SecureCredentialStore.loadServiceAccount()?.client_email
    @State private var pendingJsonString: String?

    private var canSave: Bool {
        (pendingJsonString != nil || SecureCredentialStore.loadServiceAccount() != nil) &&
        !spreadsheetId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(lm["onboarding.description"])
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section(lm["onboarding.service_acct"]) {
                    Button {
                        isImporting = true
                    } label: {
                        HStack {
                            Label(importedEmail ?? lm["onboarding.import_btn"], systemImage: "doc.badge.plus")
                            if importedEmail != nil {
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    if let email = importedEmail {
                        Text(email).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section(lm["onboarding.sheet_label"]) {
                    TextField(lm["onboarding.sheet_ph"], text: $spreadsheetId)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section {
                    Button(action: saveAndConnect) {
                        HStack {
                            Spacer()
                            Text(lm["onboarding.save"])
                                .font(.headline.weight(.bold))
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red).font(.footnote)
                    }
                }
            }
            .navigationTitle(lm["onboarding.title"])
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
                handleImport(result)
            }
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let needsAccess = url.startAccessingSecurityScopedResource()
            defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }

            let data = try Data(contentsOf: url)
            let account = try JSONDecoder().decode(GoogleServiceAccountJWT.ServiceAccountKey.self, from: data)
            guard let jsonString = String(data: data, encoding: .utf8) else {
                throw NSError(domain: "Onboarding", code: 0)
            }
            pendingJsonString = jsonString
            importedEmail = account.client_email
            errorMessage = nil
        } catch {
            errorMessage = lm.fmt("onboarding.file_error", error.localizedDescription)
        }
    }

    private func saveAndConnect() {
        guard canSave else { return }
        do {
            if let json = pendingJsonString {
                try SecureCredentialStore.save(jsonString: json)
            }
            SecureCredentialStore.spreadsheetID = spreadsheetId.trimmingCharacters(in: .whitespacesAndNewlines)
            errorMessage = nil
            onSaved()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    OnboardingCredentialsView(onSaved: {})
        .environmentObject(LanguageManager.shared)
}
