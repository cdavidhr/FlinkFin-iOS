import Foundation

/// Swift port of `recommend()` (dashboard_server.py in desktop project).
/// Generates recommendation signals (STRONG BUY / BUY / HOLD / TAKE PROFIT) and
/// factor reasons based on live prices and holding metrics. Kept in sync with
/// desktop scoring. Dynamic reason strings are localized via LanguageManager.shared.
enum RecommendationEngine {

    static func recommend(for holding: Holding) -> Recommendation {
        let lm = LanguageManager.shared
        var score = 0
        var reasons: [String] = []

        guard let price = holding.livePrice, price > 0 else {
            return Recommendation(holdingID: holding.id, signal: .notAvailable, reasons: [])
        }

        // 1. Analyst Target Price & Upside
        if let avgT = holding.avgTarget, avgT > 0 {
            let upside = (avgT - price) / price
            let tstr = String(format: "$%.2f", avgT)
            if upside > 0.25 {
                score += 3
                reasons.append(lm.fmt("reason.upside", pct(upside, signed: true), tstr))
            } else if upside > 0.10 {
                score += 2
                reasons.append(lm.fmt("reason.upside", pct(upside, signed: true), tstr))
            } else if upside > 0 {
                score += 1
                reasons.append(lm.fmt("reason.upside", pct(upside, signed: true), tstr))
            } else if upside < -0.10 {
                score -= 2
                reasons.append(lm.fmt("reason.overvalued", pct(-upside), tstr))
            }
            if let minT = holding.minTarget, let maxT = holding.maxTarget {
                reasons.append(lm.fmt("reason.target_range", String(format: "$%.2f", minT), String(format: "$%.2f", maxT)))
            }
        }

        // 2. Institutional Analyst Consensus
        if let recKey = holding.recommendationKey?.lowercased() {
            if recKey.contains("strong_buy") {
                score += 2
                reasons.append(lm["reason.strong_buy"])
            } else if recKey.contains("buy") {
                score += 1
                reasons.append(lm["reason.buy"])
            } else if recKey.contains("sell") || recKey.contains("underperform") {
                score -= 2
                reasons.append(lm["reason.sell"])
            }
        }

        // 3. Financial Performance and Earnings (EPS)
        if let epsT = holding.epsTrailing, let epsF = holding.epsForward {
            if epsF > epsT && epsF > 0 {
                score += 1
                reasons.append(lm.fmt("reason.eps_growth", String(format: "$%.2f", epsT), String(format: "$%.2f", epsF)))
            } else if epsT < 0 && epsF <= 0 {
                score -= 1
                reasons.append(lm.fmt("reason.eps_loss", String(format: "$%.2f", epsT)))
            }
        }

        // 4. Profitability & Margins (ROE, Profit Margins, Revenue Growth)
        if let roe = holding.returnOnEquity, roe > 0.15 {
            score += 1
            reasons.append(lm.fmt("reason.roe", String(format: "%.1f", roe * 100)))
        }
        if let pm = holding.profitMargins, pm > 0.15 {
            reasons.append(lm.fmt("reason.net_margin", String(format: "%.1f", pm * 100)))
        }
        if let rg = holding.revenueGrowth {
            if rg > 0.10 {
                score += 1
                reasons.append(lm.fmt("reason.rev_growth", String(format: "%+.1f", rg * 100)))
            } else if rg < -0.10 {
                score -= 1
                reasons.append(lm.fmt("reason.rev_decline", String(format: "%.1f", rg * 100)))
            }
        }

        // 5. Financial Health / Solvency (Debt/Equity)
        if let de = holding.debtToEquity {
            if de < 50 {
                reasons.append(lm.fmt("reason.solid_balance", String(format: "%.1f", de)))
            } else if de > 250 {
                score -= 1
                reasons.append(lm.fmt("reason.high_debt", String(format: "%.1f", de)))
            }
        }

        // 6. Position Gain/Loss Performance
        if let urPct = holding.liveGLPct {
            if urPct < -0.25 {
                reasons.append(lm.fmt("reason.position_loss", pct(urPct)))
            } else if urPct > 1.50 {
                reasons.append(lm.fmt("reason.position_big_gain", pct(urPct)))
            } else if urPct > 0.30 {
                reasons.append(lm.fmt("reason.position_gain", pct(urPct)))
            }
        }

        if let cy = holding.currentYield, cy > 0.04 {
            score += 1
            reasons.append(lm.fmt("reason.dividend_yield", String(format: "%.1f", cy * 100)))
        }

        if holding.cost == 0, (holding.liveValueNative ?? 0) > 0 {
            reasons.append(lm["reason.free_shares"])
        }

        if holding.avgTarget == nil {
            if holding.recommendationKey == nil {
                reasons.append(lm["reason.no_coverage"])
            }
            if let urPct = holding.liveGLPct {
                if urPct > 0.10 {
                    score += 1
                }
            }
        }

        let signal: RecommendationSignal
        if score >= 4 { signal = .strongBuy }
        else if score >= 1 { signal = .buy }
        else if score <= -2 { signal = .takeProfit }
        else { signal = .hold }

        return Recommendation(holdingID: holding.id, signal: signal, reasons: reasons)
    }

    private static func pct(_ value: Double, signed: Bool = false) -> String {
        let v = value * 100
        let fmt = signed ? "%+.0f%%" : "%.0f%%"
        return String(format: fmt, v)
    }
}
