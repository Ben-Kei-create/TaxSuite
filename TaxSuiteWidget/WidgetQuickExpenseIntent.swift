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

    @Parameter(title: "コメント")
    var note: String

    init() {}

    init(title: String, amount: Double, category: String, project: String, note: String = "") {
        self.title = title
        self.amount = amount
        self.category = category
        self.project = project
        self.note = note
    }

    func perform() async throws -> some IntentResult {
        let action = TaxSuiteQuickExpenseAction(
            title: title,
            amount: amount,
            category: category,
            project: project,
            note: note
        )
        TaxSuiteWidgetStore.enqueueQuickExpense(action)
        return .result()
    }
}
