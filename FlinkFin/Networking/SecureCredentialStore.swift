import Foundation
import Security

/// Stores the Google service account JSON in the device Keychain —
/// never in the app bundle, UserDefaults, or unencrypted disk.
enum SecureCredentialStore {
    private static let service = "com.portfoliodashboard.serviceaccount"
    private static let account = "google-service-account-json"

    static func save(jsonString: String) throws {
        guard let data = jsonString.data(using: .utf8) else { return }
        delete() // Remove existing item before adding

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func loadJSONString() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func loadServiceAccount() -> GoogleServiceAccountJWT.ServiceAccountKey? {
        guard let json = loadJSONString(), let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GoogleServiceAccountJWT.ServiceAccountKey.self, from: data)
    }

    // MARK: - Spreadsheet ID (Non-secret identifier)

    private static let sheetIDDefaultsKey = "portfolioDashboard.spreadsheetId"
    private static let defaultSpreadsheetID = ""  // Enter your spreadsheet ID here or via the app's onboarding screen

    static var spreadsheetID: String {
        get { UserDefaults.standard.string(forKey: sheetIDDefaultsKey) ?? defaultSpreadsheetID }
        set { UserDefaults.standard.set(newValue, forKey: sheetIDDefaultsKey) }
    }
}
