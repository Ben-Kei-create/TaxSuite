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
    static let defaultProjectNames = ["メイン業", "副業", "その他"]
    /// プロジェクトの最大登録数（デフォルト 3 + 追加枠 7）
    static let maxProjectCount = 10
    /// プロジェクトの最小登録数（常にデフォルト相当の 3 件は確保する）
    static let minProjectCount = 3
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
    var note: String

    init(
        id: Int,
        title: String,
        amount: Double,
        category: String,
        project: String,
        note: String = ""
    ) {
        self.id = id
        self.title = title
        self.amount = amount
        self.category = category
        self.project = project
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case amount
        case category
        case project
        case note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        amount = try container.decode(Double.self, forKey: .amount)
        category = try container.decode(String.self, forKey: .category)
        project = try container.decode(String.self, forKey: .project)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
    }

    /// 出荷時デフォルト（既存のハードコード値と完全一致）
    static var defaultSlots: [WidgetButtonSlot] {
        let projectNames = TaxSuiteWidgetStore.loadProjectNames()
        return [
            WidgetButtonSlot(id: 0, title: "カフェ",  amount: 600,  category: "会議費",     project: projectNames[0]),
            WidgetButtonSlot(id: 1, title: "電車",    amount: 180,  category: "交通費",     project: projectNames[2]),
            WidgetButtonSlot(id: 2, title: "昼食",    amount: 1000, category: "福利厚生費", project: projectNames[2]),
            WidgetButtonSlot(id: 3, title: "消耗品",  amount: 1500, category: "消耗品費",   project: projectNames[2])
        ]
    }
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

    private nonisolated static var projectNamesKey: String {
        "taxsuite_project_names_v1"
    }

    nonisolated static func loadProjectNames() -> [String] {
        let storedNames = sharedDefaults.stringArray(forKey: projectNamesKey) ?? TaxSuiteWidgetSupport.defaultProjectNames
        return normalizedProjectNames(storedNames)
    }

    @discardableResult
    nonisolated static func saveProjectNames(_ names: [String]) -> [String] {
        let normalized = normalizedProjectNames(names)
        sharedDefaults.set(normalized, forKey: projectNamesKey)
        reloadTimelines()
        return normalized
    }

    nonisolated static func projectNameOptions(including extras: [String] = []) -> [String] {
        var options = loadProjectNames()
        var seen = Set(options.map(normalizedProjectLookupKey))

        for extra in extras {
            let trimmed = extra.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = normalizedProjectLookupKey(trimmed)
            guard seen.insert(key).inserted else { continue }
            options.append(trimmed)
        }

        return options
    }

    nonisolated static func primaryProjectName() -> String {
        loadProjectNames()[0]
    }

    nonisolated static func secondaryProjectName() -> String {
        loadProjectNames()[1]
    }

    nonisolated static func fallbackProjectName() -> String {
        loadProjectNames()[2]
    }

    nonisolated static func sanitizeProjectName(_ name: String, fallbackIndex: Int = 2) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let names = loadProjectNames()
            let index = min(max(fallbackIndex, 0), names.count - 1)
            return names[index]
        }
        return trimmed
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

    private nonisolated static func normalizedProjectNames(_ names: [String]) -> [String] {
        let defaults = TaxSuiteWidgetSupport.defaultProjectNames
        let minCount = TaxSuiteWidgetSupport.minProjectCount
        let maxCount = TaxSuiteWidgetSupport.maxProjectCount

        var normalized: [String] = []
        var seen = Set<String>()

        // 入力された名前を先頭から順に詰めていく（空欄・重複はスキップ）
        for rawValue in names {
            if normalized.count >= maxCount { break }
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = normalizedProjectLookupKey(trimmed)
            guard seen.insert(key).inserted else { continue }
            normalized.append(trimmed)
        }

        // 最小件数に満たない分はデフォルト → 自動生成名で補う
        var autoIndex = 1
        while normalized.count < minCount {
            let position = normalized.count
            let fallback = defaults.indices.contains(position) ? defaults[position] : "プロジェクト\(position + 1)"
            let fallbackKey = normalizedProjectLookupKey(fallback)
            if seen.insert(fallbackKey).inserted {
                normalized.append(fallback)
                continue
            }

            // デフォルト名が既に使われている → 連番でユニーク名を合成
            while true {
                let generated = "プロジェクト\(autoIndex)"
                autoIndex += 1
                let generatedKey = normalizedProjectLookupKey(generated)
                if seen.insert(generatedKey).inserted {
                    normalized.append(generated)
                    break
                }
            }
        }

        return normalized
    }

    private nonisolated static func normalizedProjectLookupKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "ja_JP"))
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
