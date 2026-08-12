import Foundation

/// Mirror of the dict returned by `compute_holdings()` in database.py, plus live
/// fields added by `build_portfolio_data()` in dashboard_server.py.
struct Holding: Identifiable, Codable, Equatable {
    var name: String
    var currency: String
    var ticker: String
    var category: String
    var units: Double
    var cost: Double
    var cpu: Double?
    var realizedGL: Double
    var dividends: Double
    var dividendsTTM: Double
    var avgTarget: Double?
    var minTarget: Double?
    var maxTarget: Double?
    var firstDate: String
    var lastDate: String

    var livePrice: Double?
    var fxRate: Double?
    var sparkline: [Double]?
    var priceIsLive: Bool = true

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
