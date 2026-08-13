import SwiftUI

/// Entry point. Decides between onboarding (no credentials in Keychain
/// yet) and the real app, never saving the private key outside the
/// Keychain — see SecureCredentialStore.swift and AGENTS.md in this project.
@main
struct FlinkFinApp: App {
    @StateObject private var lm = LanguageManager.shared
    @State private var sessionID = UUID()
    @State private var hasCredentials = SecureCredentialStore.loadServiceAccount() != nil

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCredentials, let account = SecureCredentialStore.loadServiceAccount() {
                    let config = GoogleSheetsClient.Config(
                        spreadsheetId: SecureCredentialStore.spreadsheetID,
                        serviceAccount: account
                    )
                    RootTabView(
                        store: PortfolioStore(sheets: GoogleSheetsClient(config: config)),
                        onDisconnect: {
                            hasCredentials = false
                            sessionID = UUID()
                        }
                    )
                } else {
                    OnboardingCredentialsView {
                        hasCredentials = true
                        sessionID = UUID()
                    }
                }
            }
            .id(sessionID)
            .environmentObject(lm)
        }
    }
}
