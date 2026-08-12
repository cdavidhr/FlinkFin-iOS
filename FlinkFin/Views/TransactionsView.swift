import SwiftUI

/// Pestaña "Transacciones" — espejo de #tab-transactions: listado de
/// movimientos (Buy/Sell/Div), más reciente primero. Solo lectura en este
/// scaffold v1 — el dashboard web permite añadir transacciones a mano
/// (POST /api/transactions contra SQLite); esta app, al leer directamente
/// de Google Sheets, NO escribe en la hoja (ver regla en AGENTS.md del
/// proyecto `dashboard`: nunca editar el Sheet del usuario directamente).
/// Si en el futuro se quiere registrar transacciones desde la app, lo más
/// seguro es escribirlas en una hoja/pestaña separada y dejar que el
/// usuario las revise, no escribir directamente sobre "Transactions *".
struct TransactionsView: View {
    @EnvironmentObject private var store: PortfolioStore
    @State private var query: String = ""

    private var filtered: [Transaction] {
        let sorted = store.transactions.sorted { $0.date > $1.date }
        guard !query.isEmpty else { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { tx in
                TransactionRow(tx: tx)
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "Buscar por nombre")
            .navigationTitle("Transacciones")
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
            .overlay {
                if filtered.isEmpty {
                    ContentUnavailableView("Sin transacciones", systemImage: "list.bullet.rectangle")
                }
            }
        }
    }
}

private struct TransactionRow: View {
    let tx: Transaction

    private var typeColor: Color {
        switch tx.type {
        case .buy: return .green
        case .sell: return .red
        case .div: return .blue
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(tx.type.rawValue)
                // HIG: caption2 escala con Dynamic Type; system(size:10) no.
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Capsule().fill(typeColor.opacity(0.18)))
                .foregroundStyle(typeColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(tx.name).font(.subheadline.weight(.medium))
                Text(tx.date).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Fmt.number(tx.units, decimals: 4)) u.").font(.caption)
                Text(Fmt.money(tx.price, currency: tx.currency)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    TransactionsView().environmentObject(PortfolioStore(sheets: GoogleSheetsClient(config: .preview)))
}
