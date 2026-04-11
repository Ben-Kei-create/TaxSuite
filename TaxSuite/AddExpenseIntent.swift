import AppIntents
import SwiftData

// MARK: - プロジェクトの選択肢
// Siri が「エンジニア業、講師業、その他」の選択肢を音声で認識できる

enum ExpenseProject: String, AppEnum {
    case engineer   = "エンジニア業"
    case instructor = "講師業"
    case other      = "その他"

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "プロジェクト"
    static var caseDisplayRepresentations: [ExpenseProject: DisplayRepresentation] = [
        .engineer:   "エンジニア業",
        .instructor: "講師業",
        .other:      "その他",
    ]
}

// MARK: - メインインテント
// 「Hey Siri、TaxSuiteでタクシー代を追加」と言うと起動

struct AddExpenseIntent: AppIntent {
    static var title: LocalizedStringResource       = "経費を追加"
    static var description                          = IntentDescription("TaxSuiteに経費を記録します")
    static var openAppWhenRun: Bool                 = false  // バックグラウンドで完結

    @Parameter(title: "項目名", description: "例: タクシー代、カフェ代")
    var expenseTitle: String

    @Parameter(title: "金額（円）", description: "例: 2000")
    var amount: Double

    @Parameter(title: "プロジェクト", default: .other)
    var project: ExpenseProject

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // メインアプリと同じスキーマ・ストアにアクセス
        let schema = Schema([ExpenseItem.self, RecurringExpense.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let container = try ModelContainer(for: schema, configurations: [config])

        let expense = ExpenseItem(
            title:   expenseTitle,
            amount:  amount,
            project: project.rawValue
        )
        container.mainContext.insert(expense)

        let msg = "¥\(Int(amount).formatted())の\(expenseTitle)を\(project.rawValue)に記録しました"
        return .result(dialog: IntentDialog(stringLiteral: msg))
    }
}

// MARK: - Siri に登録する起動フレーズ
// 設定 → Siriと検索 → TaxSuite からも確認できる

struct TaxSuiteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // ⚠️ App Intents のルール:
        //   フレーズ内のパラメーター補間は AppEnum / AppEntity のみ使用可
        //   String パラメーター (expenseTitle, amount) は Siri が対話的に質問してくれる
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
