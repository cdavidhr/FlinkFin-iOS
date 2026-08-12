import SwiftUI

/// Punto de entrada. Decide entre onboarding (sin credenciales en Keychain
/// todavía) y la app real, sin guardar nunca la clave privada fuera del
/// Keychain — ver SecureCredentialStore.swift y AGENTS.md de este proyecto.
@main
struct FlinkFinApp: App {
    @State private var hasCredentials = SecureCredentialStore.loadServiceAccount() != nil

    var body: some Scene {
        WindowGroup {
            if hasCredentials, let account = SecureCredentialStore.loadServiceAccount() {
                let config = GoogleSheetsClient.Config(
                    spreadsheetId: SecureCredentialStore.spreadsheetID,
                    serviceAccount: account
                )
                RootTabView(store: PortfolioStore(sheets: GoogleSheetsClient(config: config)))
            } else {
                OnboardingCredentialsView {
                    hasCredentials = true
                }
            }
        }
    }
}
