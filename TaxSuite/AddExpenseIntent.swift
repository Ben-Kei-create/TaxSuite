import AppIntents
import SwiftData

struct ProjectNameOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [String] {
        TaxSuiteWidgetStore.loadProjectNames()
    }

    func defaultResult() async -> String? {
        TaxSuiteWidgetStore.fallbackProjectName()
    }
}

struct AddExpenseIntent: AppIntent {
    static var title: LocalizedStringResource = "経費を追加"
    static var description = IntentDescription("TaxSuiteに経費を記録します")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "項目名", description: "例: タクシー代、カフェ代")
    var expenseTitle: String

    @Parameter(title: "金額（円）", description: "例: 2000")
    var amount: Double

    @Parameter(
        title: "プロジェクト",
        description: "どの仕事の経費かを選びます",
        optionsProvider: ProjectNameOptionsProvider()
    )
    var project: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let container = try TaxSuitePersistence.makeContainer()
        let context = container.mainContext
        let resolvedProject = TaxSuiteWidgetStore.sanitizeProjectName(project)

        let expense = ExpenseItem(
            timestamp: Date(),
            title: expenseTitle,
            amount: amount,
            category: "未分類",
            project: resolvedProject,
            businessRatio: 1.0
        )
        context.insert(expense)
        try context.save()

        let allExpenses = try context.fetch(FetchDescriptor<ExpenseItem>())
        let allIncomes = try context.fetch(FetchDescriptor<IncomeItem>())
        let snapshot = TaxSuiteWidgetStore.makeSnapshot(
            expenses: allExpenses,
            incomes: allIncomes,
            taxRate: TaxSuiteWidgetStore.currentTaxRate()
        )
        TaxSuiteWidgetStore.save(snapshot: snapshot)

        let message = "¥\(Int(amount).formatted())の\(expenseTitle)を\(resolvedProject)に記録しました"
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

struct TaxSuiteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddExpenseIntent(),
            phrases: [
                "\(.applicationName)に経費を記録",
                "\(.applicationName)で経費を追加",
                "\(.applicationName)で経費を入力",
            ],
            shortTitle: "経費を追加",
            systemImageName: "yensign.circle.fill"
        )
    }
}
