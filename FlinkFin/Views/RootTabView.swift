import SwiftUI

/// Punto de entrada de la UI — 5 pestañas, mismo reparto que
/// templates/index.html (Resumen/Posiciones/Rendimiento/Recomendaciones/
/// Transacciones). `store` se crea una vez aquí y se pasa como
/// `@EnvironmentObject` al resto del árbol.
struct RootTabView: View {
    @StateObject private var store: PortfolioStore

    init(store: PortfolioStore) {
        _store = StateObject(wrappedValue: store)
    }

    var body: some View {
        TabView {
            OverviewView()
                .tabItem { Label("Resumen", systemImage: "chart.pie.fill") }

            HoldingsView()
                .tabItem { Label("Posiciones", systemImage: "briefcase.fill") }

            PerformanceView()
                .tabItem { Label("Rendimiento", systemImage: "chart.line.uptrend.xyaxis") }

            RecommendationsView()
                .tabItem { Label("Recomendaciones", systemImage: "lightbulb.fill") }

            TransactionsView()
                .tabItem { Label("Transacciones", systemImage: "list.bullet.rectangle") }
        }
        .environmentObject(store)
        .task {
            await store.refresh()
            await store.refreshHistory()
        }
    }
}
