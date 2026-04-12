import Foundation
#if !WIDGET_EXTENSION
import SwiftData
#endif
#if canImport(WidgetKit)
import WidgetKit
#endif

enum TaxSuiteWidgetSupport {
    static let appGroupID = "group.com.fumiakiMogi777.TaxSuite"
    static let snapshotKey = "taxsuite_widget_snapshot_v1"
    static let defaultTaxRate = 0.2
}

struct TaxSuiteWidgetSnapshot: Codable, Equatable {
    let generatedAt: Date
    let monthLabel: String
    let currentMonthRevenue: Double
    let currentMonthExpenses: Double
    let estimatedTax: Double
    let takeHome: Double
    let todayExpensesTotal: Double
    let todayExpenseCount: Int
    let recentExpenseTitle: String?
}

enum TaxSuiteWidgetStore {
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

    private nonisolated static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: TaxSuiteWidgetSupport.appGroupID) ?? .standard
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

    private nonisolated static func monthString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy年M月"
        return formatter.string(from: date)
    }
}
#endif
