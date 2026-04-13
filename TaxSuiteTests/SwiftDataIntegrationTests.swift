// MARK: - SwiftDataIntegrationTests.swift
//
// 結合テスト: SwiftData（ModelContext）を使ったデータ保存・取得・削除を検証する。
// isStoredInMemoryOnly: true で本番データを汚さない使い捨て DB を使用。
//
// 実行方法: Xcode メニュー → Product → Test (⌘U)

import XCTest
import SwiftData
@testable import TaxSuite

@MainActor
final class SwiftDataIntegrationTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!

    // MARK: - セットアップ / ティアダウン

    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: ExpenseItem.self, IncomeItem.self, RecurringExpense.self, LocationTrigger.self,
            configurations: config
        )
        context = container.mainContext
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
    }

    // MARK: - ExpenseItem CRUD

    func testInsertAndFetchExpense() throws {
        let expense = ExpenseItem(
            timestamp: Date(),
            title: "テスト交通費",
            amount: 500,
            category: "旅費交通費",
            project: "メイン業",
            businessRatio: 1.0
        )
        context.insert(expense)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<ExpenseItem>())
        XCTAssertEqual(fetched.count, 1, "1件保存されていること")
        XCTAssertEqual(fetched.first?.title, "テスト交通費", "タイトルが一致すること")
        XCTAssertEqual(fetched.first?.amount, 500, "金額が一致すること")
    }

    func testEffectiveAmount_withBusinessRatio() throws {
        let expense = ExpenseItem(
            timestamp: Date(),
            title: "家賃按分",
            amount: 100_000,
            businessRatio: 0.4
        )
        context.insert(expense)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<ExpenseItem>())
        XCTAssertEqual(fetched.first?.effectiveAmount, 40_000, "按分後の金額が正しく計算されること")
    }

    func testDeleteExpense() throws {
        let expense = ExpenseItem(title: "削除テスト", amount: 300)
        context.insert(expense)
        try context.save()

        context.delete(expense)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<ExpenseItem>())
        XCTAssertTrue(fetched.isEmpty, "削除後は件数が 0 になること")
    }

    // MARK: - IncomeItem

    func testInsertAndFetchIncome() throws {
        let income = IncomeItem(
            timestamp: Date(),
            title: "Web 制作案件",
            amount: 300_000,
            project: "メイン業"
        )
        context.insert(income)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<IncomeItem>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.amount, 300_000)
    }

    // MARK: - RecurringExpense

    func testRecurringExpenseNote() throws {
        let recurring = RecurringExpense(
            title: "Adobe Creative Cloud",
            amount: 6_480,
            dayOfMonth: 1,
            project: "メイン業",
            note: "制作ツール月額"
        )
        context.insert(recurring)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<RecurringExpense>())
        XCTAssertEqual(fetched.first?.note, "制作ツール月額", "コメントが保存されること")
    }

    // MARK: - 当月フィルタリング（計算ロジック検証）

    func testCurrentMonthExpenseFilter() throws {
        let calendar = Calendar.current
        let now = Date()

        // 今月の経費
        let thisMonth = ExpenseItem(timestamp: now, title: "今月", amount: 10_000)
        // 先月の経費
        let lastMonthDate = calendar.date(byAdding: .month, value: -1, to: now)!
        let lastMonth = ExpenseItem(timestamp: lastMonthDate, title: "先月", amount: 5_000)

        context.insert(thisMonth)
        context.insert(lastMonth)
        try context.save()

        let all = try context.fetch(FetchDescriptor<ExpenseItem>())
        let currentMonthTotal = all
            .filter { calendar.isDate($0.timestamp, equalTo: now, toGranularity: .month) }
            .reduce(0) { $0 + $1.effectiveAmount }

        XCTAssertEqual(currentMonthTotal, 10_000, "今月分のみが合計されること")
    }

    // MARK: - TaxCalculator との結合

    func testTakeHomeWithRealData() throws {
        context.insert(IncomeItem(timestamp: Date(), title: "案件A", amount: 500_000, project: "メイン業"))
        context.insert(ExpenseItem(timestamp: Date(), title: "交通費", amount: 50_000, businessRatio: 1.0))
        context.insert(ExpenseItem(timestamp: Date(), title: "家賃", amount: 100_000, businessRatio: 0.5))
        try context.save()

        let incomes  = try context.fetch(FetchDescriptor<IncomeItem>())
        let expenses = try context.fetch(FetchDescriptor<ExpenseItem>())

        let revenue     = incomes.reduce(0) { $0 + $1.amount }
        let expenseTotal = expenses.reduce(0) { $0 + $1.effectiveAmount } // 50,000 + 50,000 = 100,000

        let takeHome = TaxCalculator.calculateTakeHome(
            revenue: revenue,
            expenses: expenseTotal,
            taxRate: 0.2
        )
        // 課税所得 400,000 × 20% = 80,000 → 手取り 320,000
        XCTAssertEqual(takeHome, 320_000.0, accuracy: 0.01,
                       "DB から読み込んだデータで手取りが正しく計算されること")
    }
}
