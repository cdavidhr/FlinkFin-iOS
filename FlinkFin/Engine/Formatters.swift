import Foundation

/// Number formatting shared across views — avoids repeating `NumberFormatter`
/// or `String(format:)` in each View. Business logic rounding is done in
/// PortfolioEngine/RecommendationEngine; this is strictly for presentation.
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

    /// Share/unit quantities: no extra decimals if integer, up to 4 if fractional.
    static func units(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 4
        f.minimumFractionDigits = 0
        return f.string(from: value as NSNumber) ?? String(value)
    }

    static func date(_ isoDate: String) -> String {
        isoDate // formatted as "yyyy-MM-dd"
    }

    /// Compact large numbers: 1 200 000 000 → "1.2B", 450 000 → "450K".
    /// Used for market cap and volume.
    static func compact(_ value: Double) -> String {
        switch abs(value) {
        case 1_000_000_000_000...: return String(format: "%.1fT", value / 1_000_000_000_000)
        case 1_000_000_000...:     return String(format: "%.1fB", value / 1_000_000_000)
        case 1_000_000...:         return String(format: "%.1fM", value / 1_000_000)
        case 1_000...:             return String(format: "%.1fK", value / 1_000)
        default:                   return String(format: "%.0f", value)
        }
    }

    /// Ratio (P/E, P/B…) with 1 decimal — "N/A" if nil or non-positive.
    static func ratio(_ value: Double?) -> String {
        guard let v = value, v > 0 else { return "N/A" }
        return String(format: "%.1f", v)
    }
}
