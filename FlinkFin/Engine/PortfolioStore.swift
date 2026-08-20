import Foundation

/// Display currency for the app UI.
/// Internal metrics are calculated in SGD; this enum controls whether
/// the UI renders them in SGD or converts to EUR in real time.
enum DisplayCurrency: String, CaseIterable {
    case sgd = "SGD"
    case eur = "EUR"

    var symbol: String {
        switch self {
        case .sgd: return "S$"
        case .eur: return "€"
        }
    }
}

/// @MainActor orchestrator uniting Sheets + Yahoo + engines (PortfolioEngine/RecommendationEngine)
/// into published state for SwiftUI — mirroring `build_portfolio_data()` in dashboard_server.py.
@MainActor
final class PortfolioStore: ObservableObject {

    @Published private(set) var transactions: [Transaction] = []
    @Published private(set) var holdings: [Holding] = []
    @Published private(set) var totals: PortfolioTotals?
    @Published private(set) var byCurrency: [CurrencyBreakdown] = []
    @Published private(set) var recommendations: [String: Recommendation] = [:]
    @Published private(set) var history: [HistoryPoint] = []
    @Published private(set) var intradayHistory: [HistoryPoint] = []
    @Published private(set) var isLoadingIntradayHistory = false
    @Published private(set) var fx: [String: Double] = YahooFinanceClient.fallbackFXRates
    @Published private(set) var lastUpdated: Date?
    /// Number of duplicate rows removed in last refresh(). 0 if none.
    @Published private(set) var duplicatesFoundOnLastRefresh: Int = 0
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    /// Ticker returns over period selected in PerformanceView.
    @Published private(set) var periodReturns: [String: Double] = [:]
    @Published private(set) var isLoadingPeriodReturns = false
    /// Change in total portfolio value from previous close in SGD.
    @Published private(set) var dailyChangeValueSGD: Double? = nil
    /// Percentage change relative to previous close.
    @Published private(set) var dailyChangePct: Double? = nil

    /// User-selected display currency.
    @Published var displayCurrency: DisplayCurrency = .sgd

    /// SGD → EUR exchange rate.
    @Published private(set) var sgdToEurRate: Double = 1.0 / 1.45

    // MARK: - Display Currency Conversion

    func toDisplay(_ sgdAmount: Double) -> Double {
        switch displayCurrency {
        case .sgd: return sgdAmount
        case .eur: return sgdAmount * sgdToEurRate
        }
    }

    var displayCode: String { displayCurrency.rawValue }

    private let sheets: GoogleSheetsClient

    init(sheets: GoogleSheetsClient) {
        self.sheets = sheets
    }

    /// Guards against overlapping refresh() calls (e.g. RootTabView's startup .task
    /// racing with a manual pull-to-refresh or the toolbar reload button). Each
    /// refresh() already costs 1 Sheets batchGet request; running two at once used
    /// to double that and contributed to hitting the per-minute read quota (429).
    private var isRefreshing = false

    /// Reloads transactions + metadata from Sheets, recomputes holdings,
    /// fetches live prices/FX/sparklines from Yahoo, and builds recommendations.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            isRefreshing = false
        }

        do {
            let portfolioData = try await sheets.fetchPortfolioData()
            let stockMeta = portfolioData.stockMeta
            let fetchedTransactions = portfolioData.transactions
            self.duplicatesFoundOnLastRefresh = portfolioData.duplicatesRemoved
            self.transactions = fetchedTransactions

            let baseHoldings = PortfolioEngine.computeHoldings(transactions: fetchedTransactions, meta: stockMeta)
            let tickers = baseHoldings.compactMap { $0.ticker.isEmpty ? nil : $0.ticker }

            async let fxRates = YahooFinanceClient.fetchFXRates()
            async let pricesResult = YahooFinanceClient.fetchPricesAndPrevClose(tickers: tickers)
            async let sparks = YahooFinanceClient.fetchSparklines(tickers: tickers)
            async let targets = YahooFinanceClient.fetchAnalystTargets(tickers: tickers)
            async let eursgdSeries = YahooFinanceClient.fetchCloseSeries(
                symbol: "EURSGD=X", range: "5d", interval: "1d"
            )
            let (resolvedFX, (resolvedPrices, resolvedPrevClose), resolvedSparks, resolvedTargets, eursgdPricesOpt) =
                await (fxRates, pricesResult, sparks, targets, try? eursgdSeries)

            if let eursgd = (eursgdPricesOpt ?? []).compactMap({ $0 }).last, eursgd > 0 {
                self.sgdToEurRate = 1.0 / eursgd
            }

            var enriched: [Holding] = []
            var newRecs: [String: Recommendation] = [:]
            var prevValueSGD: Double = 0
            var prevDataCount: Int = 0
            for var h in baseHoldings {
                h.fxRate = resolvedFX[h.currency] ?? 1.0
                let cleanTicker = h.ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                if let liveT = resolvedTargets[cleanTicker] {
                    if let meanT = liveT.targetMean, meanT > 0 {
                        h.avgTarget = meanT
                        h.minTarget = liveT.targetLow
                        h.maxTarget = liveT.targetHigh
                    }
                    if let key = liveT.recommendationKey, !key.isEmpty {
                        h.recommendationKey = key
                    }
                }
                if let live = resolvedPrices[h.ticker] {
                    h.livePrice = live
                    h.priceIsLive = true
                } else {
                    h.livePrice = h.cpu ?? 0
                    h.priceIsLive = false
                }
                if let prev = resolvedPrevClose[h.ticker], let fx = h.fxRate {
                    prevValueSGD += prev * h.units * fx
                    prevDataCount += 1
                }
                h.sparkline = resolvedSparks[h.ticker]
                enriched.append(h)
                newRecs[h.id] = RecommendationEngine.recommend(for: h)
            }

            self.holdings = enriched.sorted { $0.liveValueSGD ?? 0 > $1.liveValueSGD ?? 0 }
            self.recommendations = newRecs
            self.fx = resolvedFX
            let totalsResult = Self.computeTotals(enriched)
            self.totals = totalsResult
            self.byCurrency = Self.computeBreakdown(enriched)
            self.lastUpdated = Date()

            if prevDataCount > 0 && prevValueSGD > 0 {
                let currentSGD = totalsResult.valueSGD
                self.dailyChangeValueSGD = currentSGD - prevValueSGD
                self.dailyChangePct = (currentSGD - prevValueSGD) / prevValueSGD
            } else {
                self.dailyChangeValueSGD = nil
                self.dailyChangePct = nil
            }
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    /// Fetches total portfolio history for Performance tab.
    func refreshHistory() async {
        do {
            self.history = try await sheets.fetchPortfolioHistory().sorted { $0.date < $1.date }
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Period Returns (Top/Bottom 5 in PerformanceView)

    func fetchPeriodReturns(days: Int) async {
        let tickers = holdings.compactMap { $0.ticker.isEmpty ? nil : $0.ticker }
        guard !tickers.isEmpty else { return }

        isLoadingPeriodReturns = true
        defer { isLoadingPeriodReturns = false }

        let range = days > 365 ? "5y" : "1y"
        let interval = "1d"

        var result: [String: Double] = [:]

        await withTaskGroup(of: (String, Double?).self) { group in
            for ticker in Set(tickers) {
                group.addTask {
                    guard let encoded = ticker.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                          let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?range=\(range)&interval=\(interval)")
                    else { return (ticker, nil) }

                    var req = URLRequest(url: url)
                    req.setValue(
                        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
                        forHTTPHeaderField: "User-Agent"
                    )
                    guard let (data, resp) = try? await URLSession.shared.data(for: req),
                          let http = resp as? HTTPURLResponse, http.statusCode == 200
                    else { return (ticker, nil) }

                    struct CR: Decodable {
                        struct C: Decodable { let result: [R]? }
                        struct R: Decodable {
                            struct I: Decodable {
                                struct Q: Decodable { let close: [Double?]? }
                                struct A: Decodable { let adjclose: [Double?]? }
                                let quote: [Q]
                                let adjclose: [A]?
                            }
                            let indicators: I
                            let timestamp: [Int]?
                        }
                        let chart: C
                    }
                    guard let decoded = try? JSONDecoder().decode(CR.self, from: data),
                          let r = decoded.chart.result?.first
                    else { return (ticker, nil) }

                    let closes: [Double]
                    if let adj = r.indicators.adjclose?.first?.adjclose {
                        closes = adj.compactMap { $0 }
                    } else {
                        closes = (r.indicators.quote.first?.close ?? []).compactMap { $0 }
                    }

                    let cutoff: [Double]
                    if days >= 9999 {
                        cutoff = closes
                    } else if let ts = r.timestamp {
                        let cutoffEpoch = Date().timeIntervalSince1970 - Double(days) * 86400
                        let paired = zip(ts, closes).filter { Double($0.0) >= cutoffEpoch }.map { $0.1 }
                        cutoff = paired
                    } else {
                        let n = min(days, closes.count)
                        cutoff = Array(closes.suffix(n))
                    }

                    guard cutoff.count >= 2, let first = cutoff.first, first > 0 else {
                        return (ticker, nil)
                    }
                    let ret = (cutoff.last! / first) - 1
                    return (ticker, ret)
                }
            }
            for await (ticker, ret) in group {
                if let ret { result[ticker] = ret }
            }
        }

        self.periodReturns = result
    }

    // MARK: - Synthetic Intraday History (1D / 5D)

    func fetchIntradayHistory(days: Int) async {
        guard days == 1 || days == 5 else { return }

        let validHoldings = holdings.filter { !$0.ticker.isEmpty && $0.units > 0 }
        guard !validHoldings.isEmpty else { return }

        DispatchQueue.main.async { self.isLoadingIntradayHistory = true }
        defer { DispatchQueue.main.async { self.isLoadingIntradayHistory = false } }

        let range = days == 1 ? "1d" : "5d"
        let interval = days == 1 ? "5m" : "15m"

        var seriesByHolding: [String: [(ts: Double, val: Double)]] = [:]

        await withTaskGroup(of: (String, [(ts: Double, val: Double)]).self) { group in
            for h in validHoldings {
                group.addTask {
                    guard let encoded = h.ticker.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                          let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?range=\(range)&interval=\(interval)")
                    else { return (h.ticker, []) }

                    var req = URLRequest(url: url)
                    req.setValue(
                        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
                        forHTTPHeaderField: "User-Agent"
                    )

                    guard let (data, resp) = try? await URLSession.shared.data(for: req),
                          let http = resp as? HTTPURLResponse, http.statusCode == 200
                    else { return (h.ticker, []) }

                    struct CR: Decodable {
                        struct C: Decodable { let result: [R]? }
                        struct R: Decodable {
                            struct I: Decodable {
                                struct Q: Decodable { let close: [Double?]? }
                                struct A: Decodable { let adjclose: [Double?]? }
                                let quote: [Q]
                                let adjclose: [A]?
                            }
                            let indicators: I
                            let timestamp: [Int]?
                        }
                        let chart: C
                    }

                    guard let decoded = try? JSONDecoder().decode(CR.self, from: data),
                          let r = decoded.chart.result?.first,
                          let ts = r.timestamp else { return (h.ticker, []) }

                    let closes: [Double?]
                    if let adj = r.indicators.adjclose?.first?.adjclose {
                        closes = adj
                    } else {
                        closes = r.indicators.quote.first?.close ?? []
                    }

                    let fxRate = h.fxRate ?? 1.0
                    let pairs = zip(ts, closes).compactMap { t, c -> (ts: Double, val: Double)? in
                        guard let c = c else { return nil }
                        return (ts: Double(t), val: c * h.units * fxRate)
                    }
                    return (h.ticker, pairs)
                }
            }

            for await (ticker, pairs) in group {
                if !pairs.isEmpty {
                    seriesByHolding[ticker] = pairs
                }
            }
        }

        let allTS = Set(seriesByHolding.values.flatMap { $0.map { $0.ts } }).sorted()

        var currentIndexes = [String: Int]()
        for k in seriesByHolding.keys { currentIndexes[k] = 0 }

        let offset = (self.history.last?.value ?? 0) - (self.totals?.valueSGD ?? 0)
        let costConstant = self.history.last?.cost ?? self.totals?.costSGD ?? 0

        var newHistory: [HistoryPoint] = []
        let formatter = ISO8601DateFormatter()

        for ts in allTS {
            var sumSGD: Double = 0
            for (ticker, series) in seriesByHolding {
                var idx = currentIndexes[ticker]!
                while idx < series.count - 1 && series[idx + 1].ts <= ts {
                    idx += 1
                }
                currentIndexes[ticker] = idx
                if series[idx].ts <= ts {
                    sumSGD += series[idx].val
                }
            }

            let totalValue = sumSGD + offset
            let dateStr = formatter.string(from: Date(timeIntervalSince1970: ts))

            newHistory.append(HistoryPoint(
                date: dateStr,
                cost: costConstant,
                value: totalValue,
                unrealizedGL: totalValue - costConstant,
                realizedGL: 0,
                dividends: 0
            ))
        }

        DispatchQueue.main.async {
            self.intradayHistory = newHistory
        }
    }

    // MARK: - Aggregates

    private static func computeTotals(_ holdings: [Holding]) -> PortfolioTotals {
        let value = holdings.reduce(0) { $0 + ($1.liveValueSGD ?? 0) }
        let cost = holdings.reduce(0) { $0 + $1.costSGD }
        let gl = value - cost
        return PortfolioTotals(valueSGD: value, costSGD: cost, glSGD: gl, glPct: cost != 0 ? gl / cost : 0)
    }

    private static func computeBreakdown(_ holdings: [Holding]) -> [CurrencyBreakdown] {
        var byCurrency: [String: CurrencyBreakdown] = [:]
        for h in holdings {
            let value = h.liveValueSGD ?? 0
            let cost = h.costSGD
            var entry = byCurrency[h.currency] ?? CurrencyBreakdown(
                currency: h.currency, value: 0, cost: 0, gl: 0, count: 0, fxRate: h.fxRate ?? 1.0
            )
            entry.value += value
            entry.cost += cost
            entry.gl += value - cost
            entry.count += 1
            byCurrency[h.currency] = entry
        }
        return byCurrency.values.sorted { $0.currency < $1.currency }
    }
}

// MARK: - Aggregate Result Models

struct PortfolioTotals: Codable, Equatable {
    var valueSGD: Double
    var costSGD: Double
    var glSGD: Double
    var glPct: Double
}

struct CurrencyBreakdown: Codable, Equatable, Identifiable {
    var currency: String
    var value: Double
    var cost: Double
    var gl: Double
    var count: Int
    var fxRate: Double

    var id: String { currency }
}
