import Foundation
import Security

/// Guarda el JSON de la cuenta de servicio de Google en el Keychain del
/// dispositivo — nunca en el bundle de la app, en `UserDefaults` ni en
/// disco sin cifrar. Esto es justo lo que pedía la restricción de
/// seguridad acordada para este proyecto: la clave privada no debe vivir
/// hardcodeada/empaquetada en la app ni acabar en git.
///
/// El usuario pega el JSON una vez en `OnboardingCredentialsView`; a partir
/// de ahí se lee de aquí en cada arranque. Borrar credenciales = volver a
/// pasar por el onboarding.
enum SecureCredentialStore {
    private static let service = "com.portfoliodashboard.serviceaccount"
    private static let account = "google-service-account-json"

    static func save(jsonString: String) throws {
        let data = Data(jsonString.utf8)
        // Borra cualquier entrada previa para evitar errDuplicateItem.
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // Solo accesible en este dispositivo, tras el primer
            // desbloqueo, y no se incluye en backups a otros dispositivos.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "SecureCredentialStore", code: Int(status),
                           userInfo: [NSLocalizedDescriptionKey: "No se pudo guardar en Keychain (status \(status))"])
        }
    }

    static func loadJSONString() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
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
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Decodifica el JSON guardado directamente al tipo que ya espera
    /// GoogleSheetsClient/JWTSigner.
    static func loadServiceAccount() -> GoogleServiceAccountJWT.ServiceAccountKey? {
        guard let json = loadJSONString(), let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GoogleServiceAccountJWT.ServiceAccountKey.self, from: data)
    }

    // MARK: - ID de la hoja (no es secreto, solo un identificador — sin
    // la cuenta de servicio compartida con el Sheet no sirve de nada).
    // Rellena con el ID de tu propia hoja: es el string largo en la URL del Sheet.
    // Ejemplo: https://docs.google.com/spreadsheets/d/<SPREADSHEET_ID>/edit

    private static let sheetIDDefaultsKey = "portfolioDashboard.spreadsheetId"
    private static let defaultSpreadsheetID = ""  // ← Enter your spreadsheet ID here or via the app's onboarding screen

    static var spreadsheetID: String {
        get { UserDefaults.standard.string(forKey: sheetIDDefaultsKey) ?? defaultSpreadsheetID }
        set { UserDefaults.standard.set(newValue, forKey: sheetIDDefaultsKey) }
    }
}
