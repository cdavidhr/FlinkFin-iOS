import Foundation

/// Port directo de `recommend()` (dashboard_server.py, proyecto `dashboard`).
/// Genera una señal (STRONG BUY / BUY / HOLD / TAKE PROFIT) y las razones en
/// texto, a partir del precio en vivo y los datos de la posición. Mantener
/// en sync con el original si cambia el scoring — documentar en
/// CHANGELOG.md cuál de los dos lados se editó primero.
enum RecommendationEngine {

    static func recommend(for holding: Holding) -> Recommendation {
        var score = 0
        var reasons: [String] = []

        guard let price = holding.livePrice, price > 0 else {
            return Recommendation(holdingID: holding.id, signal: .notAvailable, reasons: [])
        }

        if let avgT = holding.avgTarget, avgT > 0 {
            let upside = (avgT - price) / price
            let tstr = String(format: "$%.2f", avgT)
            if upside > 0.25 {
                score += 3
                reasons.append("📈 \(pct(upside, signed: true)) upside hasta objetivo analistas (\(tstr))")
            } else if upside > 0.10 {
                score += 2
                reasons.append("📈 \(pct(upside, signed: true)) upside hasta objetivo analistas (\(tstr))")
            } else if upside > 0 {
                score += 1
                reasons.append("📈 \(pct(upside, signed: true)) upside hasta objetivo analistas (\(tstr))")
            } else if upside < -0.10 {
                score -= 2
                reasons.append("⚠️ Cotización \(pct(-upside)) por encima del objetivo analistas (\(tstr))")
            }
            if let minT = holding.minTarget, let maxT = holding.maxTarget {
                reasons.append(String(format: "🎯 Rango consenso: $%.2f – $%.2f", minT, maxT))
            }
        }

        // 2. Consenso Institucional de Analistas
        if let recKey = holding.recommendationKey?.lowercased() {
            if recKey.contains("strong_buy") {
                score += 2
                reasons.append("⭐ Consenso analistas: Strong Buy")
            } else if recKey.contains("buy") {
                score += 1
                reasons.append("⭐ Consenso analistas: Buy")
            } else if recKey.contains("sell") || recKey.contains("underperform") {
                score -= 2
                reasons.append("⚠️ Consenso analistas: Venta / Infraponderar")
            }
        }

        // 3. Resultados Financieros y Beneficios (EPS)
        if let epsT = holding.epsTrailing, let epsF = holding.epsForward {
            if epsF > epsT && epsF > 0 {
                score += 1
                reasons.append(String(format: "💡 Crecimiento esperado de beneficio (EPS: $%.2f ➔ $%.2f)", epsT, epsF))
            } else if epsT < 0 && epsF <= 0 {
                score -= 1
                reasons.append(String(format: "⚠️ Empresa en pérdidas (EPS: $%.2f)", epsT))
            }
        }

        // 4. Rentabilidad y Márgenes (ROE, Profit Margins, Revenue Growth)
        if let roe = holding.returnOnEquity, roe > 0.15 {
            score += 1
            reasons.append(String(format: "📊 Alta rentabilidad sobre capital (ROE: %.1f%%)", roe * 100))
        }
        if let pm = holding.profitMargins, pm > 0.15 {
            reasons.append(String(format: "💵 Margen neto saludable (%.1f%%)", pm * 100))
        }
        if let rg = holding.revenueGrowth {
            if rg > 0.10 {
                score += 1
                reasons.append(String(format: "🚀 Crecimiento de ingresos del %+.1f%%", rg * 100))
            } else if rg < -0.10 {
                score -= 1
                reasons.append(String(format: "📉 Caída de ingresos del %.1f%%", rg * 100))
            }
        }

        // 5. Salud Financiera / Solvencia (Deuda/Equity)
        if let de = holding.debtToEquity {
            if de < 50 {
                reasons.append(String(format: "🛡️ Balance sólido (Deuda/Capital: %.1f%%)", de))
            } else if de > 250 {
                score -= 1
                reasons.append(String(format: "⚠️ Alto endeudamiento (Deuda/Capital: %.1f%%)", de))
            }
        }

        // 6. Rendimiento de la Posición (Informativo, no altera la puntuación de valoración de mercado)
        if let urPct = holding.liveGLPct {
            if urPct < -0.25 {
                reasons.append("📉 Pérdida latente del \(pct(urPct)) en tu posición")
            } else if urPct > 1.50 {
                reasons.append("🏆 Ganancia latente del \(pct(urPct)) en tu posición")
            } else if urPct > 0.30 {
                reasons.append("✅ Posición en verde, +\(pct(urPct))")
            }
        }

        if let cy = holding.currentYield, cy > 0.04 {
            score += 1
            reasons.append("💰 Dividend yield: \(String(format: "%.1f%%", cy * 100))")
        }

        if holding.cost == 0, (holding.liveValueNative ?? 0) > 0 {
            reasons.append("🎁 Recibidas sin coste — ganancia íntegra")
        }

        if holding.avgTarget == nil {
            if holding.recommendationKey == nil {
                reasons.append("ℹ️ Sin cobertura de precio objetivo por analistas")
            }
            // Evaluación para ETFs y activos sin precio objetivo de Wall Street
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
