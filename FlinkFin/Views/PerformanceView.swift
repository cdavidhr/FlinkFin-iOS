import SwiftUI
import Charts

/// Pestaña "Rendimiento" — espejo de #tab-performance: gráfico valor vs
/// coste con selector de periodo, estadísticas del periodo visible,
/// y ranking de las 5 posiciones que más han subido / bajado en el periodo.
struct PerformanceView: View {
    @EnvironmentObject private var store: PortfolioStore
    @State private var periodDays: Int = 365

    private static let periods: [(label: String, days: Int)] = [
        ("1D", 1), ("5D", 5), ("1M", 30), ("3M", 90), ("6M", 180), ("1A", 365), ("2A", 730), ("Todo", 9999),
    ]

    private var visiblePoints: [HistoryPoint] {
        if periodDays == 1 || periodDays == 5 {
            return store.intradayHistory
        }
        guard periodDays < 9999,
              let cutoff = Calendar.current.date(byAdding: .day, value: -periodDays, to: Date())
        else { return store.history }
        let cutoffStr = isoString(cutoff)
        return store.history.filter { $0.date >= cutoffStr }
    }

    /// Posiciones ordenadas por rentabilidad en el periodo, con datos disponibles.
    private var rankedHoldings: [(holding: Holding, ret: Double)] {
        store.holdings.compactMap { h in
            guard !h.ticker.isEmpty, let ret = store.periodReturns[h.ticker] else { return nil }
            return (holding: h, ret: ret)
        }
        .sorted { $0.ret > $1.ret }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    chartCard
                    statsRow
                    if !store.holdings.isEmpty {
                        moversSection
                    }
                }
                .padding()
            }
            .navigationTitle("Rendimiento")
            .refreshable {
                await store.refreshHistory()
                await store.fetchPeriodReturns(days: periodDays)
                if periodDays == 1 || periodDays == 5 {
                    await store.fetchIntradayHistory(days: periodDays)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Image("AppLogoSmall")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 84)
                        .accessibilityHidden(true)
                }
            }
            // Al cambiar el periodo recargamos los retornos individuales y el intradía si aplica
            .onChange(of: periodDays) {
                Task {
                    await store.fetchPeriodReturns(days: periodDays)
                    if periodDays == 1 || periodDays == 5 {
                        await store.fetchIntradayHistory(days: periodDays)
                    }
                }
            }
            // Al cargar la vista por primera vez (holdings ya disponibles)
            .task {
                if !store.holdings.isEmpty && store.periodReturns.isEmpty {
                    await store.fetchPeriodReturns(days: periodDays)
                }
                if (periodDays == 1 || periodDays == 5) && store.intradayHistory.isEmpty {
                    await store.fetchIntradayHistory(days: periodDays)
                }
            }
        }
    }

    // MARK: - Gráfico

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Valor del portfolio vs coste").font(.headline)
                Spacer()
            }
            periodPicker
            if visiblePoints.isEmpty {
                ContentUnavailableView("Sin histórico todavía", systemImage: "chart.line.flattrend.xyaxis")
                    .frame(height: 200)
            } else {
                Chart(visiblePoints) { point in
                    LineMark(x: .value("Fecha", point.date), y: .value("Valor", store.toDisplay(point.value)))
                        .foregroundStyle(by: .value("Serie", "Valor"))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Fecha", point.date), y: .value("Coste", store.toDisplay(point.cost)))
                        .foregroundStyle(by: .value("Serie", "Coste"))
                        .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden)
                .frame(height: 220)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(.thinMaterial))
    }

    private var periodPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(Self.periods, id: \.days) { period in
                    Button(period.label) { periodDays = period.days }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(periodDays == period.days ? Color.accentColor : Color.secondary.opacity(0.15)))
                        .foregroundStyle(periodDays == period.days ? Color(uiColor: .systemBackground) : .primary)
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(periodDays == period.days ? .isSelected : [])
                }
            }
        }
    }

    // MARK: - Estadísticas del periodo

    @ViewBuilder
    private var statsRow: some View {
        if let first = visiblePoints.first, let last = visiblePoints.last, first.value > 0 {
            let change = last.value - first.value
            let changePct = change / first.value
            HStack(spacing: 12) {
                statCard("Inicio periodo", Fmt.money(store.toDisplay(first.value), currency: store.displayCode))
                statCard("Actual",         Fmt.money(store.toDisplay(last.value),  currency: store.displayCode))
                statCard("Variación",
                    "\(Fmt.money(store.toDisplay(change), currency: store.displayCode)) (\(Fmt.pct(changePct, signed: true)))")
            }
        }
    }

    // MARK: - Top 5 / Bottom 5

    private var moversSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Cabecera de sección
            HStack {
                Text("Mejores y peores del periodo")
                    .font(.headline)
                Spacer()
                if store.isLoadingPeriodReturns {
                    ProgressView().controlSize(.small)
                }
            }

            if store.periodReturns.isEmpty && !store.isLoadingPeriodReturns {
                Text("Desliza hacia abajo para cargar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !rankedHoldings.isEmpty {
                let top    = Array(rankedHoldings.prefix(5))
                let bottom = Array(rankedHoldings.suffix(5).reversed())

                HStack(alignment: .top, spacing: 12) {
                    // Top 5 — mayores subidas
                    moverCard(
                        title: "↑ Top 5",
                        color: .green,
                        icon: "arrow.up.circle.fill",
                        items: top
                    )
                    // Bottom 5 — mayores caídas
                    moverCard(
                        title: "↓ Bottom 5",
                        color: .red,
                        icon: "arrow.down.circle.fill",
                        items: bottom
                    )
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(.thinMaterial))
    }

    private func moverCard(
        title: String,
        color: Color,
        icon: String,
        items: [(holding: Holding, ret: Double)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)

            ForEach(items, id: \.holding.id) { item in
                moverRow(item.holding, ret: item.ret, color: color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func moverRow(_ h: Holding, ret: Double, color: Color) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(h.ticker)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                Text(h.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(Fmt.pct(ret, signed: true))
                .font(.caption.weight(.semibold))
                .foregroundStyle(ret >= 0 ? Color.green : Color.red)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private func statCard(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.footnote.weight(.semibold))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.thinMaterial))
    }

    private func isoString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}

#Preview {
    PerformanceView().environmentObject(PortfolioStore(sheets: GoogleSheetsClient(config: .preview)))
}
