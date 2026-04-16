import SwiftUI
import SwiftData
import Charts

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

struct TaxSuiteBannerHeader: View {
    var body: some View {
        AdBannerView()
            .frame(height: 50)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

struct TaxSuiteScreenSurface<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        ZStack {
            Color(white: 0.97).ignoresSafeArea()

            VStack(spacing: 8) {
                TaxSuiteBannerHeader()
                content()
            }
        }
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

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allExpenses: [ExpenseItem]
    @Query private var allIncomes: [IncomeItem]
    @AppStorage("isTaxSuiteProEnabled") private var isTaxSuiteProEnabled = false

    @Query(filter: DashboardView.todayPredicate, sort: \ExpenseItem.timestamp, order: .reverse)
    private var todayExpenses: [ExpenseItem]

    @Binding var taxRate: Double

    @State private var showingExpenseSheet = false
    @State private var showingIncomeSheet = false
    @State private var editingExpense: ExpenseItem?
    @State private var showingReceiptImporter = false
    @State private var showingProModal = false
    @State private var showingShortcutBar = false
    @State private var shortcutSlots = TaxSuiteWidgetStore.loadButtonSlots()

    @State private var draftTitle: String = ""
    @State private var draftAmount: String = ""

    // 本日の経費の一括削除モード用ステート。iPhone の写真アプリ風の選択モードを実現する。
    @State private var isSelectionMode = false
    @State private var selectedExpenseIDs: Set<PersistentIdentifier> = []
    // 現在スワイプで削除ボタンが露出している行。複数行が同時に開かないよう 1 行だけに制限する。
    @State private var swipeRevealedExpenseID: PersistentIdentifier? = nil
    @State private var showingBulkDeleteConfirm = false

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

    var quickExpenseTemplates: [QuickExpenseTemplate] {
        // ショートカットの並びが経費追加のたびに入れ替わらないよう、
        // 「タイトルごとの使用回数」と「タイトル名の昇順」で安定的にソートする。
        // 新規追加は使用回数が 1 段階ずつ増えるだけなので、並び順の変化が緩やか。
        let grouped = Dictionary(grouping: allExpenses) { expense -> String in
            expense.title
                .replacingOccurrences(of: " (自動)", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }
        .filter { !$0.key.isEmpty }

        let sortedGroups = grouped.sorted { lhs, rhs in
            if lhs.value.count != rhs.value.count {
                return lhs.value.count > rhs.value.count
            }
            return lhs.key < rhs.key
        }

        var templates = sortedGroups.compactMap { (_, items) -> QuickExpenseTemplate? in
            // 代表アイテムはそのタイトルの最新のものを使う（金額・カテゴリなどの最新値を反映するため）
            guard let representative = items.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
            let baseTitle = representative.title
                .replacingOccurrences(of: " (自動)", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !baseTitle.isEmpty else { return nil }
            return QuickExpenseTemplate(
                id: "history-\(baseTitle)",
                title: baseTitle,
                amount: representative.amount,
                category: representative.category,
                project: representative.project,
                note: representative.note
            )
        }

        if templates.count >= 4 {
            return Array(templates.prefix(4))
        }

        let projectNames = TaxSuiteWidgetStore.loadProjectNames()
        let fallback = [
            QuickExpenseTemplate(id: "default-train",    title: "電車",   amount: 180,  category: "交通費",    project: projectNames[2], note: ""),
            QuickExpenseTemplate(id: "default-cafe",     title: "カフェ", amount: 600,  category: "会議費",    project: projectNames[0], note: ""),
            QuickExpenseTemplate(id: "default-lunch",    title: "昼食",   amount: 1000, category: "福利厚生費", project: projectNames[2], note: ""),
            QuickExpenseTemplate(id: "default-supplies", title: "消耗品", amount: 1500, category: "消耗品費",  project: projectNames[2], note: "")
        ]

        let existingTitles = Set(templates.map { $0.title.lowercased() })
        for template in fallback where !existingTitles.contains(template.title.lowercased()) {
            templates.append(template)
            if templates.count == 4 { break }
        }

        return templates
    }

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
            TaxSuiteScreenSurface {
                ZStack(alignment: .bottom) {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 26) {
                            mainMetricCard
                            quickAddSection
                            todayExpensesSection
                            Spacer().frame(height: 104)
                        }
                        .padding(.top, 6)
                        .padding(.bottom, 20)
                    }
                    // スワイプで開いている行があるときに背景をタップすると閉じられるようにする
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            if swipeRevealedExpenseID != nil {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                    swipeRevealedExpenseID = nil
                                }
                            }
                        }
                    )

                    if isSelectionMode {
                        selectionActionBar
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .zIndex(3)
                    } else if showingShortcutBar {
                        shortcutBarOverlay
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .zIndex(2)
                    } else {
                        floatingActionButtons
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .zIndex(1)
                    }
                }
                .animation(.spring(response: 0.34, dampingFraction: 0.84), value: showingShortcutBar)
                .animation(.spring(response: 0.34, dampingFraction: 0.84), value: isSelectionMode)
            }
            .navigationTitle(isSelectionMode ? selectionNavTitle : "ダッシュボード")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isSelectionMode {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("キャンセル") {
                            exitSelectionMode()
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(allTodaySelected ? "選択解除" : "すべて選択") {
                            toggleSelectAllToday()
                        }
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        Text("TaxSuite v1.0")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                    }
                }
            }
            // タブバー（ホーム/カレンダー/分析/設定）は + ボタン押下時でも常に表示しておく。
            // ショートカットバーはタブバーの上に重ねる形で出現させる。
            .animation(.spring(response: 0.3, dampingFraction: 0.86), value: showingShortcutBar)
            .sheet(isPresented: $showingExpenseSheet) { ExpenseEditView(expense: nil, initialTitle: draftTitle, initialAmount: draftAmount) }
            .sheet(isPresented: $showingIncomeSheet) { IncomeEditView() }
            .sheet(item: $editingExpense) { expense in ExpenseEditView(expense: expense) }
            .sheet(isPresented: $showingReceiptImporter) { ReceiptImportView() }
            .sheet(isPresented: $showingProModal) { ProUpgradeView() }
            .confirmationDialog(
                "選択した\(selectedExpenseIDs.count)件の経費を削除しますか？",
                isPresented: $showingBulkDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("削除", role: .destructive) {
                    deleteSelectedExpenses()
                }
                Button("キャンセル", role: .cancel) {}
            }
            .task {
                syncWidgetSnapshot()
                refreshShortcutSlots()
            }
            .onChange(of: widgetSnapshotFingerprint) { _, _ in
                syncWidgetSnapshot()
            }
        }
    }

    // 選択モード時のナビゲーションタイトル
    private var selectionNavTitle: String {
        let count = selectedExpenseIDs.count
        return count == 0 ? "項目を選択" : "\(count)件選択中"
    }

    private var allTodaySelected: Bool {
        !todayExpenses.isEmpty && selectedExpenseIDs.count == todayExpenses.count
    }

    private func toggleSelectAllToday() {
        if allTodaySelected {
            selectedExpenseIDs.removeAll()
        } else {
            selectedExpenseIDs = Set(todayExpenses.map { $0.persistentModelID })
        }
    }

    private func enterSelectionMode(initiallySelecting expense: ExpenseItem? = nil) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            swipeRevealedExpenseID = nil
            isSelectionMode = true
            if let expense {
                selectedExpenseIDs = [expense.persistentModelID]
            } else {
                selectedExpenseIDs = []
            }
        }
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }

    private func exitSelectionMode() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            isSelectionMode = false
            selectedExpenseIDs.removeAll()
        }
    }

    private func toggleSelection(for expense: ExpenseItem) {
        let id = expense.persistentModelID
        if selectedExpenseIDs.contains(id) {
            selectedExpenseIDs.remove(id)
        } else {
            selectedExpenseIDs.insert(id)
        }
    }

    private func deleteExpense(_ expense: ExpenseItem) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            modelContext.delete(expense)
            try? modelContext.save()
            swipeRevealedExpenseID = nil
        }
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    private func deleteSelectedExpenses() {
        let idsToDelete = selectedExpenseIDs
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            for expense in todayExpenses where idsToDelete.contains(expense.persistentModelID) {
                modelContext.delete(expense)
            }
            try? modelContext.save()
            exitSelectionMode()
        }
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    // 選択モード時にボトムへ表示する削除確認バー
    private var selectionActionBar: some View {
        HStack(spacing: 12) {
            Button(action: { showingBulkDeleteConfirm = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "trash.fill")
                    Text(selectedExpenseIDs.isEmpty
                         ? "削除"
                         : "\(selectedExpenseIDs.count)件を削除")
                        .fontWeight(.semibold)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(selectedExpenseIDs.isEmpty ? Color.red.opacity(0.4) : Color.red)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(selectedExpenseIDs.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
    }

    private func openIncomeSheet() {
        closeShortcutBar()
        showingIncomeSheet = true
    }

    private func openReceiptImporter() {
        closeShortcutBar()
        if isTaxSuiteProEnabled {
            showingReceiptImporter = true
        } else {
            showingProModal = true
        }
    }

    private func openNewExpenseSheet() {
        closeShortcutBar()
        draftTitle = ""
        draftAmount = ""
        showingExpenseSheet = true
    }

    private func openDraftSheet(title: String, amount: Double) {
        closeShortcutBar()
        draftTitle = title
        draftAmount = String(Int(amount))
        showingExpenseSheet = true
    }

    private func toggleShortcutBar() {
        if !showingShortcutBar {
            refreshShortcutSlots()
        }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
            showingShortcutBar.toggle()
        }
    }

    private func closeShortcutBar() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            showingShortcutBar = false
        }
    }

    private func refreshShortcutSlots() {
        shortcutSlots = TaxSuiteWidgetStore.loadButtonSlots()
    }

    private var floatingActionButtons: some View {
        HStack {
            Button(action: openReceiptImporter) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.black)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.22), radius: 6, x: 0, y: 4)
            }

            Spacer()

            Button(action: toggleShortcutBar) {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.black)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.22), radius: 6, x: 0, y: 4)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private var shortcutBarOverlay: some View {
        // タブバーは常に表示したままにするため、ショートカットバーは安全領域を尊重してタブバーの上に並べる。
        VStack(spacing: 0) {
            // 上部に細いハンドルを置いて、タップすれば閉じられることを視覚的に示す
            Button(action: { closeShortcutBar() }) {
                Capsule()
                    .fill(Color.black.opacity(0.18))
                    .frame(width: 36, height: 4)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("ショートカットを閉じる")

            HStack(spacing: 8) {
                ForEach(shortcutSlots) { slot in
                    shortcutBarButton(for: slot)
                }

                manualEntryButton
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity)
        }
        .background(
            // タブバーとの境界が分かるように薄い影とブラーを背景に重ねる
            ZStack {
                Color(white: 0.98).opacity(0.98)
                VStack {
                    Divider().opacity(0.12)
                    Spacer()
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: -2)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private func shortcutBarButton(for slot: WidgetButtonSlot) -> some View {
        let enabled = !slot.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && slot.amount > 0

        return Button {
            guard enabled else { return }
            addShortcutExpense(slot)
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.06))
                        .frame(width: 42, height: 42)
                    Image(systemName: shortcutSymbol(for: slot))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.black)
                }

                Text(slot.title.isEmpty ? "未設定" : slot.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(enabled ? .black : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var manualEntryButton: some View {
        Menu {
            Button(action: openNewExpenseSheet) {
                Label("経費を入力", systemImage: "square.and.pencil")
            }
            Button(action: openIncomeSheet) {
                Label("売上を入力", systemImage: "arrow.down.circle.fill")
            }
            Button(action: openReceiptImporter) {
                Label("領収書から追加", systemImage: "camera.fill")
            }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black)
                        .frame(width: 42, height: 42)
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                }

                Text("手入力")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.black)
                    .lineLimit(1)
            }
            .frame(width: 56)
            .padding(.vertical, 4)
        }
    }

    private func addShortcutExpense(_ slot: WidgetButtonSlot) {
        let trimmedTitle = slot.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, slot.amount > 0 else { return }

        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            modelContext.insert(
                ExpenseItem(
                    timestamp: Date(),
                    title: trimmedTitle,
                    amount: slot.amount,
                    category: slot.category,
                    project: TaxSuiteWidgetStore.sanitizeProjectName(slot.project),
                    businessRatio: 1.0,
                    note: slot.note
                )
            )
            try? modelContext.save()
            showingShortcutBar = false
        }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func shortcutSymbol(for slot: WidgetButtonSlot) -> String {
        let combined = "\(slot.title) \(slot.category)".lowercased()

        if combined.contains("交通") || combined.contains("電車") || combined.contains("タクシー") || combined.contains("新幹線") {
            return "tram.fill"
        }
        if combined.contains("カフェ") || combined.contains("会議") {
            return "cup.and.saucer.fill"
        }
        if combined.contains("昼食") || combined.contains("食") || combined.contains("福利厚生") {
            return "fork.knife"
        }
        if combined.contains("消耗") || combined.contains("備品") || combined.contains("文具") {
            return "shippingbox.fill"
        }
        if combined.contains("通信") || combined.contains("サーバー") || combined.contains("ドメイン") || combined.contains("aws") {
            return "wifi"
        }
        if combined.contains("固定費") || combined.contains("サブスク") {
            return "arrow.triangle.2.circlepath.circle.fill"
        }
        return "yen.circle.fill"
    }

    private var mainMetricCard: some View {
        VStack(spacing: 18) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 8) {
                    Text("今月の推定手取り").font(.subheadline).foregroundColor(.gray)
                    Text("¥\(Int(takeHome).formatted())")
                        .taxSuiteHeroAmountStyle()
                        .foregroundColor(.black)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 20)

                // 売上追加ボタン
                Button {
                    showingIncomeSheet = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.blue)
                        .background(Color.white.clipShape(Circle()))
                }
                .padding(.top, 12)
                .padding(.trailing, 14)
            }

            Divider().padding(.horizontal, 20)

            HStack(spacing: 0) {
                metricItem(title: "今月の売上", value: currentMonthRevenue, valueColor: .blue)
                Divider().frame(height: 30)
                metricItem(title: "経費(按分後)", value: currentMonthExpense)
                Divider().frame(height: 30)
                metricItem(title: "推定税額", value: estimatedTax, valueColor: .red.opacity(0.8))
            }
            .padding(.bottom, 20)
        }
        .background(Color.white)
        .cornerRadius(24)
        .shadow(color: .black.opacity(0.04), radius: 12, x: 0, y: 6)
        .padding(.horizontal, 20)
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

    private var quickAddSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("最近よく使う経費")
                .taxSuiteSectionHeadingStyle()
                .padding(.horizontal, 24)
                .padding(.bottom, 2)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(quickExpenseTemplates) { template in
                    QuickAddButton(
                        title: template.title,
                        amount: template.amount,
                        onTap: { addExpense(template) },
                        onLongPress: { openDraftSheet(title: template.title, amount: template.amount) }
                    )
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private var todayExpensesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("本日の経費")
                    .taxSuiteSectionHeadingStyle()
                Spacer()
                if !todayExpenses.isEmpty && !isSelectionMode {
                    Button("選択") {
                        enterSelectionMode()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.blue)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 2)

            if todayExpenses.isEmpty {
                Text("本日の記録はありません")
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 20)
            } else {
                VStack(spacing: 8) {
                    ForEach(todayExpenses) { expense in
                        TodayExpenseRow(
                            expense: expense,
                            isSelectionMode: isSelectionMode,
                            isSelected: selectedExpenseIDs.contains(expense.persistentModelID),
                            isSwipeRevealed: swipeRevealedExpenseID == expense.persistentModelID,
                            onTap: {
                                if isSelectionMode {
                                    toggleSelection(for: expense)
                                } else if swipeRevealedExpenseID != nil {
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                        swipeRevealedExpenseID = nil
                                    }
                                } else {
                                    editingExpense = expense
                                }
                            },
                            onLongPress: {
                                if !isSelectionMode {
                                    enterSelectionMode(initiallySelecting: expense)
                                }
                            },
                            onSwipeReveal: {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                    swipeRevealedExpenseID = expense.persistentModelID
                                }
                            },
                            onSwipeReset: {
                                if swipeRevealedExpenseID == expense.persistentModelID {
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                        swipeRevealedExpenseID = nil
                                    }
                                }
                            },
                            onDelete: {
                                deleteExpense(expense)
                            }
                        )
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func addExpense(_ template: QuickExpenseTemplate) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            modelContext.insert(
                ExpenseItem(
                    title: template.title,
                    amount: template.amount,
                    category: template.category,
                    project: template.project,
                    businessRatio: 1.0
                )
            )
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
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
    var title: String
    var amount: Double
    var onTap: () -> Void
    var onLongPress: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.black)
                .lineLimit(1)
            Text("¥\(Int(amount))")
                .taxSuiteAmountStyle(size: 17, weight: .bold, tracking: -0.2)
                .foregroundColor(.black)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .background(Color.white)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.035), radius: 5, x: 0, y: 3)
        .onTapGesture(perform: onTap)
        .onLongPressGesture {
            let generator = UIImpactFeedbackGenerator(style: .heavy)
            generator.impactOccurred()
            onLongPress()
        }
    }
}

// 本日の経費リスト 1 行分のビュー。スワイプで削除アクションを露出し、
// 長押しで親に選択モード開始を通知する。選択モード中はチェックマークを表示する。
struct TodayExpenseRow: View {
    let expense: ExpenseItem
    let isSelectionMode: Bool
    let isSelected: Bool
    let isSwipeRevealed: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void
    let onSwipeReveal: () -> Void
    let onSwipeReset: () -> Void
    let onDelete: () -> Void

    @State private var dragOffset: CGFloat = 0

    // 削除ボタン領域の幅。iOS 標準のスワイプアクションのコンパクトさに合わせる。
    private let actionWidth: CGFloat = 74
    // これ以上スワイプしたら「確定」として露出状態にスナップする閾値
    private let revealThreshold: CGFloat = 36
    // 速度を考慮したスワイプ確定の閾値（予測終点の移動量）
    private let velocityCommitThreshold: CGFloat = 160

    // スワイプ・選択モードを考慮した最終的な水平オフセット
    private var effectiveOffset: CGFloat {
        if isSelectionMode { return 0 }
        let baseOffset: CGFloat = isSwipeRevealed ? -actionWidth : 0
        let combined = baseOffset + dragOffset
        // 右方向への過度なスワイプは抑制。左方向も actionWidth の 1.3 倍までに制限。
        return max(min(combined, 0), -actionWidth * 1.3)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            // カード本体（背面）— 左にオフセットして削除ボタンを露出
            HStack(spacing: 12) {
                if isSelectionMode {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundColor(isSelected ? .blue : .gray.opacity(0.5))
                        .transition(.scale.combined(with: .opacity))
                }

                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(expense.title).font(.subheadline).bold().foregroundColor(.black)
                        if !expense.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(expense.note)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        HStack(spacing: 6) {
                            // ジオフェンス由来なら「自動記録」を示すピンを先頭に。
                            // 設定のトリガー一覧と同じ `mappin.circle.fill` を使って視覚的に揃える。
                            if expense.locationTriggerName != nil {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.caption2)
                                    .foregroundColor(Color(red: 0.22, green: 0.55, blue: 0.30))
                                    .accessibilityLabel("自動記録")
                            }
                            Text(expense.project)
                                .font(.caption2)
                                .foregroundColor(.gray)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(6)
                            if expense.businessRatio < 1.0 {
                                Text("\(Int(expense.businessRatio * 100))%")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.orange.opacity(0.1))
                                    .cornerRadius(6)
                            }
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("¥\(Int(expense.effectiveAmount).formatted())")
                            .taxSuiteAmountStyle(size: 16, weight: .semibold, tracking: -0.2)
                            .foregroundColor(.black)
                        if expense.businessRatio < 1.0 {
                            Text("全体: ¥\(Int(expense.amount))")
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundColor(.gray)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            // ジオフェンス由来は薄緑背景でカレンダーのヒートマップと同じ世界観に寄せる
            .background(expense.locationTriggerName != nil
                        ? Color(red: 0.89, green: 0.96, blue: 0.90)
                        : Color.white)
            .cornerRadius(15)
            .shadow(color: .black.opacity(0.02), radius: 3, x: 0, y: 2)
            .offset(x: effectiveOffset)
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isSwipeRevealed)
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isSelectionMode)
            .gesture(swipeGesture)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .onLongPressGesture(minimumDuration: 0.45) {
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                onLongPress()
            }

            // 削除ボタン（前面）— カードのタップが優先されないよう最後に重ねる
            // iOS 標準の `.swipeActions` と同じように、カード右端から少し浮いた
            // 丸ボタン風に仕上げる（カレンダー側の見た目と統一）。
            if !isSelectionMode {
                Button(action: onDelete) {
                    VStack(spacing: 3) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 16, weight: .semibold))
                        Text("削除")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color.red)
                    )
                    .padding(.vertical, 6)
                    .padding(.trailing, 4)
                }
                .buttonStyle(.plain)
                .frame(width: actionWidth)
                // 露出していないときはタップされないよう無効化
                .allowsHitTesting(isSwipeRevealed)
                .opacity(effectiveOffset < -8 ? 1 : 0)
            }
        }
    }

    // 選択モード中はドラッグを無効化するため、ハンドラ内で early return する。
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                guard !isSelectionMode else { return }
                // 水平方向が主体のときだけ処理（縦スクロールとの両立）
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragOffset = value.translation.width
            }
            .onEnded { value in
                guard !isSelectionMode else {
                    dragOffset = 0
                    return
                }
                let horizontal = value.translation.width
                let predicted = value.predictedEndTranslation.width
                guard abs(horizontal) > abs(value.translation.height) else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        dragOffset = 0
                    }
                    return
                }

                // 位置（距離）または速度（予測終点）のいずれかが左方向に十分なら露出確定
                let shouldReveal = horizontal < -revealThreshold || predicted < -velocityCommitThreshold
                // 右方向は、露出中のみリセットに倒す。距離でも速度でも判定。
                let shouldReset = horizontal > revealThreshold || predicted > velocityCommitThreshold

                // dragOffset のゼロ復帰と親コールバックを同じスプリングで駆動し、
                // finger リリース時のスナップをヌルッと繋げる。
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    dragOffset = 0
                    if shouldReveal {
                        onSwipeReveal()
                    } else if shouldReset, isSwipeRevealed {
                        onSwipeReset()
                    } else if !isSwipeRevealed {
                        // しきい値未満の左スワイプは元に戻す
                        onSwipeReset()
                    }
                }
            }
    }
}

struct WalletChargeInputView: View {
    @Binding var amountText: String

    private var sanitizedAmountBinding: Binding<String> {
        Binding(
            get: { amountText },
            set: { newValue in
                let filtered = newValue.filter { character in
                    character.isNumber || character == "."
                }

                let components = filtered.split(separator: ".", omittingEmptySubsequences: false)
                if components.count <= 2 {
                    amountText = filtered
                } else {
                    amountText = components.prefix(2).joined(separator: ".")
                }
            }
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("¥")
                .taxSuiteAmountStyle(size: 22, weight: .bold)
                .foregroundColor(.gray)

            TextField("0", text: sanitizedAmountBinding)
                .keyboardType(.decimalPad)
                .taxSuiteAmountStyle(size: 32, weight: .bold, tracking: -0.4)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
    }
}

struct IncomeEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var income: IncomeItem?

    @State private var title: String = ""
    @State private var amountText: String = ""
    @State private var selectedDate: Date = Date()
    @State private var project: String = TaxSuiteWidgetStore.primaryProjectName()

    private var projects: [String] {
        TaxSuiteWidgetStore.projectNameOptions(including: [project])
    }

    var body: some View {
        NavigationStack {
            TaxSuiteScreenSurface {
                Form {
                    Section(header: Text("案件名")) {
                        TextField("例：A社Web制作", text: $title)
                    }
                    Section(header: Text("金額")) {
                        WalletChargeInputView(amountText: $amountText)
                    }
                    Section(header: Text("日付")) {
                        DatePicker(
                            "受取日",
                            selection: $selectedDate,
                            in: ...Date(),
                            displayedComponents: [.date]
                        )
                        .datePickerStyle(.compact)
                        .tint(.black)
                        .environment(\.locale, Locale(identifier: "ja_JP"))
                    }
                    Section(header: Text("プロジェクト")) {
                        Picker("プロジェクト", selection: $project) {
                            ForEach(projects, id: \.self) { project in
                                Text(project).tag(project)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    if income != nil {
                        Section {
                            Button("この記録を削除", role: .destructive, action: deleteIncome)
                        }
                    }
                }
            }
            .navigationTitle(income == nil ? "売上を追加" : "売上を編集")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: configureOnAppear)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存", action: saveIncome)
                        .fontWeight(.bold)
                        .disabled(title.isEmpty || amountText.isEmpty)
                }
            }
        }
    }

    private func configureOnAppear() {
        if let income {
            title = income.title
            amountText = String(Int(income.amount))
            selectedDate = income.timestamp
            project = TaxSuiteWidgetStore.sanitizeProjectName(income.project, fallbackIndex: 0)
        } else {
            project = TaxSuiteWidgetStore.sanitizeProjectName(project, fallbackIndex: 0)
        }
    }

    private func saveIncome() {
        let amount = Double(amountText) ?? 0
        if let income {
            income.title = title
            income.amount = amount
            income.timestamp = selectedDate
            income.project = project
        } else {
            modelContext.insert(IncomeItem(timestamp: selectedDate, title: title, amount: amount, project: project))
        }
        dismiss()
    }

    private func deleteIncome() {
        guard let income else { return }
        modelContext.delete(income)
        try? modelContext.save()
        dismiss()
    }
}

struct ExpenseEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ExpenseItem.timestamp, order: .reverse) private var expenseHistory: [ExpenseItem]

    var expense: ExpenseItem?
    var initialTitle: String = ""
    var initialAmount: String = ""
    var initialCategory: String = ""
    var initialProject: String = ""
    var initialDate: Date = Date()
    /// ジオフェンス通知から開かれた場合にトリガー名を受け取り、保存時に ExpenseItem へ付与する。
    var initialLocationTriggerName: String? = nil

    @State private var title: String = ""
    @State private var amountText: String = ""
    @State private var selectedDate: Date = Date()
    @State private var category: String = "未分類"
    @State private var project: String = TaxSuiteWidgetStore.fallbackProjectName()
    @State private var businessRatio: Double = 1.0
    @State private var note: String = ""
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

    private var commentSamples: [String] {
        ExpenseCommentTemplate.samples(for: category)
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
            TaxSuiteScreenSurface {
                Form {
                    Section(header: Text("項目名"), footer: suggestionFooter) {
                        TextField("例：タクシー代", text: $title)
                    }
                    Section(header: Text("金額")) {
                        WalletChargeInputView(amountText: $amountText)
                    }
                    Section(header: Text("日付")) {
                        DatePicker(
                            "発生日",
                            selection: $selectedDate,
                            in: ...Date(),
                            displayedComponents: [.date]
                        )
                        .datePickerStyle(.compact)
                        .tint(.black)
                        .environment(\.locale, Locale(identifier: "ja_JP"))
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
                    Section(header: Text("コメント")) {
                        VStack(alignment: .leading, spacing: 12) {
                            TextEditor(text: $note)
                                .frame(minHeight: 92)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(commentSamples, id: \.self) { sample in
                                        Button(sample) {
                                            note = sample
                                        }
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(.black)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 8)
                                        .background(Color.black.opacity(0.06))
                                        .clipShape(Capsule())
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    Section(
                        header: Text("事業用割合 (家事按分)"),
                        footer: Text("プライベートの支出が含まれる場合、事業の経費とする割合を指定します。")
                    ) {
                        VStack {
                            HStack {
                                Text("事業用: \(Int(businessRatio * 100))%").fontWeight(.bold)
                                Spacer()
                                if let amount = Double(amountText) {
                                    Text("経費計上額: ¥\(Int(amount * businessRatio))").foregroundColor(.gray)
                                }
                            }
                            Slider(value: $businessRatio, in: 0...1.0, step: 0.1).tint(.black)
                        }
                        .padding(.vertical, 8)
                    }
                    if expense != nil {
                        Section {
                            Button("この記録を削除", role: .destructive, action: deleteExpense)
                        }
                    }
                }
            }
            .navigationTitle(expense == nil ? "経費を追加" : "経費を編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存", action: saveExpense)
                        .fontWeight(.bold)
                        .disabled(title.isEmpty || amountText.isEmpty)
                }
            }
            .onAppear(perform: configureOnAppear)
            .onChange(of: title) { _, newTitle in
                guard expense == nil else { return }
                applySuggestion(for: newTitle)
            }
        }
    }

    private func configureOnAppear() {
        if let expense {
            title = expense.title
            amountText = String(Int(expense.amount))
            selectedDate = expense.timestamp
            category = expense.category
            project = expense.project
            businessRatio = expense.businessRatio
            note = expense.note
            hasManualCategoryOverride = true
            hasManualProjectOverride = true
        } else {
            title = initialTitle
            amountText = initialAmount
            selectedDate = initialDate   // カレンダーなどから指定された日付を使用
            note = ""
            if !initialCategory.isEmpty {
                category = initialCategory
                hasManualCategoryOverride = true
            }
            if !initialProject.isEmpty {
                project = initialProject
                hasManualProjectOverride = true
            }
            project = TaxSuiteWidgetStore.fallbackProjectName()
            applySuggestion(for: initialTitle)
        }
    }

    private func saveExpense() {
        let amount = Double(amountText) ?? 0
        if let expense {
            expense.title         = title
            expense.amount        = amount
            expense.timestamp     = selectedDate
            expense.category      = category
            expense.project       = project
            expense.businessRatio = businessRatio
            expense.note          = note
        } else {
            modelContext.insert(
                ExpenseItem(
                    timestamp: selectedDate,
                    title: title,
                    amount: amount,
                    category: category,
                    project: project,
                    businessRatio: businessRatio,
                    note: note,
                    locationTriggerName: initialLocationTriggerName
                )
            )
        }
        dismiss()
    }

    private func deleteExpense() {
        guard let expense else { return }
        modelContext.delete(expense)
        try? modelContext.save()
        dismiss()
    }

    private func applySuggestion(for rawTitle: String) {
        let trimmedTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        suggestion = ExpenseAutofillPredictor.predict(for: trimmedTitle, from: expenseHistory)

        guard !trimmedTitle.isEmpty else {
            if !hasManualCategoryOverride {
                category = "未分類"
            }
            if !hasManualProjectOverride {
                project = TaxSuiteWidgetStore.fallbackProjectName()
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

struct CalendarHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ExpenseItem.timestamp, order: .reverse) private var expenses: [ExpenseItem]
    @State private var selectedDate = Date()
    @State private var displayedMonth = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? Date()
    @State private var editingExpense: ExpenseItem?
    @State private var showingNewExpenseSheet = false
    @State private var showingMonthPicker = false

    private let weekdaySymbols = ["日", "月", "火", "水", "木", "金", "土"]

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ja_JP")
        return calendar
    }

    // 同一日内では「追加した順に新しいものが上」になるよう、createdAt 降順でソート。
    // createdAt が同一（旧データ）の場合は timestamp 降順でフォールバック。
    var dailyExpenses: [ExpenseItem] {
        expenses
            .filter { calendar.isDate($0.timestamp, inSameDayAs: selectedDate) }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.timestamp > rhs.timestamp
            }
    }
    var dailyTotal: Double { dailyExpenses.reduce(0) { $0 + $1.effectiveAmount } }

    private var monthExpenses: [ExpenseItem] {
        expenses.filter { calendar.isDate($0.timestamp, equalTo: displayedMonth, toGranularity: .month) }
    }

    private var dailyTotalsByDate: [Date: Double] {
        Dictionary(grouping: monthExpenses) { expense in
            calendar.startOfDay(for: expense.timestamp)
        }
        .mapValues { items in
            items.reduce(0) { $0 + $1.effectiveAmount }
        }
    }

    private var monthGrid: [Date?] {
        let monthStart = startOfMonth(for: displayedMonth)
        let daysInMonth = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        let startWeekday = calendar.component(.weekday, from: monthStart)
        let leadingDays = (startWeekday - calendar.firstWeekday + 7) % 7

        var grid = Array<Date?>(repeating: nil, count: leadingDays)
        for dayOffset in 0..<daysInMonth {
            if let day = calendar.date(byAdding: .day, value: dayOffset, to: monthStart) {
                grid.append(day)
            }
        }

        while grid.count % 7 != 0 {
            grid.append(nil)
        }

        return grid
    }

    private var maxDailyTotal: Double {
        dailyTotalsByDate.values.max() ?? 0
    }

    private var dailyExpenseHeader: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedDate, format: .dateTime.month().day().weekday())
                    .taxSuiteListHeaderStyle()
                Text("¥\(Int(dailyTotal).formatted())")
                    .taxSuiteAmountStyle(size: 18, weight: .bold, tracking: -0.2)
                    .foregroundColor(.primary)
            }
            Spacer()
            // 選択日に経費を手動追加するボタン
            Button {
                showingNewExpenseSheet = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.caption.weight(.bold))
                    Text("経費を追加")
                        .font(.caption.weight(.semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    var body: some View {
        NavigationStack {
            TaxSuiteScreenSurface {
                VStack(spacing: 10) {
                    contributionCalendarCard

                    List {
                        Section(header: dailyExpenseHeader) {
                            if dailyExpenses.isEmpty {
                                Text("記録はありません").foregroundColor(.gray)
                            } else {
                                ForEach(dailyExpenses) { expense in
                                    Button(action: { editingExpense = expense }) {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 3) {
                                                HStack(spacing: 5) {
                                                    // ジオフェンス由来なら設定と同じピンで「自動記録」を示す
                                                    if expense.locationTriggerName != nil {
                                                        Image(systemName: "mappin.circle.fill")
                                                            .font(.caption2)
                                                            .foregroundColor(Color(red: 0.22, green: 0.55, blue: 0.30))
                                                            .accessibilityLabel("自動記録")
                                                    }
                                                    Text(expense.title).font(.subheadline.weight(.semibold)).foregroundColor(.black)
                                                }
                                                Text(expense.project).font(.caption2).foregroundColor(.gray)
                                                if !expense.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                                    Text(expense.note).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                                                }
                                            }
                                            Spacer()
                                            Text("¥\(Int(expense.effectiveAmount).formatted())")
                                                .taxSuiteAmountStyle(size: 15, weight: .semibold, tracking: -0.2)
                                                .foregroundColor(.black)
                                        }
                                        .padding(.vertical, 2)
                                    }
                                    // ジオフェンス由来はリスト行全体を薄緑にしてヒートマップと揃える
                                    .listRowBackground(
                                        expense.locationTriggerName != nil
                                            ? Color(red: 0.89, green: 0.96, blue: 0.90)
                                            : Color(UIColor.secondarySystemGroupedBackground)
                                    )
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            deleteDailyExpense(expense)
                                        } label: {
                                            Label("削除", systemImage: "trash.fill")
                                        }
                                        .tint(.red)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("カレンダー")
            .onChange(of: selectedDate) { _, newValue in
                if !calendar.isDate(newValue, equalTo: displayedMonth, toGranularity: .month) {
                    displayedMonth = startOfMonth(for: newValue)
                }
            }
            .sheet(item: $editingExpense) { expense in
                ExpenseEditView(expense: expense)
            }
            // 選択日付で経費を新規作成
            .sheet(isPresented: $showingNewExpenseSheet) {
                ExpenseEditView(expense: nil, initialDate: selectedDate)
            }
            // 年月選択ピッカー
            .sheet(isPresented: $showingMonthPicker) {
                MonthYearPickerSheet(
                    initialMonth: displayedMonth,
                    calendar: calendar
                ) { picked in
                    let newMonth = startOfMonth(for: picked)
                    displayedMonth = newMonth
                    selectedDate = preferredSelectionDate(in: newMonth)
                }
                .presentationDetents([.medium])
            }
        }
    }

    private var contributionCalendarCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: { shiftMonth(by: -1) }) {
                    Image(systemName: "chevron.left")
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(.black)
                        .frame(width: 32, height: 32)
                        .background(Color.black.opacity(0.05))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Spacer()

                // タイトルをタップすると年月ピッカーを表示し、任意の年月へ直接ジャンプできる
                Button(action: { showingMonthPicker = true }) {
                    VStack(spacing: 3) {
                        HStack(spacing: 4) {
                            Text(displayedMonthTitle)
                                .font(.headline)
                                .foregroundColor(.black)
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.bold))
                                .foregroundColor(.black.opacity(0.6))
                        }
                        Text("黄=0円 / 緑=支出あり")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("年月を選択")
                .accessibilityHint("タップして年月を直接指定します")

                Spacer()

                Button(action: { shiftMonth(by: 1) }) {
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(.black)
                        .frame(width: 32, height: 32)
                        .background(Color.black.opacity(0.05))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 6) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(Array(monthGrid.enumerated()), id: \.offset) { _, date in
                    if let date {
                        Button(action: { selectedDate = date }) {
                            dayCell(for: date)
                        }
                        .buttonStyle(.plain)
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.clear)
                            .frame(height: 36)
                    }
                }
            }

            HStack(spacing: 6) {
                Text("少")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                ForEach(0..<4, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(legendColor(for: level))
                        .frame(width: 16, height: 16)
                }
                Text("多")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(16)
        .background(Color.white)
        .cornerRadius(20)
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private func dayCell(for date: Date) -> some View {
        let total = dailyTotalsByDate[calendar.startOfDay(for: date)] ?? 0
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(date)

        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(heatmapColor(for: date, total: total))

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isSelected ? Color.black : (isToday ? Color.black.opacity(0.22) : Color.clear),
                    lineWidth: isSelected ? 1.8 : 1
                )

            Text(dayNumberString(for: date))
                .font(.caption2.weight(isSelected ? .bold : .medium))
                .foregroundColor(dayNumberColor(for: date, total: total))
        }
        .frame(height: 36)
    }

    private var displayedMonthTitle: String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy年M月"
        return formatter.string(from: displayedMonth)
    }

    private func dayNumberString(for date: Date) -> String {
        String(calendar.component(.day, from: date))
    }

    private func heatmapColor(for date: Date, total: Double) -> Color {
        let today = calendar.startOfDay(for: Date())
        let normalizedDate = calendar.startOfDay(for: date)

        if normalizedDate > today {
            return Color.white
        }

        guard total > 0 else {
            return Color.yellow.opacity(0.15)
        }

        let intensity = min(total / 10_000.0, 1.0)
        return Color(
            red: max(0.12, 0.86 - (0.64 * intensity)),
            green: max(0.42, 0.97 - (0.40 * intensity)),
            blue: max(0.14, 0.88 - (0.72 * intensity))
        )
    }

    private func dayNumberColor(for date: Date, total: Double) -> Color {
        let today = calendar.startOfDay(for: Date())
        let normalizedDate = calendar.startOfDay(for: date)

        guard normalizedDate <= today, total > 0 else {
            return .black
        }

        return min(total / 10_000.0, 1.0) >= 0.72 ? .white : .black
    }

    private func legendColor(for level: Int) -> Color {
        switch level {
        case 0:
            return Color.yellow.opacity(0.15)
        case 1:
            return heatmapLegendColor(intensity: 0.25)
        case 2:
            return heatmapLegendColor(intensity: 0.6)
        default:
            return heatmapLegendColor(intensity: 1.0)
        }
    }

    private func heatmapLegendColor(intensity: Double) -> Color {
        Color(
            red: max(0.12, 0.86 - (0.64 * intensity)),
            green: max(0.42, 0.97 - (0.40 * intensity)),
            blue: max(0.14, 0.88 - (0.72 * intensity))
        )
    }

    private func shiftMonth(by value: Int) {
        guard let shiftedMonth = calendar.date(byAdding: .month, value: value, to: displayedMonth) else { return }
        let nextMonth = startOfMonth(for: shiftedMonth)
        displayedMonth = nextMonth
        selectedDate = preferredSelectionDate(in: nextMonth)
    }

    private func preferredSelectionDate(in month: Date) -> Date {
        let selectedDay = calendar.component(.day, from: selectedDate)
        let maxDay = calendar.range(of: .day, in: .month, for: month)?.count ?? selectedDay

        var components = calendar.dateComponents([.year, .month], from: month)
        components.day = min(selectedDay, maxDay)
        return calendar.date(from: components) ?? month
    }

    private func startOfMonth(for date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    private func deleteDailyExpenses(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(dailyExpenses[index])
        }
        try? modelContext.save()
    }

    private func deleteDailyExpense(_ expense: ExpenseItem) {
        modelContext.delete(expense)
        try? modelContext.save()
    }
}

// 年月を直接選べるピッカー。カレンダー画面と分析画面の両方から利用する。
struct MonthYearPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let initialMonth: Date
    let calendar: Calendar
    let onPick: (Date) -> Void

    // 選択肢は「今年の +1 年」から「2015年」までを降順で表示。
    // 経費アプリの過去データを遡れる範囲として十分な幅を確保する。
    private let yearRange: [Int]
    private let monthRange: [Int] = Array(1...12)

    @State private var selectedYear: Int
    @State private var selectedMonth: Int

    init(initialMonth: Date, calendar: Calendar, onPick: @escaping (Date) -> Void) {
        self.initialMonth = initialMonth
        self.calendar = calendar
        self.onPick = onPick

        let components = calendar.dateComponents([.year, .month], from: initialMonth)
        let currentYear = calendar.component(.year, from: Date())
        let startYear = min(components.year ?? currentYear, 2015)
        let endYear = max(currentYear + 1, components.year ?? currentYear)
        self.yearRange = Array((startYear...endYear).reversed())

        _selectedYear = State(initialValue: components.year ?? currentYear)
        _selectedMonth = State(initialValue: components.month ?? 1)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Picker("年", selection: $selectedYear) {
                        ForEach(yearRange, id: \.self) { year in
                            Text("\(year)年").tag(year)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(maxWidth: .infinity)

                    Picker("月", selection: $selectedMonth) {
                        ForEach(monthRange, id: \.self) { month in
                            Text("\(month)月").tag(month)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 12)
            }
            .navigationTitle("年月を選択")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("表示") {
                        var components = DateComponents()
                        components.year = selectedYear
                        components.month = selectedMonth
                        components.day = 1
                        if let date = calendar.date(from: components) {
                            onPick(date)
                        }
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }
}

struct AllHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ExpenseItem.timestamp, order: .reverse) private var allExpenses: [ExpenseItem]
    private var externalEditingExpense: Binding<ExpenseItem?>?
    @State private var viewMode: Int = 0
    @State private var localEditingExpense: ExpenseItem?

    init(editingExpense: Binding<ExpenseItem?>? = nil) {
        self.externalEditingExpense = editingExpense
    }

    private var editingExpense: Binding<ExpenseItem?> {
        externalEditingExpense ?? $localEditingExpense
    }

    var groupedByMonth: [(String, [ExpenseItem])] {
        let dict = Dictionary(grouping: allExpenses) { item in
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy年MM月"
            return formatter.string(from: item.timestamp)
        }
        return dict.sorted { $0.key > $1.key }
    }

    var body: some View {
        TaxSuiteScreenSurface {
            VStack(spacing: 0) {
                Picker("表示モード", selection: $viewMode) {
                    Text("月別まとめ").tag(0)
                    Text("すべて").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()

                List {
                    if allExpenses.isEmpty {
                        Text("まだ記録がありません").foregroundColor(.gray)
                    } else if viewMode == 0 {
                        ForEach(groupedByMonth, id: \.0) { monthString, itemsInMonth in
                            Section(header: Text(monthString).taxSuiteListHeaderStyle()) {
                                ForEach(itemsInMonth) { expense in
                                    expenseRow(expense)
                                }
                                .onDelete { offsets in
                                    deleteExpenses(itemsInMonth, at: offsets)
                                }
                            }
                        }
                    } else {
                        ForEach(allExpenses) { expense in
                            expenseRow(expense)
                        }
                        .onDelete(perform: deleteAllExpenses)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("すべての履歴")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: editingExpense) { expense in
            ExpenseEditView(expense: expense)
        }
    }

    private func expenseRow(_ expense: ExpenseItem) -> some View {
        Button(action: { editingExpense.wrappedValue = expense }) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(expense.title).font(.subheadline.weight(.semibold)).foregroundColor(.black)
                    HStack {
                        Text(expense.project)
                            .font(.caption2)
                            .foregroundColor(.gray)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(6)
                        Text(expense.timestamp, style: .date).font(.caption2).foregroundColor(.gray)
                    }
                    if !expense.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(expense.note).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Text("¥\(Int(expense.effectiveAmount).formatted())")
                    .taxSuiteAmountStyle(size: 16, weight: .semibold, tracking: -0.2)
                    .foregroundColor(.black)
            }
            .padding(.vertical, 2)
        }
    }

    private func deleteAllExpenses(at offsets: IndexSet) {
        deleteExpenses(allExpenses, at: offsets)
    }

    private func deleteExpenses(_ expenses: [ExpenseItem], at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(expenses[index])
        }
        try? modelContext.save()
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
                || term.category.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        TaxSuiteScreenSurface {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("TaxSuite ミニ辞典")
                            .font(.title3.bold())
                        Text("税務とお金まわりの基本を、短く確認できます。")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding(.vertical, 2)
                }

                ForEach(GlossaryTerm.Category.allCases, id: \.self) { category in
                    let terms = filteredTerms.filter { $0.category == category }

                    if !terms.isEmpty {
                        Section(category.displayName) {
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
        }
        .navigationTitle("税の知識")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "用語を検索")
    }
}

struct GlossaryTermDetailView: View {
    let term: GlossaryTerm

    var body: some View {
        TaxSuiteScreenSurface {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(term.category.displayName)
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

                    if let sources = term.sources, !sources.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 6) {
                                Image(systemName: "link")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("参考（公式ソース）")
                                    .font(.subheadline.bold())
                                    .foregroundColor(.secondary)
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(sources, id: \.url) { source in
                                    if let url = URL(string: source.url) {
                                        Link(destination: url) {
                                            HStack(alignment: .top, spacing: 8) {
                                                Image(systemName: "arrow.up.right.square")
                                                    .font(.footnote)
                                                    .foregroundColor(.blue)
                                                    .padding(.top, 2)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(source.title)
                                                        .font(.subheadline)
                                                        .foregroundColor(.blue)
                                                        .multilineTextAlignment(.leading)
                                                    Text(source.url)
                                                        .font(.caption2)
                                                        .foregroundColor(.secondary)
                                                        .lineLimit(1)
                                                        .truncationMode(.middle)
                                                }
                                                Spacer(minLength: 0)
                                            }
                                        }
                                    }
                                }
                            }
                            Text("※ 最新の内容は公式サイトでご確認ください。")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.blue.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
        }
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
        TaxSuiteScreenSurface {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("書き出し前の確認")
                            .font(.title3.bold())
                        Text(format.previewSummary)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding(.vertical, 2)
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
        }
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
    @AppStorage("taxAdvisorName")      private var advisorName:   String = ""
    @AppStorage("taxAdvisorEmail")     private var advisorEmail:  String = ""
    @AppStorage("taxSuiteSenderName")  private var senderName:    String = ""
    @AppStorage("taxSuiteBusinessName") private var businessName: String = ""

    let taxRate: Double

    @State private var reportType: ReportType = .monthly
    @State private var selectedFormat: ExportFormat
    @State private var targetMonth: Date = Date()
    @State private var note: String = ""
    @State private var sharePayload: SharePayload?
    @State private var exportErrorMessage: String?

    // Gmail 下書き作成の状態
    @State private var gmailDraftStatus: GmailDraftStatus = .idle

    enum GmailDraftStatus: Equatable {
        case idle
        case creating
        case success
        case failure(String)
    }

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
        TaxSuiteScreenSurface {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("報告をそのまま外に出す")
                            .font(.title3.bold())
                        Text("件名・本文・CSVをまとめて準備します。")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding(.vertical, 2)
                }

                Section(header: Text("相手と差出人").taxSuiteListHeaderStyle()) {
                    TextField("宛名（例: 山田先生）", text: $advisorName)
                    HStack(spacing: 8) {
                        Image(systemName: "envelope")
                            .foregroundColor(.secondary)
                            .frame(width: 18)
                        TextField("宛先メールアドレス", text: $advisorEmail)
                            .keyboardType(.emailAddress)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
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

                // Gmail 直接送信セクション
                Section {
                    Button(action: { Task { await createGmailDraft() } }) {
                        HStack(spacing: 12) {
                            ZStack {
                                if gmailDraftStatus == .creating {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .scaleEffect(0.85)
                                } else if gmailDraftStatus == .success {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                        .font(.system(size: 20))
                                } else {
                                    Image(systemName: "tray.and.arrow.up.fill")
                                        .foregroundColor(.white)
                                        .font(.system(size: 16))
                                }
                            }
                            .frame(width: 24, height: 24)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(gmailDraftStatus == .success ? "Gmail に下書きを保存しました" : "Gmail に下書きを作成")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                Text(gmailDraftStatus == .success
                                     ? "Gmail アプリの「下書き」から確認できます"
                                     : advisorEmail.isEmpty ? "宛先メールアドレスを入力するとToに自動入力" : "宛先: \(advisorEmail)")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.8))
                            }
                            Spacer()
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 4)
                    }
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(gmailDraftStatus == .success ? Color.green : Color.black)
                            .padding(.vertical, 2)
                    )
                    .disabled(gmailDraftStatus == .creating)

                    if case .failure(let msg) = gmailDraftStatus {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(msg)
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                        .padding(.vertical, 4)
                    }
                } footer: {
                    Text("Gmail アカウントにログインしていると、ワンタップで下書きが作成されます。")
                        .font(.caption2)
                }

                // フォールバック：共有シート
                Section {
                    Button(action: shareDraft) {
                        HStack(spacing: 12) {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundColor(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("共有シートで開く")
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                Text("Mail・AirDrop・その他アプリに渡す")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
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

    // MARK: - Gmail 下書き作成

    @MainActor
    private func createGmailDraft() async {
        guard GoogleAuthService.shared.isSignedIn else {
            gmailDraftStatus = .failure("Googleアカウントにログインしてください（設定 → 連携）")
            return
        }

        gmailDraftStatus = .creating

        do {
            let pkg = try ReportDraftBuilder.makeDraft(
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

            try await GmailAPIService.shared.createDraft(
                to: advisorEmail,
                subject: pkg.subject,
                body: pkg.body,
                csvURL: pkg.attachments.first
            )

            withAnimation(.spring(response: 0.4)) {
                gmailDraftStatus = .success
            }
            // 3秒後に idle へ戻す
            try? await Task.sleep(for: .seconds(3))
            withAnimation { gmailDraftStatus = .idle }

        } catch {
            gmailDraftStatus = .failure(error.localizedDescription)
        }
    }

    // MARK: - 共有シート（フォールバック）

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
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ExpenseItem.timestamp, order: .reverse) private var expenses: [ExpenseItem]
    @Query(sort: \IncomeItem.timestamp, order: .reverse) private var incomes: [IncomeItem]
    @Binding var taxRate: Double
    @AppStorage("isTaxSuiteProEnabled") private var isTaxSuiteProEnabled = false
    @State private var exportFile: ExportFile?
    @State private var exportErrorMessage: String?
    @State private var selectedExportFormat: ExportFormat = .standard
    @State private var projectNameDrafts = TaxSuiteWidgetStore.loadProjectNames()
    @State private var savedProjectNames = TaxSuiteWidgetStore.loadProjectNames()
    @State private var isMigratingProjects = false
    @State private var projectMigrationErrorMessage: String?
    // Google Auth の状態を監視（@Observable singleton）
    @State private var authService = GoogleAuthService.shared

    var body: some View {
        NavigationStack {
            TaxSuiteScreenSurface {
                List {
                    Section {
                        Button {
                            isTaxSuiteProEnabled.toggle()
                        } label: {
                            HStack(spacing: 12) {
                                Text("TaxSuite Pro")
                                    .font(.headline)
                                    .foregroundColor(.black)
                                Spacer()
                                Text(isTaxSuiteProEnabled ? "ON" : "OFF")
                                    .font(.caption.bold())
                                    .foregroundColor(isTaxSuiteProEnabled ? .green : .secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background((isTaxSuiteProEnabled ? Color.green : Color.gray).opacity(0.12))
                                    .clipShape(Capsule())
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    Section(header: Text("計算設定")) {
                        HStack {
                            Text("推定税率")
                            Spacer()
                            Picker("", selection: $taxRate) {
                                Text("10%").tag(0.1)
                                Text("20%").tag(0.2)
                                Text("30%").tag(0.3)
                            }
                            .tint(.black)
                        }
                    }
                    Section(
                        header: Text("プロジェクト設定"),
                        footer: Text("デフォルトの3つに加えて最大\(TaxSuiteWidgetSupport.maxProjectCount)個まで追加できます。名前は自由に変更でき、空欄は「メイン業 / 副業 / その他」に戻ります。")
                    ) {
                        ForEach(projectNameDrafts.indices, id: \.self) { index in
                            TextField("プロジェクト\(index + 1)", text: Binding(
                                get: { projectNameDrafts[index] },
                                set: { projectNameDrafts[index] = $0 }
                            ))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(saveProjectNames)
                        }
                        .onDelete { indexSet in
                            deleteProjectRows(at: indexSet)
                        }

                        if projectNameDrafts.count < TaxSuiteWidgetSupport.maxProjectCount {
                            Button {
                                addProjectRow()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundColor(.blue)
                                    Text("プロジェクトを追加")
                                        .foregroundColor(.blue)
                                    Spacer()
                                    Text("\(projectNameDrafts.count) / \(TaxSuiteWidgetSupport.maxProjectCount)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        } else {
                            HStack {
                                Text("上限に達しました")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(projectNameDrafts.count) / \(TaxSuiteWidgetSupport.maxProjectCount)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    Section(header: Text("固定費")) {
                        NavigationLink(destination: RecurringExpensesSettingsView()) {
                            HStack(spacing: 12) {
                                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                                    .foregroundColor(.blue)
                                Text("固定費を管理")
                                    .font(.headline)
                                    .foregroundColor(.black)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    Section(header: Text("ショートカット")) {
                        NavigationLink(destination: WidgetButtonSettingsView()) {
                            HStack(spacing: 12) {
                                Image(systemName: "square.grid.2x2.fill")
                                    .foregroundColor(.purple)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("ショートカットを設定")
                                        .font(.headline)
                                        .foregroundColor(.black)
                                    Text("ダッシュボードとホーム画面で共通")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    Section(header: Text("場所でリマインド")) {
                        NavigationLink(destination: LocationTriggersView()) {
                            HStack(spacing: 12) {
                                Image(systemName: "mappin.and.ellipse")
                                    .foregroundColor(.red)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("ジオフェンス設定")
                                        .font(.headline)
                                        .foregroundColor(.black)
                                    Text("到着通知で経費をワンタップ記録")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
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
                                Text("書き出し結果をプレビュー")
                                    .font(.headline)
                                    .foregroundColor(.black)
                                Spacer()
                                Text(selectedExportFormat.rawValue)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }

                        Button(action: exportCSV) {
                            HStack(spacing: 12) {
                                Image(systemName: "square.and.arrow.up.fill")
                                    .foregroundColor(.orange)
                                Text("CSVを書き出す")
                                    .font(.headline)
                                    .foregroundColor(.black)
                                Spacer()
                                Text(selectedExportFormat.rawValue)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    Section(header: Text("連携")) {
                        // Google アカウント認証行（@Observable で状態を自動監視）
                        GoogleSignInRow(authService: authService)

                        if authService.isSignedIn {
                            NavigationLink(
                                destination: ReportDraftComposerView(
                                    defaultFormat: selectedExportFormat,
                                    taxRate: taxRate
                                )
                            ) {
                                HStack(spacing: 12) {
                                    Image(systemName: "paperplane.circle.fill")
                                        .foregroundColor(.indigo)
                                    Text("Gmail 用の報告下書き")
                                        .font(.headline)
                                        .foregroundColor(.black)
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            }

                            NavigationLink(destination: GmailReceiptInboxView()) {
                                HStack(spacing: 12) {
                                    Image(systemName: "envelope.open.fill")
                                        .foregroundColor(.orange)
                                    Text("領収書メールを取り込む")
                                        .font(.headline)
                                        .foregroundColor(.black)
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            }
                        } else {
                            HStack(spacing: 12) {
                                Image(systemName: "lock.fill")
                                    .foregroundColor(.gray)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Gmail 用の報告下書き")
                                        .font(.headline)
                                        .foregroundColor(.gray)
                                    Text("ログイン後に解放")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    Section(header: Text("学ぶ")) {
                        NavigationLink(destination: TaxKnowledgeGlossaryView()) {
                            HStack(spacing: 12) {
                                Image(systemName: "book.closed.fill")
                                    .foregroundColor(.green)
                                Text("税の知識ミニ辞典")
                                    .font(.headline)
                                    .foregroundColor(.black)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("設定")
            .sheet(item: $exportFile) { exportFile in
                ShareSheet(activityItems: [exportFile.url])
            }
            .overlay {
                if isMigratingProjects {
                    ZStack {
                        Color.black.opacity(0.08)
                            .ignoresSafeArea()

                        VStack(spacing: 12) {
                            ProgressView()
                                .progressViewStyle(.circular)
                            Text("過去データを更新中...")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.primary)
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 18)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .transition(.opacity)
                }
            }
            .alert("CSVを書き出せませんでした", isPresented: Binding(
                get: { exportErrorMessage != nil },
                set: { if !$0 { exportErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportErrorMessage ?? "不明なエラーが発生しました。")
            }
            .alert("プロジェクト名を更新できませんでした", isPresented: Binding(
                get: { projectMigrationErrorMessage != nil },
                set: { if !$0 { projectMigrationErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(projectMigrationErrorMessage ?? "不明なエラーが発生しました。")
            }
            .onAppear {
                let loadedProjectNames = TaxSuiteWidgetStore.loadProjectNames()
                projectNameDrafts = loadedProjectNames
                savedProjectNames = loadedProjectNames
            }
            .onDisappear(perform: saveProjectNames)
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

    private func saveProjectNames() {
        let previousNames = savedProjectNames
        let normalizedNames = TaxSuiteWidgetStore.saveProjectNames(projectNameDrafts)
        projectNameDrafts = normalizedNames
        savedProjectNames = normalizedNames

        let renamePairs = renamedProjectPairs(from: previousNames, to: normalizedNames)
        guard !renamePairs.isEmpty else { return }

        Task {
            await migrateProjectReferences(using: renamePairs)
        }
    }

    private func addProjectRow() {
        guard projectNameDrafts.count < TaxSuiteWidgetSupport.maxProjectCount else { return }
        projectNameDrafts.append("")
    }

    private func deleteProjectRows(at offsets: IndexSet) {
        // 最小件数（デフォルトの 3 件）を割らないように削除を制限する
        let minCount = TaxSuiteWidgetSupport.minProjectCount
        guard projectNameDrafts.count > minCount else { return }

        let maxDeletable = projectNameDrafts.count - minCount
        // 先頭から削除しても最小件数を保てる範囲だけ受け入れる
        let sortedOffsets = Array(offsets).sorted()
        let allowedOffsets = Array(sortedOffsets.prefix(maxDeletable))

        var updated = projectNameDrafts
        for offset in allowedOffsets.reversed() {
            guard updated.indices.contains(offset) else { continue }
            updated.remove(at: offset)
        }
        projectNameDrafts = updated
        saveProjectNames()
    }

    private func renamedProjectPairs(from previousNames: [String], to nextNames: [String]) -> [(old: String, new: String)] {
        // 追加・削除があった場合は位置ベースの比較で誤ったリネーム扱いになるので、
        // 件数が一致する「インプレース編集」のときだけ位置比較を行う。
        guard previousNames.count == nextNames.count else { return [] }

        return zip(previousNames, nextNames).compactMap { previousName, nextName in
            let trimmedPrevious = previousName.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedNext = nextName.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !trimmedPrevious.isEmpty, !trimmedNext.isEmpty, trimmedPrevious != trimmedNext else {
                return nil
            }

            return (old: trimmedPrevious, new: trimmedNext)
        }
    }

    @MainActor
    private func migrateProjectReferences(using renamePairs: [(old: String, new: String)]) async {
        guard !renamePairs.isEmpty else { return }

        isMigratingProjects = true
        defer { isMigratingProjects = false }

        await Task.yield()

        let renameLookup = Dictionary(uniqueKeysWithValues: renamePairs.map { ($0.old, $0.new) })

        do {
            var didChange = false

            let expensesToUpdate = try modelContext.fetch(FetchDescriptor<ExpenseItem>())
            for (index, expense) in expensesToUpdate.enumerated() {
                let currentProject = expense.project
                if let newProject = renameLookup[currentProject], currentProject != newProject {
                    expense.project = newProject
                    didChange = true
                }

                if index > 0 && index.isMultiple(of: 40) {
                    await Task.yield()
                }
            }

            let incomesToUpdate = try modelContext.fetch(FetchDescriptor<IncomeItem>())
            for (index, income) in incomesToUpdate.enumerated() {
                let currentProject = income.project
                if let newProject = renameLookup[currentProject], currentProject != newProject {
                    income.project = newProject
                    didChange = true
                }

                if index > 0 && index.isMultiple(of: 40) {
                    await Task.yield()
                }
            }

            let recurringExpensesToUpdate = try modelContext.fetch(FetchDescriptor<RecurringExpense>())
            for (index, recurringExpense) in recurringExpensesToUpdate.enumerated() {
                let currentProject = recurringExpense.project
                if let newProject = renameLookup[currentProject], currentProject != newProject {
                    recurringExpense.project = newProject
                    didChange = true
                }

                if index > 0 && index.isMultiple(of: 40) {
                    await Task.yield()
                }
            }

            var shortcutSlots = TaxSuiteWidgetStore.loadButtonSlots()
            var didUpdateShortcutSlots = false
            for index in shortcutSlots.indices {
                let currentProject = shortcutSlots[index].project
                if let newProject = renameLookup[currentProject], currentProject != newProject {
                    shortcutSlots[index].project = newProject
                    didUpdateShortcutSlots = true
                }
            }

            if didUpdateShortcutSlots {
                TaxSuiteWidgetStore.saveButtonSlots(shortcutSlots)
            }

            if didChange {
                try modelContext.save()
            }
        } catch {
            projectMigrationErrorMessage = error.localizedDescription
        }
    }
}

struct RecurringExpensesSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecurringExpense.dayOfMonth) private var recurringExpenses: [RecurringExpense]
    @State private var showingAddSheet = false
    @State private var editingRecurringExpense: RecurringExpense?

    var body: some View {
        TaxSuiteScreenSurface {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("毎月の固定費")
                            .font(.title3.bold())
                        Text("登録しておくと、当月分を自動追加します。")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding(.vertical, 2)
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
        }
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
    @State private var project: String = TaxSuiteWidgetStore.fallbackProjectName()
    @State private var dayOfMonth: Int = 1
    @State private var note: String = ""

    private var projects: [String] {
        TaxSuiteWidgetStore.projectNameOptions(including: recurringExpense.map { [$0.project] } ?? [project])
    }

    private var commentSamples: [String] {
        ExpenseCommentTemplate.recurringCommentSamples(for: title)
    }

    var body: some View {
        NavigationStack {
            TaxSuiteScreenSurface {
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
                    Section("コメント") {
                        VStack(alignment: .leading, spacing: 12) {
                            TextEditor(text: $note)
                                .frame(minHeight: 72)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(commentSamples, id: \.self) { sample in
                                        Button(sample) {
                                            note = sample
                                        }
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(.black)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 8)
                                        .background(Color.black.opacity(0.06))
                                        .clipShape(Capsule())
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }
            .navigationTitle(recurringExpense == nil ? "固定費を追加" : "固定費を編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存", action: saveRecurringExpense)
                        .fontWeight(.bold)
                        .disabled(title.isEmpty || amountText.isEmpty)
                }
            }
            .onAppear {
                guard let recurringExpense else {
                    project = TaxSuiteWidgetStore.fallbackProjectName()
                    return
                }
                title = recurringExpense.title
                amountText = String(Int(recurringExpense.amount))
                project = recurringExpense.project
                dayOfMonth = recurringExpense.dayOfMonth
                note = recurringExpense.note
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
            recurringExpense.note = note
        } else {
            modelContext.insert(
                RecurringExpense(
                    title: title,
                    amount: amount,
                    project: project,
                    dayOfMonth: dayOfMonth,
                    note: note
                )
            )
        }

        try? modelContext.save()
        dismiss()
    }
}

// MARK: - GoogleSignInRow

/// Google Sign-In の認証状態を表示・操作する汎用行コンポーネント。
/// `GoogleAuthService` は `@Observable` なので、`let` で渡すだけで
/// SwiftUI が `isSignedIn` 等の変化を自動追跡する。
struct GoogleSignInRow: View {
    let authService: GoogleAuthService

    @State private var isSigningIn = false
    @State private var authError: String?
    @State private var showingError = false

    var body: some View {
        if authService.isSignedIn {
            signedInContent
        } else {
            signInButton
        }
    }

    // MARK: Signed-in state

    private var signedInContent: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 22))

            VStack(alignment: .leading, spacing: 2) {
                Text(authService.userDisplayName.isEmpty ? "Google アカウント" : authService.userDisplayName)
                    .font(.headline)
                    .foregroundColor(.black)
                Text(authService.userEmail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("ログアウト") {
                authService.signOut()
            }
            .font(.caption.bold())
            .foregroundColor(.red)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.red.opacity(0.08))
            .clipShape(Capsule())
        }
        .padding(.vertical, 6)
    }

    // MARK: Not signed-in state

    private var signInButton: some View {
        Button {
            guard !isSigningIn else { return }
            Task {
                isSigningIn = true
                defer { isSigningIn = false }
                do {
                    try await authService.signIn()
                } catch {
                    authError = error.localizedDescription
                    showingError = true
                }
            }
        } label: {
            HStack(spacing: 12) {
                Group {
                    if isSigningIn {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.blue)
                    } else {
                        Image(systemName: "person.circle")
                            .foregroundColor(.blue)
                            .font(.system(size: 22))
                    }
                }
                .frame(width: 22, height: 22)

                Text(isSigningIn ? "認証中..." : "Google でログイン")
                    .font(.headline)
                    .foregroundColor(isSigningIn ? .secondary : .black)

                Spacer()

                if !isSigningIn {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .disabled(isSigningIn)
        .alert("ログインに失敗しました", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(authError ?? "不明なエラーが発生しました。")
        }
    }
}

// MARK: - GmailReceiptInboxView

/// Gmail から取得した領収書メールを一覧表示する画面。
/// 各メールの subject / from / 金額候補を表示し、タップで経費入力のヒントに使える。
struct GmailReceiptInboxView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ExpenseItem.timestamp, order: .reverse) private var expenseHistory: [ExpenseItem]

    @State private var messages: [GmailMessageSummary] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingError = false

    var body: some View {
        TaxSuiteScreenSurface {
            Group {
                if isLoading {
                    loadingView
                } else if messages.isEmpty && errorMessage == nil {
                    emptyView
                } else {
                    messageList
                }
            }
        }
        .navigationTitle("領収書メール")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await loadMessages() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .alert("取得に失敗しました", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "不明なエラー")
        }
        .task { await loadMessages() }
    }

    // MARK: Sub-views

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(1.2)
            Text("メールを取得中...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "envelope.open")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("領収書メールが見つかりませんでした")
                .foregroundColor(.secondary)
            Text("直近30日間のメールを「領収書」「Receipt」等のキーワードで検索しています。")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxHeight: .infinity)
    }

    private var messageList: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("領収書メール")
                        .font(.title3.bold())
                    Text("直近30日・\(messages.count)件 ／ 金額は自動推定です")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                .padding(.vertical, 2)
            }

            Section(header: Text("メール一覧").font(.subheadline).fontWeight(.semibold).foregroundColor(.secondary)) {
                ForEach(messages) { message in
                    GmailMessageRow(message: message, expenseHistory: expenseHistory) {
                        saveExpense(from: message)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: Actions

    private func loadMessages() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            messages = try await GmailAPIService.shared.fetchRecentReceiptEmails()
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    private func saveExpense(from message: GmailMessageSummary) {
        guard let amount = message.detectedAmount, amount > 0 else { return }
        let suggestion = ExpenseAutofillPredictor.predict(for: message.subject, from: expenseHistory)
        let category = suggestion?.category ?? "未分類"
        let project  = suggestion?.project  ?? TaxSuiteWidgetStore.fallbackProjectName()
        modelContext.insert(
            ExpenseItem(
                title: message.subject.prefix(40).description,
                amount: amount,
                category: category,
                project: project,
                note: "Gmail から取り込み"
            )
        )
        try? modelContext.save()
    }
}

// MARK: - GmailMessageRow

private struct GmailMessageRow: View {
    let message: GmailMessageSummary
    let expenseHistory: [ExpenseItem]
    let onSave: () -> Void

    @State private var saved = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "envelope.fill")
                .foregroundColor(.orange.opacity(0.8))
                .frame(width: 20)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(message.subject.isEmpty ? "(件名なし)" : message.subject)
                    .font(.body.weight(.semibold))
                    .foregroundColor(.black)
                    .lineLimit(2)

                Text(message.from)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Text(message.dateString)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                if let amount = message.detectedAmount {
                    Text("¥\(Int(amount).formatted())")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.black)
                } else {
                    Text("金額不明")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                if message.detectedAmount != nil {
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            saved = true
                        }
                        onSave()
                    } label: {
                        Label(saved ? "保存済" : "経費に追加", systemImage: saved ? "checkmark" : "plus.circle")
                            .font(.caption.bold())
                            .foregroundColor(saved ? .green : .blue)
                    }
                    .buttonStyle(.plain)
                    .disabled(saved)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct ReceiptImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// 手動追加 + スキャン確認後のドラフトをここに蓄積する
    @State private var drafts: [ReceiptBatchDraft] = []
    @State private var showingScanner = false
    /// スキャン後の未確認キュー（ページごとに1件）
    @State private var pendingReceipts: [ParsedReceipt] = []
    /// キューの先頭を確認中かどうか
    @State private var showingReview = false

    private let categoryOptions = ExpenseAutofillPredictor.defaultCategories
    private var projectOptions: [String] {
        TaxSuiteWidgetStore.projectNameOptions(including: drafts.map(\.project))
    }

    var body: some View {
        NavigationStack {
            TaxSuiteScreenSurface {
                Form {
                    // ヘッダー + スキャンボタン
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("領収書まとめ入力")
                                .font(.title3.bold())
                            Text("カメラでスキャンすると1枚ずつ確認できます。手動追加もできます。")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        .padding(.vertical, 2)

                        Button {
                            showingScanner = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "camera.viewfinder")
                                    .font(.system(size: 18, weight: .semibold))
                                Text("カメラでスキャン")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.black)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)

                        // 未確認キューのバッジ
                        if !pendingReceipts.isEmpty {
                            Label("\(pendingReceipts.count)枚の確認待ち", systemImage: "clock.badge.exclamationmark")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.orange)
                        }
                    }

                    // スキャン・手動追加された明細（編集可）
                    if !drafts.isEmpty {
                        ForEach($drafts) { $draft in
                            Section {
                                TextField("項目名", text: $draft.title)
                                WalletChargeInputView(amountText: $draft.amountText)
                                DatePicker("日付", selection: $draft.date, in: ...Date(), displayedComponents: .date)
                                    .datePickerStyle(.compact)
                                    .environment(\.locale, Locale(identifier: "ja_JP"))
                                Picker("カテゴリ", selection: $draft.category) {
                                    ForEach(categoryOptions, id: \.self) { Text($0).tag($0) }
                                }
                                Picker("プロジェクト", selection: $draft.project) {
                                    ForEach(projectOptions, id: \.self) { Text($0).tag($0) }
                                }
                                if draft.businessRatio < 1.0 {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text("事業用: \(Int(draft.businessRatio * 100))%").font(.caption).bold()
                                            Spacer()
                                            if let amt = Double(draft.amountText) {
                                                Text("計上: ¥\(Int(amt * draft.businessRatio))").font(.caption2).foregroundColor(.gray)
                                            }
                                        }
                                        Slider(value: $draft.businessRatio, in: 0...1.0, step: 0.1).tint(.black)
                                    }
                                } else {
                                    Button {
                                        withAnimation { draft.businessRatio = 0.5 }
                                    } label: {
                                        Label("按分を設定する", systemImage: "percent")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                TextField("コメント（任意）", text: $draft.note, axis: .vertical)
                                    .lineLimit(2, reservesSpace: false)
                            } header: {
                                HStack {
                                    Text("明細")
                                    Spacer()
                                    // 個別削除ボタン
                                    Button {
                                        withAnimation { drafts.removeAll { $0.id == draft.id } }
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundColor(.red)
                                            .font(.body)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    // 手動追加ボタン
                    Section {
                        Button {
                            withAnimation { drafts.append(ReceiptBatchDraft()) }
                        } label: {
                            Label("明細を手動追加", systemImage: "plus.circle")
                                .foregroundColor(.black)
                        }
                    }
                }
            }
            .navigationTitle("領収書から追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存", action: saveDrafts)
                        .fontWeight(.bold)
                        .disabled(validDrafts.isEmpty)
                }
            }
            .fullScreenCover(isPresented: $showingScanner) {
                ReceiptScannerView(
                    onParsedAll: { receipts in
                        showingScanner = false
                        guard !receipts.isEmpty else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            pendingReceipts = receipts
                            showingReview = true
                        }
                    },
                    onCancel: { showingScanner = false }
                )
            }
            // 1枚ずつ順番に確認シートを表示
            .sheet(isPresented: $showingReview, onDismiss: advanceQueue) {
                if let current = pendingReceipts.first {
                    ScannedReceiptReviewView(
                        parsed: current,
                        onConfirmed: { draft in
                            drafts.append(draft)
                            pendingReceipts.removeFirst()
                        },
                        onSkip: {
                            pendingReceipts.removeFirst()
                        },
                        queueIndex: 0,
                        queueTotal: pendingReceipts.count
                    )
                }
            }
        }
    }

    /// シートが閉じた後、キューに残りがあれば次を表示
    private func advanceQueue() {
        if !pendingReceipts.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                showingReview = true
            }
        }
    }

    private var validDrafts: [ReceiptBatchDraft] {
        drafts.filter {
            !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !(Double($0.amountText) ?? 0).isZero
        }
    }

    private func saveDrafts() {
        for draft in validDrafts {
            modelContext.insert(
                ExpenseItem(
                    timestamp: draft.date,
                    title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    amount: Double(draft.amountText) ?? 0,
                    category: draft.category,
                    project: draft.project,
                    businessRatio: draft.businessRatio,
                    note: draft.note
                )
            )
        }
        try? modelContext.save()
        dismiss()
    }
}

struct ProUpgradeView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("isTaxSuiteProEnabled") private var isTaxSuiteProEnabled = false

    var body: some View {
        TaxSuiteScreenSurface {
            VStack(spacing: 24) {
                Text("TaxSuite Pro")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .padding(.top, 12)

                Text("テスト用にそのまま有効化できます。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)

                Spacer()

                Button(isTaxSuiteProEnabled ? "すでに有効です" : "テスト用に Pro を有効化") {
                    isTaxSuiteProEnabled = true
                    dismiss()
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 24)

                Button("閉じる") { dismiss() }
                    .padding(.bottom, 28)
                    .foregroundColor(.gray)
            }
        }
    }
}

// MARK: - WidgetButtonSettingsView

/// ショートカットの 4 つのクイック追加ボタンを設定する画面。
/// スロット一覧 + ミニプレビューカード + 各スロットへの編集 NavigationLink を提供する。
struct WidgetButtonSettingsView: View {
    @Query(sort: \ExpenseItem.timestamp, order: .reverse) private var expenseHistory: [ExpenseItem]
    @Query(sort: \RecurringExpense.dayOfMonth) private var recurringExpenses: [RecurringExpense]

    @State private var slots: [WidgetButtonSlot] = TaxSuiteWidgetStore.loadButtonSlots()

    var body: some View {
        TaxSuiteScreenSurface {
            List {
                // ミニプレビューカード
                Section {
                    widgetPreviewCard
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                        .listRowBackground(Color.clear)
                }

                // スロット一覧（削除・追加可能）
                Section(header: Text("ボタン設定（最大4つ）")) {
                    ForEach($slots) { $slot in
                        NavigationLink(destination: WidgetSlotEditorView(slot: $slot, expenseHistory: Array(expenseHistory.prefix(60)), recurringExpenses: recurringExpenses)) {
                            slotRow(slot)
                        }
                    }
                    .onDelete { offsets in
                        withAnimation {
                            slots.remove(atOffsets: offsets)
                            // ID を 0 始まりで詰め直す
                            for i in slots.indices { slots[i].id = i }
                            TaxSuiteWidgetStore.saveButtonSlots(slots)
                        }
                    }

                    if slots.count < 4 {
                        Button {
                            withAnimation {
                                let projectNames = TaxSuiteWidgetStore.loadProjectNames()
                                let newSlot = WidgetButtonSlot(
                                    id: slots.count,
                                    title: "",
                                    amount: 0,
                                    category: "未分類",
                                    project: projectNames.first ?? "その他"
                                )
                                slots.append(newSlot)
                                TaxSuiteWidgetStore.saveButtonSlots(slots)
                            }
                        } label: {
                            Label("ショートカットを追加", systemImage: "plus.circle.fill")
                                .foregroundColor(.black)
                        }
                    }
                }

                // デフォルトに戻す
                Section {
                    Button(role: .destructive) {
                        withAnimation {
                            slots = WidgetButtonSlot.defaultSlots
                            TaxSuiteWidgetStore.saveButtonSlots(slots)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.counterclockwise")
                            Text("デフォルトに戻す")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("ショートカット設定")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: slots) { _, newSlots in
            TaxSuiteWidgetStore.saveButtonSlots(newSlots)
        }
    }

    // MARK: Mini preview card

    private var widgetPreviewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("プレビュー")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            // 2×2 ボタングリッド
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                spacing: 8
            ) {
                ForEach(slots) { slot in
                    previewButton(slot)
                }
            }
        }
        .padding(14)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.985, green: 0.985, blue: 0.975),
                    Color(red: 0.956, green: 0.961, blue: 0.985)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func previewButton(_ slot: WidgetButtonSlot) -> some View {
        // プレビュー上のボタンはあくまで「見た目」確認用。タップしても経費は追加されないが、
        // 押下感（ハプティック＋視覚フィードバック）は実機と同じになるよう Button 化する。
        Button(action: {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }) {
            VStack(alignment: .leading, spacing: 3) {
                Text(slot.title.isEmpty ? "未設定" : slot.title)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(slot.title.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                Text(slot.amount > 0 ? "¥\(Int(slot.amount).formatted())" : "---")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(slot.amount > 0 ? .primary : .secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.88))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.black.opacity(0.05), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PreviewButtonStyle())
        .accessibilityHint("プレビュー表示。タップしても経費は追加されません")
    }

    // MARK: Slot row

    private func slotRow(_ slot: WidgetButtonSlot) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.purple.opacity(0.12))
                    .frame(width: 32, height: 32)
                Text("\(slot.id + 1)")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.purple)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(slot.title.isEmpty ? "未設定" : slot.title)
                    .font(.body)
                    .foregroundColor(slot.title.isEmpty ? .secondary : .primary)
                Text(slot.amount > 0
                     ? "¥\(Int(slot.amount).formatted())  \(slot.category)  \(slot.project)"
                     : "金額未設定")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

// プレビュー用ボタンの押下スタイル。実機のウィジェットボタン同様の軽い縮小＋暗化フィードバックのみ行う。
private struct PreviewButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

// MARK: - WidgetSlotEditorView

/// 1 スロット分のクイック追加ボタンを編集するフォーム。
/// `@Binding` でスロットを受け取り、変更は即時に呼び元の `slots` に反映される。
struct WidgetSlotEditorView: View {
    @Binding var slot: WidgetButtonSlot
    let expenseHistory: [ExpenseItem]
    let recurringExpenses: [RecurringExpense]

    @State private var amountText: String = ""

    private let categoryOptions = ExpenseAutofillPredictor.defaultCategories
    private var projectOptions: [String] {
        TaxSuiteWidgetStore.projectNameOptions(including: [slot.project])
    }

    var body: some View {
        TaxSuiteScreenSurface {
            Form {
                // 基本情報
                Section(header: Text("ボタン情報")) {
                    TextField("名前（例: カフェ、電車）", text: $slot.title)

                    WalletChargeInputView(amountText: $amountText)
                        .onChange(of: amountText) { _, v in
                            slot.amount = Double(v) ?? slot.amount
                        }

                    Picker("カテゴリ", selection: $slot.category) {
                        ForEach(categoryOptions, id: \.self) { Text($0).tag($0) }
                    }

                    Picker("プロジェクト", selection: $slot.project) {
                        ForEach(projectOptions, id: \.self) { Text($0).tag($0) }
                    }

                    TextField("コメント（任意）", text: $slot.note, axis: .vertical)
                        .lineLimit(2...4)
                }

                // 経費履歴から選ぶ
                if !recentSuggestions.isEmpty {
                    Section(header: Text("履歴から選ぶ")) {
                        ForEach(recentSuggestions, id: \.title) { item in
                            Button {
                                applyHistoryItem(item)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title)
                                            .font(.body)
                                            .foregroundColor(.primary)
                                        Text("¥\(Int(item.effectiveAmount).formatted())  \(item.category)  \(item.project)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.up.left.circle")
                                        .foregroundColor(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // 固定費から選ぶ
                if !recurringExpenses.isEmpty {
                    Section(header: Text("固定費から選ぶ")) {
                        ForEach(recurringExpenses) { recurring in
                            Button {
                                applyRecurring(recurring)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(recurring.title)
                                            .font(.body)
                                            .foregroundColor(.primary)
                                        Text("¥\(Int(recurring.amount).formatted())  \(recurring.project)  毎月\(recurring.dayOfMonth)日")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.up.left.circle")
                                        .foregroundColor(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .navigationTitle("スロット \(slot.id + 1) を編集")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            amountText = slot.amount > 0 ? String(Int(slot.amount)) : ""
        }
    }

    // MARK: - Computed

    /// 経費履歴から重複タイトルを除いた上位 10 件
    private var recentSuggestions: [ExpenseItem] {
        var seen = Set<String>()
        return expenseHistory.filter { item in
            guard !item.title.isEmpty else { return false }
            return seen.insert(item.title).inserted
        }.prefix(10).map { $0 }
    }

    // MARK: - Actions

    private func applyHistoryItem(_ item: ExpenseItem) {
        slot.title    = item.title
        slot.amount   = item.effectiveAmount
        slot.category = item.category
        slot.project  = item.project
        slot.note     = item.note
        amountText    = String(Int(item.effectiveAmount))
    }

    private func applyRecurring(_ recurring: RecurringExpense) {
        slot.title    = recurring.title
        slot.amount   = recurring.amount
        slot.category = ExpenseAutofillPredictor.predict(for: recurring.title, from: expenseHistory)?.category ?? "未分類"
        slot.project  = recurring.project
        slot.note     = ""
        amountText    = String(Int(recurring.amount))
    }
}
