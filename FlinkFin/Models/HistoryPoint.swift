import Foundation

/// A row from the "Portfolio History" sheet — mirror of `parse_history()` in
/// dashboard_server.py. Note: this value represents total net worth (stocks +
/// cash + external assets), NOT the same figure as `PortfolioTotals.valueSGD`.
struct HistoryPoint: Identifiable, Codable, Equatable {
    var date: String   // "YYYY-MM-DD"
    var cost: Double
    var value: Double
    var unrealizedGL: Double
    var realizedGL: Double
    var dividends: Double

    var id: String { date }
}

/// Recommendation signal — mirror of `recommend()` in dashboard_server.py.
enum RecommendationSignal: String, Codable {
    case strongBuy = "STRONG BUY"
    case buy = "BUY"
    case hold = "HOLD"
    case takeProfit = "TAKE PROFIT"
    case notAvailable = "N/A"
}

struct Recommendation: Identifiable, Codable, Equatable {
    var holdingID: String
    var signal: RecommendationSignal
    var reasons: [String]

    var id: String { holdingID }
}
