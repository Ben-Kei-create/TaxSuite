import SwiftUI
import SwiftData
import Charts

// MARK: - データモデル
@Model
final class ExpenseItem {
    var timestamp: Date
    var title: String
    var amount: Double
    var category: String
    var project: String
    var businessRatio: Double
    var recurringExpenseID: String?

    init(timestamp: Date = Date(), title: String, amount: Double, category: String = "未分類", project: String = "その他", businessRatio: Double = 1.0, recurringExpenseID: String? = nil) {
        self.timestamp = timestamp
        self.title = title
        self.amount = amount
        self.category = category
        self.project = project
        self.businessRatio = businessRatio
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
    var title: String; var amount: Double; var project: String; var dayOfMonth: Int; var lastExecutedYear: Int; var lastExecutedMonth: Int
    init(title: String, amount: Double, project: String, dayOfMonth: Int) {
        self.title = title; self.amount = amount; self.project = project; self.dayOfMonth = dayOfMonth; self.lastExecutedYear = 0; self.lastExecutedMonth = 0
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
}

// MARK: - Helper: 計算ロジック
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

extension View {
    func taxSuiteAmountStyle(size: CGFloat, weight: Font.Weight = .semibold, tracking: CGFloat = 0) -> some View {
        self
            .font(.system(size: size, weight: weight, design: .rounded))
            .monospacedDigit()
            .tracking(tracking)
    }

    func taxSuiteHeroAmountStyle() -> some View {
        taxSuiteAmountStyle(size: 48, weight: .bold, tracking: -1.2)
    }

    func taxSuiteSectionHeadingStyle() -> some View {
        self
            .font(.title3)
            .fontWeight(.heavy)
            .foregroundColor(.primary)
    }

    func taxSuiteListHeaderStyle() -> some View {
        self
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)
    }
}

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

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    var subject: String? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        if let subject {
            controller.setValue(subject, forKey: "subject")
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
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
        var lines = [
            [
                "record_type",
                "date",
                "title",
                "amount",
                "category",
                "project",
                "business_ratio",
                "effective_amount",
                "is_recurring_auto"
            ].joined(separator: ",")
        ]

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
                csvField("false")
            ].joined(separator: ","))
        }

        return lines.joined(separator: "\n")
    }

    private nonisolated static func generateFreeeCSV(expenses: [ExpenseItem], incomes: [IncomeItem]) -> String {
        var rows: [(Date, String)] = []

        for expense in expenses {
            let line = [
                "支出",
                dateString(from: expense.timestamp),
                csvField(expense.accountingCategory),
                csvField(String(Int(expense.effectiveAmount))),
                csvField(expense.project),
                csvField(expense.title)
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
            let memo = "\(expense.title) [\(expense.project)]"
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

struct GlossaryTerm: Identifiable, Hashable {
    enum Category: String, CaseIterable, Hashable {
        case tax = "税の基本"
        case bookkeeping = "記録と申告"
        case investment = "投資の基本"
    }

    let id: String
    let title: String
    let category: Category
    let summary: String
    let detail: String

    static let sampleTerms: [GlossaryTerm] = [
        GlossaryTerm(
            id: "kakutei-shinkoku",
            title: "確定申告",
            category: .tax,
            summary: "1年間の所得と税額をまとめて申告する手続きです。",
            detail: "個人事業主や副業の収入がある人が、1月1日から12月31日までの所得を整理して税額を確定させる手続きです。TaxSuiteに記録した売上や経費は、この整理の土台になります。"
        ),
        GlossaryTerm(
            id: "keihi",
            title: "経費",
            category: .tax,
            summary: "仕事のために使ったお金のうち、事業に必要な支出です。",
            detail: "売上を得るために必要だった支出は経費として扱えます。プライベートと混ざるものは、家事按分で事業分だけを計上するのが基本です。"
        ),
        GlossaryTerm(
            id: "kaji-anbun",
            title: "家事按分",
            category: .bookkeeping,
            summary: "仕事と私用が混ざる支出を、事業分だけに分ける考え方です。",
            detail: "通信費や家賃の一部など、事業と私生活の両方で使う支出は、そのまま全額を経費にはできません。TaxSuiteの事業割合スライダーで、事業に使った比率だけを管理できます。"
        ),
        GlossaryTerm(
            id: "aoiro-shinkoku",
            title: "青色申告",
            category: .bookkeeping,
            summary: "一定の帳簿付けを行うことで特典を受けられる申告方式です。",
            detail: "複式簿記や期限内申告などの条件を満たすと、青色申告特別控除などのメリットがあります。日々の記録を整えておくほど有利になりやすい制度です。"
        ),
        GlossaryTerm(
            id: "genka-shokyaku",
            title: "減価償却",
            category: .bookkeeping,
            summary: "高額な資産の購入費を、複数年に分けて経費化する考え方です。",
            detail: "パソコンやカメラのように長く使うものは、一度に全額を経費にせず、耐用年数に応じて少しずつ費用化する場合があります。"
        ),
        GlossaryTerm(
            id: "nisa",
            title: "NISA",
            category: .investment,
            summary: "一定額までの投資利益が非課税になる制度です。",
            detail: "つみたて投資枠や成長投資枠を使って、運用益や配当金にかかる税金を抑えながら投資できます。税の基本と投資を一緒に学ぶ入口として人気があります。"
        ),
        GlossaryTerm(
            id: "index-toshi",
            title: "インデックス投資",
            category: .investment,
            summary: "市場全体の値動きに連動することを目指す投資方法です。",
            detail: "日経平均やS&P500のような指数に連動する商品へ分散して投資する考え方です。長期・積立・分散の基本と相性が良い手法です。"
        ),
        GlossaryTerm(
            id: "haito-rimawari",
            title: "配当利回り",
            category: .investment,
            summary: "株価に対して、年間配当がどれくらいかを示す目安です。",
            detail: "配当金の多さを比較するときの参考指標ですが、高いほど安全とは限りません。値上がり益や企業の安定性と合わせて見るのが大切です。"
        )
    ]
}

// MARK: - App Root
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @AppStorage("taxRate") private var taxRate: Double = 0.2
    
    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView(taxRate: $taxRate).tabItem { Label("ホーム", systemImage: "house.fill") }.tag(0)
            CalendarHistoryView().tabItem { Label("カレンダー", systemImage: "calendar") }.tag(1)
            AnalyticsView().tabItem { Label("分析", systemImage: "chart.pie.fill") }.tag(2)
            SettingsView(taxRate: $taxRate).tabItem { Label("設定", systemImage: "gearshape.fill") }.tag(3)
        }
        .accentColor(.black)
        .task {
            checkAndAddRecurringExpenses()
            refreshWidgetSnapshot()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            checkAndAddRecurringExpenses()
            refreshWidgetSnapshot()
        }
    }

    @MainActor
    private func checkAndAddRecurringExpenses() {
        let recurringDescriptor = FetchDescriptor<RecurringExpense>()
        guard let recurringExpenses = try? modelContext.fetch(recurringDescriptor), !recurringExpenses.isEmpty else { return }

        let calendar = Calendar.current
        let now = Date()
        let currentMonth = calendar.component(.month, from: now)
        let currentYear = calendar.component(.year, from: now)
        var hasChanges = false

        for recurring in recurringExpenses {
            let recurringIDString = recurring.persistenceKey
            let expenseDescriptor = FetchDescriptor<ExpenseItem>(
                predicate: #Predicate { expense in
                    expense.recurringExpenseID == recurringIDString
                }
            )

            guard let createdExpenses = try? modelContext.fetch(expenseDescriptor) else { continue }

            let alreadyAddedThisMonth = createdExpenses.contains { expense in
                let expenseMonth = calendar.component(.month, from: expense.timestamp)
                let expenseYear = calendar.component(.year, from: expense.timestamp)
                return expenseMonth == currentMonth && expenseYear == currentYear
            }

            guard !alreadyAddedThisMonth else { continue }

            let autoExpense = ExpenseItem(
                timestamp: recurring.scheduledDate(in: now, calendar: calendar),
                title: recurring.title + " (自動)",
                amount: recurring.amount,
                category: "固定費",
                project: recurring.project,
                businessRatio: 1.0,
                recurringExpenseID: recurringIDString
            )
            modelContext.insert(autoExpense)
            hasChanges = true
        }

        if hasChanges {
            try? modelContext.save()
        }
    }

    @MainActor
    private func refreshWidgetSnapshot() {
        let expenseDescriptor = FetchDescriptor<ExpenseItem>()
        let incomeDescriptor = FetchDescriptor<IncomeItem>()
        guard
            let expenses = try? modelContext.fetch(expenseDescriptor),
            let incomes = try? modelContext.fetch(incomeDescriptor)
        else { return }

        let snapshot = TaxSuiteWidgetStore.makeSnapshot(
            expenses: expenses,
            incomes: incomes,
            taxRate: taxRate
        )
        TaxSuiteWidgetStore.save(snapshot: snapshot)
    }
}

// MARK: - Tab 1: DashboardView
struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allExpenses: [ExpenseItem]
    @Query private var allIncomes: [IncomeItem]
    
    @Query(filter: DashboardView.todayPredicate, sort: \ExpenseItem.timestamp, order: .reverse)
    private var todayExpenses: [ExpenseItem]
    
    @Binding var taxRate: Double
    
    @State private var showingExpenseSheet = false
    @State private var showingIncomeSheet = false
    @State private var editingExpense: ExpenseItem?
    
    @State private var draftTitle: String = ""
    @State private var draftAmount: String = ""
    
    var currentMonthRevenue: Double {
        let calendar = Calendar.current
        let now = Date()
        return allIncomes.filter { calendar.isDate($0.timestamp, equalTo: now, toGranularity: .month) }.reduce(0) { $0 + $1.amount }
    }
    
    var currentMonthExpense: Double {
        let calendar = Calendar.current
        let now = Date()
        return allExpenses.filter { calendar.isDate($0.timestamp, equalTo: now, toGranularity: .month) }.reduce(0) { $0 + $1.effectiveAmount }
    }
    
    var estimatedTax: Double { TaxCalculator.calculateTax(revenue: currentMonthRevenue, expenses: currentMonthExpense, taxRate: taxRate) }
    var takeHome: Double { TaxCalculator.calculateTakeHome(revenue: currentMonthRevenue, expenses: currentMonthExpense, taxRate: taxRate) }

    var widgetSnapshotFingerprint: String {
        let latestExpense = allExpenses.map(\.timestamp).max()?.timeIntervalSince1970 ?? 0
        let latestIncome = allIncomes.map(\.timestamp).max()?.timeIntervalSince1970 ?? 0
        let todayTotal = todayExpenses.reduce(0) { $0 + $1.effectiveAmount }

        return [
            String(format: "%.2f", currentMonthRevenue),
            String(format: "%.2f", currentMonthExpense),
            String(format: "%.2f", estimatedTax),
            String(format: "%.2f", takeHome),
            String(format: "%.2f", todayTotal),
            String(todayExpenses.count),
            String(allExpenses.count),
            String(allIncomes.count),
            String(latestExpense),
            String(latestIncome),
            String(format: "%.2f", taxRate)
        ].joined(separator: "|")
    }
    
    static var todayPredicate: Predicate<ExpenseItem> {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return #Predicate<ExpenseItem> { item in item.timestamp >= start && item.timestamp < end }
    }
    
    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                Color(white: 0.97).ignoresSafeArea()
                
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 32) {
                        mainMetricCard
                        adBannerSection
                        quickAddSection
                        todayExpensesSection
                        Spacer().frame(height: 96)
                    }.padding(.vertical, 24)
                }
                
                Menu {
                    Button(action: { showingIncomeSheet = true }) { Label("売上を記録", systemImage: "arrow.down.circle.fill") }
                    Button(action: { openNewExpenseSheet() }) { Label("経費を記録", systemImage: "arrow.up.circle.fill") }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 60, height: 60)
                        .background(Color.black)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 4)
                }
                .padding(.trailing, 20).padding(.bottom, 20)
            }
            .navigationTitle("ダッシュボード")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingExpenseSheet) { ExpenseEditView(expense: nil, initialTitle: draftTitle, initialAmount: draftAmount) }
            .sheet(isPresented: $showingIncomeSheet) { IncomeEditView() }
            .sheet(item: $editingExpense) { expense in ExpenseEditView(expense: expense) }
            .task {
                syncWidgetSnapshot()
            }
            .onChange(of: widgetSnapshotFingerprint) { _, _ in
                syncWidgetSnapshot()
            }
        }
    }
    
    private func openNewExpenseSheet() { draftTitle = ""; draftAmount = ""; showingExpenseSheet = true }
    private func openDraftSheet(title: String, amount: Double) { draftTitle = title; draftAmount = String(Int(amount)); showingExpenseSheet = true }
    
    private var mainMetricCard: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("今月の推定手取り").font(.subheadline).foregroundColor(.gray)
                Text("¥\(Int(takeHome).formatted())")
                    .taxSuiteHeroAmountStyle()
                    .foregroundColor(.black)
            }.padding(.top, 24)
            Divider().padding(.horizontal, 24)
            HStack(spacing: 0) {
                metricItem(title: "今月の売上", value: currentMonthRevenue, valueColor: .blue)
                Divider().frame(height: 30)
                metricItem(title: "経費(按分後)", value: currentMonthExpense)
                Divider().frame(height: 30)
                metricItem(title: "推定税額", value: estimatedTax, valueColor: .red.opacity(0.8))
            }.padding(.bottom, 24)
        }.background(Color.white).cornerRadius(24).shadow(color: .black.opacity(0.04), radius: 12, x: 0, y: 6).padding(.horizontal, 20)
    }
    
    private func metricItem(title: String, value: Double, valueColor: Color = .black) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.caption).foregroundColor(.gray)
            Text("¥\(Int(value).formatted())")
                .taxSuiteAmountStyle(size: 17, weight: .semibold, tracking: -0.2)
                .foregroundColor(valueColor)
        }
        .frame(maxWidth: .infinity)
    }

    private var adBannerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("スポンサー")
                .font(.caption)
                .foregroundColor(.gray)
                .padding(.horizontal, 24)

            HStack {
                Spacer()
                AdBannerView()
                    .frame(height: 50)
                Spacer()
            }
            .padding(.vertical, 12)
            .background(Color.white)
            .cornerRadius(18)
            .shadow(color: .black.opacity(0.03), radius: 8, x: 0, y: 4)
            .padding(.horizontal, 20)
        }
    }
    
    private var quickAddSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("クイック入力")
                    .taxSuiteSectionHeadingStyle()
                Text("長押しで詳細")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 4)

            HStack(spacing: 12) {
                QuickAddButton(icon: "🚃", title: "電車", amount: 180, onTap: { addExpense("電車", 180, "交通費") }, onLongPress: { openDraftSheet(title: "電車", amount: 180) })
                QuickAddButton(icon: "☕️", title: "カフェ", amount: 600, onTap: { addExpense("カフェ", 600, "会議費") }, onLongPress: { openDraftSheet(title: "カフェ", amount: 600) })
                QuickAddButton(icon: "🍱", title: "昼食", amount: 1000, onTap: { addExpense("昼食", 1000, "福利厚生費") }, onLongPress: { openDraftSheet(title: "昼食", amount: 1000) })
                QuickAddButton(icon: "🖊", title: "消耗品", amount: 1500, onTap: { addExpense("消耗品", 1500, "消耗品費") }, onLongPress: { openDraftSheet(title: "消耗品", amount: 1500) })
            }.padding(.horizontal, 20)
        }
    }
    
    private var todayExpensesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("本日の経費")
                .taxSuiteSectionHeadingStyle()
                .padding(.horizontal, 24)
                .padding(.bottom, 4)
            if todayExpenses.isEmpty { Text("本日の記録はありません").font(.subheadline).foregroundColor(.gray).frame(maxWidth: .infinity, alignment: .center).padding(.top, 20)
            } else {
                VStack(spacing: 10) {
                    ForEach(todayExpenses) { expense in
                        Button(action: { editingExpense = expense }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(expense.title).font(.body).bold().foregroundColor(.black)
                                    HStack {
                                        Text(expense.project).font(.caption2).foregroundColor(.gray).padding(.horizontal, 8).padding(.vertical, 4).background(Color.gray.opacity(0.1)).cornerRadius(6)
                                        if expense.businessRatio < 1.0 { Text("事業割合: \(Int(expense.businessRatio * 100))%").font(.caption2).foregroundColor(.orange).padding(.horizontal, 8).padding(.vertical, 4).background(Color.orange.opacity(0.1)).cornerRadius(6) }
                                    }
                                }
                                Spacer()
                                VStack(alignment: .trailing) {
                                    Text("¥\(Int(expense.effectiveAmount).formatted())")
                                        .taxSuiteAmountStyle(size: 17, weight: .semibold, tracking: -0.2)
                                        .foregroundColor(.black)
                                    if expense.businessRatio < 1.0 {
                                        Text("全体: ¥\(Int(expense.amount))")
                                            .font(.caption2)
                                            .monospacedDigit()
                                            .foregroundColor(.gray)
                                    }
                                }
                            }.padding(16).background(Color.white).cornerRadius(16).shadow(color: .black.opacity(0.02), radius: 4, x: 0, y: 2)
                        }
                    }
                }.padding(.horizontal, 20)
            }
        }
    }
    
    private func addExpense(_ title: String, _ amount: Double, _ category: String) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            modelContext.insert(ExpenseItem(title: title, amount: amount, category: category, project: "その他", businessRatio: 1.0))
            let generator = UIImpactFeedbackGenerator(style: .medium); generator.impactOccurred()
        }
    }

    private func syncWidgetSnapshot() {
        let snapshot = TaxSuiteWidgetStore.makeSnapshot(
            expenses: allExpenses,
            incomes: allIncomes,
            taxRate: taxRate
        )
        TaxSuiteWidgetStore.save(snapshot: snapshot)
    }
}

struct QuickAddButton: View {
    var icon: String; var title: String; var amount: Double; var onTap: () -> Void; var onLongPress: () -> Void
    var body: some View {
        VStack(spacing: 8) {
            Text(icon).font(.title2)
            Text(title).font(.caption2).foregroundColor(.gray)
            Text("¥\(Int(amount))")
                .taxSuiteAmountStyle(size: 12, weight: .bold)
                .foregroundColor(.black)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 16).background(Color.white).cornerRadius(16).shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 3)
        .onTapGesture { onTap() }
        .onLongPressGesture { let g = UIImpactFeedbackGenerator(style: .heavy); g.impactOccurred(); onLongPress() }
    }
}

// MARK: - 🌟 【新機能】ウォレット風チャージ入力UI（日本円の硬貨・紙幣に完全対応）
struct WalletChargeInputView: View {
    @Binding var amountText: String
    
    // 実際のお金の単位（500円玉と、高額入力用の5万円を追加）
    let chargeAmounts = [1, 5, 10, 50, 100, 500, 1000, 5000, 10000, 50000]
    
    var body: some View {
        VStack(spacing: 12) {
            // 金額表示＆キーボード入力欄
            HStack {
                Text("¥")
                    .taxSuiteAmountStyle(size: 22, weight: .bold)
                    .foregroundColor(.gray)
                TextField("0", text: $amountText)
                    .keyboardType(.numberPad)
                    .taxSuiteAmountStyle(size: 32, weight: .bold, tracking: -0.4)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 8)
            
            // 🌟 3列 × 4行の完璧なボタンレイアウト
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                // お金追加ボタン（10個）
                ForEach(chargeAmounts, id: \.self) { val in
                    Button(action: { addAmount(val) }) {
                        Text("+\(val.formatted())")
                            .taxSuiteAmountStyle(size: 15, weight: .bold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.blue.opacity(0.1))
                            .foregroundColor(.blue)
                            .cornerRadius(10)
                    }
                }
                
                // 1文字消す（バックスペース）ボタン
                Button(action: {
                    if !amountText.isEmpty {
                        amountText.removeLast()
                        let g = UIImpactFeedbackGenerator(style: .light); g.impactOccurred()
                    }
                }) {
                    Image(systemName: "delete.left")
                        .font(.subheadline).bold()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.gray.opacity(0.1))
                        .foregroundColor(.gray)
                        .cornerRadius(10)
                }
                
                // 全クリアボタン
                Button(action: {
                    amountText = ""
                    let g = UIImpactFeedbackGenerator(style: .rigid); g.impactOccurred()
                }) {
                    Text("クリア")
                        .font(.subheadline).bold()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.1))
                        .foregroundColor(.red)
                        .cornerRadius(10)
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    private func addAmount(_ val: Int) {
        // 現在のテキストを数値に変換（空の場合は0）
        let current = Int(amountText) ?? 0
        // 加算して文字列に戻す
        amountText = String(current + val)
        
        // 押すたびに気持ちいい振動を返す
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }
}
// MARK: - 売上入力シート
struct IncomeEditView: View {
    @Environment(\.modelContext) private var modelContext; @Environment(\.dismiss) private var dismiss
    @State private var title: String = ""; @State private var amountText: String = ""; @State private var project: String = "エンジニア業"
    let projects = ["エンジニア業", "講師業", "その他"]
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("案件名")) {
                    TextField("例：A社Web制作", text: $title)
                }
                // 🌟 ウォレットUIを適用
                Section(header: Text("金額をチャージ入力")) {
                    WalletChargeInputView(amountText: $amountText)
                }
                Section(header: Text("プロジェクト")) {
                    Picker("プロジェクト", selection: $project) { ForEach(projects, id: \.self) { proj in Text(proj).tag(proj) } }.pickerStyle(.segmented)
                }
            }
            .navigationTitle("売上を追加").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        modelContext.insert(IncomeItem(title: title, amount: Double(amountText) ?? 0, project: project))
                        dismiss()
                    }.fontWeight(.bold).disabled(title.isEmpty || amountText.isEmpty)
                }
            }
        }
    }
}

// MARK: - 経費入力シート
struct ExpenseEditView: View {
    @Environment(\.modelContext) private var modelContext; @Environment(\.dismiss) private var dismiss
    @Query(sort: \ExpenseItem.timestamp, order: .reverse) private var expenseHistory: [ExpenseItem]
    var expense: ExpenseItem?; var initialTitle: String = ""; var initialAmount: String = ""
    @State private var title: String = ""
    @State private var amountText: String = ""
    @State private var category: String = "未分類"
    @State private var project: String = "その他"
    @State private var businessRatio: Double = 1.0
    @State private var suggestion: ExpenseAutofillSuggestion?
    @State private var isApplyingSuggestion = false
    @State private var hasManualCategoryOverride = false
    @State private var hasManualProjectOverride = false

    private var categoryOptions: [String] {
        ExpenseAutofillPredictor.categoryOptions(from: expenseHistory)
    }

    private var projectOptions: [String] {
        ExpenseAutofillPredictor.projectOptions(from: expenseHistory)
    }

    private var categoryBinding: Binding<String> {
        Binding(
            get: { category },
            set: { newValue in
                category = newValue
                if !isApplyingSuggestion {
                    hasManualCategoryOverride = true
                }
            }
        )
    }

    private var projectBinding: Binding<String> {
        Binding(
            get: { project },
            set: { newValue in
                project = newValue
                if !isApplyingSuggestion {
                    hasManualProjectOverride = true
                }
            }
        )
    }

    private var suggestionMessage: String? {
        guard expense == nil, let suggestion else { return nil }

        if let matchedTitle = suggestion.matchedTitle, suggestion.project != nil {
            return "過去の「\(matchedTitle)」を参考に、カテゴリとプロジェクトを提案しています。"
        }

        if suggestion.category != nil {
            return "項目名からカテゴリを自動提案しています。必要なら手動で変更できます。"
        }

        return nil
    }

    @ViewBuilder
    private var suggestionFooter: some View {
        if let suggestionMessage {
            Text(suggestionMessage)
                .foregroundColor(.blue)
        }
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section(
                    header: Text("項目名"),
                    footer: suggestionFooter
                ) {
                    TextField("例：タクシー代", text: $title)
                }
                // 🌟 ウォレットUIを適用
                Section(header: Text("金額をチャージ入力")) {
                    WalletChargeInputView(amountText: $amountText)
                }
                Section(header: Text("分類")) {
                    Picker("カテゴリ", selection: categoryBinding) {
                        ForEach(categoryOptions, id: \.self) { item in
                            Text(item).tag(item)
                        }
                    }
                    .tint(.black)

                    Picker("プロジェクト", selection: projectBinding) {
                        ForEach(projectOptions, id: \.self) { item in
                            Text(item).tag(item)
                        }
                    }
                    .tint(.black)
                }
                Section(header: Text("事業用割合 (家事按分)"), footer: Text("プライベートの支出が含まれる場合、事業の経費とする割合を指定します。")) {
                    VStack {
                        HStack { Text("事業用: \(Int(businessRatio * 100))%").fontWeight(.bold); Spacer(); if let amt = Double(amountText) { Text("経費計上額: ¥\(Int(amt * businessRatio))").foregroundColor(.gray) } }
                        Slider(value: $businessRatio, in: 0...1.0, step: 0.1).tint(.black)
                    }.padding(.vertical, 8)
                }
            }
            .navigationTitle(expense == nil ? "経費を追加" : "経費を編集").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        let amount = Double(amountText) ?? 0
                        if let e = expense {
                            e.title = title
                            e.amount = amount
                            e.category = category
                            e.project = project
                            e.businessRatio = businessRatio
                        } else {
                            modelContext.insert(
                                ExpenseItem(
                                    timestamp: Date(),
                                    title: title,
                                    amount: amount,
                                    category: category,
                                    project: project,
                                    businessRatio: businessRatio
                                )
                            )
                        }
                        dismiss()
                    }.fontWeight(.bold).disabled(title.isEmpty || amountText.isEmpty)
                }
            }
            .onAppear {
                if let e = expense {
                    title = e.title
                    amountText = String(Int(e.amount))
                    category = e.category
                    project = e.project
                    businessRatio = e.businessRatio
                    hasManualCategoryOverride = true
                    hasManualProjectOverride = true
                } else {
                    title = initialTitle
                    amountText = initialAmount
                    applySuggestion(for: initialTitle)
                }
            }
            .onChange(of: title) { _, newTitle in
                guard expense == nil else { return }
                applySuggestion(for: newTitle)
            }
        }
    }

    private func applySuggestion(for rawTitle: String) {
        let trimmedTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        suggestion = ExpenseAutofillPredictor.predict(for: trimmedTitle, from: expenseHistory)

        guard !trimmedTitle.isEmpty else {
            if !hasManualCategoryOverride {
                category = "未分類"
            }
            if !hasManualProjectOverride {
                project = "その他"
            }
            return
        }

        guard let suggestion else { return }

        isApplyingSuggestion = true
        if let predictedCategory = suggestion.category, !hasManualCategoryOverride {
            category = predictedCategory
        }
        if let predictedProject = suggestion.project, !hasManualProjectOverride {
            project = predictedProject
        }
        isApplyingSuggestion = false
    }
}

// MARK: - カレンダー・分析・設定（以下既存通り）
struct CalendarHistoryView: View {
    @Query(sort: \ExpenseItem.timestamp, order: .reverse) private var expenses: [ExpenseItem]
    @State private var selectedDate = Date(); @State private var editingExpense: ExpenseItem?
    var dailyExpenses: [ExpenseItem] { expenses.filter { Calendar.current.isDate($0.timestamp, inSameDayAs: selectedDate) } }
    var dailyTotal: Double { dailyExpenses.reduce(0) { $0 + $1.effectiveAmount } }

    private var dailyExpenseHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("この日の経費")
                .taxSuiteListHeaderStyle()
            Text("¥\(Int(dailyTotal).formatted())")
                .taxSuiteAmountStyle(size: 18, weight: .bold, tracking: -0.2)
                .foregroundColor(.primary)
        }
        .padding(.vertical, 4)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.97).ignoresSafeArea()
                VStack(spacing: 0) {
                    DatePicker("日付", selection: $selectedDate, displayedComponents: [.date]).datePickerStyle(.graphical).tint(.black).padding().background(Color.white).cornerRadius(15).padding()
                    List {
                        Section { NavigationLink(destination: AllHistoryView(editingExpense: $editingExpense)) { HStack { Image(systemName: "list.bullet.rectangle.portrait").foregroundColor(.blue); Text("すべての入力履歴を見る").fontWeight(.bold).foregroundColor(.blue) }.padding(.vertical, 4) } }
                        Section(header: dailyExpenseHeader) {
                            if dailyExpenses.isEmpty { Text("記録はありません").foregroundColor(.gray) }
                            else { ForEach(dailyExpenses) { expense in Button(action: { editingExpense = expense }) { HStack { VStack(alignment: .leading, spacing: 4) { Text(expense.title).font(.headline).foregroundColor(.black); Text(expense.project).font(.caption).foregroundColor(.gray) }; Spacer(); Text("¥\(Int(expense.effectiveAmount).formatted())").taxSuiteAmountStyle(size: 16, weight: .semibold, tracking: -0.2).foregroundColor(.black) } } } }
                        }
                    }.listStyle(.insetGrouped)
                }
            }.navigationTitle("カレンダー").sheet(item: $editingExpense) { expense in ExpenseEditView(expense: expense) }
        }
    }
}

struct AllHistoryView: View {
    @Query(sort: \ExpenseItem.timestamp, order: .reverse) private var allExpenses: [ExpenseItem]
    @Binding var editingExpense: ExpenseItem?
    @State private var viewMode: Int = 0
    var groupedByMonth: [(String, [ExpenseItem])] {
        let dict = Dictionary(grouping: allExpenses) { item in let f = DateFormatter(); f.dateFormat = "yyyy年MM月"; return f.string(from: item.timestamp) }
        return dict.sorted { $0.key > $1.key }
    }
    var body: some View {
        ZStack {
            Color(white: 0.97).ignoresSafeArea()
            VStack(spacing: 0) {
                Picker("表示モード", selection: $viewMode) { Text("月別まとめ").tag(0); Text("すべて").tag(1) }.pickerStyle(.segmented).padding()
                List {
                    if allExpenses.isEmpty { Text("まだ記録がありません").foregroundColor(.gray) }
                    else if viewMode == 0 { ForEach(groupedByMonth, id: \.0) { monthString, itemsInMonth in Section(header: Text(monthString).taxSuiteListHeaderStyle()) { ForEach(itemsInMonth) { expense in expenseRow(expense) } } } }
                    else { ForEach(allExpenses) { expense in expenseRow(expense) } }
                }.listStyle(.insetGrouped)
            }
        }.navigationTitle("すべての履歴").navigationBarTitleDisplayMode(.inline)
    }
    private func expenseRow(_ expense: ExpenseItem) -> some View {
        Button(action: { editingExpense = expense }) { HStack { VStack(alignment: .leading, spacing: 6) { Text(expense.title).font(.headline).foregroundColor(.black); HStack { Text(expense.project).font(.caption2).foregroundColor(.gray).padding(.horizontal, 8).padding(.vertical, 4).background(Color.gray.opacity(0.1)).cornerRadius(6); Text(expense.timestamp, style: .date).font(.caption2).foregroundColor(.gray) } }; Spacer(); Text("¥\(Int(expense.effectiveAmount).formatted())").taxSuiteAmountStyle(size: 17, weight: .semibold, tracking: -0.2).foregroundColor(.black) }.padding(.vertical, 4) }
    }
}

struct CategorySum: Identifiable, Equatable { var id = UUID(); var name: String; var total: Double }

struct AnalyticsView: View {
    @Query private var expenses: [ExpenseItem]
    @State private var animatedData: [CategorySum] = []
    var expenseSummary: [CategorySum] {
        let grouped = Dictionary(grouping: expenses, by: { $0.title })
        return grouped.map { key, expensesList in CategorySum(name: key, total: expensesList.reduce(0) { $0 + $1.effectiveAmount }) }.sorted { $0.total > $1.total }
    }
    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.97).ignoresSafeArea()
                if expenseSummary.isEmpty { Text("まだデータがありません").foregroundColor(.gray) }
                else {
                    List {
                        Section { Chart(animatedData) { item in BarMark(x: .value("金額", item.total), y: .value("項目", item.name)).foregroundStyle(by: .value("項目", item.name)).cornerRadius(8) }.frame(height: 250).padding(.vertical).animation(.spring(response: 0.7, dampingFraction: 0.6), value: animatedData)
                            .onAppear { animatedData = expenseSummary.map { CategorySum(name: $0.name, total: 0.0) }; DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { animatedData = expenseSummary } }
                            .onChange(of: expenses) { _, _ in animatedData = expenseSummary }
                        }
                        Section(header: Text("内訳").taxSuiteListHeaderStyle()) { ForEach(expenseSummary) { item in HStack { Text(item.name); Spacer(); Text("¥\(Int(item.total).formatted())").taxSuiteAmountStyle(size: 16, weight: .bold, tracking: -0.2) } } }
                    }.listStyle(.insetGrouped)
                }
            }.navigationTitle("分析")
        }
    }
}

struct TaxKnowledgeGlossaryView: View {
    @State private var searchText = ""

    private var filteredTerms: [GlossaryTerm] {
        if searchText.isEmpty {
            return GlossaryTerm.sampleTerms
        }

        return GlossaryTerm.sampleTerms.filter { term in
            term.title.localizedCaseInsensitiveContains(searchText)
                || term.summary.localizedCaseInsensitiveContains(searchText)
                || term.detail.localizedCaseInsensitiveContains(searchText)
                || term.category.rawValue.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("TaxSuite ミニ辞典")
                        .font(.title3.bold())
                    Text("税務とお金まわりでよく出る言葉を、やさしく確認できる入口です。今後ここに用語を増やしていけます。")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                .padding(.vertical, 4)
            }

            ForEach(GlossaryTerm.Category.allCases, id: \.self) { category in
                let terms = filteredTerms.filter { $0.category == category }

                if !terms.isEmpty {
                    Section(category.rawValue) {
                        ForEach(terms) { term in
                            NavigationLink(destination: GlossaryTermDetailView(term: term)) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(term.title)
                                        .font(.headline)
                                        .foregroundColor(.black)
                                    Text(term.summary)
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                        .lineLimit(2)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("税の知識")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "用語を検索")
    }
}

struct GlossaryTermDetailView: View {
    let term: GlossaryTerm

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(term.category.rawValue)
                        .font(.caption.bold())
                        .foregroundColor(.blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.08))
                        .clipShape(Capsule())
                    Text(term.title)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(term.summary)
                        .font(.headline)
                        .foregroundColor(.secondary)
                }

                Text(term.detail)
                    .font(.body)
                    .foregroundColor(.black)
                    .lineSpacing(6)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .background(Color(white: 0.97))
        .navigationTitle(term.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CSVPreviewView: View {
    @Query(sort: \ExpenseItem.timestamp, order: .reverse) private var expenses: [ExpenseItem]

    let format: ExportFormat

    private var previewExpenses: [ExpenseItem] {
        Array(expenses.prefix(50))
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("書き出し前の確認")
                        .font(.title3.bold())
                    Text(format.previewSummary)
                        .font(.subheadline)
                        .foregroundColor(.gray)

                    if format.usesAccountingCategoryMapping {
                        Text("売上は会計ソフト向けに `売上高` として出力されます。経費は下の一覧どおりに整理されます。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section(header: Text(sectionTitle).taxSuiteListHeaderStyle()) {
                if previewExpenses.isEmpty {
                    Text("記録がありません")
                        .foregroundColor(.gray)
                } else {
                    ForEach(previewExpenses) { expense in
                        previewRow(for: expense)
                    }

                    if expenses.count > previewExpenses.count {
                        Text("最新 \(previewExpenses.count) 件を表示中")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("書き出しプレビュー")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var sectionTitle: String {
        format.usesAccountingCategoryMapping ? "変換結果" : "出力されるカテゴリ"
    }

    @ViewBuilder
    private func previewRow(for expense: ExpenseItem) -> some View {
        let originalCategory = displayedCategory(for: expense.category)
        let exportedCategory = format.usesAccountingCategoryMapping ? expense.accountingCategory : originalCategory
        let didMap = originalCategory != exportedCategory

        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(expense.title)
                    .font(.body)
                    .fontWeight(.semibold)
                    .foregroundColor(.black)

                HStack(spacing: 6) {
                    Text(expense.timestamp, format: .dateTime.month().day())
                    Text("・")
                    Text(expense.project)
                }
                .font(.caption)
                .foregroundColor(.gray)

                HStack(spacing: 8) {
                    categoryBadge(text: originalCategory, tint: .gray, backgroundOpacity: 0.12)

                    if format.usesAccountingCategoryMapping {
                        Image(systemName: "arrow.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.secondary)
                        categoryBadge(
                            text: exportedCategory,
                            tint: didMap ? .blue : .secondary,
                            backgroundOpacity: didMap ? 0.12 : 0.1
                        )
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text("¥\(Int(expense.effectiveAmount).formatted())")
                    .taxSuiteAmountStyle(size: 17, weight: .bold, tracking: -0.2)

                Text(statusText(didMap: didMap))
                    .font(.caption2)
                    .foregroundColor(didMap ? .blue : .secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func displayedCategory(for category: String) -> String {
        let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未分類" : trimmed
    }

    private func statusText(didMap: Bool) -> String {
        if format.usesAccountingCategoryMapping {
            return didMap ? "変換あり" : "そのまま出力"
        }

        return "標準形式"
    }

    @ViewBuilder
    private func categoryBadge(text: String, tint: Color, backgroundOpacity: Double) -> some View {
        Text(text)
            .font(.caption.bold())
            .foregroundColor(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(backgroundOpacity))
            .clipShape(Capsule())
    }
}

struct ReportDraftComposerView: View {
    @Query(sort: \ExpenseItem.timestamp, order: .reverse) private var expenses: [ExpenseItem]
    @Query(sort: \IncomeItem.timestamp, order: .reverse) private var incomes: [IncomeItem]
    @AppStorage("taxAdvisorName") private var advisorName: String = ""
    @AppStorage("taxSuiteSenderName") private var senderName: String = ""
    @AppStorage("taxSuiteBusinessName") private var businessName: String = ""

    let taxRate: Double

    @State private var reportType: ReportType = .monthly
    @State private var selectedFormat: ExportFormat
    @State private var targetMonth: Date = Date()
    @State private var note: String = ""
    @State private var sharePayload: SharePayload?
    @State private var exportErrorMessage: String?

    init(defaultFormat: ExportFormat, taxRate: Double) {
        self.taxRate = taxRate
        _selectedFormat = State(initialValue: defaultFormat)
    }

    private var preview: ReportDraftPreview {
        ReportDraftBuilder.preview(
            expenses: expenses,
            incomes: incomes,
            format: selectedFormat,
            reportType: reportType,
            advisorName: advisorName,
            senderName: senderName,
            businessName: businessName,
            targetMonth: targetMonth,
            note: note,
            taxRate: taxRate
        )
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("報告をそのまま外に出す")
                        .font(.title3.bold())
                    Text("TaxSuite の数字を、件名・本文・CSV添付まで整えた状態で共有シートへ渡します。")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                .padding(.vertical, 4)
            }

            Section(header: Text("相手と差出人").taxSuiteListHeaderStyle()) {
                TextField("宛名（例: 山田先生）", text: $advisorName)
                TextField("差出人名", text: $senderName)
                TextField("屋号 / 事業名（任意）", text: $businessName)
            }

            Section(header: Text("報告内容").taxSuiteListHeaderStyle()) {
                Picker("報告タイプ", selection: $reportType) {
                    ForEach(ReportType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }

                Picker("CSV形式", selection: $selectedFormat) {
                    ForEach(ExportFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }

                DatePicker("対象月", selection: $targetMonth, displayedComponents: [.date])

                VStack(alignment: .leading, spacing: 8) {
                    Text("補足メモ")
                        .font(.subheadline.weight(.semibold))
                    TextEditor(text: $note)
                        .frame(minHeight: 88)
                }

                Text(reportType.subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("概要").taxSuiteListHeaderStyle()) {
                HStack {
                    metricColumn(title: "売上", value: preview.revenueTotal)
                    Spacer()
                    metricColumn(title: "経費", value: preview.expenseTotal)
                    Spacer()
                    metricColumn(title: "推定手取り", value: preview.takeHomeTotal)
                }
                .padding(.vertical, 4)

                HStack {
                    Text("件数")
                    Spacer()
                    Text("売上 \(preview.incomeCount)件 / 経費 \(preview.expenseCount)件")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("添付ファイル")
                    Spacer()
                    Text(preview.attachmentName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section(header: Text("本文プレビュー").taxSuiteListHeaderStyle()) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(preview.subject)
                        .font(.headline)
                        .foregroundColor(.black)

                    Text(preview.body)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .lineSpacing(5)
                }
                .padding(.vertical, 4)
            }

            Section {
                Button(action: shareDraft) {
                    HStack(spacing: 12) {
                        Image(systemName: "paperplane.fill")
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("共有シートで下書きを開く")
                                .font(.headline)
                                .foregroundColor(.black)
                            Text("Mail や Gmail に件名・本文・CSV を渡します")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("報告下書き")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sharePayload) { payload in
            ShareSheet(activityItems: payload.items, subject: payload.subject)
        }
        .alert("下書きを作成できませんでした", isPresented: Binding(
            get: { exportErrorMessage != nil },
            set: { if !$0 { exportErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportErrorMessage ?? "不明なエラーが発生しました。")
        }
    }

    private func metricColumn(title: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text("¥\(Int(value).formatted())")
                .taxSuiteAmountStyle(size: 18, weight: .bold, tracking: -0.2)
        }
    }

    private func shareDraft() {
        do {
            let draft = try ReportDraftBuilder.makeDraft(
                expenses: expenses,
                incomes: incomes,
                format: selectedFormat,
                reportType: reportType,
                advisorName: advisorName,
                senderName: senderName,
                businessName: businessName,
                targetMonth: targetMonth,
                note: note,
                taxRate: taxRate
            )
            sharePayload = SharePayload(
                items: [draft.body as Any] + draft.attachments.map { $0 as Any },
                subject: draft.subject
            )
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }
}

struct SettingsView: View {
    @Query(sort: \ExpenseItem.timestamp, order: .reverse) private var expenses: [ExpenseItem]
    @Query(sort: \IncomeItem.timestamp, order: .reverse) private var incomes: [IncomeItem]
    @Binding var taxRate: Double
    @State private var showingProModal = false
    @State private var exportFile: ExportFile?
    @State private var exportErrorMessage: String?
    @State private var selectedExportFormat: ExportFormat = .standard
    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.97).ignoresSafeArea()
                List {
                    Section { Button(action: { showingProModal = true }) { HStack { VStack(alignment: .leading, spacing: 4) { Text("TaxSuite Pro にアップグレード").font(.headline).foregroundColor(.black); Text("領収書スキャン・無制限のデータ保存").font(.caption).foregroundColor(.gray) }; Spacer(); Image(systemName: "chevron.right").foregroundColor(.gray).font(.caption) }.padding(.vertical, 4) } }
                    Section(header: Text("計算設定")) { HStack { Text("推定税率"); Spacer(); Picker("", selection: $taxRate) { Text("10%").tag(0.1); Text("20%").tag(0.2); Text("30%").tag(0.3) }.tint(.black) } }
                    Section(header: Text("固定費")) {
                        NavigationLink(destination: RecurringExpensesSettingsView()) {
                            HStack(spacing: 12) {
                                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                                    .foregroundColor(.blue)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("固定費を管理")
                                        .font(.headline)
                                        .foregroundColor(.black)
                                    Text("毎月のサブスクや定額支出を自動入力")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    Section(header: Text("データ")) {
                        LabeledContent("書き出し形式") {
                            Picker("書き出し形式", selection: $selectedExportFormat) {
                                ForEach(ExportFormat.allCases) { format in
                                    Text(format.rawValue).tag(format)
                                }
                            }
                            .labelsHidden()
                            .tint(.black)
                        }

                        NavigationLink(destination: CSVPreviewView(format: selectedExportFormat)) {
                            HStack(spacing: 12) {
                                Image(systemName: "doc.text.magnifyingglass")
                                    .foregroundColor(.blue)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("書き出し結果をプレビュー")
                                        .font(.headline)
                                        .foregroundColor(.black)
                                    Text(formatPreviewSubtitle)
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.gray)
                                    .font(.caption)
                            }
                            .padding(.vertical, 4)
                        }

                        Button(action: exportCSV) {
                            HStack(spacing: 12) {
                                Image(systemName: "square.and.arrow.up.fill")
                                    .foregroundColor(.orange)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("CSVを書き出す")
                                        .font(.headline)
                                        .foregroundColor(.black)
                                    Text(selectedExportFormat.subtitle)
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.gray)
                                    .font(.caption)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    Section(header: Text("連携")) {
                        NavigationLink(destination: ReportDraftComposerView(defaultFormat: selectedExportFormat, taxRate: taxRate)) {
                            HStack(spacing: 12) {
                                Image(systemName: "paperplane.circle.fill")
                                    .foregroundColor(.indigo)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("報告下書きを作成")
                                        .font(.headline)
                                        .foregroundColor(.black)
                                    Text("税理士や自分向けに件名・本文・CSV をまとめて準備")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.gray)
                                    .font(.caption)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    Section(header: Text("学ぶ")) {
                        NavigationLink(destination: TaxKnowledgeGlossaryView()) {
                            HStack(spacing: 12) {
                                Image(systemName: "book.closed.fill")
                                    .foregroundColor(.green)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("税の知識ミニ辞典")
                                        .font(.headline)
                                        .foregroundColor(.black)
                                    Text("税務用語や投資の基本をさっと確認")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }.listStyle(.insetGrouped)
            }
            .navigationTitle("設定")
            .sheet(isPresented: $showingProModal) { ProUpgradeView() }
            .sheet(item: $exportFile) { exportFile in
                ShareSheet(activityItems: [exportFile.url])
            }
            .alert("CSVを書き出せませんでした", isPresented: Binding(
                get: { exportErrorMessage != nil },
                set: { if !$0 { exportErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportErrorMessage ?? "不明なエラーが発生しました。")
            }
        }
    }

    private func exportCSV() {
        do {
            let url = try CSVExporter.export(expenses: expenses, incomes: incomes, format: selectedExportFormat)
            exportFile = ExportFile(url: url)
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }

    private var formatPreviewSubtitle: String {
        selectedExportFormat.usesAccountingCategoryMapping
            ? "勘定科目への変換結果を先に確認"
            : "現在の入力内容がどう出力されるか確認"
    }
}

struct RecurringExpensesSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecurringExpense.dayOfMonth) private var recurringExpenses: [RecurringExpense]
    @State private var showingAddSheet = false
    @State private var editingRecurringExpense: RecurringExpense?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("毎月の固定費")
                        .font(.title3.bold())
                    Text("一度登録しておくと、アプリがアクティブになったタイミングで当月分を自動追加します。")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                .padding(.vertical, 4)
            }

            Section("登録済み") {
                if recurringExpenses.isEmpty {
                    Text("まだ固定費は登録されていません")
                        .foregroundColor(.gray)
                } else {
                    ForEach(recurringExpenses) { recurringExpense in
                        Button {
                            editingRecurringExpense = recurringExpense
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(recurringExpense.title)
                                        .font(.headline)
                                        .foregroundColor(.black)
                                    HStack(spacing: 8) {
                                        Text(recurringExpense.project)
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.gray.opacity(0.1))
                                            .cornerRadius(6)
                                        Text("毎月\(recurringExpense.dayOfMonth)日")
                                            .font(.caption2)
                                            .foregroundColor(.blue)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.blue.opacity(0.1))
                                            .cornerRadius(6)
                                    }
                                }
                                Spacer()
                                Text("¥\(Int(recurringExpense.amount).formatted())")
                                    .taxSuiteAmountStyle(size: 17, weight: .semibold, tracking: -0.2)
                                    .foregroundColor(.black)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .onDelete(perform: deleteRecurringExpenses)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("固定費を管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            RecurringExpenseEditView(recurringExpense: nil)
        }
        .sheet(item: $editingRecurringExpense) { recurringExpense in
            RecurringExpenseEditView(recurringExpense: recurringExpense)
        }
    }

    private func deleteRecurringExpenses(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(recurringExpenses[index])
        }
        try? modelContext.save()
    }
}

struct RecurringExpenseEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    var recurringExpense: RecurringExpense?

    @State private var title: String = ""
    @State private var amountText: String = ""
    @State private var project: String = "その他"
    @State private var dayOfMonth: Int = 1

    private let projects = ["エンジニア業", "講師業", "その他"]

    var body: some View {
        NavigationStack {
            Form {
                Section("名前") {
                    TextField("例：Adobe / サーバー代", text: $title)
                }
                Section("金額") {
                    WalletChargeInputView(amountText: $amountText)
                }
                Section("プロジェクト") {
                    Picker("プロジェクト", selection: $project) {
                        ForEach(projects, id: \.self) { project in
                            Text(project).tag(project)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("引き落とし日") {
                    Stepper(value: $dayOfMonth, in: 1...31) {
                        Text("毎月 \(dayOfMonth) 日")
                    }
                    Text("存在しない日付はその月の末日に自動調整します。")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
            .navigationTitle(recurringExpense == nil ? "固定費を追加" : "固定費を編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        saveRecurringExpense()
                    }
                    .fontWeight(.bold)
                    .disabled(title.isEmpty || amountText.isEmpty)
                }
            }
            .onAppear {
                guard let recurringExpense else { return }
                title = recurringExpense.title
                amountText = String(Int(recurringExpense.amount))
                project = recurringExpense.project
                dayOfMonth = recurringExpense.dayOfMonth
            }
        }
    }

    private func saveRecurringExpense() {
        let amount = Double(amountText) ?? 0

        if let recurringExpense {
            recurringExpense.title = title
            recurringExpense.amount = amount
            recurringExpense.project = project
            recurringExpense.dayOfMonth = dayOfMonth
        } else {
            modelContext.insert(
                RecurringExpense(
                    title: title,
                    amount: amount,
                    project: project,
                    dayOfMonth: dayOfMonth
                )
            )
        }

        try? modelContext.save()
        dismiss()
    }
}

struct ProUpgradeView: View {
    @Environment(\.dismiss) var dismiss
    var body: some View { VStack(spacing: 30) { Text("TaxSuite Pro").font(.system(size: 32, weight: .bold, design: .rounded)).padding(.top, 40); Spacer(); Button("閉じる") { dismiss() }.padding().foregroundColor(.gray) } }
}

#Preview {
    ContentView().modelContainer(for: [ExpenseItem.self, RecurringExpense.self, IncomeItem.self], inMemory: true)
}
