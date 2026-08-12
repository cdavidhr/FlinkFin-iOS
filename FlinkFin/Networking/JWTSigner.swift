import Foundation
import Security

/// Crea y firma JSON Web Tokens RS256 para el flujo OAuth2
/// "Server-to-Server" de Google (cuentas de servicio) — equivalente Swift de
/// lo que hace `google-auth` en el backend Python (gsheets_sync.py).
/// Implementado solo con frameworks de Apple (Security) para no añadir una
/// dependencia SPM externa para algo tan sensible como firmar credenciales.
///
/// ⚠️ No probado en Xcode todavía (este proyecto se generó sin acceso a un
/// Mac). El DER-unwrapping de PKCS#8 → PKCS#1 es lógica estándar y debería
/// funcionar, pero es la pieza más probable de necesitar un ajuste si algo
/// falla — revisar primero aquí si `signIn()` lanza error en GoogleSheetsClient.
enum GoogleServiceAccountJWT {

    struct ServiceAccountKey: Decodable {
        let client_email: String
        let private_key: String
        let token_uri: String
    }

    enum JWTError: Error {
        case invalidPEM
        case keyImportFailed(String)
        case signingFailed(String)
    }

    /// Construye un JWT firmado, listo para intercambiar por un access token
    /// en `token_uri` (grant_type urn:ietf:params:oauth:grant-type:jwt-bearer).
    static func makeSignedJWT(
        serviceAccount: ServiceAccountKey,
        scope: String = "https://www.googleapis.com/auth/spreadsheets.readonly",
        expiresIn: TimeInterval = 3600
    ) throws -> String {
        let now = Date()
        let claims: [String: Any] = [
            "iss": serviceAccount.client_email,
            "scope": scope,
            "aud": serviceAccount.token_uri,
            "iat": Int(now.timeIntervalSince1970),
            "exp": Int(now.addingTimeInterval(expiresIn).timeIntervalSince1970),
        ]
        let header: [String: Any] = ["alg": "RS256", "typ": "JWT"]

        let headerB64 = try base64URLEncode(json: header)
        let claimsB64 = try base64URLEncode(json: claims)
        let signingInput = "\(headerB64).\(claimsB64)"

        let privateKey = try importPrivateKey(pem: serviceAccount.private_key)
        let signature = try sign(message: signingInput, with: privateKey)

        return "\(signingInput).\(signature.base64URLEncodedString())"
    }

    // MARK: - PEM / DER

    private static func importPrivateKey(pem: String) throws -> SecKey {
        let lines = pem
            .split(separator: "\n")
            .filter { !$0.contains("BEGIN") && !$0.contains("END") }
            .joined()
        guard let pkcs8Data = Data(base64Encoded: lines) else { throw JWTError.invalidPEM }
        let pkcs1Data = try extractPKCS1(fromPKCS8: pkcs8Data)

        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        guard let key = SecKeyCreateWithData(pkcs1Data as CFData, attributes as CFDictionary, &error) else {
            throw JWTError.keyImportFailed(error?.takeRetainedValue().localizedDescription ?? "desconocido")
        }
        return key
    }

    /// Las claves de cuentas de servicio de Google vienen en PKCS#8
    /// ("-----BEGIN PRIVATE KEY-----"). `SecKeyCreateWithData` necesita el
    /// bloque PKCS#1 interno ("RSAPrivateKey"), así que hay que desenvolver
    /// el DER: SEQUENCE { INTEGER version, SEQUENCE algorithmId,
    /// OCTET STRING key }. El contenido de ese OCTET STRING ya es el DER
    /// PKCS#1 que necesita Security.framework.
    private static func extractPKCS1(fromPKCS8 data: Data) throws -> Data {
        var outerReader = DERReader(data: data)
        let outerValue = try outerReader.readTLV(expectedTag: 0x30) // SEQUENCE

        var inner = DERReader(data: outerValue)
        _ = try inner.readTLV(expectedTag: 0x02)       // INTEGER version
        _ = try inner.readTLV(expectedTag: 0x30)       // SEQUENCE AlgorithmIdentifier
        let octet = try inner.readTLV(expectedTag: 0x04) // OCTET STRING -> PKCS#1 DER
        return octet
    }

    // MARK: - Firma

    private static func sign(message: String, with key: SecKey) throws -> Data {
        guard let data = message.data(using: .utf8) else { throw JWTError.signingFailed("encoding") }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            data as CFData,
            &error
        ) as Data? else {
            throw JWTError.signingFailed(error?.takeRetainedValue().localizedDescription ?? "desconocido")
        }
        return signature
    }

    private static func base64URLEncode(json: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return data.base64URLEncodedString()
    }
}

/// Lector DER mínimo — solo lo necesario para desenvolver PKCS#8 → PKCS#1.
/// Soporta longitud corta (<128 bytes) y larga (0x81/0x82 + N bytes),
/// suficiente para claves RSA de 2048/4096 bits.
private struct DERReader {
    let data: Data
    var offset: Int = 0

    mutating func readTLV(expectedTag: UInt8) throws -> Data {
        guard offset < data.count else { throw GoogleServiceAccountJWT.JWTError.invalidPEM }
        let base = data.startIndex
        let tag = data[base + offset]
        guard tag == expectedTag else { throw GoogleServiceAccountJWT.JWTError.invalidPEM }
        offset += 1

        guard offset < data.count else { throw GoogleServiceAccountJWT.JWTError.invalidPEM }
        let firstLenByte = data[base + offset]
        offset += 1

        var length: Int
        if firstLenByte & 0x80 == 0 {
            length = Int(firstLenByte)
        } else {
            let numBytes = Int(firstLenByte & 0x7F)
            guard offset + numBytes <= data.count else { throw GoogleServiceAccountJWT.JWTError.invalidPEM }
            length = 0
            for i in 0..<numBytes {
                length = (length << 8) | Int(data[base + offset + i])
            }
            offset += numBytes
        }

        guard offset + length <= data.count else { throw GoogleServiceAccountJWT.JWTError.invalidPEM }
        let value = data.subdata(in: (base + offset)..<(base + offset + length))
        offset += length
        return value
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
