import AppIntents

struct WidgetQuickExpenseIntent: AppIntent {
    static var title: LocalizedStringResource = "ウィジェットから経費を追加"
    static var openAppWhenRun: Bool = false

    @Parameter(title: "項目名")
    var title: String

    @Parameter(title: "金額")
    var amount: Double

    @Parameter(title: "カテゴリ")
    var category: String

    @Parameter(title: "プロジェクト")
    var project: String

    init() {}

    init(title: String, amount: Double, category: String, project: String) {
        self.title = title
        self.amount = amount
        self.category = category
        self.project = project
    }

    func perform() async throws -> some IntentResult {
        let action = TaxSuiteQuickExpenseAction(
            title: title,
            amount: amount,
            category: category,
            project: project
        )
        TaxSuiteWidgetStore.enqueueQuickExpense(action)
        return .result()
    }
}
