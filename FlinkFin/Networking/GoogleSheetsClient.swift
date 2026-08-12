import Foundation

/// Cliente de la API de Google Sheets v4 que lee y parsea las mismas
/// pestañas que `gsheets_sync.py` + `database.py` (proyecto `dashboard`)
/// procesan en el backend Python — reimplementado aquí porque esta app usa
/// lógica independiente (no llama al servidor FastAPI).
///
/// IDs del Sheet y nombres de pestañas confirmados contra gsheets_sync.py:
///   - Hoja: "2021 Stock Portfolio Tracker"
///   - Transacciones: "Transactions" (SGD), "Transactions USD",
///     "Transactions HKD", "Transactions AUD"
///   - Metadatos/tickers: "Stock Summary", "Stock Summary USD" (única con
///     precios objetivo), "Stock Summary HKD", "Summary AUD"
///   - Histórico: "Portfolio History"
/// Si el usuario renombra alguna pestaña en el Sheet, actualizar las
/// constantes de abajo (y también gsheets_sync.py, para no divergir).
///
/// Credenciales: requiere el mismo JSON de cuenta de servicio que usa el
/// backend Python (`credentials/service_account.json`). NUNCA debe vivir en
/// el bundle de la app ni en git — ver README.md de este proyecto.
actor GoogleSheetsClient {

    struct Config {
        var spreadsheetId: String
        var serviceAccount: GoogleServiceAccountJWT.ServiceAccountKey

        /// Config falsa para SwiftUI Previews / tests — NO usar en la app
        /// real. La clave privada no es válida; cualquier intento de red
        /// con esto fallará en `accessToken()` (esperado en una preview
        /// sin red).
        static var preview: Config {
            Config(
                spreadsheetId: "preview-sheet-id",
                serviceAccount: .init(
                    client_email: "preview@example.iam.gserviceaccount.com",
                    private_key: "-----BEGIN PRIVATE KEY-----\npreview\n-----END PRIVATE KEY-----",
                    token_uri: "https://oauth2.googleapis.com/token"
                )
            )
        }
    }

    enum SheetsError: Error {
        case tokenExchangeFailed(String)
        case requestFailed(String)
        case badResponse
    }

    // Nombres de pestaña — mismos que gsheets_sync.py / database.py.
    private static let transactionSheets: [(name: String, currency: String)] = [
        ("Transactions", "SGD"),
        ("Transactions USD", "USD"),
        ("Transactions HKD", "HKD"),
        ("Transactions AUD", "AUD"),
    ]
    private static let metaSheets: [(name: String, currency: String, hasTargets: Bool)] = [
        ("Stock Summary", "SGD", false),
        ("Stock Summary USD", "USD", true),
        ("Stock Summary HKD", "HKD", false),
        ("Summary AUD", "AUD", false),
    ]
    private static let validTypes: Set<String> = ["Buy", "Sell", "Div"]

    private let config: Config
    private var cachedToken: String?
    private var tokenExpiry: Date = .distantPast

    init(config: Config) {
        self.config = config
    }

    // MARK: - API pública

    /// Lee las 4 pestañas de transacciones (en el mismo orden que
    /// `import_from_excel_if_empty()`) y les asigna un id secuencial — el
    /// mismo papel que el id autoincremental de SQLite, usado como criterio
    /// de desempate en `PortfolioEngine.computeHoldings` cuando dos
    /// transacciones caen en la misma fecha.
    func fetchAllTransactions() async throws -> (transactions: [Transaction], duplicatesRemoved: Int) {
        let nameToTicker = try await fetchNameToTickerMap()
        var out: [Transaction] = []
        var nextID = 1
        for (sheetName, currency) in Self.transactionSheets {
            let rows = try await fetchSheetValues(sheetName: sheetName)
            for row in rows.dropFirst() { // min_row=2: la fila 0 es cabecera
                guard let typeStr = row[safe: 1]?.asString, Self.validTypes.contains(typeStr),
                      let type = TransactionType(rawValue: typeStr) else { continue }
                guard let date = row[safe: 0]?.asDateString,
                      let name = row[safe: 2]?.asString, !name.isEmpty,
                      let units = row[safe: 3]?.asDouble,
                      let price = row[safe: 4]?.asDouble else { continue }
                let fees = row[safe: 5]?.asDouble ?? 0
                let remarks = row[safe: 18]?.asString
                out.append(Transaction(
                    id: nextID,
                    date: date,
                    type: type,
                    name: name,
                    ticker: nameToTicker[name],
                    currency: currency,
                    units: units,
                    price: price,
                    fees: fees,
                    remarks: remarks,
                    source: "google_sheets"
                ))
                nextID += 1
            }
        }

        // Deduplica por clave de negocio: (date, type, name, currency, units, price).
        // No se incluye `remarks` porque dos filas con idéntico contenido financiero
        // pero observación distinta son un duplicado accidental del Sheet, no una
        // transacción real diferente — el usuario confirmó que comprar exactamente
        // el mismo activo, misma cantidad y precio el mismo día es improbable.
        // Mismo patrón que fetchPortfolioHistory() usa para el histórico.
        struct TxKey: Hashable {
            let date: String, typeRaw: String, name: String
            let currency: String, units: Double, price: Double
        }
        var seen = Set<TxKey>()
        var deduped: [Transaction] = []
        for tx in out {
            let key = TxKey(date: tx.date, typeRaw: tx.type.rawValue, name: tx.name,
                            currency: tx.currency, units: tx.units, price: tx.price)
            if seen.insert(key).inserted {
                deduped.append(tx)
            }
        }
        return (transactions: deduped, duplicatesRemoved: out.count - deduped.count)
    }

    /// Espejo de `_import_stock_meta` — categoría + tickers + precios
    /// objetivo de analistas (solo la pestaña USD trae targets, igual que
    /// en el Excel). Clave del diccionario: `"\(name)|\(currency)"`, igual
    /// que `Holding.id` / `Transaction.positionKey`.
    func fetchStockMeta() async throws -> [String: StockMeta] {
        var out: [String: StockMeta] = [:]
        for (sheetName, currency, hasTargets) in Self.metaSheets {
            guard let rows = try? await fetchSheetValues(sheetName: sheetName) else { continue }
            var inData = false
            for row in rows {
                guard row.count >= 12 else { continue }
                if let marker = row[safe: 1]?.asString, marker == "Stock Name" || marker == "º" {
                    inData = true
                    continue
                }
                guard inData, let name = row[safe: 1]?.asString, !name.isEmpty else { continue }

                var avgT: Double?, minT: Double?, maxT: Double?
                if hasTargets, row.count > 27 {
                    avgT = row[safe: 25]?.asDouble
                    minT = row[safe: 26]?.asDouble
                    maxT = row[safe: 27]?.asDouble
                }
                let key = "\(name)|\(currency)"
                out[key] = StockMeta(
                    ticker: row[safe: 4]?.asString,
                    category: row[safe: 0]?.asString ?? "Other",
                    avgTarget: avgT, minTarget: minT, maxTarget: maxT
                )
            }
        }
        return out
    }

    /// Espejo de `parse_history()` (dashboard_server.py — la función que
    /// alimenta /api/history, no de `_import_portfolio_history` de
    /// database.py). OJO: hay una discrepancia ya existente en el propio
    /// Python entre ambas funciones — `parse_history` salta las 2 primeras
    /// filas (`rows[2:]`) mientras que `_import_portfolio_history` solo
    /// salta 1 (`min_row=2`). Aquí replicamos `parse_history` porque es la
    /// que determina lo que ve el usuario en el gráfico de patrimonio total.
    /// Si esto resulta ser un bug real en el Python (no una cabecera de 2
    /// filas a propósito), corregirlo en ambos lados a la vez — no decidir
    /// unilateralmente cuál es "el bueno".
    func fetchPortfolioHistory() async throws -> [HistoryPoint] {
        guard let rows = try? await fetchSheetValues(sheetName: "Portfolio History"), rows.count > 2 else { return [] }
        var out: [HistoryPoint] = []
        for row in rows.dropFirst(2) {
            guard let date = row[safe: 0]?.asDateString, row[safe: 2]?.asDouble != nil else { continue }
            out.append(HistoryPoint(
                date: date,
                cost: row[safe: 1]?.asDouble ?? 0,
                value: row[safe: 2]?.asDouble ?? 0,
                unrealizedGL: row[safe: 4]?.asDouble ?? 0,
                realizedGL: row[safe: 5]?.asDouble ?? 0,
                dividends: row[safe: 6]?.asDouble ?? 0
            ))
        }
        // Deduplica por fecha, quedándose con la última entrada de cada día
        // (igual que el `reversed()` + `seen` de parse_history).
        var seen = Set<String>()
        var deduped: [HistoryPoint] = []
        for point in out.reversed() {
            if !seen.contains(point.date) {
                seen.insert(point.date)
                deduped.append(point)
            }
        }
        return deduped.reversed()
    }

    // MARK: - name -> ticker (espejo de _stock_name_to_ticker)

    private func fetchNameToTickerMap() async throws -> [String: String] {
        var mapping: [String: String] = [:]
        let sheetNames = ["Stock Summary", "Stock Summary USD", "Stock Summary HKD", "Summary AUD"]
        for sheetName in sheetNames {
            guard let rows = try? await fetchSheetValues(sheetName: sheetName) else { continue }
            var inData = false
            for row in rows {
                guard row.count >= 12 else { continue }
                if let marker = row[safe: 1]?.asString, marker == "Stock Name" || marker == "º" {
                    inData = true
                    continue
                }
                guard inData, let name = row[safe: 1]?.asString, !name.isEmpty else { continue }
                if mapping[name] == nil, let ticker = row[safe: 4]?.asString, !ticker.isEmpty {
                    mapping[name] = ticker
                }
            }
        }
        return mapping
    }

    // MARK: - Autenticación (ver JWTSigner.swift)

    private func accessToken() async throws -> String {
        if let token = cachedToken, Date() < tokenExpiry {
            return token
        }
        let jwt = try GoogleServiceAccountJWT.makeSignedJWT(serviceAccount: config.serviceAccount)

        var request = URLRequest(url: URL(string: config.serviceAccount.token_uri)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=\(jwt)"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SheetsError.tokenExchangeFailed(String(data: data, encoding: .utf8) ?? "sin detalle")
        }
        struct TokenResponse: Decodable { let access_token: String; let expires_in: Int }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        cachedToken = decoded.access_token
        tokenExpiry = Date().addingTimeInterval(TimeInterval(decoded.expires_in - 60))
        return decoded.access_token
    }

    // MARK: - Lectura cruda de una pestaña

    private struct ValueRange: Decodable { let values: [[SheetCell]]? }

    /// Descarga una pestaña completa con `valueRenderOption=UNFORMATTED_VALUE`
    /// — igual que `ws.get_values(value_render_option="UNFORMATTED_VALUE")`
    /// en gsheets_sync.py, para que las fechas lleguen como números de serie
    /// y no como texto ya formateado.
    private func fetchSheetValues(sheetName: String) async throws -> [[SheetCell]] {
        let token = try await accessToken()
        guard let encodedRange = sheetName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://sheets.googleapis.com/v4/spreadsheets/\(config.spreadsheetId)/values/\(encodedRange)?valueRenderOption=UNFORMATTED_VALUE")
        else { throw SheetsError.badResponse }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SheetsError.requestFailed("\(sheetName): \(String(data: data, encoding: .utf8) ?? "sin detalle")")
        }
        let decoded = try JSONDecoder().decode(ValueRange.self, from: data)
        return decoded.values ?? []
    }
}

// MARK: - Celda de Sheets con tipo dinámico (string/number/bool)

/// La API de Sheets devuelve filas "irregulares" (cada fila solo tiene tantas
/// celdas como la última con contenido) y cada celda puede ser String, Double
/// o Bool. Este tipo decodifica cualquiera de los tres y ofrece accesores
/// convenientes, similar a cómo openpyxl entrega valores ya tipados.
enum SheetCell: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Double.self) {
            self = .number(v)
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    var asString: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return String(n)
        case .bool(let b): return String(b)
        }
    }

    var asDouble: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        case .bool: return nil
        }
    }

    /// Convierte a "yyyy-MM-dd", aceptando tanto números de serie estilo
    /// Excel (epoch 1899-12-30, igual que `_EXCEL_EPOCH` en gsheets_sync.py)
    /// como texto ya formateado.
    var asDateString: String? {
        switch self {
        case .number(let serial):
            let epoch = DateComponents(calendar: Calendar(identifier: .gregorian),
                                        timeZone: TimeZone(identifier: "UTC"),
                                        year: 1899, month: 12, day: 30).date!
            let date = epoch.addingTimeInterval(serial * 86400)
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone(identifier: "UTC")
            return f.string(from: date)
        case .string(let s):
            return String(s.prefix(10))
        case .bool:
            return nil
        }
    }
}

extension Array {
    /// Acceso seguro — evita crashear si una fila viene más corta de lo
    /// esperado (filas irregulares de la API de Sheets).
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
