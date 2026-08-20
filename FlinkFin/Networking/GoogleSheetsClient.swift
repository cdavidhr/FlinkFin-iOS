import Foundation

/// Swift client for Google Sheets API v4 (read-only).
/// Uses `JWTSigner` to generate JWT tokens signed with the service account's RS256 private key,
/// then exchanges them for Google OAuth2 access tokens — NO third-party SDK dependencies required.
actor GoogleSheetsClient {
    struct Config {
        var spreadsheetId: String
        var serviceAccount: GoogleServiceAccountJWT.ServiceAccountKey
    }

    // Note: stock metadata uses the shared `StockMeta` model (PortfolioEngine.swift),
    // not a locally-nested type — `PortfolioEngine.computeHoldings(meta:)` expects
    // that exact type, and a same-named nested type here would silently shadow it
    // and fail to type-check at the call site.

    private let config: Config
    private var cachedToken: String?
    private var tokenExpiry: Date = .distantPast

    init(config: Config) {
        self.config = config
    }

    enum SheetsError: Error, LocalizedError {
        case tokenExchangeFailed(String)
        case requestFailed(String)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .tokenExchangeFailed(let detail):
                return "Token exchange failed: \(detail)"
            case .requestFailed(let detail):
                return "Sheets request failed: \(detail)"
            case .badResponse:
                return "Bad response from Google Sheets API"
            }
        }
    }

    // MARK: - Tab Configurations (matching gsheets_sync.py)

    private static let transactionSheets: [(name: String, currency: String)] = [
        ("Transactions", "SGD"),
        ("Transactions USD", "USD"),
        ("Transactions HKD", "HKD"),
        ("Transactions AUD", "AUD"),
    ]

    private static let metaSheets: [(name: String, currency: String, hasTargets: Bool)] = [
        ("Stock Summary", "SGD", true),
        ("Stock Summary USD", "USD", true),
        ("Stock Summary HKD", "HKD", false),
        ("Summary AUD", "AUD", false),
    ]

    private static let validTypes: Set<String> = ["Buy", "Sell", "Div"]

    // MARK: - Public API

    /// Fetches the transaction tabs and the stock-meta tabs using TWO batchGet HTTP
    /// requests (kept separate on purpose — see note below), then derives
    /// transactions (deduped, sequential IDs) and stock metadata
    /// (ticker/category/analyst targets) from those two responses.
    ///
    /// Previously `PortfolioStore.refresh()` triggered 3 separate batchGet calls per
    /// refresh: one for the transaction tabs, and TWO redundant calls hitting the
    /// exact same 4 meta tabs (one to build the name→ticker map, one for stock meta).
    /// That doubled the Sheets read-quota cost of every refresh and was the direct
    /// cause of the "429 RATE_LIMIT_EXCEEDED" error on Transactions AUD at startup.
    /// This fetches the meta tabs only once (down to 2 requests/refresh) but keeps
    /// transactions and meta as separate batchGet calls: Sheets' batchGet fails the
    /// WHOLE request with a single 400 if even one requested tab doesn't exist, and
    /// `fetchSheetValuesBatch` treats that 400 as "no data" rather than an error —
    /// merging all 8 tabs into one call (an earlier version of this fix) meant a
    /// single missing optional tab (e.g. no "Summary AUD") silently zeroed out
    /// transactions too, showing "no data" instead of loading anything. Keeping the
    /// two groups separate means a missing tab in one group no longer blanks out
    /// the other.
    func fetchPortfolioData() async throws -> (transactions: [Transaction], duplicatesRemoved: Int, stockMeta: [String: StockMeta]) {
        let txSheetNames = Self.transactionSheets.map { $0.name }
        let metaSheetNames = Self.metaSheets.map { $0.name }

        async let txBatchTask = fetchSheetValuesBatch(sheetNames: txSheetNames)
        async let metaBatchTask = fetchSheetValuesBatch(sheetNames: metaSheetNames)
        let txData = try await txBatchTask
        let metaData = (try? await metaBatchTask) ?? [:]

        let nameToTicker = Self.buildNameToTickerMap(from: metaData)
        let stockMeta = Self.buildStockMeta(from: metaData)
        let (transactions, duplicatesRemoved) = Self.buildTransactions(from: txData, nameToTicker: nameToTicker)

        return (transactions, duplicatesRemoved, stockMeta)
    }

    // MARK: - Helpers: parsing batchGet results (pure, no network I/O)

    private static func buildTransactions(
        from batchData: [String: [[SheetCell]]],
        nameToTicker: [String: String]
    ) -> (transactions: [Transaction], duplicatesRemoved: Int) {
        var out: [Transaction] = []
        var nextID = 1

        for (sheetName, currency) in Self.transactionSheets {
            guard let rows = batchData[sheetName], !rows.isEmpty else { continue }
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
    private static func buildStockMeta(from batchData: [String: [[SheetCell]]]) -> [String: StockMeta] {
        var out: [String: StockMeta] = [:]

        for (sheetName, currency, hasTargets) in Self.metaSheets {
            guard let rows = batchData[sheetName], !rows.isEmpty else { continue }
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

    private static func buildNameToTickerMap(from batchData: [String: [[SheetCell]]]) -> [String: String] {
        var mapping: [String: String] = [:]
        let sheetNames = Self.metaSheets.map { $0.name }

        for sheetName in sheetNames {
            guard let rows = batchData[sheetName], !rows.isEmpty else { continue }
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

    /// Mirror of `parse_history()` (dashboard_server.py).
    func fetchPortfolioHistory() async throws -> [HistoryPoint] {
        let batchData = (try? await fetchSheetValuesBatch(sheetNames: ["Portfolio History"])) ?? [:]
        guard let rows = batchData["Portfolio History"], rows.count > 2 else { return [] }
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

    private var currentSpreadsheetId: String {
        let stored = SecureCredentialStore.spreadsheetID.trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.isEmpty ? config.spreadsheetId : stored
    }

    private var currentServiceAccount: GoogleServiceAccountJWT.ServiceAccountKey {
        SecureCredentialStore.loadServiceAccount() ?? config.serviceAccount
    }

    // MARK: - Authentication

    private func accessToken() async throws -> String {
        if let token = cachedToken, Date() < tokenExpiry {
            return token
        }
        let account = currentServiceAccount
        let jwt = try GoogleServiceAccountJWT.makeSignedJWT(serviceAccount: account)

        var request = URLRequest(url: URL(string: account.token_uri)!)
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

    // MARK: - Batch & Single Tab Reading

    private struct BatchValueRangeResponse: Decodable {
        struct NamedValueRange: Decodable {
            let range: String?
            let values: [[SheetCell]]?
        }
        let valueRanges: [NamedValueRange]?
    }

    /// Downloads multiple tabs in a SINGLE HTTP request using spreadsheets.values.batchGet.
    /// Drastically reduces network roundtrips and prevents 429 Rate Limit Exceeded errors.
    private func fetchSheetValuesBatch(sheetNames: [String]) async throws -> [String: [[SheetCell]]] {
        let token = try await accessToken()
        var components = URLComponents(string: "https://sheets.googleapis.com/v4/spreadsheets/\(currentSpreadsheetId)/values:batchGet")!
        var queryItems = sheetNames.map { URLQueryItem(name: "ranges", value: $0) }
        queryItems.append(URLQueryItem(name: "valueRenderOption", value: "UNFORMATTED_VALUE"))
        components.queryItems = queryItems

        guard let url = components.url else { throw SheetsError.badResponse }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        var (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 429 {
            // Rate limited (429): pause 2 seconds and retry once
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let (retryData, retryResponse) = try await URLSession.shared.data(for: request)
            data = retryData
            response = retryResponse
        }

        guard let http = response as? HTTPURLResponse else { throw SheetsError.badResponse }

        if http.statusCode == 200 {
            let decoded = try JSONDecoder().decode(BatchValueRangeResponse.self, from: data)
            var result: [String: [[SheetCell]]] = [:]
            if let ranges = decoded.valueRanges {
                for (index, item) in ranges.enumerated() {
                    if index < sheetNames.count {
                        result[sheetNames[index]] = item.values ?? []
                    }
                }
            }
            return result
        } else if http.statusCode == 429 {
            throw SheetsError.requestFailed("Google Sheets rate limit reached (Quota Exceeded 429). Please wait 1 minute before refreshing again.")
        } else if http.statusCode == 400 || http.statusCode == 404 {
            return [:]
        } else {
            throw SheetsError.requestFailed("\(String(data: data, encoding: .utf8) ?? "no detail")")
        }
    }
}

extension GoogleSheetsClient.Config {
    static var preview: GoogleSheetsClient.Config {
        GoogleSheetsClient.Config(
            spreadsheetId: "preview-spreadsheet-id",
            serviceAccount: GoogleServiceAccountJWT.ServiceAccountKey(
                client_email: "preview@example.iam.gserviceaccount.com",
                private_key: "-----BEGIN PRIVATE KEY-----\npreview\n-----END PRIVATE KEY-----",
                token_uri: "https://oauth2.googleapis.com/token"
            )
        )
    }
}

// MARK: - Dynamic-typed Sheets cell (string/number/bool)

enum SheetCell: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Double.self) {
            self = .number(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else {
            self = .string("")
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

    /// Converts Excel serial date (e.g. 45678.5) to ISO-8601 date string YYYY-MM-DD.
    var asDateString: String? {
        switch self {
        case .number(let serial):
            let daysSince1900 = Int(floor(serial))
            var dateComponents = DateComponents()
            dateComponents.year = 1899
            dateComponents.month = 12
            dateComponents.day = 30 + daysSince1900
            let calendar = Calendar(identifier: .gregorian)
            guard let date = calendar.date(from: dateComponents) else { return nil }
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            return fmt.string(from: date)
        case .string(let s):
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case .bool:
            return nil
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
