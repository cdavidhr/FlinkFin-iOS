import SwiftUI
import Charts

/// Pestaña "Posiciones" — lista de posiciones con tarjeta expandible al tap.
/// Al expandirse, carga datos fundamentales de Yahoo Finance (quoteSummary)
/// de forma diferida y los almacena en caché durante la sesión.
struct HoldingsView: View {
    @EnvironmentObject private var store: PortfolioStore
    @State private var currencyFilter: String = "all"
    @State private var sortOption: SortOption = .value
    /// Caché de datos fundamentales por ticker — se rellena bajo demanda.
    @State private var quoteCache: [String: StockQuote] = [:]

    enum SortOption: String, CaseIterable, Identifiable {
        case value = "Por valor (SGD)"
        case glPct = "Por G/L %"
        case name = "Por nombre"
        var id: String { rawValue }
    }

    private var currencies: [String] {
        Array(Set(store.holdings.map(\.currency))).sorted()
    }

    private var filtered: [Holding] {
        var list = store.holdings
        if currencyFilter != "all" {
            list = list.filter { $0.currency == currencyFilter }
        }
        switch sortOption {
        case .value: list.sort { ($0.liveValueSGD ?? 0) > ($1.liveValueSGD ?? 0) }
        case .glPct: list.sort { ($0.liveGLPct ?? 0) > ($1.liveGLPct ?? 0) }
        case .name:  list.sort { $0.name < $1.name }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                List(filtered) { holding in
                    HoldingCard(
                        holding: holding,
                        recommendation: store.recommendations[holding.id],
                        cachedQuote: quoteCache[holding.ticker],
                        onQuoteLoaded: { quote in
                            quoteCache[holding.ticker] = quote
                        }
                    )
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .background(Color(uiColor: .systemGroupedBackground))
                .overlay {
                    if store.holdings.isEmpty && !store.isLoading {
                        ContentUnavailableView(
                            "Sin posiciones",
                            systemImage: "briefcase",
                            description: Text("Actualiza desde la pestaña Resumen para cargar el portfolio.")
                        )
                    }
                }
            }
            .navigationTitle("Posiciones")
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

    private var filterBar: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    filterChip("Todas", isSelected: currencyFilter == "all") { currencyFilter = "all" }
                    ForEach(currencies, id: \.self) { ccy in
                        filterChip(ccy, isSelected: currencyFilter == ccy) { currencyFilter = ccy }
                    }
                }
                .padding(.horizontal)
            }
            Picker("Ordenar", selection: $sortOption) {
                ForEach(SortOption.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }

    private func filterChip(_ label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.15)))
                .foregroundStyle(isSelected ? Color(uiColor: .systemBackground) : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Tarjeta expandible

private struct HoldingCard: View {
    let holding: Holding
    let recommendation: Recommendation?
    let cachedQuote: StockQuote?
    let onQuoteLoaded: (StockQuote) -> Void

    @State private var isExpanded = false
    @State private var isLoadingQuote = false
    @State private var quoteFailed = false
    @State private var quoteErrorDescription: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
                if isExpanded && cachedQuote == nil && !holding.ticker.isEmpty {
                    Task { await loadQuote() }
                }
            } label: {
                HoldingRowContent(holding: holding, recommendation: recommendation, isExpanded: isExpanded)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider().padding(.horizontal, 4)
                HoldingDetailPanel(
                    holding: holding,
                    quote: cachedQuote,
                    isLoading: isLoadingQuote,
                    failed: quoteFailed,
                    errorDescription: quoteErrorDescription
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(isExpanded ? 0.08 : 0.04),
                        radius: isExpanded ? 8 : 4, x: 0, y: 2)
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
    }

    private func loadQuote() async {
        isLoadingQuote = true
        quoteFailed = false
        quoteErrorDescription = nil
        do {
            let q = try await YahooFinanceClient.fetchQuoteDetail(ticker: holding.ticker)
            onQuoteLoaded(q)
        } catch {
            quoteFailed = true
            quoteErrorDescription = error.localizedDescription
        }
        isLoadingQuote = false
    }
}

// MARK: - Contenido de la fila principal

private struct HoldingRowContent: View {
    @EnvironmentObject private var store: PortfolioStore
    let holding: Holding
    let recommendation: Recommendation?
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(holding.name).font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                Text("\(holding.ticker) · \(holding.currency)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text("\(Fmt.units(holding.units)) ud · \(Fmt.money(holding.livePrice ?? holding.cpu ?? 0, currency: holding.currency))/ud")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if holding.priceIsLive == false {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .imageScale(.small)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Precio estimado, no en vivo")
                    }
                }
                if let signal = recommendation?.signal, signal != .notAvailable {
                    SignalBadge(signal: signal)
                }
            }

            VStack(alignment: .trailing, spacing: 6) {
                if let sparkline = holding.sparkline, sparkline.count >= 2 {
                    MiniLineChart(values: sparkline, color: (holding.liveGLSGD ?? 0) >= 0 ? .green : .red)
                        .frame(width: 70, height: 32)
                }
                // Valor de mercado en la moneda de presentación seleccionada
                Text(Fmt.money(store.toDisplay(holding.liveValueSGD ?? 0), currency: store.displayCode))
                    .font(.subheadline.weight(.semibold))
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.2), value: store.displayCurrency)
                if let glp = holding.liveGLPct {
                    Text(Fmt.pct(glp, signed: true))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(glp >= 0 ? .green : .red)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Panel de detalle expandido

private struct HoldingDetailPanel: View {
    @EnvironmentObject private var store: PortfolioStore
    let holding: Holding
    let quote: StockQuote?
    let isLoading: Bool
    let failed: Bool
    var errorDescription: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView("Cargando datos de mercado…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.top, 12)
            } else if failed || (quote == nil && holding.ticker.isEmpty) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        holding.ticker.isEmpty
                            ? "Sin ticker — no hay datos de mercado disponibles."
                            : "No se pudieron cargar datos de Yahoo Finance.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let desc = errorDescription {
                        Text(desc)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 20)
                    }
                }
                .padding(.top, 8)
            } else if let q = quote {
                marketDataSection(q)
            }

            myPositionSection
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private func marketDataSection(_ q: StockQuote) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Datos de mercado", systemImage: "chart.bar.xaxis")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            // Solo mostrar las celdas que tienen dato real — evitar rejilla llena de "n/d"
            let stats: [(String, String)] = [
                q.trailingPE  .map { ("P/E (TTM)", Fmt.ratio($0)) },
                q.forwardPE   .map { ("P/E (FWD)", Fmt.ratio($0)) },
                q.beta        .map { ("Beta",      String(format: "%.2f", $0)) },
                q.trailingEps .map { ("EPS",       Fmt.money($0, currency: holding.currency)) },
                q.priceToBook .map { ("P/Book",    Fmt.ratio($0)) },
                q.dividendYield.map { ("Div. yield", Fmt.pct($0)) },
                q.grossMargins .map { ("Mg. bruto",  Fmt.pct($0)) },
                q.profitMargins.map { ("Mg. neto",   Fmt.pct($0)) },
                q.roe          .map { ("ROE",         Fmt.pct($0)) },
                q.volume       .map { ("Volumen",     Fmt.compact($0)) },
                q.marketCap    .map { ("Cap. mercado", Fmt.compact($0)) },
            ].compactMap { $0 }

            if !stats.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 8
                ) {
                    ForEach(stats, id: \.0) { item in
                        miniStatCell(item.0, item.1)
                    }
                }
            }

            // Barra de rango 52 semanas — siempre visible si hay dato
            if let low = q.fiftyTwoWeekLow, let high = q.fiftyTwoWeekHigh, high > low {
                rangeBar(low: low, high: high, current: holding.livePrice, currency: holding.currency)
            }
        }
    }

    private func rangeBar(low: Double, high: Double, current: Double?, currency: String) -> some View {
        let fraction = current.map { min(max(($0 - low) / (high - low), 0), 1) }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Rango 52 semanas").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if let c = current {
                    Text(Fmt.money(c, currency: currency))
                        .font(.caption2.weight(.medium))
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 6)
                    if let f = fraction {
                        Capsule()
                            .fill(LinearGradient(
                                colors: [.red.opacity(0.7), .orange, .green],
                                startPoint: .leading, endPoint: .trailing
                            ))
                            .frame(width: max(geo.size.width * CGFloat(f), 6), height: 6)
                        Circle()
                            .fill(Color(uiColor: .systemBackground))
                            .overlay(Circle().stroke(Color.primary.opacity(0.5), lineWidth: 1.5))
                            .frame(width: 12, height: 12)
                            .offset(x: geo.size.width * CGFloat(f) - 6, y: -3)
                    }
                }
            }
            .frame(height: 12)
            HStack {
                Text(Fmt.money(low, currency: currency)).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.money(high, currency: currency)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var myPositionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Mi posición", systemImage: "person.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            let cpu = holding.cpu ?? 0
            // Valores por unidad en moneda nativa del holding (no se convierten)
            // Valores totales en SGD se convierten a la moneda de presentación
            let stats: [(String, String)] = [
                ("Coste medio/ud", Fmt.money(cpu, currency: holding.currency)),
                ("Coste total",    Fmt.money(holding.cost, currency: holding.currency)),
                ("G/L realizada",  Fmt.money(store.toDisplay(holding.realizedGL * (holding.fxRate ?? 1)), currency: store.displayCode)),
                ("Dividendos tot", Fmt.money(store.toDisplay(holding.dividends  * (holding.fxRate ?? 1)), currency: store.displayCode)),
                ("Divid. (TTM)",   Fmt.money(store.toDisplay(holding.dividendsTTM * (holding.fxRate ?? 1)), currency: store.displayCode)),
                ("Desde",          holding.firstDate),
            ]
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                spacing: 8
            ) {
                ForEach(stats, id: \.0) { item in
                    miniStatCell(item.0, item.1)
                }
            }

            if let avg = holding.avgTarget {
                HStack(spacing: 8) {
                    if let mn = holding.minTarget {
                        miniStatCell("Obj. mín.", Fmt.money(mn, currency: holding.currency))
                    }
                    miniStatCell("Obj. medio", Fmt.money(avg, currency: holding.currency))
                    if let mx = holding.maxTarget {
                        miniStatCell("Obj. máx.", Fmt.money(mx, currency: holding.currency))
                    }
                }
            }
        }
    }

    private func miniStatCell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

// MARK: - SignalBadge

struct SignalBadge: View {
    let signal: RecommendationSignal

    private var config: (color: Color, icon: String) {
        switch signal {
        case .strongBuy:    return (.green, "sparkles")
        case .buy:          return (.mint, "arrow.up.right")
        case .hold:         return (.blue, "minus.circle")
        case .takeProfit:   return (.orange, "banknote")
        case .notAvailable: return (.secondary, "questionmark.circle")
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: config.icon)
                .font(.system(size: 9, weight: .bold))
            Text(signal.rawValue)
                .font(.caption2.weight(.bold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(config.color.opacity(0.18)))
        .foregroundStyle(config.color)
    }
}

#Preview {
    HoldingsView().environmentObject(PortfolioStore(sheets: GoogleSheetsClient(config: .preview)))
}
