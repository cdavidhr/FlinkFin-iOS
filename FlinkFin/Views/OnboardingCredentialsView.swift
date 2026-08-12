import SwiftUI
import UniformTypeIdentifiers

/// Onboarding screen presented when no credentials are found in Keychain.
/// Allows the user to import their Google service account `service_account.json`
/// via the iOS file picker and save it securely in Keychain.
struct OnboardingCredentialsView: View {
    var onSaved: () -> Void

    @EnvironmentObject private var lm: LanguageManager
    @State private var spreadsheetId: String = SecureCredentialStore.spreadsheetID
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var importedEmail: String?

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
                        Label(importedEmail ?? lm["onboarding.import_btn"], systemImage: "doc.badge.plus")
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
            try SecureCredentialStore.save(jsonString: jsonString)
            SecureCredentialStore.spreadsheetID = spreadsheetId
            importedEmail = account.client_email
            errorMessage = nil
            onSaved()
        } catch {
            errorMessage = lm.fmt("onboarding.file_error", error.localizedDescription)
        }
    }
}

#Preview {
    OnboardingCredentialsView(onSaved: {})
        .environmentObject(LanguageManager.shared)
}
