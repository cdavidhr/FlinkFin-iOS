import SwiftUI
import Charts

/// "Holdings" tab — list of positions with expandable detail card on tap.
/// On expansion, lazily fetches fundamental market data from Yahoo Finance
/// (quoteSummary) and caches it for the session.
struct HoldingsView: View {
    @EnvironmentObject private var store: PortfolioStore
    @EnvironmentObject private var lm: LanguageManager
    @State private var currencyFilter: String = "all"
    @State private var sortOptionKey: String = "holdings.sort.by_value"
    /// Cache for fundamental quote data per ticker.
    @State private var quoteCache: [String: StockQuote] = [:]

    private var currencies: [String] {
        Array(Set(store.holdings.map(\.currency))).sorted()
    }

    private var filtered: [Holding] {
        var list = store.holdings
        if currencyFilter != "all" {
            list = list.filter { $0.currency == currencyFilter }
        }
        switch sortOptionKey {
        case "holdings.sort.by_gl":   list.sort { ($0.liveGLPct ?? 0) > ($1.liveGLPct ?? 0) }
        case "holdings.sort.by_name": list.sort { $0.name < $1.name }
        default:                      list.sort { ($0.liveValueSGD ?? 0) > ($1.liveValueSGD ?? 0) }
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
                            lm["holdings.empty"],
                            systemImage: "briefcase",
                            description: Text(lm["holdings.empty.hint"])
                        )
                    }
                }
            }
            .navigationTitle(lm["holdings.title"])
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
                    filterChip(lm["holdings.filter.all"], isSelected: currencyFilter == "all") { currencyFilter = "all" }
                    ForEach(currencies, id: \.self) { ccy in
                        filterChip(ccy, isSelected: currencyFilter == ccy) { currencyFilter = ccy }
                    }
                }
                .padding(.horizontal)
            }
            Picker(lm["holdings.sort"], selection: $sortOptionKey) {
                Text(lm["holdings.sort.by_value"]).tag("holdings.sort.by_value")
                Text(lm["holdings.sort.by_gl"]).tag("holdings.sort.by_gl")
                Text(lm["holdings.sort.by_name"]).tag("holdings.sort.by_name")
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

// MARK: - Expandable Card

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

// MARK: - Main Row Content

private struct HoldingRowContent: View {
    @EnvironmentObject private var store: PortfolioStore
    @EnvironmentObject private var lm: LanguageManager
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
                    Text("\(Fmt.units(holding.units)) \(lm["holdings.units"]) · \(Fmt.money(holding.livePrice ?? holding.cpu ?? 0, currency: holding.currency))/\(lm["holdings.units"])")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if holding.priceIsLive == false {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .imageScale(.small)
                            .foregroundStyle(.orange)
                            .accessibilityLabel(lm["holdings.estimated_price"])
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

// MARK: - Expanded Detail Panel

private struct HoldingDetailPanel: View {
    @EnvironmentObject private var store: PortfolioStore
    @EnvironmentObject private var lm: LanguageManager
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
                    ProgressView(lm["holdings.loading"])
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.top, 12)
            } else if failed || (quote == nil && holding.ticker.isEmpty) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        holding.ticker.isEmpty
                            ? lm["holdings.no_ticker"]
                            : lm["holdings.load_failed"],
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
            Label(lm["holdings.market_data"], systemImage: "chart.bar.xaxis")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            let stats: [(String, String)] = [
                q.trailingPE  .map { (lm["holdings.pe_ttm"], Fmt.ratio($0)) },
                q.forwardPE   .map { (lm["holdings.pe_fwd"], Fmt.ratio($0)) },
                q.beta        .map { ("Beta",               String(format: "%.2f", $0)) },
                q.trailingEps .map { ("EPS",                Fmt.money($0, currency: holding.currency)) },
                q.priceToBook .map { ("P/Book",             Fmt.ratio($0)) },
                q.dividendYield.map { ("Div. yield",        Fmt.pct($0)) },
                q.grossMargins .map { (lm["holdings.gross_margin"], Fmt.pct($0)) },
                q.profitMargins.map { (lm["holdings.net_margin"],   Fmt.pct($0)) },
                q.roe          .map { ("ROE",                Fmt.pct($0)) },
                q.volume       .map { (lm["holdings.volume"],       Fmt.compact($0)) },
                q.marketCap    .map { (lm["holdings.market_cap"],   Fmt.compact($0)) },
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

            if let low = q.fiftyTwoWeekLow, let high = q.fiftyTwoWeekHigh, high > low {
                rangeBar(low: low, high: high, current: holding.livePrice, currency: holding.currency)
            }
        }
    }

    private func rangeBar(low: Double, high: Double, current: Double?, currency: String) -> some View {
        let fraction = current.map { min(max(($0 - low) / (high - low), 0), 1) }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(lm["holdings.week52"]).font(.caption2).foregroundStyle(.secondary)
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
            Label(lm["holdings.my_position"], systemImage: "person.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            let cpu = holding.cpu ?? 0
            let stats: [(String, String)] = [
                (lm["holdings.avg_cost"],      Fmt.money(cpu, currency: holding.currency)),
                (lm["holdings.total_cost"],    Fmt.money(holding.cost, currency: holding.currency)),
                (lm["holdings.realized_gl"],   Fmt.money(store.toDisplay(holding.realizedGL * (holding.fxRate ?? 1)), currency: store.displayCode)),
                (lm["holdings.dividends"],     Fmt.money(store.toDisplay(holding.dividends  * (holding.fxRate ?? 1)), currency: store.displayCode)),
                (lm["holdings.dividends_ttm"], Fmt.money(store.toDisplay(holding.dividendsTTM * (holding.fxRate ?? 1)), currency: store.displayCode)),
                (lm["holdings.since"],         holding.firstDate),
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
                        miniStatCell(lm["holdings.target.min"], Fmt.money(mn, currency: holding.currency))
                    }
                    miniStatCell(lm["holdings.target.avg"], Fmt.money(avg, currency: holding.currency))
                    if let mx = holding.maxTarget {
                        miniStatCell(lm["holdings.target.max"], Fmt.money(mx, currency: holding.currency))
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
    @EnvironmentObject private var lm: LanguageManager
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

    private var signalText: String {
        switch signal {
        case .strongBuy:    return lm["rec.signal.strong_buy"]
        case .buy:          return lm["rec.signal.buy"]
        case .hold:         return lm["rec.signal.hold"]
        case .takeProfit:   return lm["rec.signal.take_profit"]
        case .notAvailable: return lm["rec.signal.na"]
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: config.icon)
                .font(.system(size: 9, weight: .bold))
            Text(signalText)
                .font(.caption2.weight(.bold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(config.color.opacity(0.18)))
        .foregroundStyle(config.color)
    }
}

#Preview {
    HoldingsView()
        .environmentObject(PortfolioStore(sheets: GoogleSheetsClient(config: .preview)))
        .environmentObject(LanguageManager.shared)
}
