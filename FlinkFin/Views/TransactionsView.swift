import SwiftUI

/// "Transactions" tab — mirrors #tab-transactions: read-only list of movements
/// (Buy/Sell/Div), most recent first. Direct Google Sheets access means this app
/// never writes to the sheet (per project rule: read-only against Sheets).
struct TransactionsView: View {
    @EnvironmentObject private var store: PortfolioStore
    @EnvironmentObject private var lm: LanguageManager
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
            .searchable(text: $query, prompt: lm["txn.search"])
            .navigationTitle(lm["txn.title"])
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
                    ContentUnavailableView(lm["txn.empty"], systemImage: "list.bullet.rectangle")
                }
            }
        }
    }
}

private struct TransactionRow: View {
    @EnvironmentObject private var lm: LanguageManager
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
                Text("\(Fmt.number(tx.units, decimals: 4)) \(lm["txn.units"])").font(.caption)
                Text(Fmt.money(tx.price, currency: tx.currency)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    TransactionsView()
        .environmentObject(PortfolioStore(sheets: GoogleSheetsClient(config: .preview)))
        .environmentObject(LanguageManager.shared)
}
