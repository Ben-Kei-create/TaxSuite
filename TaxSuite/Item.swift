import Foundation
import SwiftData

@Model
final class ExpenseItem {
    var timestamp: Date
    var title: String
    var amount: Double
    var category: String
    
    init(timestamp: Date = Date(), title: String, amount: Double, category: String = "未分類") {
        self.timestamp = timestamp
        self.title = title
        self.amount = amount
        self.category = category
    }
}
