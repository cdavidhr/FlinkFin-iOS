import SwiftUI
import UniformTypeIdentifiers

/// Pantalla única que se muestra mientras no haya credenciales guardadas en
/// el Keychain. El usuario importa el mismo `service_account.json` que ya
/// usa el backend Python (credentials/service_account.json en el proyecto
/// `dashboard`) — vía el selector de archivos de iOS, NO pegando texto a
/// mano (más fácil y evita errores de copy-paste con una clave RSA larga).
/// El JSON se guarda en Keychain y nunca toca disco sin cifrar ni el
/// bundle de la app.
struct OnboardingCredentialsView: View {
    var onSaved: () -> Void

    @State private var spreadsheetId: String = SecureCredentialStore.spreadsheetID
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var importedEmail: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Importa el JSON de la cuenta de servicio de Google que comparte acceso de lectura a tu Google Sheet de portfolio. Es el mismo fichero que usa el dashboard de escritorio (credentials/service_account.json).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Cuenta de servicio") {
                    Button {
                        isImporting = true
                    } label: {
                        Label(importedEmail ?? "Importar service_account.json", systemImage: "doc.badge.plus")
                    }
                    if let email = importedEmail {
                        Text(email).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("ID de la hoja de cálculo") {
                    TextField("ID del Google Sheet", text: $spreadsheetId)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red).font(.footnote)
                    }
                }
            }
            .navigationTitle("Conectar Google Sheets")
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
            errorMessage = "No se pudo leer el fichero: \(error.localizedDescription)"
        }
    }
}

#Preview {
    OnboardingCredentialsView(onSaved: {})
}
