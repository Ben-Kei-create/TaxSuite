import Foundation
#if !WIDGET_EXTENSION
import SwiftData
#endif
#if canImport(WidgetKit)
import WidgetKit
#endif

nonisolated enum TaxSuiteWidgetSupport {
    static let appGroupID = "group.com.fumiakiMogi777.TaxSuite"
    static let snapshotKey = "taxsuite_widget_snapshot_v1"
    static let defaultTaxRate = 0.2
}

nonisolated struct TaxSuiteWidgetSnapshot: Codable, Equatable {
    let generatedAt: Date
    let monthLabel: String
    let taxRate: Double
    let currentMonthRevenue: Double
    let currentMonthExpenses: Double
    let estimatedTax: Double
    let takeHome: Double
    let todayExpensesTotal: Double
    let todayExpenseCount: Int
    let recentExpenseTitle: String?
}

// MARK: - WidgetButtonSlot

/// ホーム画面ウィジェットのクイック追加ボタン 1 スロット分の設定値。
/// App Group の UserDefaults に JSON として保存し、アプリ ↔ ウィジェット間で共有する。
nonisolated struct WidgetButtonSlot: Codable, Equatable, Identifiable {
    /// スロット番号（0 〜 3 の固定インデックス）
    var id: Int
    var title: String
    var amount: Double
    var category: String
    var project: String

    /// 出荷時デフォルト（既存のハードコード値と完全一致）
    static let defaultSlots: [WidgetButtonSlot] = [
        WidgetButtonSlot(id: 0, title: "カフェ",  amount: 600,  category: "会議費",     project: "エンジニア業"),
        WidgetButtonSlot(id: 1, title: "電車",    amount: 180,  category: "交通費",     project: "その他"),
        WidgetButtonSlot(id: 2, title: "昼食",    amount: 1000, category: "福利厚生費", project: "その他"),
        WidgetButtonSlot(id: 3, title: "消耗品",  amount: 1500, category: "消耗品費",   project: "その他")
    ]
}

nonisolated struct TaxSuiteQuickExpenseAction: Codable, Equatable, Identifiable {
    let id: UUID
    let title: String
    let amount: Double
    let category: String
    let project: String
    let note: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        amount: Double,
        category: String,
        project: String,
        note: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.amount = amount
        self.category = category
        self.project = project
        self.note = note
        self.createdAt = createdAt
    }
}

nonisolated enum TaxSuiteWidgetStore {
    nonisolated static func save(snapshot: TaxSuiteWidgetSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(snapshot) else { return }
        sharedDefaults.set(data, forKey: TaxSuiteWidgetSupport.snapshotKey)
        reloadTimelines()
    }

    nonisolated static func load() -> TaxSuiteWidgetSnapshot? {
        guard let data = sharedDefaults.data(forKey: TaxSuiteWidgetSupport.snapshotKey) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TaxSuiteWidgetSnapshot.self, from: data)
    }

    nonisolated static func enqueueQuickExpense(_ action: TaxSuiteQuickExpenseAction) {
        var queued = pendingQuickExpenses()
        queued.append(action)
        savePendingQuickExpenses(queued)

        let snapshot = (load() ?? emptySnapshot(for: action.createdAt)).appending(action)
        save(snapshot: snapshot)
    }

    nonisolated static func consumePendingQuickExpenses() -> [TaxSuiteQuickExpenseAction] {
        let queued = pendingQuickExpenses()
        sharedDefaults.removeObject(forKey: pendingQuickExpenseKey)
        return queued
    }

    private nonisolated static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: TaxSuiteWidgetSupport.appGroupID) ?? .standard
    }

    private nonisolated static var pendingQuickExpenseKey: String {
        "taxsuite_widget_pending_quick_expenses_v1"
    }

    private nonisolated static var buttonSlotsKey: String {
        "taxsuite_widget_button_slots_v1"
    }

    /// 4 つのスロット設定を App Group に保存し、ウィジェットのタイムラインを即時リロードする。
    nonisolated static func saveButtonSlots(_ slots: [WidgetButtonSlot]) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(slots) else { return }
        sharedDefaults.set(data, forKey: buttonSlotsKey)
        reloadTimelines()
    }

    /// 保存済みスロット設定を読み込む。未保存の場合はデフォルト値を返す。
    nonisolated static func loadButtonSlots() -> [WidgetButtonSlot] {
        guard let data = sharedDefaults.data(forKey: buttonSlotsKey) else {
            return WidgetButtonSlot.defaultSlots
        }
        return (try? JSONDecoder().decode([WidgetButtonSlot].self, from: data))
            ?? WidgetButtonSlot.defaultSlots
    }

    private nonisolated static func pendingQuickExpenses() -> [TaxSuiteQuickExpenseAction] {
        guard let data = sharedDefaults.data(forKey: pendingQuickExpenseKey) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([TaxSuiteQuickExpenseAction].self, from: data)) ?? []
    }

    private nonisolated static func savePendingQuickExpenses(_ actions: [TaxSuiteQuickExpenseAction]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(actions) else { return }
        sharedDefaults.set(data, forKey: pendingQuickExpenseKey)
    }

    private nonisolated static func emptySnapshot(for date: Date) -> TaxSuiteWidgetSnapshot {
        TaxSuiteWidgetSnapshot(
            generatedAt: date,
            monthLabel: monthString(for: date),
            taxRate: TaxSuiteWidgetSupport.defaultTaxRate,
            currentMonthRevenue: 0,
            currentMonthExpenses: 0,
            estimatedTax: 0,
            takeHome: 0,
            todayExpensesTotal: 0,
            todayExpenseCount: 0,
            recentExpenseTitle: nil
        )
    }

    private nonisolated static func reloadTimelines() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

#if !WIDGET_EXTENSION
extension TaxSuiteWidgetStore {
    nonisolated static func makeSnapshot(
        expenses: [ExpenseItem],
        incomes: [IncomeItem],
        taxRate: Double,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TaxSuiteWidgetSnapshot {
        let monthExpenses = expenses.filter { calendar.isDate($0.timestamp, equalTo: now, toGranularity: .month) }
        let monthIncomes = incomes.filter { calendar.isDate($0.timestamp, equalTo: now, toGranularity: .month) }
        let startOfToday = calendar.startOfDay(for: now)
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        let todayExpenses = expenses.filter { $0.timestamp >= startOfToday && $0.timestamp < endOfToday }

        let revenueTotal = monthIncomes.reduce(0) { $0 + $1.amount }
        let expenseTotal = monthExpenses.reduce(0) { $0 + $1.effectiveAmount }
        let estimatedTax = TaxCalculator.calculateTax(revenue: revenueTotal, expenses: expenseTotal, taxRate: taxRate)
        let takeHome = TaxCalculator.calculateTakeHome(revenue: revenueTotal, expenses: expenseTotal, taxRate: taxRate)

        return TaxSuiteWidgetSnapshot(
            generatedAt: now,
            monthLabel: monthString(for: now),
            taxRate: taxRate,
            currentMonthRevenue: revenueTotal,
            currentMonthExpenses: expenseTotal,
            estimatedTax: estimatedTax,
            takeHome: takeHome,
            todayExpensesTotal: todayExpenses.reduce(0) { $0 + $1.effectiveAmount },
            todayExpenseCount: todayExpenses.count,
            recentExpenseTitle: expenses.sorted(by: { $0.timestamp > $1.timestamp }).first?.title
        )
    }

    nonisolated static func currentTaxRate() -> Double {
        guard let value = UserDefaults.standard.object(forKey: "taxRate") as? Double else {
            return TaxSuiteWidgetSupport.defaultTaxRate
        }
        return value
    }

}
#endif

private extension TaxSuiteWidgetStore {
    nonisolated static func monthString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy年M月"
        return formatter.string(from: date)
    }
}

private extension TaxSuiteWidgetSnapshot {
    nonisolated func appending(_ action: TaxSuiteQuickExpenseAction) -> TaxSuiteWidgetSnapshot {
        let expenseTotal = currentMonthExpenses + action.amount
        let taxableIncome = max(0, currentMonthRevenue - expenseTotal)
        let nextEstimatedTax = taxableIncome * taxRate
        let nextTakeHome = currentMonthRevenue - expenseTotal - nextEstimatedTax

        return TaxSuiteWidgetSnapshot(
            generatedAt: action.createdAt,
            monthLabel: monthLabel,
            taxRate: taxRate,
            currentMonthRevenue: currentMonthRevenue,
            currentMonthExpenses: expenseTotal,
            estimatedTax: nextEstimatedTax,
            takeHome: nextTakeHome,
            todayExpensesTotal: todayExpensesTotal + action.amount,
            todayExpenseCount: todayExpenseCount + 1,
            recentExpenseTitle: action.title
        )
    }
}
