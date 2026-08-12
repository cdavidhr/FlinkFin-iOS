import SwiftUI

// Language selection sheet, accessible via the gear icon in RootTabView.
struct SettingsView: View {
    @EnvironmentObject var lm: LanguageManager
    @Environment(\.dismiss) private var dismiss

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
        .environmentObject(LanguageManager())
}
