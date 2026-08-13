import SwiftUI

/// UI entry point — 5 tabs matching templates/index.html (Overview / Holdings /
/// Performance / Recommendations / Transactions). `store` is passed in via init,
/// wrapped in @StateObject, and injected as an environment object for child views.
struct RootTabView: View {
    @StateObject private var store: PortfolioStore
    @EnvironmentObject private var lm: LanguageManager
    @State private var showSettings = false

    init(store: PortfolioStore) {
        _store = StateObject(wrappedValue: store)
    }

    var body: some View {
        TabView {
            OverviewView()
                .tabItem { Label(lm["tab.overview"], systemImage: "chart.pie.fill") }

            HoldingsView()
                .tabItem { Label(lm["tab.holdings"], systemImage: "briefcase.fill") }

            PerformanceView()
                .tabItem { Label(lm["tab.performance"], systemImage: "chart.line.uptrend.xyaxis") }

            RecommendationsView()
                .tabItem { Label(lm["tab.recommendations"], systemImage: "lightbulb.fill") }

            TransactionsView()
                .tabItem { Label(lm["tab.transactions"], systemImage: "list.bullet.rectangle") }
        }
        .environmentObject(store)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .task {
            await store.refresh()
            await store.refreshHistory()
        }
    }
}
