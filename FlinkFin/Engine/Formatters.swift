import Foundation

/// Formato de números compartido por las vistas — evita repetir
/// `NumberFormatter`/`String(format:)` en cada View. Los redondeos "de
/// negocio" (los que importan para los cálculos) ya se hacen en
/// PortfolioEngine/RecommendationEngine; esto es solo presentación.
enum Fmt {
    static func money(_ value: Double, currency: String = "SGD") -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 2
        return f.string(from: value as NSNumber) ?? String(format: "%.2f", value)
    }

    static func pct(_ value: Double, signed: Bool = false) -> String {
        String(format: signed ? "%+.1f%%" : "%.1f%%", value * 100)
    }

    static func number(_ value: Double, decimals: Int = 2) -> String {
        String(format: "%.\(decimals)f", value)
    }

    /// Unidades/acciones: sin decimales de sobra si son enteras, hasta 4 si no.
    static func units(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 4
        f.minimumFractionDigits = 0
        return f.string(from: value as NSNumber) ?? String(value)
    }

    static func date(_ isoDate: String) -> String {
        isoDate // ya viene como "yyyy-MM-dd"; formatear con DateFormatter si se quiere localizar
    }

    /// Números grandes en forma compacta: 1 200 000 000 → "1.2B", 450 000 → "450K".
    /// Usado para capitalización de mercado y volumen.
    static func compact(_ value: Double) -> String {
        switch abs(value) {
        case 1_000_000_000_000...: return String(format: "%.1fT", value / 1_000_000_000_000)
        case 1_000_000_000...:     return String(format: "%.1fB", value / 1_000_000_000)
        case 1_000_000...:         return String(format: "%.1fM", value / 1_000_000)
        case 1_000...:             return String(format: "%.1fK", value / 1_000)
        default:                   return String(format: "%.0f", value)
        }
    }

    /// Ratio (P/E, P/B…) con 1 decimal — "n/d" si nil o negativo.
    static func ratio(_ value: Double?) -> String {
        guard let v = value, v > 0 else { return "n/d" }
        return String(format: "%.1f", v)
    }
}
