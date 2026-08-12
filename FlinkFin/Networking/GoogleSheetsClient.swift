import Foundation

/// Google Sheets API v4 client that reads and parses the same tabs as
/// `gsheets_sync.py` + `database.py` (desktop project). Re-implemented here
/// because this app runs independent logic (does not call FastAPI).
///
/// Sheet IDs and tab names matching gsheets_sync.py:
///   - Sheet: "2021 Stock Portfolio Tracker"
///   - Transactions: "Transactions" (SGD), "Transactions USD",
///     "Transactions HKD", "Transactions AUD"
///   - Metadata/tickers: "Stock Summary", "Stock Summary USD" (only one with
///     target prices), "Stock Summary HKD", "Summary AUD"
///   - History: "Portfolio History"
///
/// Credentials: requires the same service account JSON used by the Python backend
/// (`credentials/service_account.json`). NEVER stored in app bundle or git — see README.md.
actor GoogleSheetsClient {

    struct Config {
        var spreadsheetId: String
        var serviceAccount: GoogleServiceAccountJWT.ServiceAccountKey

        /// Dummy config for SwiftUI Previews / tests — NOT used in production.
        /// Private key is invalid; network calls with this will fail in `accessToken()`.
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

    // Tab names — matching gsheets_sync.py / database.py.
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

    // MARK: - Public API

    /// Reads all 4 transaction tabs (in the same order as `import_from_excel_if_empty()`)
    /// and assigns sequential IDs — serving the same role as SQLite autoincrement IDs.
    func fetchAllTransactions() async throws -> (transactions: [Transaction], duplicatesRemoved: Int) {
        let nameToTicker = try await fetchNameToTickerMap()
        var out: [Transaction] = []
        var nextID = 1
        for (sheetName, currency) in Self.transactionSheets {
            let rows = try await fetchSheetValues(sheetName: sheetName)
            for row in rows.dropFirst() { // min_row=2: row 0 is header
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

        // Deduplicate by business key: (date, type, name, currency, units, price).
        // Excludes `remarks` so identical financial rows with differing remarks are treated as duplicates.
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

    /// Mirror of `_import_stock_meta` — category + tickers + analyst price targets.
    /// Dictionary key: `"\(name)|\(currency)"`, matching `Holding.id` / `Transaction.positionKey`.
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

    /// Mirror of `parse_history()` (dashboard_server.py).
    /// Note: skips first 2 header rows (`rows.dropFirst(2)`).
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
        // Deduplicate by date, keeping the latest entry per date.
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

    // MARK: - name -> ticker (mirror of _stock_name_to_ticker)

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

    // MARK: - Authentication (see JWTSigner.swift)

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
            throw SheetsError.tokenExchangeFailed(String(data: data, encoding: .utf8) ?? "no detail")
        }
        struct TokenResponse: Decodable { let access_token: String; let expires_in: Int }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        cachedToken = decoded.access_token
        tokenExpiry = Date().addingTimeInterval(TimeInterval(decoded.expires_in - 60))
        return decoded.access_token
    }

    // MARK: - Raw tab reading

    private struct ValueRange: Decodable { let values: [[SheetCell]]? }

    /// Downloads a full tab with `valueRenderOption=UNFORMATTED_VALUE` so date
    /// values arrive as serial numbers rather than preformatted strings.
    private func fetchSheetValues(sheetName: String) async throws -> [[SheetCell]] {
        let token = try await accessToken()
        guard let encodedRange = sheetName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://sheets.googleapis.com/v4/spreadsheets/\(config.spreadsheetId)/values/\(encodedRange)?valueRenderOption=UNFORMATTED_VALUE")
        else { throw SheetsError.badResponse }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SheetsError.requestFailed("\(sheetName): \(String(data: data, encoding: .utf8) ?? "no detail")")
        }
        let decoded = try JSONDecoder().decode(ValueRange.self, from: data)
        return decoded.values ?? []
    }
}

// MARK: - Dynamic-typed Sheets cell (string/number/bool)

/// Sheets API returns ragged rows where cells may be String, Double, or Bool.
/// Decodes any of the three and provides convenient accessors.
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

    /// Converts to "yyyy-MM-dd", accepting both Excel-style serial numbers
    /// (epoch 1899-12-30) and formatted strings.
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
    /// Safe element access for ragged rows.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
