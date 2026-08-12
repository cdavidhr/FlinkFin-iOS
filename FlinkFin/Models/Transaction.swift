import Foundation

/// Espejo de la tabla `transactions` en `database.py` del proyecto dashboard
/// (FastAPI). Si esa tabla cambia, actualizar este modelo a la vez —
/// ver AGENTS.md del proyecto `dashboard` para el esquema autorizado.
enum TransactionType: String, Codable, CaseIterable {
    case buy = "Buy"
    case sell = "Sell"
    case div = "Div"
}

struct Transaction: Identifiable, Codable, Equatable {
    var id: Int
    var date: String          // "YYYY-MM-DD"
    var type: TransactionType
    var name: String
    var ticker: String?
    var currency: String      // "SGD" | "USD" | "HKD" | "AUD" | ...
    var units: Double
    var price: Double
    var fees: Double
    var remarks: String?
    var source: String        // "manual" | "google_sheets" | "excel" | ...

    /// Clave de agrupación de posiciones — igual que `(name, currency)` en
    /// `compute_holdings()` (database.py).
    var positionKey: String { "\(name)|\(currency)" }
}
