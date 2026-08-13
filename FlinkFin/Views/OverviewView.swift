import SwiftUI
import Charts

/// "Overview" tab — mirrors #tab-overview in templates/index.html:
/// hero with total value + evolution chart, key metrics, currency breakdown.
struct OverviewView: View {
    @EnvironmentObject private var store: PortfolioStore
    @EnvironmentObject private var lm: LanguageManager
    @State private var duplicatesBannerDismissed = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    heroCard
                    if store.duplicatesFoundOnLastRefresh > 0 && !duplicatesBannerDismissed {
                        duplicatesNotice
                    }
                    kpiGrid
                    currencyGrid
                }
                .padding()
            }
            .navigationTitle(lm["overview.title"])
            .refreshable {
                duplicatesBannerDismissed = false
                await store.refresh()
                await store.refreshHistory()
            }
            .onChange(of: store.duplicatesFoundOnLastRefresh) {
                duplicatesBannerDismissed = false
            }
            .onChange(of: showSettings) { _, isShowing in
                if !isShowing {
                    Task {
                        await store.refresh()
                        await store.refreshHistory()
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 16) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        Button {
                            Task {
                                await store.refresh()
                                await store.refreshHistory()
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(store.isLoading)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Image("AppLogoSmall")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 84)
                        .accessibilityHidden(true)
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .overlay {
                if store.isLoading && store.holdings.isEmpty {
                    ProgressView(lm["overview.loading"])
                } else if !store.isLoading && store.holdings.isEmpty && store.lastUpdated != nil {
                    ContentUnavailableView(
                        lm["overview.no_data"],
                        systemImage: "chart.pie",
                        description: Text(lm["overview.no_data.hint"])
                    )
                }
            }
            .alert(lm["overview.error"], isPresented: errorBinding) {
                Button(lm["overview.ok"], role: .cancel) {}
            } message: {
                Text(store.errorMessage ?? "")
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })
    }

    // MARK: - Hero

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(lm["overview.portfolio_value"])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // Currency picker (S$ / €) — updates display currency across the app
                currencyPicker
            }

            Text(Fmt.money(store.toDisplay(store.totals?.valueSGD ?? 0), currency: store.displayCode))
                .font(.largeTitle.weight(.bold))
                .fontDesign(.rounded)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.25), value: store.displayCurrency)

            // Daily change from previous day's close
            if let dayChange = store.dailyChangeValueSGD, let dayPct = store.dailyChangePct {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .imageScale(.small)
                    Text(lm["overview.today"])
                    Text(" ") // thin space
                    Image(systemName: dayChange >= 0 ? "arrow.up" : "arrow.down")
                        .imageScale(.small)
                    Text(Fmt.money(store.toDisplay(abs(dayChange)), currency: store.displayCode))
                    Text("(\(Fmt.pct(dayPct, signed: true)))")
                        .foregroundStyle(dayChange >= 0 ? .green : .red)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(dayChange >= 0 ? .green : .red)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.25), value: store.displayCurrency)
            }
            if !store.history.isEmpty {
                Chart(store.history) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Value", point.value))
                        .interpolationMethod(.monotone)
                    AreaMark(x: .value("Date", point.date), y: .value("Value", point.value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                }
                .chartXAxis(.hidden)
                .frame(height: 90)
                .padding(.top, 4)
            }
            if let updated = store.lastUpdated {
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                    Text(updated, style: .relative)
                    Text(lm["overview.ago"])
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(.thinMaterial))
    }

    /// Segmented picker for S$ / € display currency.
    private var currencyPicker: some View {
        HStack(spacing: 0) {
            ForEach(DisplayCurrency.allCases, id: \.self) { ccy in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        store.displayCurrency = ccy
                    }
                } label: {
                    Text(ccy.symbol)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            store.displayCurrency == ccy
                                ? Color.accentColor
                                : Color.secondary.opacity(0.12)
                        )
                        .foregroundStyle(
                            store.displayCurrency == ccy
                                ? Color(uiColor: .systemBackground)
                                : .primary
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(store.displayCurrency == ccy ? .isSelected : [])
                .accessibilityLabel(ccy.rawValue)
            }
        }
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
    }

    // MARK: - KPIs

    private var kpiGrid: some View {
        let totals = store.totals
        return VStack(alignment: .leading, spacing: 8) {
            Text(lm["overview.key_metrics"]).font(.headline)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                kpiCard(lm["overview.total_cost"],
                        Fmt.money(store.toDisplay(totals?.costSGD ?? 0), currency: store.displayCode))
                kpiCard(lm["overview.unrealized_gl"],
                        Fmt.money(store.toDisplay(totals?.glSGD ?? 0), currency: store.displayCode))
                kpiCard(lm["overview.return"], Fmt.pct(totals?.glPct ?? 0, signed: true))
                kpiCard(lm["overview.holdings_count"], "\(store.holdings.count)")
            }
        }
    }

    private func kpiCard(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.25), value: store.displayCurrency)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.thinMaterial))
    }

    // MARK: - Currency Breakdown

    private var currencyGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(lm["overview.currency_alloc"]).font(.headline)
            ForEach(store.byCurrency, id: \.currency) { c in
                HStack {
                    Text(c.currency).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(Fmt.money(store.toDisplay(c.value), currency: store.displayCode))
                        .font(.subheadline)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.25), value: store.displayCurrency)
                    Text("\(c.count)")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.secondary.opacity(0.15)))
                }
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - Duplicates Notice

    private var duplicatesNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(lm.fmt("overview.duplicates", store.duplicatesFoundOnLastRefresh))
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    duplicatesBannerDismissed = true
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.yellow.opacity(0.12)))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

#Preview {
    OverviewView()
        .environmentObject(PortfolioStore(sheets: GoogleSheetsClient(config: .preview)))
        .environmentObject(LanguageManager.shared)
}
