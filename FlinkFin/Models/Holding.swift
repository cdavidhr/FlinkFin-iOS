import Foundation

/// Espejo del dict que devuelve `compute_holdings()` en database.py, más los
/// campos "en vivo" que añade `build_portfolio_data()` en dashboard_server.py
/// (precio actual, valor en SGD, sparkline...).
struct Holding: Identifiable, Codable, Equatable {
    // ── Derivado del libro de transacciones (estático, sin red) ──────────
    var name: String
    var currency: String
    var ticker: String
    var category: String
    var units: Double
    var cost: Double            // coste total en la divisa nativa
    var cpu: Double?            // coste medio por unidad
    var realizedGL: Double
    var dividends: Double
    var dividendsTTM: Double
    var avgTarget: Double?      // precio objetivo medio analistas
    var minTarget: Double?
    var maxTarget: Double?
    var firstDate: String
    var lastDate: String

    // ── Datos en vivo (rellenados tras llamar a YahooFinanceClient) ──────
    var livePrice: Double?
    var fxRate: Double?         // divisa nativa -> SGD
    var sparkline: [Double]?
    /// `false` cuando Yahoo no devolvió precio para este ticker y `livePrice`
    /// es en realidad el coste medio (`cpu`) usado como respaldo — ver
    /// `PortfolioStore.refresh()`. Permite avisar en la UI en vez de fallar
    /// en silencio.
    var priceIsLive: Bool = true

    // ── Datos fundamentales (para recomendación y detalle) ──────────────
    var recommendationKey: String? = nil
    var epsTrailing: Double? = nil
    var epsForward: Double? = nil
    var returnOnEquity: Double? = nil
    var profitMargins: Double? = nil
    var revenueGrowth: Double? = nil
    var debtToEquity: Double? = nil

    var id: String { "\(name)|\(currency)" }

    var costSGD: Double { cost * (fxRate ?? 1) }

    var liveValueNative: Double? {
        guard let p = livePrice else { return nil }
        return units * p
    }

    var liveValueSGD: Double? {
        guard let v = liveValueNative, let fx = fxRate else { return nil }
        return v * fx
    }

    var liveGLSGD: Double? {
        guard let v = liveValueSGD else { return nil }
        return v - costSGD
    }

    var liveGLPct: Double? {
        guard let gl = liveGLSGD, costSGD > 1e-9 else { return nil }
        return gl / costSGD
    }

    var currentYield: Double? {
        guard let v = liveValueNative, v > 0 else { return nil }
        return dividendsTTM / v
    }
}

/// Totales agregados — equivalente a `totals` en la respuesta de
/// `/api/portfolio`. `valueSGD` es SIEMPRE solo-acciones (sin efectivo ni
/// activos externos) — ver AGENTS.md § Decisiones.
struct PortfolioTotals: Codable, Equatable {
    var valueSGD: Double
    var costSGD: Double
    var glSGD: Double
    var glPct: Double
}

struct CurrencyBreakdown: Codable, Equatable {
    var currency: String
    var value: Double
    var cost: Double
    var gl: Double
    var count: Int
    var fxRate: Double
}
