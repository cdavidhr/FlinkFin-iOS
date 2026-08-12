import SwiftUI
import Charts

/// Pestaña "Resumen" — espejo de #tab-overview en templates/index.html:
/// hero con valor total + gráfico de evolución, KPIs, desglose por divisa.
struct OverviewView: View {
    @EnvironmentObject private var store: PortfolioStore
    /// Controla si el banner de duplicados está cerrado por el usuario.
    /// Se resetea automáticamente cuando el siguiente refresh encuentra duplicados.
    @State private var duplicatesBannerDismissed = false

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
            .navigationTitle("Resumen")
            .refreshable {
                duplicatesBannerDismissed = false
                await store.refresh()
                await store.refreshHistory()
            }
            .onChange(of: store.duplicatesFoundOnLastRefresh) {
                duplicatesBannerDismissed = false
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
            .overlay {
                if store.isLoading && store.holdings.isEmpty {
                    ProgressView("Cargando…")
                } else if !store.isLoading && store.holdings.isEmpty && store.lastUpdated != nil {
                    ContentUnavailableView(
                        "Sin datos",
                        systemImage: "chart.pie",
                        description: Text("Pulsa el botón ↻ para cargar el portfolio desde Google Sheets.")
                    )
                }
            }
            .alert("Error", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
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
                Text("Valor total del portfolio")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // Selector S$ / € — cambia la moneda de presentación de toda la app
                currencyPicker
            }

            Text(Fmt.money(store.toDisplay(store.totals?.valueSGD ?? 0), currency: store.displayCode))
                // HIG: .largeTitle + fontDesign escala con Dynamic Type
                .font(.largeTitle.weight(.bold))
                .fontDesign(.rounded)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.25), value: store.displayCurrency)

            // Variación desde el cierre del día anterior
            if let dayChange = store.dailyChangeValueSGD, let dayPct = store.dailyChangePct {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .imageScale(.small)
                    Text("Hoy")
                    Text(" ") // espacio fino
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
                    LineMark(x: .value("Fecha", point.date), y: .value("Valor", point.value))
                        .interpolationMethod(.monotone)
                    AreaMark(x: .value("Fecha", point.date), y: .value("Valor", point.value))
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
                    Text("ago")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(.thinMaterial))
    }

    /// Selector S$ / € con aspecto de píldoras, estilo HIG.
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
            Text("Métricas clave").font(.headline)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                kpiCard("Coste total",
                        Fmt.money(store.toDisplay(totals?.costSGD ?? 0), currency: store.displayCode))
                kpiCard("G/L no realizada",
                        Fmt.money(store.toDisplay(totals?.glSGD ?? 0), currency: store.displayCode))
                kpiCard("Rentabilidad", Fmt.pct(totals?.glPct ?? 0, signed: true))
                kpiCard("Posiciones", "\(store.holdings.count)")
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

    // MARK: - Distribución por divisa

    private var currencyGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Distribución por divisa").font(.headline)
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

    // MARK: - Banner duplicados

    private var duplicatesNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("Se filtraron \(store.duplicatesFoundOnLastRefresh) fila\(store.duplicatesFoundOnLastRefresh == 1 ? "" : "s") duplicada\(store.duplicatesFoundOnLastRefresh == 1 ? "" : "s") en el Sheet.")
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
    OverviewView().environmentObject(PortfolioStore(sheets: GoogleSheetsClient(config: .preview)))
}
