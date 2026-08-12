import Foundation

/// Swift equivalent of helpers `_fetch_fx_live` / `_fetch_prices_live` /
/// `_fetch_sparklines_live` (dashboard_server.py). Uses unofficial endpoint
/// `query1.finance.yahoo.com/v8/finance/chart/{symbol}`, which is the same one
/// yfinance uses under the hood for prices and history.
///
/// For fundamental data (P/E, beta, market cap…) Yahoo Finance requires
/// a session crumb that cannot be reliably fetched from iOS simulator/device without a browser.
/// `fetchQuoteDetail` parses the `meta` section of the chart response (52-week range, price, volume)
/// and calculates annual range from 1-year history using the same endpoint.
enum YahooFinanceClient {

    static let fallbackFXRates: [String: Double] = [
        "SGD": 1.0, "USD": 1.35, "HKD": 0.17, "AUD": 0.88,
    ]

    private static let fxPairs: [(pair: String, currency: String)] = [
        ("USDSGD=X", "USD"), ("HKDSGD=X", "HKD"), ("AUDSGD=X", "AUD"),
    ]

    // MARK: - Prices, FX, and Sparklines (mirror of Python dashboard)

    static func fetchFXRates() async -> [String: Double] {
        var rates = fallbackFXRates
        await withTaskGroup(of: (String, Double?).self) { group in
            for (pair, ccy) in fxPairs {
                group.addTask {
                    let s = try? await fetchCloseSeries(symbol: pair, range: "5d", interval: "1d")
                    return (ccy, s?.compactMap { $0 }.last)
                }
            }
            for await (ccy, v) in group { if let v { rates[ccy] = v } }
        }
        return rates
    }

    static func fetchPrices(tickers: [String]) async -> [String: Double] {
        guard !tickers.isEmpty else { return [:] }
        var prices: [String: Double] = [:]
        await withTaskGroup(of: (String, Double?).self) { group in
            for t in Set(tickers) where !t.isEmpty {
                group.addTask {
                    let s = try? await fetchCloseSeries(symbol: t, range: "5d", interval: "1d")
                    return (t, s?.compactMap { $0 }.last)
                }
            }
            for await (t, v) in group { if let v { prices[t] = v } }
        }
        return prices
    }

    /// Same as fetchPrices but also returns previous day's close (penultimate value of 5d/1d series)
    /// to calculate intraday change without extra network overhead.
    static func fetchPricesAndPrevClose(tickers: [String])
        async -> (current: [String: Double], prevClose: [String: Double])
    {
        guard !tickers.isEmpty else { return ([:], [:]) }
        var current: [String: Double] = [:]
        var prevClose: [String: Double] = [:]
        await withTaskGroup(of: (String, Double?, Double?).self) { group in
            for t in Set(tickers) where !t.isEmpty {
                group.addTask {
                    let s = (try? await fetchCloseSeries(symbol: t, range: "5d", interval: "1d"))
                              ?? []
                    let clean = s.compactMap { $0 }
                    let cur  = clean.last
                    // penultimate = previous session close
                    let prev = clean.count >= 2 ? clean[clean.count - 2] : nil
                    return (t, cur, prev)
                }
            }
            for await (t, c, p) in group {
                if let c { current[t]  = c }
                if let p { prevClose[t] = p }
            }
        }
        return (current, prevClose)
    }

    static func fetchSparklines(tickers: [String]) async -> [String: [Double]] {
        guard !tickers.isEmpty else { return [:] }
        var sparks: [String: [Double]] = [:]
        await withTaskGroup(of: (String, [Double]?).self) { group in
            for t in Set(tickers) where !t.isEmpty {
                group.addTask {
                    let s = try? await fetchCloseSeries(symbol: t, range: "1mo", interval: "1d")
                    let clean = s?.compactMap { $0 }
                    guard let clean, clean.count >= 3 else { return (t, nil) }
                    return (t, clean.map { (($0 * 10000).rounded()) / 10000 })
                }
            }
            for await (t, v) in group { if let v { sparks[t] = v } }
        }
        return sparks
    }

    // MARK: - Live Analyst Targets
    //
    // PRIMARY SOURCE: TradingView Scanner API
    //   POST https://scanner.tradingview.com/global/scan
    //   • Free, no API key, no auth required
    //   • Supports global exchanges: NASDAQ, NYSE, SGX, LSE, ASX, etc.
    //   • Single batch request for all tickers
    //   • Returns: price_target_average, price_target_high, price_target_low, recommendation_mark
    //
    // SECONDARY SOURCE: Yahoo Finance quoteSummary with crumb (US + international)
    // TERTIARY SOURCE: Finviz (US only, tickers without suffix)
    //
    // Note on ETFs: ETFs (VWRA.L, etc.) naturally do not have analyst price targets.
    // For ETFs, nil is returned and RecommendationEngine falls back to position performance logic.

    struct LiveAnalystTarget {
        var targetMean: Double?
        var targetHigh: Double?
        var targetLow: Double?
        var recommendationKey: String?   // "strong_buy" | "buy" | "hold" | "underperform" | "strong_sell"
    }

    // MARK: Ticker → Exchange mapping for TradingView
    // TradingView requires "EXCHANGE:TICKER" format (e.g., "NASDAQ:PLTR", "SGX:D05").

    private static func tradingViewSymbol(for ticker: String) -> String {
        let upper = ticker.uppercased()
        if upper.hasSuffix(".SI") {
            // Singapore Exchange: D05.SI → SGX:D05
            return "SGX:" + upper.replacingOccurrences(of: ".SI", with: "")
        } else if upper.hasSuffix(".L") {
            // London Stock Exchange: VWRA.L → LSE:VWRA
            return "LSE:" + upper.replacingOccurrences(of: ".L", with: "")
        } else if upper.hasSuffix(".AX") {
            // Australian Securities Exchange: WEB.AX → ASX:WEB
            return "ASX:" + upper.replacingOccurrences(of: ".AX", with: "")
        } else if upper.hasSuffix(".HK") {
            return "HKEX:" + upper.replacingOccurrences(of: ".HK", with: "")
        } else if upper.hasSuffix(".T") {
            return "TSE:" + upper.replacingOccurrences(of: ".T", with: "")
        } else if upper.contains("=X") || upper.contains("^") {
            // FX and ETFs without specific suffix — search global
            return "FOREXCOM:" + upper.replacingOccurrences(of: "=X", with: "").replacingOccurrences(of: "^", with: "")
        } else {
            // Assume US: TradingView global scanner auto-detects NASDAQ/NYSE
            return upper
        }
    }

    private static func recommendationKey(from mark: Double?) -> String? {
        guard let m = mark else { return nil }
        // TradingView recommendation_mark: 1.0=Strong Buy … 5.0=Strong Sell
        if m <= 1.5 { return "strong_buy" }
        if m <= 2.5 { return "buy" }
        if m <= 3.5 { return "hold" }
        if m <= 4.5 { return "underperform" }
        return "strong_sell"
    }

    // MARK: Dedicated URLSession with cookie storage for Yahoo
    private static let yahooSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.httpCookieStorage = HTTPCookieStorage.shared
        return URLSession(configuration: config)
    }()

    private static func applyYahooHeaders(to req: inout URLRequest) {
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue("application/json, */*;q=0.9", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    }

    // MARK: Public Entry Point

    static func fetchAnalystTargets(tickers: [String]) async -> [String: LiveAnalystTarget] {
        let clean = Array(Set(tickers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }.filter { !$0.isEmpty }))
        guard !clean.isEmpty else { return [:] }

        // Step 1: try TradingView batch (all tickers at once)
        var results = await fetchFromTradingView(tickers: clean)

        // Step 2: for tickers missing from TradingView, try Yahoo + Finviz
        let missing = clean.filter { results[$0] == nil }
        if !missing.isEmpty {
            let crumb = await fetchYahooCrumb()
            await withTaskGroup(of: (String, LiveAnalystTarget?).self) { group in
                for ticker in missing {
                    group.addTask { (ticker, await fetchFallback(ticker: ticker, crumb: crumb)) }
                }
                for await (ticker, target) in group {
                    if let t = target, t.targetMean != nil || t.recommendationKey != nil {
                        results[ticker] = t
                    }
                }
            }
        }
        return results
    }

    // MARK: Layer 1 — TradingView Scanner API (batch, free, global)

    private static func fetchFromTradingView(tickers: [String]) async -> [String: LiveAnalystTarget] {
        guard let url = URL(string: "https://scanner.tradingview.com/global/scan") else { return [:] }

        let tvSymbols = tickers.map { tradingViewSymbol(for: $0) }
        let columns = ["name", "price_target_average", "price_target_high", "price_target_low", "recommendation_mark"]
        let payload: [String: Any] = [
            "symbols": ["tickers": tvSymbols],
            "columns": columns
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return [:] }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue("https://www.tradingview.com", forHTTPHeaderField: "Origin")
        req.setValue("https://www.tradingview.com/", forHTTPHeaderField: "Referer")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["data"] as? [[String: Any]]
        else { return [:] }

        var tvToTicker: [String: String] = [:]
        for ticker in tickers {
            tvToTicker[tradingViewSymbol(for: ticker)] = ticker
        }

        var results: [String: LiveAnalystTarget] = [:]
        for row in rows {
            guard let symbol = row["s"] as? String,
                  let values = row["d"] as? [Any?]
            else { continue }

            let mean = values.count > 1 ? (values[1] as? Double) : nil
            let high = values.count > 2 ? (values[2] as? Double) : nil
            let low  = values.count > 3 ? (values[3] as? Double) : nil
            let mark = values.count > 4 ? (values[4] as? Double) : nil

            guard let ticker = tvToTicker[symbol] else { continue }

            if (mean != nil && (mean ?? 0) > 0) || mark != nil {
                results[ticker] = LiveAnalystTarget(
                    targetMean: mean,
                    targetHigh: high,
                    targetLow: low,
                    recommendationKey: recommendationKey(from: mark)
                )
            }
        }
        return results
    }

    // MARK: Layer 2 — Yahoo Finance quoteSummary with crumb

    private static func fetchYahooCrumb() async -> String? {
        for urlStr in ["https://fc.yahoo.com", "https://finance.yahoo.com"] {
            guard let url = URL(string: urlStr) else { continue }
            var r = URLRequest(url: url)
            applyYahooHeaders(to: &r)
            _ = try? await yahooSession.data(for: r)
        }
        for urlStr in ["https://query1.finance.yahoo.com/v1/test/getcrumb",
                       "https://query2.finance.yahoo.com/v1/test/getcrumb"] {
            guard let url = URL(string: urlStr) else { continue }
            var r = URLRequest(url: url)
            applyYahooHeaders(to: &r)
            if let (data, resp) = try? await yahooSession.data(for: r),
               let http = resp as? HTTPURLResponse, http.statusCode == 200,
               let crumb = String(data: data, encoding: .utf8),
               !crumb.isEmpty, crumb != "null", !crumb.contains("<") {
                return crumb
            }
        }
        return nil
    }

    // MARK: Layer 2+3 — Yahoo + Finviz fallback

    private static func fetchFallback(ticker: String, crumb: String?) async -> LiveAnalystTarget? {
        // Yahoo quoteSummary
        if let crumb, !crumb.isEmpty,
           let enc = ticker.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let cEnc = crumb.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {

            struct QSR: Decodable {
                struct QS: Decodable {
                    struct I: Decodable {
                        struct FD: Decodable {
                            struct V: Decodable { let raw: Double? }
                            let targetMeanPrice: V?
                            let targetHighPrice: V?
                            let targetLowPrice: V?
                            let recommendationKey: String?
                        }
                        let financialData: FD?
                    }
                    let result: [I]?
                }
                let quoteSummary: QS?
            }

            for base in ["query1", "query2"] {
                let u = "https://\(base).finance.yahoo.com/v10/finance/quoteSummary/\(enc)?modules=financialData&crumb=\(cEnc)"
                guard let url = URL(string: u) else { continue }
                var req = URLRequest(url: url)
                applyYahooHeaders(to: &req)
                if let (data, resp) = try? await yahooSession.data(for: req),
                   let http = resp as? HTTPURLResponse, http.statusCode == 200,
                   let d = try? JSONDecoder().decode(QSR.self, from: data),
                   let fd = d.quoteSummary?.result?.first?.financialData {
                    let mean = fd.targetMeanPrice?.raw
                    let key  = fd.recommendationKey
                    if (mean != nil && mean! > 0) || (key != nil && !key!.isEmpty) {
                        return LiveAnalystTarget(targetMean: mean, targetHigh: fd.targetHighPrice?.raw,
                                                 targetLow: fd.targetLowPrice?.raw, recommendationKey: key)
                    }
                }
            }
        }

        // Finviz (US only, tickers without dot)
        guard !ticker.contains("."),
              let enc = ticker.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://finviz.com/quote.ashx?t=\(enc)&p=d")
        else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/125.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        req.setValue("https://finviz.com", forHTTPHeaderField: "Referer")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8)
        else { return nil }

        let target = extractDouble(pattern: "Target Price</td><td[^>]*><b>([0-9.]+)", from: html)
        let recom  = extractDouble(pattern: "Recom</td><td[^>]*><b>([0-9.]+)", from: html)
        guard let target, target > 0 else { return nil }
        return LiveAnalystTarget(targetMean: target, targetHigh: nil, targetLow: nil,
                                 recommendationKey: recommendationKey(from: recom != nil ? recom! * 1.25 : nil))
    }

    // MARK: Regex Helpers

    private static func extractDouble(pattern: String, from text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        return Double(ns.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: ""))
    }

    private static func extractString(pattern: String, from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    // MARK: - Fundamental data (crumb-free)

    static func fetchQuoteDetail(ticker: String) async throws -> StockQuote {
        guard !ticker.isEmpty,
              let encoded = ticker.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?range=1y&interval=1d")
        else { throw URLError(.badURL) }

        var req = URLRequest(url: url)
        applyHeaders(to: &req)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "Yahoo", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(code) for \(ticker)"])
        }

        let decoded = try JSONDecoder().decode(ChartResponseFull.self, from: data)
        guard let result = decoded.chart.result?.first else {
            throw URLError(.cannotParseResponse)
        }

        let meta = result.meta

        let closes: [Double] = (result.indicators.adjclose?.first?.adjclose
                                ?? result.indicators.quote.first?.close
                                ?? []).compactMap { $0 }

        let w52High = meta.fiftyTwoWeekHigh ?? (closes.isEmpty ? nil : closes.max())
        let w52Low  = meta.fiftyTwoWeekLow  ?? (closes.isEmpty ? nil : closes.min())

        return StockQuote(
            ticker:                 ticker,
            regularMarketPrice:     meta.regularMarketPrice,
            regularMarketChangePct: nil,
            fiftyTwoWeekHigh:       w52High,
            fiftyTwoWeekLow:        w52Low,
            volume:                 meta.regularMarketVolume.map { Double($0) },
            trailingPE:             nil,
            forwardPE:              nil,
            trailingEps:            nil,
            priceToBook:            nil,
            marketCap:              nil,
            averageVolume:          nil,
            beta:                   nil,
            dividendYield:          nil,
            dividendRate:           nil,
            targetMean:             nil,
            grossMargins:           nil,
            profitMargins:          nil,
            roe:                    nil
        )
    }

    // MARK: - Decodables

    private struct ChartResponseFull: Decodable {
        struct ChartWrapper: Decodable { let result: [ChartResult]? }
        struct ChartResult: Decodable {
            let meta: ChartMeta
            let indicators: Indicators
        }
        struct ChartMeta: Decodable {
            let regularMarketPrice: Double?
            let regularMarketVolume: Int?
            let fiftyTwoWeekHigh: Double?
            let fiftyTwoWeekLow: Double?
        }
        struct Indicators: Decodable {
            struct Quote: Decodable { let close: [Double?]? }
            struct AdjClose: Decodable { let adjclose: [Double?]? }
            let quote: [Quote]
            let adjclose: [AdjClose]?
        }
        let chart: ChartWrapper
    }

    private struct ChartResponse: Decodable {
        struct Result: Decodable {
            struct Indicators: Decodable {
                struct Quote: Decodable { let close: [Double?]? }
                struct AdjClose: Decodable { let adjclose: [Double?]? }
                let quote: [Quote]
                let adjclose: [AdjClose]?
            }
            let indicators: Indicators
        }
        struct Chart: Decodable { let result: [Result]? }
        let chart: Chart
    }

    static func fetchCloseSeries(symbol: String, range: String, interval: String) async throws -> [Double?] {
        guard let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?range=\(range)&interval=\(interval)")
        else { return [] }

        var req = URLRequest(url: url)
        applyHeaders(to: &req)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return [] }

        let decoded = try JSONDecoder().decode(ChartResponse.self, from: data)
        guard let result = decoded.chart.result?.first else { return [] }

        if let adj = result.indicators.adjclose?.first?.adjclose { return adj }
        return result.indicators.quote.first?.close ?? []
    }

    // MARK: - Headers

    private static func applyHeaders(to req: inout URLRequest) {
        req.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue("application/json, */*", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    }
}

// MARK: - Fundamental Data Model

struct StockQuote {
    var ticker: String
    var regularMarketPrice: Double?
    var regularMarketChangePct: Double?
    var fiftyTwoWeekHigh: Double?
    var fiftyTwoWeekLow: Double?
    var volume: Double?
    var trailingPE: Double?
    var forwardPE: Double?
    var trailingEps: Double?
    var priceToBook: Double?
    var marketCap: Double?
    var averageVolume: Double?
    var beta: Double?
    var dividendYield: Double?
    var dividendRate: Double?
    var targetMean: Double?
    var grossMargins: Double?
    var profitMargins: Double?
    var roe: Double?
    var sector: String?
    var industry: String?
    var description: String?
    var analystRating: String?
}
