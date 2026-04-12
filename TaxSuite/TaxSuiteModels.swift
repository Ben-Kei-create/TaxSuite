import Foundation
import SwiftData

// MARK: - SwiftData Models

@Model
final class ExpenseItem {
    var timestamp: Date
    var title: String
    var amount: Double
    var category: String
    var project: String
    var businessRatio: Double
    var note: String
    var recurringExpenseID: String?

    init(
        timestamp: Date = Date(),
        title: String,
        amount: Double,
        category: String = "未分類",
        project: String = "その他",
        businessRatio: Double = 1.0,
        note: String = "",
        recurringExpenseID: String? = nil
    ) {
        self.timestamp = timestamp
        self.title = title
        self.amount = amount
        self.category = category
        self.project = project
        self.businessRatio = businessRatio
        self.note = note
        self.recurringExpenseID = recurringExpenseID
    }

    var effectiveAmount: Double { amount * businessRatio }
}

@Model
final class IncomeItem {
    var timestamp: Date
    var title: String
    var amount: Double
    var project: String

    init(timestamp: Date = Date(), title: String, amount: Double, project: String = "その他") {
        self.timestamp = timestamp
        self.title = title
        self.amount = amount
        self.project = project
    }
}

@Model
final class RecurringExpense {
    var title: String
    var amount: Double
    var project: String
    var dayOfMonth: Int
    var lastExecutedYear: Int
    var lastExecutedMonth: Int

    init(title: String, amount: Double, project: String, dayOfMonth: Int) {
        self.title = title
        self.amount = amount
        self.project = project
        self.dayOfMonth = dayOfMonth
        self.lastExecutedYear = 0
        self.lastExecutedMonth = 0
    }
}

extension RecurringExpense {
    var persistenceKey: String {
        if let data = try? JSONEncoder().encode(persistentModelID),
           let string = String(data: data, encoding: .utf8) {
            return string
        }

        return String(describing: persistentModelID)
    }

    func scheduledDate(in referenceDate: Date, calendar: Calendar = .current) -> Date {
        let safeDay = max(1, dayOfMonth)
        let maxDay = calendar.range(of: .day, in: .month, for: referenceDate)?.count ?? safeDay

        var components = calendar.dateComponents([.year, .month], from: referenceDate)
        components.day = min(safeDay, maxDay)

        return calendar.date(from: components) ?? referenceDate
    }
}

// MARK: - Mapping / Tax / Autofill

enum AccountingCategoryMapper {
    private nonisolated static let standardCategories: Set<String> = [
        "未分類",
        "通信費",
        "旅費交通費",
        "会議費",
        "消耗品費",
        "新聞図書費",
        "地代家賃",
        "福利厚生費",
        "外注費",
        "支払手数料"
    ]

    private nonisolated static let titleRules: [(keywords: [String], category: String)] = [
        (["aws", "gcp", "azure", "vps", "サーバー", "ドメイン", "domain", "回線", "wifi", "wi-fi", "ネット", "internet"], "通信費"),
        (["adobe", "figma", "notion", "chatgpt", "claude", "openai"], "通信費"),
        (["タクシー", "電車", "新幹線", "バス", "駐車", "高速", "ガソリン", "suica", "pasmo", "uber"], "旅費交通費"),
        (["カフェ", "スタバ", "喫茶", "coffee", "打ち合わせ", "会食", "ミーティング"], "会議費"),
        (["本", "書籍", "参考書", "雑誌", "新聞", "資料"], "新聞図書費"),
        (["家賃", "賃料", "スタジオ", "オフィス", "コワーキング", "coworking"], "地代家賃"),
        (["ノート", "ペン", "文具", "インク", "プリンタ", "マウス", "キーボード", "ケーブル", "アダプタ", "用紙"], "消耗品費")
    ]

    private nonisolated static let categoryAliases: [String: String] = [
        "交通費": "旅費交通費",
        "電車代": "旅費交通費",
        "タクシー代": "旅費交通費",
        "ネット代": "通信費",
        "回線代": "通信費",
        "サーバー代": "通信費",
        "ドメイン代": "通信費",
        "ソフトウェア": "通信費",
        "サブスク": "通信費",
        "家賃": "地代家賃",
        "スタジオ代": "地代家賃",
        "書籍代": "新聞図書費",
        "資料代": "新聞図書費",
        "固定費": "支払手数料"
    ]

    nonisolated static func category(forTitle title: String, userCategory: String) -> String {
        let normalizedTitle = normalized(title)
        for rule in titleRules where rule.keywords.contains(where: normalizedTitle.contains) {
            return rule.category
        }

        let trimmedCategory = userCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        if standardCategories.contains(trimmedCategory) {
            return trimmedCategory
        }

        let normalizedCategory = normalized(trimmedCategory)
        if let mapped = categoryAliases.first(where: { normalized($0.key) == normalizedCategory })?.value {
            return mapped
        }

        return trimmedCategory.isEmpty ? "未分類" : trimmedCategory
    }

    private nonisolated static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "　", with: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "ja_JP"))
    }
}

extension ExpenseItem {
    nonisolated var accountingCategory: String {
        AccountingCategoryMapper.category(forTitle: title, userCategory: category)
    }

    nonisolated var isSubscription: Bool {
        recurringExpenseID != nil
    }
}

struct TaxCalculator {
    nonisolated static func calculateTax(revenue: Double, expenses: Double, taxRate: Double) -> Double {
        let taxableIncome = max(0, revenue - expenses)
        return taxableIncome * taxRate
    }

    nonisolated static func calculateTakeHome(revenue: Double, expenses: Double, taxRate: Double) -> Double {
        let taxableIncome = max(0, revenue - expenses)
        return revenue - expenses - (taxableIncome * taxRate)
    }
}

struct ExpenseAutofillSuggestion: Equatable {
    let category: String?
    let project: String?
    let matchedTitle: String?
}

enum ExpenseAutofillPredictor {
    static let defaultCategories = [
        "未分類",
        "交通費",
        "会議費",
        "福利厚生費",
        "消耗品費",
        "通信費",
        "ソフトウェア",
        "外注費",
        "固定費"
    ]

    static let defaultProjects = ["エンジニア業", "講師業", "その他"]

    private static let keywordRules: [(keywords: [String], category: String)] = [
        (["電車", "タクシー", "新幹線", "バス", "駐車", "ガソリン"], "交通費"),
        (["カフェ", "喫茶", "打ち合わせ", "会食"], "会議費"),
        (["昼食", "弁当", "ランチ"], "福利厚生費"),
        (["消耗品", "文具", "ノート", "ペン", "インク"], "消耗品費"),
        (["adobe", "figma", "notion", "chatgpt", "claude"], "ソフトウェア"),
        (["サーバー", "aws", "gcp", "vps", "ドメイン", "回線"], "通信費")
    ]

    static func categoryOptions(from history: [ExpenseItem]) -> [String] {
        mergedOptions(defaultCategories, history.map(\.category))
    }

    static func projectOptions(from history: [ExpenseItem]) -> [String] {
        mergedOptions(defaultProjects, history.map(\.project))
    }

    static func predict(for title: String, from history: [ExpenseItem]) -> ExpenseAutofillSuggestion? {
        let normalizedTitle = normalized(title)
        guard !normalizedTitle.isEmpty else { return nil }

        var categoryScores: [String: Double] = [:]
        var projectScores: [String: Double] = [:]
        var bestMatchedTitle: String?
        var bestMatchScore = 0.0
        let now = Date()

        for expense in history where expense.recurringExpenseID == nil {
            let candidateTitle = normalized(expense.title)
            let baseScore = similarityScore(for: normalizedTitle, candidate: candidateTitle)
            guard baseScore > 0 else { continue }

            let daysAgo = max(0, Calendar.current.dateComponents([.day], from: expense.timestamp, to: now).day ?? 0)
            let recencyWeight = max(0.35, 1.15 - min(Double(daysAgo) / 365.0, 0.8))
            let score = baseScore * recencyWeight

            categoryScores[expense.category, default: 0] += score
            projectScores[expense.project, default: 0] += score

            if score > bestMatchScore {
                bestMatchScore = score
                bestMatchedTitle = expense.title
            }
        }

        if categoryScores.isEmpty && projectScores.isEmpty {
            return fallbackSuggestion(for: normalizedTitle)
        }

        return ExpenseAutofillSuggestion(
            category: bestMatch(in: categoryScores) ?? fallbackSuggestion(for: normalizedTitle)?.category,
            project: bestMatch(in: projectScores),
            matchedTitle: bestMatchedTitle
        )
    }

    private static func mergedOptions(_ preferred: [String], _ extras: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for option in preferred + extras {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            ordered.append(trimmed)
        }

        return ordered
    }

    private static func bestMatch(in scores: [String: Double]) -> String? {
        scores.max { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key > rhs.key
            }
            return lhs.value < rhs.value
        }?.key
    }

    private static func fallbackSuggestion(for normalizedTitle: String) -> ExpenseAutofillSuggestion? {
        guard let rule = keywordRules.first(where: { rule in
            rule.keywords.contains { normalizedTitle.contains(normalized($0)) }
        }) else {
            return nil
        }

        return ExpenseAutofillSuggestion(category: rule.category, project: nil, matchedTitle: nil)
    }

    private static func similarityScore(for query: String, candidate: String) -> Double {
        guard !query.isEmpty, !candidate.isEmpty else { return 0 }
        if query == candidate { return 5.0 }
        if query.contains(candidate) || candidate.contains(query) { return 3.5 }

        let sharedTokens = keywords(in: query).intersection(keywords(in: candidate))
        if !sharedTokens.isEmpty {
            return 2.0 + (Double(sharedTokens.count) * 0.25)
        }

        return 0
    }

    private static func keywords(in value: String) -> Set<String> {
        let normalizedValue = normalized(value)
        guard !normalizedValue.isEmpty else { return [] }
        let maximumLength = min(4, normalizedValue.count)
        guard maximumLength >= 2 else { return [normalizedValue] }

        var tokens = Set<String>()
        for length in 2...maximumLength {
            guard normalizedValue.count >= length else { continue }
            for index in 0...(normalizedValue.count - length) {
                let start = normalizedValue.index(normalizedValue.startIndex, offsetBy: index)
                let end = normalizedValue.index(start, offsetBy: length)
                tokens.insert(String(normalizedValue[start..<end]))
            }
        }

        return tokens
    }

    private static func normalized(_ value: String) -> String {
        let strippedCharacters = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)

        return value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "ja_JP"))
            .replacingOccurrences(of: "（自動）", with: "")
            .replacingOccurrences(of: "(自動)", with: "")
            .components(separatedBy: strippedCharacters)
            .joined()
            .lowercased()
    }
}

enum AnalyticsRange: String, CaseIterable, Identifiable {
    case day = "日"
    case week = "週"
    case month = "月"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day:
            return "今日"
        case .week:
            return "今週"
        case .month:
            return "今月"
        }
    }

    func contains(_ date: Date, reference: Date, calendar: Calendar = .current) -> Bool {
        switch self {
        case .day:
            return calendar.isDate(date, inSameDayAs: reference)
        case .week:
            return calendar.isDate(date, equalTo: reference, toGranularity: .weekOfYear)
        case .month:
            return calendar.isDate(date, equalTo: reference, toGranularity: .month)
        }
    }
}

enum AnalyticsChartStyle: String, CaseIterable, Identifiable {
    case bar = "棒グラフ"
    case donut = "ドーナツ"

    var id: String { rawValue }
}

struct QuickExpenseTemplate: Identifiable, Equatable {
    let id: String
    let title: String
    let amount: Double
    let category: String
    let project: String
    let note: String
}

enum ExpenseCommentTemplate {
    private static let samples: [String: [String]] = [
        "未分類": ["仕事用の支出", "あとで分類を見直す用メモ"],
        "交通費": ["打ち合わせ先への移動", "現地訪問の往復分"],
        "会議費": ["打ち合わせ用のドリンク代", "商談前のカフェ利用"],
        "福利厚生費": ["作業中の昼食代", "長時間作業時の軽食"],
        "消耗品費": ["仕事用の備品補充", "デスク周りの消耗品購入"],
        "通信費": ["業務ツールの月額利用", "サーバー / 回線の利用料"],
        "ソフトウェア": ["制作ツールのサブスク", "業務アプリの利用料"],
        "外注費": ["制作の外部依頼分", "サポート業務の委託費"],
        "固定費": ["毎月の定額支出", "継続契約中の費用メモ"]
    ]

    static func samples(for category: String) -> [String] {
        samples[category] ?? samples["未分類"] ?? []
    }
}

// MARK: - Export / Report Support

struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct SharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
    let subject: String?
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case standard = "標準（TaxSuite形式）"
    case freee = "freee"
    case moneyForward = "マネーフォワード"

    nonisolated var id: String { rawValue }

    nonisolated var subtitle: String {
        switch self {
        case .standard:
            return "TaxSuite の全項目をそのままバックアップ形式で出力"
        case .freee:
            return "収入 / 支出ベースで freee に取り込みやすい形式"
        case .moneyForward:
            return "借方 / 貸方を分けた仕訳帳ベースの形式"
        }
    }

    nonisolated var fileStem: String {
        switch self {
        case .standard:
            return "standard"
        case .freee:
            return "freee"
        case .moneyForward:
            return "moneyforward"
        }
    }

    var previewSummary: String {
        switch self {
        case .standard:
            return "標準形式では、入力したカテゴリをそのままバックアップ用のCSVに出力します。"
        case .freee:
            return "freee 向けでは、TaxSuite が項目名とカテゴリから勘定科目を整えて書き出します。"
        case .moneyForward:
            return "マネーフォワード向けでは、仕訳帳形式に合わせて勘定科目を整理して書き出します。"
        }
    }

    var usesAccountingCategoryMapping: Bool {
        self != .standard
    }
}

enum ReportType: String, CaseIterable, Identifiable {
    case monthly = "月次報告"
    case taxFiling = "確定申告の共有"
    case documentShare = "資料共有"

    nonisolated var id: String { rawValue }

    nonisolated var subtitle: String {
        switch self {
        case .monthly:
            return "毎月の数字とCSVを、そのまま共有する定番フロー"
        case .taxFiling:
            return "申告期のまとめ資料として、少し丁寧な件名と本文で出力"
        case .documentShare:
            return "まずは資料だけ送りたいときのシンプルな下書き"
        }
    }

    nonisolated func subject(for monthLabel: String, businessName: String) -> String {
        let prefix = businessName.isEmpty ? "TaxSuite" : businessName

        switch self {
        case .monthly:
            return "[\(prefix)] \(monthLabel)分 月次資料のご共有"
        case .taxFiling:
            return "[\(prefix)] \(monthLabel)分 申告資料のご共有"
        case .documentShare:
            return "[\(prefix)] \(monthLabel)分 資料共有"
        }
    }

    nonisolated func introLine(monthLabel: String) -> String {
        switch self {
        case .monthly:
            return "\(monthLabel)分の月次資料をお送りします。"
        case .taxFiling:
            return "\(monthLabel)分の申告関連資料を共有いたします。"
        case .documentShare:
            return "\(monthLabel)分の資料を共有いたします。"
        }
    }
}

struct ReportDraftPackage {
    let subject: String
    let body: String
    let attachments: [URL]

    var attachmentNames: [String] {
        attachments.map(\.lastPathComponent)
    }
}

struct ReportDraftPreview {
    let subject: String
    let body: String
    let attachmentName: String
    let revenueTotal: Double
    let expenseTotal: Double
    let takeHomeTotal: Double
    let incomeCount: Int
    let expenseCount: Int
}

enum ReportDraftBuilder {
    nonisolated static func preview(
        expenses: [ExpenseItem],
        incomes: [IncomeItem],
        format: ExportFormat,
        reportType: ReportType,
        advisorName: String,
        senderName: String,
        businessName: String,
        targetMonth: Date,
        note: String,
        taxRate: Double
    ) -> ReportDraftPreview {
        let monthExpenses = filtered(expenses: expenses, in: targetMonth)
        let monthIncomes = filtered(incomes: incomes, in: targetMonth)
        let monthLabel = monthString(for: targetMonth)
        let subject = reportType.subject(for: monthLabel, businessName: businessName)
        let attachmentName = attachmentFileName(for: format, targetMonth: targetMonth)
        let revenueTotal = monthIncomes.reduce(0) { $0 + $1.amount }
        let expenseTotal = monthExpenses.reduce(0) { $0 + $1.effectiveAmount }
        let takeHome = TaxCalculator.calculateTakeHome(revenue: revenueTotal, expenses: expenseTotal, taxRate: taxRate)
        let advisorLine = advisorName.isEmpty ? "ご担当者さま" : "\(advisorName)さま"
        let senderLine = senderName.isEmpty ? "TaxSuite ユーザー" : senderName
        let businessLine = businessName.isEmpty ? "" : "\(businessName)\n"
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteSection = trimmedNote.isEmpty ? "" : "\n補足:\n\(trimmedNote)\n"

        let body = """
        \(advisorLine)

        いつもお世話になっております。
        \(businessLine)\(senderLine)です。

        \(reportType.introLine(monthLabel: monthLabel))

        対象月: \(monthLabel)
        売上合計: ¥\(Int(revenueTotal).formatted())
        経費合計: ¥\(Int(expenseTotal).formatted())
        推定手取り: ¥\(Int(takeHome).formatted())

        添付資料:
        ・\(attachmentName)
        \(noteSection)
        ご確認のほど、よろしくお願いいたします。
        """

        return ReportDraftPreview(
            subject: subject,
            body: body,
            attachmentName: attachmentName,
            revenueTotal: revenueTotal,
            expenseTotal: expenseTotal,
            takeHomeTotal: takeHome,
            incomeCount: monthIncomes.count,
            expenseCount: monthExpenses.count
        )
    }

    nonisolated static func makeDraft(
        expenses: [ExpenseItem],
        incomes: [IncomeItem],
        format: ExportFormat,
        reportType: ReportType,
        advisorName: String,
        senderName: String,
        businessName: String,
        targetMonth: Date,
        note: String,
        taxRate: Double
    ) throws -> ReportDraftPackage {
        let preview = preview(
            expenses: expenses,
            incomes: incomes,
            format: format,
            reportType: reportType,
            advisorName: advisorName,
            senderName: senderName,
            businessName: businessName,
            targetMonth: targetMonth,
            note: note,
            taxRate: taxRate
        )
        let monthExpenses = filtered(expenses: expenses, in: targetMonth)
        let monthIncomes = filtered(incomes: incomes, in: targetMonth)
        let fileName = attachmentFileName(for: format, targetMonth: targetMonth)
        let attachment = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        let csv = CSVExporter.generateCSV(expenses: monthExpenses, incomes: monthIncomes, format: format)
        try csv.write(to: attachment, atomically: true, encoding: .utf8)
        return ReportDraftPackage(subject: preview.subject, body: preview.body, attachments: [attachment])
    }

    private nonisolated static func filtered(expenses: [ExpenseItem], in month: Date) -> [ExpenseItem] {
        let calendar = Calendar.current
        return expenses.filter { calendar.isDate($0.timestamp, equalTo: month, toGranularity: .month) }
    }

    private nonisolated static func filtered(incomes: [IncomeItem], in month: Date) -> [IncomeItem] {
        let calendar = Calendar.current
        return incomes.filter { calendar.isDate($0.timestamp, equalTo: month, toGranularity: .month) }
    }

    private nonisolated static func monthString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy年M月"
        return formatter.string(from: date)
    }

    private nonisolated static func attachmentFileName(for format: ExportFormat, targetMonth: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return "TaxSuite-\(format.fileStem)-\(formatter.string(from: targetMonth)).csv"
    }
}

struct CSVExporter {
    nonisolated static func export(expenses: [ExpenseItem], incomes: [IncomeItem], format: ExportFormat) throws -> URL {
        let csv = generateCSV(expenses: expenses, incomes: incomes, format: format)
        let fileName = "TaxSuite-\(format.fileStem)-\(timestampString(for: Date())).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        try csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    nonisolated static func generateCSV(expenses: [ExpenseItem], incomes: [IncomeItem], format: ExportFormat) -> String {
        switch format {
        case .standard:
            return generateStandardCSV(expenses: expenses, incomes: incomes)
        case .freee:
            return generateFreeeCSV(expenses: expenses, incomes: incomes)
        case .moneyForward:
            return generateMoneyForwardCSV(expenses: expenses, incomes: incomes)
        }
    }

    private nonisolated static func generateStandardCSV(expenses: [ExpenseItem], incomes: [IncomeItem]) -> String {
        var lines = [[
            "record_type",
            "date",
            "title",
            "amount",
            "category",
            "project",
            "business_ratio",
            "effective_amount",
            "note",
            "is_recurring_auto"
        ].joined(separator: ",")]

        for expense in expenses.sorted(by: { $0.timestamp < $1.timestamp }) {
            lines.append([
                "expense",
                dateString(from: expense.timestamp),
                csvField(expense.title),
                csvField(String(Int(expense.amount))),
                csvField(expense.category),
                csvField(expense.project),
                csvField(String(format: "%.2f", expense.businessRatio)),
                csvField(String(Int(expense.effectiveAmount))),
                csvField(expense.note),
                csvField(expense.recurringExpenseID == nil ? "false" : "true")
            ].joined(separator: ","))
        }

        for income in incomes.sorted(by: { $0.timestamp < $1.timestamp }) {
            lines.append([
                "income",
                dateString(from: income.timestamp),
                csvField(income.title),
                csvField(String(Int(income.amount))),
                csvField(""),
                csvField(income.project),
                csvField("1.00"),
                csvField(String(Int(income.amount))),
                csvField(""),
                csvField("false")
            ].joined(separator: ","))
        }

        return lines.joined(separator: "\n")
    }

    private nonisolated static func generateFreeeCSV(expenses: [ExpenseItem], incomes: [IncomeItem]) -> String {
        var rows: [(Date, String)] = []

        for expense in expenses {
            let memo = expense.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? expense.title
                : "\(expense.title) / \(expense.note)"
            let line = [
                "支出",
                dateString(from: expense.timestamp),
                csvField(expense.accountingCategory),
                csvField(String(Int(expense.effectiveAmount))),
                csvField(expense.project),
                csvField(memo)
            ].joined(separator: ",")
            rows.append((expense.timestamp, line))
        }

        for income in incomes {
            let line = [
                "収入",
                dateString(from: income.timestamp),
                "売上高",
                csvField(String(Int(income.amount))),
                csvField(income.project),
                csvField(income.title)
            ].joined(separator: ",")
            rows.append((income.timestamp, line))
        }

        let lines = ["収支区分,発生日,勘定科目,金額,品目,備考"] + rows.sorted(by: sortRows).map(\.1)
        return lines.joined(separator: "\n")
    }

    private nonisolated static func generateMoneyForwardCSV(expenses: [ExpenseItem], incomes: [IncomeItem]) -> String {
        var rows: [(Date, String)] = []

        for expense in expenses {
            let amount = String(Int(expense.effectiveAmount))
            let noteSuffix = expense.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : " / \(expense.note)"
            let memo = "\(expense.title) [\(expense.project)]\(noteSuffix)"
            let line = [
                dateString(from: expense.timestamp),
                csvField(expense.accountingCategory),
                csvField(amount),
                "事業主借",
                csvField(amount),
                csvField(memo)
            ].joined(separator: ",")
            rows.append((expense.timestamp, line))
        }

        for income in incomes {
            let amount = String(Int(income.amount))
            let memo = "\(income.title) [\(income.project)]"
            let line = [
                dateString(from: income.timestamp),
                "事業主貸",
                csvField(amount),
                "売上高",
                csvField(amount),
                csvField(memo)
            ].joined(separator: ",")
            rows.append((income.timestamp, line))
        }

        let lines = ["日付,借方勘定科目,借方金額,貸方勘定科目,貸方金額,摘要"] + rows.sorted(by: sortRows).map(\.1)
        return lines.joined(separator: "\n")
    }

    private nonisolated static func dateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private nonisolated static func csvField(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private nonisolated static func sortRows(lhs: (Date, String), rhs: (Date, String)) -> Bool {
        if lhs.0 == rhs.0 {
            return lhs.1 < rhs.1
        }
        return lhs.0 < rhs.0
    }

    private nonisolated static func timestampString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

// MARK: - Glossary Support

private struct GlossaryTermsPayload: Decodable {
    let version: Int
    let language: String
    let terms: [GlossaryTerm]
}

private final class GlossaryBundleMarker {}

struct GlossaryTerm: Identifiable, Hashable, Decodable {
    enum Category: String, CaseIterable, Hashable, Decodable {
        case tax
        case bookkeeping
        case investment

        var displayName: String {
            switch self {
            case .tax:
                return "税の基本"
            case .bookkeeping:
                return "記録と申告"
            case .investment:
                return "投資の基本"
            }
        }
    }

    let id: String
    let title: String
    let category: Category
    let summary: String
    let detail: String

    static let sampleTerms: [GlossaryTerm] = loadTerms()

    private static func loadTerms() -> [GlossaryTerm] {
        let bundles = [Bundle.main, Bundle(for: GlossaryBundleMarker.self)]

        for bundle in bundles {
            guard let url = bundle.url(forResource: "GlossaryTerms", withExtension: "json") else {
                continue
            }

            do {
                let data = try Data(contentsOf: url)
                let payload = try JSONDecoder().decode(GlossaryTermsPayload.self, from: data)
                return payload.terms
            } catch {
                print("Failed to decode GlossaryTerms.json: \(error)")
            }
        }

        return []
    }
}

// MARK: - View Support Data

struct CategorySum: Identifiable, Equatable {
    let name: String
    let total: Double
    let subscriptionTotal: Double

    var id: String { name }
}

struct ReceiptBatchDraft: Identifiable {
    let id = UUID()
    var title: String = ""
    var amountText: String = ""
    var category: String = "未分類"
    var project: String = "その他"
    var note: String = ""
}
