import SwiftUI
import SwiftData
import StoreKit

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview

    @Binding var showTutorial: Bool

    @State private var selectedTab = 0
    @AppStorage("taxRate") private var taxRate: Double = 0.2
    @AppStorage("expenseSavedCount") private var expenseSavedCount = 0
    @AppStorage("hasRequestedReview") private var hasRequestedReview = false

    @Query private var allExpenses: [ExpenseItem]

    // ジオフェンス通知から開く経費入力シート
    @State private var locationManager = LocationManager.shared
    @State private var showingGeofenceExpenseSheet = false

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
        .accentColor(.primary)
        .overlay {
            if showTutorial {
                AppTutorialView {
                    withAnimation(.easeOut(duration: 0.3)) {
                        showTutorial = false
                    }
                }
                .zIndex(100)
            }
        }
        // ジオフェンス通知タップ → 経費入力シートを開く
        .sheet(isPresented: $showingGeofenceExpenseSheet, onDismiss: {
            locationManager.pendingGeofenceExpense = nil
        }) {
            if let pending = locationManager.pendingGeofenceExpense {
                ExpenseEditView(
                    expense: nil,
                    initialTitle: pending.triggerName,
                    initialAmount: pending.amount > 0 ? String(Int(pending.amount)) : "",
                    initialCategory: pending.category,
                    initialProject: pending.project,
                    initialLocationTriggerName: pending.triggerName
                )
            }
        }
        .onChange(of: locationManager.pendingGeofenceExpense) { _, newValue in
            if newValue != nil {
                selectedTab = 0  // ホームに切り替え
                showingGeofenceExpenseSheet = true
            }
        }
        .task {
            processPendingWidgetExpenses()
            checkAndAddRecurringExpenses()
            refreshWidgetSnapshot()
            await locationManager.requestNotificationPermission()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            processPendingWidgetExpenses()
            checkAndAddRecurringExpenses()
            refreshWidgetSnapshot()
        }
        .onChange(of: allExpenses.count) { _, count in
            // 経費が10件・30件に達したタイミングで一度だけレビュー依頼
            guard !hasRequestedReview, count == 10 || count == 30 else { return }
            Task {
                try? await Task.sleep(for: .seconds(1))
                requestReview()
                hasRequestedReview = true
            }
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
        var hasChanges = false

        for recurring in recurringExpenses {
            let recurringIDString = recurring.persistenceKey
            let expenseDescriptor = FetchDescriptor<ExpenseItem>(
                predicate: #Predicate { expense in
                    expense.recurringExpenseID == recurringIDString
                }
            )
            guard let createdExpenses = try? modelContext.fetch(expenseDescriptor) else { continue }

            let alreadyAdded = alreadyAddedInCurrentPeriod(
                recurring: recurring,
                createdExpenses: createdExpenses,
                now: now,
                calendar: calendar
            )
            guard !alreadyAdded else { continue }

            let autoExpense = ExpenseItem(
                timestamp: recurring.scheduledDate(in: now, calendar: calendar),
                title: recurring.title + " (自動)",
                amount: recurring.amount,
                category: "固定費",
                project: recurring.project,
                businessRatio: 1.0,
                note: recurring.note.isEmpty ? "固定費の自動入力" : recurring.note,
                recurringExpenseID: recurringIDString
            )
            modelContext.insert(autoExpense)
            hasChanges = true
        }

        if hasChanges {
            try? modelContext.save()
        }
    }

    private func alreadyAddedInCurrentPeriod(
        recurring: RecurringExpense,
        createdExpenses: [ExpenseItem],
        now: Date,
        calendar: Calendar
    ) -> Bool {
        switch RecurringFrequency(rawValue: recurring.frequency) ?? .monthly {

        case .monthly:
            let m = calendar.component(.month, from: now)
            let y = calendar.component(.year, from: now)
            return createdExpenses.contains {
                calendar.component(.month, from: $0.timestamp) == m &&
                calendar.component(.year, from: $0.timestamp) == y
            }

        case .quarterly:
            // 1-3月 / 4-6月 / 7-9月 / 10-12月 の各四半期内に1回
            let m = calendar.component(.month, from: now)
            let y = calendar.component(.year, from: now)
            let currentQuarter = (m - 1) / 3
            return createdExpenses.contains {
                let em = calendar.component(.month, from: $0.timestamp)
                let ey = calendar.component(.year, from: $0.timestamp)
                return ey == y && (em - 1) / 3 == currentQuarter
            }

        case .weekly:
            let week = calendar.component(.weekOfYear, from: now)
            let y = calendar.component(.yearForWeekOfYear, from: now)
            return createdExpenses.contains {
                calendar.component(.weekOfYear, from: $0.timestamp) == week &&
                calendar.component(.yearForWeekOfYear, from: $0.timestamp) == y
            }

        case .biweekly:
            // 年頭からの週番号を 2 で割った値が同じならスキップ
            let week = calendar.component(.weekOfYear, from: now)
            let y = calendar.component(.yearForWeekOfYear, from: now)
            let biweekPeriod = (week - 1) / 2
            return createdExpenses.contains {
                let ew = calendar.component(.weekOfYear, from: $0.timestamp)
                let ey = calendar.component(.yearForWeekOfYear, from: $0.timestamp)
                return ey == y && (ew - 1) / 2 == biweekPeriod
            }
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
    ContentView().modelContainer(for: [ExpenseItem.self, RecurringExpense.self, IncomeItem.self, LocationTrigger.self], inMemory: true)
}
