import Foundation

enum TransactionType: String, Codable, CaseIterable {
    case buy = "Buy"
    case sell = "Sell"
    case div = "Div"
}

struct Transaction: Identifiable, Codable, Equatable {
    var id: Int
    var date: String          // "YYYY-MM-DD"
    var type: TransactionType
    var name: String
    var ticker: String?
    var currency: String
    var units: Double
    var price: Double
    var fees: Double
    var remarks: String?
    var source: String

    var positionKey: String { "\(name)|\(currency)" }
}
