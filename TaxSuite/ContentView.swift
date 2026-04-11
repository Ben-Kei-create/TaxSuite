import SwiftUI
import SwiftData

// MARK: - Helper: 計算ロジックの分離
/// ダッシュボードにロジックが散らからないよう、計算専用の構造体を定義します。
struct TaxCalculator {
    static func calculateTax(revenue: Double, expenses: Double, taxRate: Double) -> Double {
        let taxableIncome = max(0, revenue - expenses)
        return taxableIncome * taxRate
    }
    
    static func calculateTakeHome(revenue: Double, expenses: Double, taxRate: Double) -> Double {
        let taxableIncome = max(0, revenue - expenses)
        let tax = taxableIncome * taxRate
        return revenue - expenses - tax
    }
}

// MARK: - Main View
struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    
    // 全経費の取得（合計計算用）
    @Query private var allExpenses: [ExpenseItem]
    
    // 当日の経費のみを取得するクエリ（iOS 17のPredicateを使用）
    @Query(filter: DashboardView.todayPredicate, sort: \ExpenseItem.timestamp, order: .reverse)
    private var todayExpenses: [ExpenseItem]
    
    // 親から渡される税率（10%, 20%, 30%）
    @Binding var taxRate: Double
    
    // 固定売上
    let revenue: Double = 500_000
    
    var totalExpense: Double {
        allExpenses.reduce(0) { $0 + $1.amount }
    }
    
    var estimatedTax: Double {
        TaxCalculator.calculateTax(revenue: revenue, expenses: totalExpense, taxRate: taxRate)
    }
    
    var takeHome: Double {
        TaxCalculator.calculateTakeHome(revenue: revenue, expenses: totalExpense, taxRate: taxRate)
    }
    
    // 本日分のデータを抽出するPredicate
    static var todayPredicate: Predicate<ExpenseItem> {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return #Predicate<ExpenseItem> { item in
            item.timestamp >= start && item.timestamp < end
        }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                // ホワイトで快適な背景色
                Color(white: 0.97).ignoresSafeArea()
                
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 28) {
                        mainMetricCard
                        quickAddSection
                        todayExpensesSection
                    }
                    .padding(.vertical, 20)
                }
            }
            .navigationTitle("ダッシュボード")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    // MARK: - UI Components
    
    /// 1. 推定手取りとサマリーのカード
    private var mainMetricCard: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("今月の推定手取り")
                    .font(.subheadline)
                    .foregroundColor(.gray)
                
                Text("¥\(Int(takeHome).formatted())")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundColor(.black)
            }
            .padding(.top, 24)
            
            Divider()
                .padding(.horizontal, 24)
            
            HStack(spacing: 0) {
                metricItem(title: "今月の売上", value: revenue)
                Divider().frame(height: 30)
                metricItem(title: "経費合計", value: totalExpense)
                Divider().frame(height: 30)
                metricItem(title: "推定税額", value: estimatedTax, valueColor: .red.opacity(0.8))
            }
            .padding(.bottom, 24)
        }
        .background(Color.white)
        .cornerRadius(24)
        .shadow(color: .black.opacity(0.04), radius: 12, x: 0, y: 6)
        .padding(.horizontal, 20)
    }
    
    /// サマリー内の個別項目
    private func metricItem(title: String, value: Double, valueColor: Color = .black) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundColor(.gray)
            Text("¥\(Int(value).formatted())")
                .font(.headline)
                .foregroundColor(valueColor)
        }
        .frame(maxWidth: .infinity)
    }
    
    /// 2. クイック入力セクション
    private var quickAddSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("クイック入力")
                .font(.headline)
                .padding(.horizontal, 24)
            
            HStack(spacing: 12) {
                QuickAddButton(icon: "🚃", title: "電車", amount: 180) { addExpense(title: "電車", amount: 180, category: "交通費") }
                QuickAddButton(icon: "☕️", title: "カフェ", amount: 600) { addExpense(title: "カフェ", amount: 600, category: "会議費") }
                QuickAddButton(icon: "🍱", title: "昼食", amount: 1000) { addExpense(title: "昼食", amount: 1000, category: "福利厚生費") }
                QuickAddButton(icon: "🖊", title: "消耗品", amount: 1500) { addExpense(title: "消耗品", amount: 1500, category: "消耗品費") }
            }
            .padding(.horizontal, 20)
        }
    }
    
    /// 3. 当日の履歴セクション
    private var todayExpensesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("本日の経費")
                .font(.headline)
                .padding(.horizontal, 24)
            
            if todayExpenses.isEmpty {
                Text("本日の記録はありません")
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 20)
            } else {
                VStack(spacing: 10) {
                    ForEach(todayExpenses) { expense in
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(expense.title)
                                    .font(.body)
                                    .bold()
                                
                                Text(expense.project)
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.gray.opacity(0.1))
                                    .cornerRadius(6)
                            }
                            Spacer()
                            Text("¥\(Int(expense.amount).formatted())")
                                .font(.headline)
                        }
                        .padding(16)
                        .background(Color.white)
                        .cornerRadius(16)
                        .shadow(color: .black.opacity(0.02), radius: 4, x: 0, y: 2)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
    
    // MARK: - Actions
    
    private func addExpense(title: String, amount: Double, category: String) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            let newExpense = ExpenseItem(
                timestamp: Date(),
                title: title,
                amount: amount,
                category: category,
                project: "その他" // 初期値
            )
            modelContext.insert(newExpense)
            
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
        }
    }
}

// MARK: - Quick Add Button Component
struct QuickAddButton: View {
    var icon: String
    var title: String
    var amount: Double
    var action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Text(icon)
                    .font(.title2)
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.gray)
                Text("¥\(Int(amount))")
                    .font(.caption)
                    .bold()
                    .foregroundColor(.black)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.white)
            .cornerRadius(16)
            .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 3)
        }
    }
}

// MARK: - Preview
#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: ExpenseItem.self, configurations: config)
    
    // モックデータの追加（Preview確認用）
    let mock1 = ExpenseItem(title: "タクシー", amount: 2000, category: "交通費", project: "エンジニア業")
    let mock2 = ExpenseItem(title: "サーバー代", amount: 5000, category: "通信費", project: "エンジニア業")
    container.mainContext.insert(mock1)
    container.mainContext.insert(mock2)
    
    return DashboardView(taxRate: .constant(0.2))
        .modelContainer(container)
}
