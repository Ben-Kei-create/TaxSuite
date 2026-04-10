import SwiftUI
import SwiftData
import Charts

struct ContentView: View {
    @State private var selectedTab = 0
    @State private var taxRate: Double = 0.2
    
    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(taxRate: taxRate)
                .tabItem { Label("ホーム", systemImage: "house.fill") }
                .tag(0)
            
            // 🌟 新機能：カレンダータブを追加！
            CalendarHistoryView()
                .tabItem { Label("カレンダー", systemImage: "calendar") }
                .tag(1)
            
            AnalyticsView()
                .tabItem { Label("分析", systemImage: "chart.pie.fill") }
                .tag(2)
            
            SettingsView(taxRate: $taxRate)
                .tabItem { Label("設定", systemImage: "gearshape.fill") }
                .tag(3)
        }
        .accentColor(.black)
    }
}

// ----------------------------------------------------
// 1. ホーム画面
// ----------------------------------------------------
struct HomeView: View {
    @Query(sort: \ExpenseItem.timestamp, order: .reverse) private var expenses: [ExpenseItem]
    @Environment(\.modelContext) private var modelContext
    
    @State private var totalRevenue: Double = 500000
    var taxRate: Double
    
    var totalExpense: Double {
        expenses.reduce(0) { $0 + $1.amount }
    }
    
    var estimatedIncome: Double {
        let tax = (totalRevenue - totalExpense) * taxRate
        return totalRevenue - totalExpense - max(0, tax)
    }
    
    var body: some View {
        ZStack {
            Color(white: 0.97).ignoresSafeArea()
            
            VStack(spacing: 0) {
                // サマリー部分
                VStack(spacing: 10) {
                    Text("今月の推定手取り").font(.subheadline).foregroundColor(.gray)
                    Text("¥\(Int(estimatedIncome).formatted())").font(.system(size: 44, weight: .bold, design: .rounded))
                    HStack(spacing: 20) {
                        SummaryItem(label: "経費合計", value: totalExpense, color: .black)
                        SummaryItem(label: "推定税金", value: (totalRevenue - totalExpense) * taxRate, color: .gray)
                    }
                }
                .padding(.top, 20)
                .padding(.bottom, 25)
                
                // 入力ボタン
                HStack(spacing: 12) {
                    SmallQuickButton(icon: "🚃", title: "電車", amount: 500) { addExpense("電車", 500) }
                    SmallQuickButton(icon: "☕️", title: "カフェ", amount: 800) { addExpense("カフェ", 800) }
                    SmallQuickButton(icon: "🚕", title: "タクシー", amount: 2000) { addExpense("タクシー", 2000) }
                    SmallQuickButton(icon: "💻", title: "ツール", amount: 5000) { addExpense("ツール", 5000) }
                }
                .padding(.horizontal)
                .padding(.bottom, 15)
                
                // 履歴リスト
                List {
                    ForEach(expenses) { expense in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(expense.title).font(.headline)
                                Text(expense.timestamp, style: .time).font(.caption).foregroundColor(.gray)
                            }
                            Spacer()
                            Text("¥\(Int(expense.amount).formatted())")
                        }
                    }
                    .onDelete(perform: deleteExpense)
                }
                .listStyle(.insetGrouped)
            }
        }
    }
    
    private func addExpense(_ title: String, _ amount: Double) {
        withAnimation(.spring()) {
            let newExpense = ExpenseItem(title: title, amount: amount)
            modelContext.insert(newExpense)
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
        }
    }
    
    private func deleteExpense(offsets: IndexSet) {
        withAnimation {
            for index in offsets { modelContext.delete(expenses[index]) }
        }
    }
}

// ----------------------------------------------------
// 2. カレンダー履歴画面（✨New!）
// ----------------------------------------------------
struct CalendarHistoryView: View {
    @Query(sort: \ExpenseItem.timestamp, order: .reverse) private var expenses: [ExpenseItem]
    @State private var selectedDate = Date()
    
    // 選んだ日付の経費だけをフィルタリングする計算プロパティ
    var dailyExpenses: [ExpenseItem] {
        expenses.filter { Calendar.current.isDate($0.timestamp, inSameDayAs: selectedDate) }
    }
    
    var dailyTotal: Double {
        dailyExpenses.reduce(0) { $0 + $1.amount }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.97).ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Apple純正の美しいカレンダーUI
                    DatePicker(
                        "日付を選択",
                        selection: $selectedDate,
                        displayedComponents: [.date]
                    )
                    .datePickerStyle(.graphical)
                    .tint(.black) // アプリのテーマ色に合わせる
                    .padding()
                    .background(Color.white)
                    .cornerRadius(15)
                    .padding()
                    .shadow(color: .black.opacity(0.03), radius: 5, x: 0, y: 3)
                    
                    // その日の履歴リスト
                    List {
                        Section(header: Text("この日の経費: ¥\(Int(dailyTotal).formatted())")) {
                            if dailyExpenses.isEmpty {
                                Text("記録はありません")
                                    .foregroundColor(.gray)
                                    .padding(.vertical, 10)
                            } else {
                                ForEach(dailyExpenses) { expense in
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(expense.title).font(.headline)
                                            Text(expense.timestamp, style: .time).font(.caption).foregroundColor(.gray)
                                        }
                                        Spacer()
                                        Text("¥\(Int(expense.amount).formatted())")
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("カレンダー")
        }
    }
}

// ----------------------------------------------------
// 3. 分析画面
// ----------------------------------------------------
struct CategorySum: Identifiable, Equatable {
    var id = UUID(); var name: String; var total: Double
}

struct AnalyticsView: View {
    @Query private var expenses: [ExpenseItem]
    @State private var animatedData: [CategorySum] = []
    
    var expenseSummary: [CategorySum] {
        let grouped = Dictionary(grouping: expenses, by: { $0.title })
        return grouped.map { CategorySum(name: $0.key, total: $0.value.reduce(0) { $1 + $2.amount }) }
            .sorted { $0.total > $1.total }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.97).ignoresSafeArea()
                if expenseSummary.isEmpty {
                    Text("まだデータがありません").foregroundColor(.gray)
                } else {
                    List {
                        Section {
                            Chart(animatedData) { item in
                                BarMark(x: .value("金額", item.total), y: .value("項目", item.name))
                                    .foregroundStyle(by: .value("項目", item.name))
                                    .cornerRadius(8)
                            }
                            .frame(height: 250).padding(.vertical)
                            .animation(.spring(response: 0.7, dampingFraction: 0.6), value: animatedData)
                            .onAppear {
                                animatedData = expenseSummary.map { CategorySum(name: $0.name, total: 0.0) }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { animatedData = expenseSummary }
                            }
                            .onChange(of: expenses) { _, _ in animatedData = expenseSummary }
                        }
                        Section(header: Text("内訳")) {
                            ForEach(expenseSummary) { item in
                                HStack {
                                    Text(item.name); Spacer()
                                    Text("¥\(Int(item.total).formatted())").bold()
                                }
                            }
                        }
                    }.listStyle(.insetGrouped)
                }
            }.navigationTitle("分析")
        }
    }
}

// ----------------------------------------------------
// 4. 設定画面
// ----------------------------------------------------
struct SettingsView: View {
    @Binding var taxRate: Double
    @State private var showingProModal = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.97).ignoresSafeArea()
                List {
                    Section {
                        Button(action: { showingProModal = true }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("TaxSuite Pro にアップグレード").font(.headline).foregroundColor(.black)
                                    Text("領収書スキャン・無制限のデータ保存").font(.caption).foregroundColor(.gray)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundColor(.gray).font(.caption)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    Section(header: Text("計算設定")) {
                        HStack {
                            Text("推定税率"); Spacer()
                            Picker("", selection: $taxRate) {
                                Text("10%").tag(0.1); Text("20%").tag(0.2); Text("30%").tag(0.3)
                            }.tint(.black)
                        }
                    }
                    Section(header: Text("データ管理")) {
                        Button(action: {}) {
                            HStack { Image(systemName: "square.and.arrow.up"); Text("税理士にデータを書き出す (CSV)") }.foregroundColor(.black)
                        }
                        HStack {
                            Image(systemName: "icloud.fill").foregroundColor(.blue)
                            Text("iCloud 同期"); Spacer(); Text("オン").foregroundColor(.gray)
                        }
                    }
                }.listStyle(.insetGrouped)
            }
            .navigationTitle("設定")
            .sheet(isPresented: $showingProModal) { ProUpgradeView() }
        }
    }
}

struct ProUpgradeView: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(spacing: 30) {
            Text("TaxSuite Pro").font(.system(size: 32, weight: .bold, design: .rounded)).padding(.top, 40)
            Text("あなたのビジネスを\nさらに「ホワイト」で快適に。").multilineTextAlignment(.center).font(.headline).foregroundColor(.gray)
            Spacer()
            Button("閉じる") { dismiss() }.padding().foregroundColor(.gray)
        }
    }
}

// ----------------------------------------------------
// 補助コンポーネント（HomeView用）
// ----------------------------------------------------
struct SummaryItem: View {
    var label: String; var value: Double; var color: Color
    var body: some View {
        VStack {
            Text(label).font(.caption).foregroundColor(.gray)
            Text("¥\(Int(value).formatted())").font(.headline).foregroundColor(color)
        }
    }
}

struct SmallQuickButton: View {
    var icon: String; var title: String; var amount: Int; var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(icon).font(.title3)
                Text(title).font(.caption2).foregroundColor(.gray)
                Text("¥\(amount)").font(.caption).bold().foregroundColor(.black)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12).background(Color.white).cornerRadius(12).shadow(color: .black.opacity(0.04), radius: 3, x: 0, y: 2)
        }
    }
}
