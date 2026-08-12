import Foundation

/// Moneda de presentación de toda la app.
/// Todos los valores internos se calculan en SGD; este enum controla
/// si la UI los muestra en SGD o los convierte a EUR en tiempo real.
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

/// Orquestador @MainActor que junta Sheets + Yahoo + los motores
/// (PortfolioEngine/RecommendationEngine) en estado publicado para SwiftUI —
/// el mismo papel que `build_portfolio_data()` en dashboard_server.py.
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
    /// Número de filas duplicadas eliminadas en la última llamada a refresh().
    /// 0 si no hubo duplicados o si aún no se ha hecho refresh.
    @Published private(set) var duplicatesFoundOnLastRefresh: Int = 0
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    /// Rentabilidad por ticker en el periodo seleccionado en PerformanceView.
    /// Clave: ticker Yahoo · Valor: variación fraccional (0.15 = +15%).
    /// Se actualiza con `fetchPeriodReturns(days:)` — no se rellena en refresh()
    /// para no retrasar la carga inicial.
    @Published private(set) var periodReturns: [String: Double] = [:]
    @Published private(set) var isLoadingPeriodReturns = false
    /// Variación del valor total del portfolio desde el cierre del día anterior
    /// hasta el momento de refresh, en SGD. nil si no hay datos suficientes.
    @Published private(set) var dailyChangeValueSGD: Double? = nil
    /// Variación porcentual respecto al valor de cierre del día anterior. nil si no hay datos.
    @Published private(set) var dailyChangePct: Double? = nil

    /// Moneda de presentación seleccionada por el usuario.
    /// Cambiarla actualiza automáticamente todas las vistas via @EnvironmentObject.
    @Published var displayCurrency: DisplayCurrency = .sgd

    /// Tasa de cambio SGD → EUR (cuántos EUR vale 1 SGD).
    /// Se obtiene de EURSGD=X invirtiendo la tasa: 1 / EURSGD_rate.
    /// Fallback: 1 EUR ≈ 1.45 SGD  →  1 SGD ≈ 0.689 EUR.
    @Published private(set) var sgdToEurRate: Double = 1.0 / 1.45

    // MARK: - Conversión de moneda de presentación

    /// Convierte un valor en SGD a la moneda de presentación activa.
    func toDisplay(_ sgdAmount: Double) -> Double {
        switch displayCurrency {
        case .sgd: return sgdAmount
        case .eur: return sgdAmount * sgdToEurRate
        }
    }

    /// Código ISO de la moneda de presentación activa (para Fmt.money).
    var displayCode: String { displayCurrency.rawValue }


    private let sheets: GoogleSheetsClient

    init(sheets: GoogleSheetsClient) {
        self.sheets = sheets
    }

    /// Recarga transacciones + metadatos desde Sheets, recalcula posiciones,
    /// pide precios/FX/sparklines en vivo a Yahoo, y genera recomendaciones.
    /// Pensado para llamarse al abrir la app y desde un botón "Actualizar"
    /// (no hay caché de servidor aquí — cada llamada pega a las dos APIs).
    func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            async let txsResult = sheets.fetchAllTransactions()
            async let meta = sheets.fetchStockMeta()
            let (txFetched, stockMeta) = try await (txsResult, meta)
            let fetchedTransactions = txFetched.transactions
            self.duplicatesFoundOnLastRefresh = txFetched.duplicatesRemoved
            self.transactions = fetchedTransactions

            let baseHoldings = PortfolioEngine.computeHoldings(transactions: fetchedTransactions, meta: stockMeta)
            let tickers = baseHoldings.compactMap { $0.ticker.isEmpty ? nil : $0.ticker }

            async let fxRates = YahooFinanceClient.fetchFXRates()
            // fetchPricesAndPrevClose descarga la misma serie 5d/1d pero devuelve
            // también el penúltimo cierre (= sesión anterior) sin red extra.
            async let pricesResult = YahooFinanceClient.fetchPricesAndPrevClose(tickers: tickers)
            async let sparks = YahooFinanceClient.fetchSparklines(tickers: tickers)
            async let targets = YahooFinanceClient.fetchAnalystTargets(tickers: tickers)
            // EURSGD=X: cuántos SGD vale 1 EUR → invertimos para tener SGD→EUR
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
                // Igual que `price_use = live or r["cpu"] or 0` en build_portfolio_data:
                if let live = resolvedPrices[h.ticker] {
                    h.livePrice = live
                    h.priceIsLive = true
                } else {
                    h.livePrice = h.cpu ?? 0
                    h.priceIsLive = false
                }
                // Acumular valor de cierre anterior para calcular variación diaria
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

            // Variación diaria: solo si al menos la mitad de posiciones tienen dato prev
            if prevDataCount > 0 && prevValueSGD > 0 {
                let currentSGD = totalsResult.valueSGD
                self.dailyChangeValueSGD = currentSGD - prevValueSGD
                self.dailyChangePct = (currentSGD - prevValueSGD) / prevValueSGD
            } else {
                self.dailyChangeValueSGD = nil
                self.dailyChangePct = nil
            }
        } catch {
            errorMessage = "No se pudieron cargar los datos: \(error.localizedDescription)"
        }
    }

    /// Carga aparte el histórico de patrimonio total (pestaña Rendimiento) —
    /// igual que /api/history es un endpoint separado de /api/portfolio.
    func refreshHistory() async {
        do {
            self.history = try await sheets.fetchPortfolioHistory().sorted { $0.date < $1.date }
        } catch {
            errorMessage = "No se pudo cargar el histórico: \(error.localizedDescription)"
        }
    }

    // MARK: - Rentabilidades por periodo (para Top/Bottom 5 en PerformanceView)

    /// Descarga el histórico de precios de cada posición y calcula la variación
    /// en el periodo `days` (los mismos periodos que el gráfico de rendimiento).
    ///
    /// - Parameter days: número de días de ventana. 9999 = desde el primer dato
    ///   disponible (equivale al botón "Todo").
    ///
    /// Usa el endpoint `v8/finance/chart` con `range=1y` y corta los datos
    /// al periodo pedido — si `days > 365` o days == 9999 pide `range=5y`.
    /// Las peticiones son concurrentes (una por ticker).
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

                    // Decodificado mínimo: solo necesitamos los cierres ajustados
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

                    // Cortar al periodo pedido usando los timestamps
                    let cutoff: [Double]
                    if days >= 9999 {
                        cutoff = closes
                    } else if let ts = r.timestamp {
                        let cutoffEpoch = Date().timeIntervalSince1970 - Double(days) * 86400
                        let paired = zip(ts, closes).filter { Double($0.0) >= cutoffEpoch }.map { $0.1 }
                        cutoff = paired
                    } else {
                        // Sin timestamps: tomar los últimos `days` puntos (aprox)
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

    // MARK: - Histórico Intradía Sintético (1D / 5D)

    /// Calcula un histórico sintético para periodos muy cortos (1 día o 5 días)
    /// obteniendo datos intradiarios de Yahoo Finance (cada 5m o 15m) y sumándolos,
    /// asumiendo que las posiciones y el efectivo actual se han mantenido constantes.
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

        // Agrupar todos los timestamps únicos ordenados
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
                // Avanzar el índice hasta el timestamp actual o el más cercano anterior
                while idx < series.count - 1 && series[idx + 1].ts <= ts {
                    idx += 1
                }
                currentIndexes[ticker] = idx
                // Sumar el valor si el punto es válido para este momento
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

    // MARK: - Agregados (espejo de build_portfolio_data)

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

