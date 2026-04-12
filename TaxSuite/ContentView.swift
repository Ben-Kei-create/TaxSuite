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

    init(timestamp: Date = Date(), title: String, amount: Double, category: String = "未分類", project: String = "その他", businessRatio: Double = 1.0) {
        self.timestamp = timestamp
        self.title = title
        self.amount = amount
        self.category = category
        self.project = project
        self.businessRatio = businessRatio
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

// MARK: - App Root
struct ContentView: View {
    @State private var selectedTab = 0
    @AppStorage("taxRate") private var taxRate: Double = 0.2
    
    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView(taxRate: $taxRate).tabItem { Label("ホーム", systemImage: "house.fill") }.tag(0)
            CalendarHistoryView().tabItem { Label("カレンダー", systemImage: "calendar") }.tag(1)
            AnalyticsView().tabItem { Label("分析", systemImage: "chart.pie.fill") }.tag(2)
            SettingsView(taxRate: $taxRate).tabItem { Label("設定", systemImage: "gearshape.fill") }.tag(3)
        }.accentColor(.black)
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
                Text("¥\(Int(takeHome).formatted())").font(.system(size: 48, weight: .bold, design: .rounded)).foregroundColor(.black)
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
        VStack(spacing: 6) { Text(title).font(.caption).foregroundColor(.gray); Text("¥\(Int(value).formatted())").font(.headline).foregroundColor(valueColor) }.frame(maxWidth: .infinity)
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
                                    Text("¥\(Int(expense.effectiveAmount).formatted())").font(.headline).foregroundColor(.black)
                                    if expense.businessRatio < 1.0 { Text("全体: ¥\(Int(expense.amount))").font(.caption2).foregroundColor(.gray) }
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
        VStack(spacing: 8) { Text(icon).font(.title2); Text(title).font(.caption2).foregroundColor(.gray); Text("¥\(Int(amount))").font(.caption).bold().foregroundColor(.black) }
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
                Text("¥").font(.title2.bold()).foregroundColor(.gray)
                TextField("0", text: $amountText)
                    .keyboardType(.numberPad)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 8)
            
            // 🌟 3列 × 4行の完璧なボタンレイアウト
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                // お金追加ボタン（10個）
                ForEach(chargeAmounts, id: \.self) { val in
                    Button(action: { addAmount(val) }) {
                        Text("+\(val.formatted())")
                            .font(.subheadline).bold()
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
    var expense: ExpenseItem?; var initialTitle: String = ""; var initialAmount: String = ""
    @State private var title: String = ""; @State private var amountText: String = ""; @State private var project: String = "その他"; @State private var businessRatio: Double = 1.0
    let projects = ["エンジニア業", "講師業", "その他"]
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("項目名")) {
                    TextField("例：タクシー代", text: $title)
                }
                // 🌟 ウォレットUIを適用
                Section(header: Text("金額をチャージ入力")) {
                    WalletChargeInputView(amountText: $amountText)
                }
                Section(header: Text("プロジェクト")) {
                    Picker("プロジェクト", selection: $project) { ForEach(projects, id: \.self) { proj in Text(proj).tag(proj) } }.pickerStyle(.segmented)
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
                        if let e = expense { e.title = title; e.amount = amount; e.project = project; e.businessRatio = businessRatio }
                        else { modelContext.insert(ExpenseItem(timestamp: Date(), title: title, amount: amount, project: project, businessRatio: businessRatio)) }
                        dismiss()
                    }.fontWeight(.bold).disabled(title.isEmpty || amountText.isEmpty)
                }
            }
            .onAppear {
                if let e = expense { title = e.title; amountText = String(Int(e.amount)); project = e.project; businessRatio = e.businessRatio }
                else { title = initialTitle; amountText = initialAmount }
            }
        }
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
                            else { ForEach(dailyExpenses) { expense in Button(action: { editingExpense = expense }) { HStack { VStack(alignment: .leading, spacing: 4) { Text(expense.title).font(.headline).foregroundColor(.black); Text(expense.project).font(.caption).foregroundColor(.gray) }; Spacer(); Text("¥\(Int(expense.effectiveAmount).formatted())").foregroundColor(.black) } } } }
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
        Button(action: { editingExpense = expense }) { HStack { VStack(alignment: .leading, spacing: 6) { Text(expense.title).font(.headline).foregroundColor(.black); HStack { Text(expense.project).font(.caption2).foregroundColor(.gray).padding(.horizontal, 8).padding(.vertical, 4).background(Color.gray.opacity(0.1)).cornerRadius(6); Text(expense.timestamp, style: .date).font(.caption2).foregroundColor(.gray) } }; Spacer(); Text("¥\(Int(expense.effectiveAmount).formatted())").font(.headline).foregroundColor(.black) }.padding(.vertical, 4) }
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
                        Section(header: Text("内訳")) { ForEach(expenseSummary) { item in HStack { Text(item.name); Spacer(); Text("¥\(Int(item.total).formatted())").bold() } } }
                    }.listStyle(.insetGrouped)
                }
            }.navigationTitle("分析")
        }
    }
}

struct SettingsView: View {
    @Binding var taxRate: Double
    @State private var showingProModal = false
    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.97).ignoresSafeArea()
                List {
                    Section { Button(action: { showingProModal = true }) { HStack { VStack(alignment: .leading, spacing: 4) { Text("TaxSuite Pro にアップグレード").font(.headline).foregroundColor(.black); Text("領収書スキャン・無制限のデータ保存").font(.caption).foregroundColor(.gray) }; Spacer(); Image(systemName: "chevron.right").foregroundColor(.gray).font(.caption) }.padding(.vertical, 4) } }
                    Section(header: Text("計算設定")) { HStack { Text("推定税率"); Spacer(); Picker("", selection: $taxRate) { Text("10%").tag(0.1); Text("20%").tag(0.2); Text("30%").tag(0.3) }.tint(.black) } }
                }.listStyle(.insetGrouped)
            }.navigationTitle("設定").sheet(isPresented: $showingProModal) { ProUpgradeView() }
        }
    }
}

struct ProUpgradeView: View {
    @Environment(\.dismiss) var dismiss
    var body: some View { VStack(spacing: 30) { Text("TaxSuite Pro").font(.system(size: 32, weight: .bold, design: .rounded)).padding(.top, 40); Spacer(); Button("閉じる") { dismiss() }.padding().foregroundColor(.gray) } }
}

#Preview {
    ContentView().modelContainer(for: [ExpenseItem.self, RecurringExpense.self, IncomeItem.self], inMemory: true)
}
