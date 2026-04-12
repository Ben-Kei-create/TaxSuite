import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedTab = 0
    @AppStorage("taxRate") private var taxRate: Double = 0.2

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView(taxRate: $taxRate)
                .tabItem { Label("ホーム", systemImage: "house.fill") }
                .tag(0)

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
        .task {
            processPendingWidgetExpenses()
            checkAndAddRecurringExpenses()
            refreshWidgetSnapshot()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            processPendingWidgetExpenses()
            checkAndAddRecurringExpenses()
            refreshWidgetSnapshot()
        }
    }

    @MainActor
    private func processPendingWidgetExpenses() {
        let actions = TaxSuiteWidgetStore.consumePendingQuickExpenses()
        guard !actions.isEmpty else { return }

        for action in actions {
            modelContext.insert(
                ExpenseItem(
                    timestamp: action.createdAt,
                    title: action.title,
                    amount: action.amount,
                    category: action.category,
                    project: action.project,
                    businessRatio: 1.0,
                    note: action.note
                )
            )
        }

        try? modelContext.save()
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
                note: "固定費の自動入力",
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

#Preview {
    ContentView().modelContainer(for: [ExpenseItem.self, RecurringExpense.self, IncomeItem.self], inMemory: true)
}
