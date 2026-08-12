import Foundation
import SwiftUI

// Supported UI languages. Stored as raw String value in AppStorage.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case spanish = "es"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .spanish: return "Español"
        }
    }
}

// Central manager for in-app language switching.
// Inject as @EnvironmentObject into the view hierarchy and access strings via subscript:
//   lm["tab.overview"]  →  "Overview" or "Resumen" depending on selected language.
// RecommendationEngine uses the shared singleton to build localized reason strings.
final class LanguageManager: ObservableObject {

    // Singleton used by non-SwiftUI code (RecommendationEngine).
    static let shared = LanguageManager()

    // Persisted language choice — survives app restarts.
    @AppStorage("appLanguage") var language: AppLanguage = .english {
        didSet { objectWillChange.send() }
    }

    // Returns the localized string for the given key.
    // Falls back to the key itself if not found (makes missing strings obvious).
    subscript(_ key: String) -> String {
        let table = language == .english ? Strings.en : Strings.es
        return table[key] ?? "[\(key)]"
    }

    // Convenience: format a localized string with printf-style arguments.
    // Example: lm.fmt("error.load_failed", error.localizedDescription)
    func fmt(_ key: String, _ args: CVarArg...) -> String {
        String(format: self[key], arguments: args)
    }
}
