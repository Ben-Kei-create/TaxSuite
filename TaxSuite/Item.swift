import Foundation
import SwiftData

@Model
final class ExpenseItem {
    var timestamp: Date
    var title: String
    var amount: Double
    var category: String
    var project: String

    init(timestamp: Date = Date(), title: String, amount: Double, category: String = "未分類", project: String = "その他") {
        self.timestamp = timestamp
        self.title = title
        self.amount = amount
        self.category = category
        self.project = project
    }
}

// 固定費（サブスク・毎月自動入力）
@Model
final class RecurringExpense {
    var title: String
    var amount: Double
    var project: String
    var dayOfMonth: Int          // 毎月何日に実行するか（1〜28）
    var lastExecutedYear: Int    // 最後に実行した年
    var lastExecutedMonth: Int   // 最後に実行した月

    init(title: String, amount: Double, project: String, dayOfMonth: Int) {
        self.title = title
        self.amount = amount
        self.project = project
        self.dayOfMonth = dayOfMonth
        self.lastExecutedYear = 0
        self.lastExecutedMonth = 0
    }
}

// アプリ共通のプロジェクト定義
let kDefaultProjects = ["エンジニア業", "講師業", "その他"]

// WidgetKit / App Group 共有設定
// ⚠️ Xcode で App Group を追加したら、自分の Bundle ID に合わせてここを変更する
// 例: Bundle ID が "com.yamada.TaxSuite" なら "group.com.yamada.taxsuite"
let kAppGroupID = "group.com.yourname.taxsuite"
