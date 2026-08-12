import Foundation

/// Direct Swift port of `compute_holdings()` (database.py, desktop dashboard).
/// Replays the transaction ledger chronologically and calculates, per holding
/// (name + currency), units, weighted average cost, realized G/L, and dividends
/// (with 12-month TTM windowing) — matching the Python backend logic.
enum PortfolioEngine {

    /// Intermediate position state while replaying the ledger.
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
    ///   - transactions: ALL transactions (they are sorted here by date and id,
    ///     matching `ORDER BY date ASC, id ASC` in SQL).
    ///   - meta: Metadata per position (category, target prices) keyed by `"\(name)|\(currency)"`.
    ///   - asOf: Only affects TTM dividend cutoff (12 months backward from this date),
    ///     matching `today` in `compute_holdings()` (database.py). Does NOT filter transactions by date.
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
                lastDate: p.lastDate
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

/// Mirror of `stock_meta` table (database.py).
struct StockMeta: Codable {
    var ticker: String?
    var category: String?
    var avgTarget: Double?
    var minTarget: Double?
    var maxTarget: Double?
}
