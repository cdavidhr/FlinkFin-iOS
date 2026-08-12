import SwiftUI

/// UI entry point — 5 tabs matching templates/index.html (Overview / Holdings /
/// Performance / Recommendations / Transactions). `store` is created in FlinkFinApp
/// and passed down along with `LanguageManager`.
struct RootTabView: View {
    @EnvironmentObject private var store: PortfolioStore
    @EnvironmentObject private var lm: LanguageManager
    @State private var showSettings = false

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
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .task {
            await store.refresh()
            await store.refreshHistory()
        }
    }
}
