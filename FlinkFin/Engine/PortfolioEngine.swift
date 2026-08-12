import Foundation

/// Port directo de `compute_holdings()` (database.py, proyecto `dashboard`).
/// Recorre el log de transacciones en orden cronológico y deriva, por cada
/// valor (nombre + divisa), unidades, coste medio ponderado, ganancias
/// realizadas y dividendos (con corte TTM a 12 meses) — el mismo enfoque que
/// usa el backend Python. Si cambias la lógica aquí, cámbiala también allí
/// (o viceversa) para no divergir; documentar en CHANGELOG.md.
enum PortfolioEngine {

    /// Posición intermedia mientras se reproduce el ledger.
    private struct WorkingPosition {
        var name: String
        var currency: String
        var ticker: String?
        var units: Double = 0
        var cost: Double = 0
        var realizedGL: Double = 0
        var dividends: Double = 0
        var dividendsTTM: Double = 0
        var firstDate: String
        var lastDate: String
    }

    /// - Parameters:
    ///   - transactions: TODAS las transacciones (no es necesario que vengan
    ///     pre-ordenadas; se ordenan aquí por fecha y luego por id, igual que
    ///     `ORDER BY date ASC, id ASC` en SQL).
    ///   - meta: metadatos por posición (categoría, precios objetivo) — keyed
    ///     por `"\(name)|\(currency)"`, espejo de `stock_meta`.
    ///   - asOf: solo afecta el corte TTM de dividendos (12 meses hacia atrás
    ///     desde esta fecha), igual que `today` en `compute_holdings()`
    ///     (database.py). **No filtra transacciones por fecha** — ni aquí ni
    ///     en el Python se excluyen filas con fecha futura; `compute_holdings()`
    ///     suma TODO lo que hay en la tabla/hoja sin importar la fecha. Antes
    ///     esta función sí excluía transacciones posteriores a `asOf`, lo que
    ///     causó una posición (PLTR) con 40 unidades menos que la web cuando
    ///     el usuario tenía una compra fechada en el futuro — corregido
    ///     2026-06-25, ver CHANGELOG.md.
    static func computeHoldings(
        transactions: [Transaction],
        meta: [String: StockMeta] = [:],
        asOf: Date = Date()
    ) -> [Holding] {
        let sorted = transactions.sorted { a, b in
            if a.date != b.date { return a.date < b.date }
            return a.id < b.id
        }

        let cal = Calendar(identifier: .gregorian)
        let ttmCutDate = cal.date(byAdding: .year, value: -1, to: asOf) ?? asOf
        let ttmCut = Self.dateString(ttmCutDate)

        var pos: [String: WorkingPosition] = [:]

        for tx in sorted {
            // Sin filtro de fecha aquí — ver doc del método arriba.
            let key = tx.positionKey
            var p = pos[key] ?? WorkingPosition(
                name: tx.name, currency: tx.currency, ticker: tx.ticker,
                firstDate: tx.date, lastDate: tx.date
            )
            if let t = tx.ticker, p.ticker == nil { p.ticker = t }
            p.lastDate = tx.date

            switch tx.type {
            case .buy:
                p.units += tx.units
                p.cost += tx.units * tx.price + tx.fees
            case .sell:
                let sellUnits = p.units > 0 ? min(tx.units, p.units) : 0
                if sellUnits > 0 {
                    let avgCost = p.cost / p.units
                    let costRemoved = avgCost * sellUnits
                    let proceeds = sellUnits * tx.price - tx.fees
                    p.realizedGL += proceeds - costRemoved
                    p.units -= sellUnits
                    p.cost -= costRemoved
                }
            case .div:
                let amount = tx.units * tx.price - tx.fees
                p.dividends += amount
                if tx.date >= ttmCut {
                    p.dividendsTTM += amount
                }
            }
            pos[key] = p
        }

        var out: [Holding] = []
        for (key, p) in pos {
            // Umbral igual que `compute_holdings()` en Python (database.py):
            // `if p["units"] < 0.1: continue`. Filtra posiciones casi cerradas
            // con unidades residuales de redondeo que Python también descarta.
            // El umbral anterior (1e-9) era demasiado permisivo e incluía esas
            // posiciones en el total, causando discrepancia con la web.
            guard p.units >= 0.1 else { continue }
            let m = meta[key]
            let cpu = p.units > 0 ? p.cost / p.units : nil
            out.append(Holding(
                name: p.name,
                currency: p.currency,
                ticker: p.ticker ?? m?.ticker ?? "",
                category: m?.category ?? "Other",
                units: (p.units * 1e6).rounded() / 1e6,
                cost: (p.cost * 100).rounded() / 100,
                cpu: cpu.map { ($0 * 1e6).rounded() / 1e6 },
                realizedGL: (p.realizedGL * 100).rounded() / 100,
                dividends: (p.dividends * 100).rounded() / 100,
                dividendsTTM: (p.dividendsTTM * 100).rounded() / 100,
                avgTarget: m?.avgTarget,
                minTarget: m?.minTarget,
                maxTarget: m?.maxTarget,
                firstDate: p.firstDate,
                lastDate: p.lastDate,
                livePrice: nil,
                fxRate: nil,
                sparkline: nil,
                recommendationKey: nil,
                epsTrailing: nil,
                epsForward: nil,
                returnOnEquity: nil,
                profitMargins: nil,
                revenueGrowth: nil,
                debtToEquity: nil
            ))
        }
        return out
    }

    private static func dateString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }
}

/// Espejo de la tabla `stock_meta` (database.py).
struct StockMeta: Codable {
    var ticker: String?
    var category: String?
    var avgTarget: Double?
    var minTarget: Double?
    var maxTarget: Double?
}
