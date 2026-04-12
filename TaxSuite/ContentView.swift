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

// MARK: - Helper: 計算ロジック
struct TaxCalculator {
    static func calculateTax(revenue: Double, expenses: Double, taxRate: Double) -> Double {
        let taxableIncome = max(0, revenue - expenses)
        return taxableIncome * taxRate
    }
    static func calculateTakeHome(revenue: Double, expenses: Double, taxRate: Double) -> Double {
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
}

struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct CSVExporter {
    static func export(expenses: [ExpenseItem], incomes: [IncomeItem]) throws -> URL {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy-MM-dd"

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
                formatter.string(from: expense.timestamp),
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
                formatter.string(from: income.timestamp),
                csvField(income.title),
                csvField(String(Int(income.amount))),
                csvField(""),
                csvField(income.project),
                csvField("1.00"),
                csvField(String(Int(income.amount))),
                csvField("false")
            ].joined(separator: ","))
        }

        let csv = lines.joined(separator: "\n")
        let fileName = "TaxSuite-\(timestampString(for: Date())).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        try csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func csvField(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private static func timestampString(for date: Date) -> String {
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
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            checkAndAddRecurringExpenses()
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
                    VStack(spacing: 28) {
                        mainMetricCard
                        adBannerSection
                        quickAddSection
                        todayExpensesSection
                        Spacer().frame(height: 80)
                    }.padding(.vertical, 20)
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
            Text("クイック入力 (長押しで詳細)").font(.caption).foregroundColor(.gray).padding(.horizontal, 24)
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
            Text("本日の経費").font(.headline).padding(.horizontal, 24)
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
    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.97).ignoresSafeArea()
                VStack(spacing: 0) {
                    DatePicker("日付", selection: $selectedDate, displayedComponents: [.date]).datePickerStyle(.graphical).tint(.black).padding().background(Color.white).cornerRadius(15).padding()
                    List {
                        Section { NavigationLink(destination: AllHistoryView(editingExpense: $editingExpense)) { HStack { Image(systemName: "list.bullet.rectangle.portrait").foregroundColor(.blue); Text("すべての入力履歴を見る").fontWeight(.bold).foregroundColor(.blue) }.padding(.vertical, 4) } }
                        Section(header: Text("この日の経費: ¥\(Int(dailyTotal).formatted())")) {
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
                    else if viewMode == 0 { ForEach(groupedByMonth, id: \.0) { monthString, itemsInMonth in Section(header: Text(monthString).font(.headline)) { ForEach(itemsInMonth) { expense in expenseRow(expense) } } } }
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
                        Section(header: Text("内訳")) { ForEach(expenseSummary) { item in HStack { Text(item.name); Spacer(); Text("¥\(Int(item.total).formatted())").taxSuiteAmountStyle(size: 16, weight: .bold, tracking: -0.2) } } }
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

struct SettingsView: View {
    @Query(sort: \ExpenseItem.timestamp, order: .reverse) private var expenses: [ExpenseItem]
    @Query(sort: \IncomeItem.timestamp, order: .reverse) private var incomes: [IncomeItem]
    @Binding var taxRate: Double
    @State private var showingProModal = false
    @State private var exportFile: ExportFile?
    @State private var exportErrorMessage: String?
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
                        Button(action: exportCSV) {
                            HStack(spacing: 12) {
                                Image(systemName: "square.and.arrow.up.fill")
                                    .foregroundColor(.orange)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("CSVを書き出す")
                                        .font(.headline)
                                        .foregroundColor(.black)
                                    Text("売上と経費を会計ソフト向けにシェア")
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
            let url = try CSVExporter.export(expenses: expenses, incomes: incomes)
            exportFile = ExportFile(url: url)
        } catch {
            exportErrorMessage = error.localizedDescription
        }
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
