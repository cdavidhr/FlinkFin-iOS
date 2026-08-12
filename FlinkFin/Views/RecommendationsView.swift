import SwiftUI

/// Pestaña "Recomendaciones" — vista enriquecida con tarjetas de KPI,
/// filtros interactivos por señal, rango de objetivos de analistas y
/// desglose visual de razones por posición.
struct RecommendationsView: View {
    @EnvironmentObject private var store: PortfolioStore
    @State private var selectedSignalFilter: RecommendationSignal? = nil

    private static let signalsOrder: [RecommendationSignal] = [.strongBuy, .buy, .hold, .takeProfit]

    private var groupedHoldings: [RecommendationSignal: [Holding]] {
        Dictionary(grouping: store.holdings) { store.recommendations[$0.id]?.signal ?? .notAvailable }
    }

    private var filteredHoldings: [Holding] {
        if let filter = selectedSignalFilter {
            return groupedHoldings[filter] ?? []
        } else {
            // Devuelve todas las posiciones ordenadas por prioridad de señal
            return store.holdings.sorted { h1, h2 in
                let s1 = store.recommendations[h1.id]?.signal ?? .notAvailable
                let s2 = store.recommendations[h2.id]?.signal ?? .notAvailable
                return signalPriority(s1) < signalPriority(s2)
            }
        }
    }

    private func signalPriority(_ signal: RecommendationSignal) -> Int {
        switch signal {
        case .strongBuy: return 0
        case .buy: return 1
        case .takeProfit: return 2
        case .hold: return 3
        case .notAvailable: return 4
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    overviewKPISection

                    if filteredHoldings.isEmpty {
                        ContentUnavailableView(
                            "Sin recomendaciones",
                            systemImage: "line.3.horizontal.decrease.circle",
                            description: Text("No hay posiciones con la señal seleccionada.")
                        )
                        .frame(height: 220)
                    } else {
                        VStack(spacing: 14) {
                            ForEach(filteredHoldings) { holding in
                                RecommendationCard(
                                    holding: holding,
                                    recommendation: store.recommendations[holding.id]
                                )
                            }
                        }
                    }

                    disclaimerFooter
                }
                .padding()
            }
            .navigationTitle("Recomendaciones")
            .refreshable { await store.refresh() }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Image("AppLogoSmall")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 84)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    // MARK: - Tarjetas resumen superior (Filtros)

    private var overviewKPISection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Resumen de Señales")
                .font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    // Botón "Todas"
                    filterChip(
                        title: "Todas",
                        count: store.holdings.count,
                        isSelected: selectedSignalFilter == nil,
                        color: .primary
                    ) {
                        withAnimation(.spring(response: 0.3)) {
                            selectedSignalFilter = nil
                        }
                    }

                    ForEach(Self.signalsOrder, id: \.self) { signal in
                        let count = (groupedHoldings[signal] ?? []).count
                        filterChip(
                            title: signal.rawValue,
                            count: count,
                            isSelected: selectedSignalFilter == signal,
                            color: signalColor(signal)
                        ) {
                            withAnimation(.spring(response: 0.3)) {
                                selectedSignalFilter = (selectedSignalFilter == signal) ? nil : signal
                            }
                        }
                    }
                }
            }
        }
    }

    private func filterChip(title: String, count: Int, isSelected: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(isSelected ? Color.white.opacity(0.3) : color.opacity(0.15)))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? color : Color(uiColor: .secondarySystemGroupedBackground))
            )
            .foregroundStyle(isSelected ? .white : .primary)
            .shadow(color: isSelected ? color.opacity(0.3) : .clear, radius: 4, y: 2)
        }
        .buttonStyle(.plain)
    }

    private func signalColor(_ signal: RecommendationSignal) -> Color {
        switch signal {
        case .strongBuy: return .green
        case .buy: return .mint
        case .hold: return .blue
        case .takeProfit: return .orange
        case .notAvailable: return .secondary
        }
    }

    private var disclaimerFooter: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.secondary)
                .font(.subheadline)
            Text("Análisis automatizado basado en precios objetivo de analistas, rentabilidad latente de tu posición, dividendo y métricas de salud financiera. **No constituye asesoramiento financiero.**")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
    }
}

// MARK: - Tarjeta de Recomendación por Posición

private struct RecommendationCard: View {
    @EnvironmentObject private var store: PortfolioStore
    let holding: Holding
    let recommendation: Recommendation?

    private var signal: RecommendationSignal {
        recommendation?.signal ?? .notAvailable
    }

    private var upsidePct: Double? {
        guard let price = holding.livePrice, price > 0, let avgT = holding.avgTarget, avgT > 0 else { return nil }
        return (avgT - price) / price
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Encabezado
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if !holding.ticker.isEmpty {
                            Text(holding.ticker)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                .foregroundStyle(Color.accentColor)
                        }
                        Text(holding.name)
                            .font(.headline)
                            .lineLimit(1)
                    }
                    Text(holding.category)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                SignalBadge(signal: signal)
            }

            Divider()

            // Métricas Clave
            HStack(spacing: 16) {
                // Precio Actual & Rendimiento
                VStack(alignment: .leading, spacing: 2) {
                    Text("Precio actual")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 4) {
                        if let price = holding.livePrice {
                            Text(Fmt.money(price, currency: holding.currency))
                                .font(.subheadline.weight(.semibold))
                        } else {
                            Text("n/d")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        if let glPct = holding.liveGLPct {
                            Text(Fmt.pct(glPct, signed: true))
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(glPct >= 0 ? .green : .red)
                        }
                    }
                }

                Spacer()

                // Precio Objetivo de Analistas
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Objetivo Analistas")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if let avgT = holding.avgTarget {
                        HStack(spacing: 4) {
                            Text(Fmt.money(avgT, currency: holding.currency))
                                .font(.subheadline.weight(.semibold))

                            if let up = upsidePct {
                                Text(Fmt.pct(up, signed: true))
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill((up >= 0 ? Color.green : Color.red).opacity(0.15)))
                                    .foregroundStyle(up >= 0 ? .green : .red)
                            }
                        }
                    } else {
                        Text("Sin objetivo")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Rango de Precio Objetivo (si está disponible)
            if let minT = holding.minTarget, let maxT = holding.maxTarget, let price = holding.livePrice, maxT > minT {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Min: \(Fmt.money(minT, currency: holding.currency))")
                        Spacer()
                        Text("Max: \(Fmt.money(maxT, currency: holding.currency))")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                    GeometryReader { geo in
                        let totalRange = maxT - minT
                        let clampedPrice = min(max(price, minT), maxT)
                        let progress = (clampedPrice - minT) / totalRange
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.secondary.opacity(0.2))
                                .frame(height: 4)
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 8, height: 8)
                                .offset(x: CGFloat(progress) * (geo.size.width - 8))
                        }
                    }
                    .frame(height: 8)
                }
            }

            // Razones / Factores
            if let reasons = recommendation?.reasons, !reasons.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Factores clave:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)

                    ForEach(reasons, id: \.self) { reason in
                        HStack(alignment: .top, spacing: 8) {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
                    }
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
        )
    }
}

#Preview {
    RecommendationsView().environmentObject(PortfolioStore(sheets: GoogleSheetsClient(config: .preview)))
}
