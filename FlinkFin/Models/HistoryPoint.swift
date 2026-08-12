import Foundation

/// Un punto de la hoja "Portfolio History" del Google Sheet — espejo de
/// `parse_history()` en dashboard_server.py. Recuerda: este valor es
/// patrimonio total (acciones + efectivo + activos externos), NO el mismo
/// número que `PortfolioTotals.valueSGD`. Mismo trade-off ya aceptado en el
/// dashboard web (ver AGENTS.md del proyecto `dashboard`).
struct HistoryPoint: Identifiable, Codable, Equatable {
    var date: String   // "YYYY-MM-DD"
    var cost: Double
    var value: Double
    var unrealizedGL: Double
    var realizedGL: Double
    var dividends: Double

    var id: String { date }
}

/// Señal de recomendación — espejo de `recommend()` en dashboard_server.py.
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
