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
    @AppStorage("isTaxSuiteProEnabled") private var isTaxSuiteProEnabled = false

    var body: some View {
        if !isTaxSuiteProEnabled {
            AdBannerView()
                .frame(height: 50)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 2)
        }
    }
}

struct TaxSuiteScreenSurface<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        ZStack {
            Color(UIColor.systemGroupedBackground).ignoresSafeArea()

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
    @State private var saveError: String?
    @State private var scrollToTopTrigger = false
    @State private var showingBulkEdit = false

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
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 26) {
                                Color.clear.frame(height: 0).id("dashTop")
                                mainMetricCard
                                quickAddSection
                                todayExpensesSection
                                Spacer().frame(height: 104)
                            }
                            .padding(.top, 6)
                            .padding(.bottom, 20)
                        }
                        .scrollIndicators(.automatic)
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                if swipeRevealedExpenseID != nil {
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                        swipeRevealedExpenseID = nil
                                    }
                                }
                            }
                        )
                        .onChange(of: scrollToTopTrigger) { _, _ in
                            withAnimation(.easeOut(duration: 0.35)) {
                                proxy.scrollTo("dashTop", anchor: .top)
                            }
                        }
                    }

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
            .sheet(isPresented: $showingBulkEdit) {
                BulkExpenseEditView(expenses: selectedExpenses)
            }
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
            .alert("保存エラー", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK") { saveError = nil }
            } message: {
                Text(saveError ?? "")
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
            do { try modelContext.save() } catch { saveError = error.localizedDescription }
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
            do { try modelContext.save() } catch { saveError = error.localizedDescription }
            exitSelectionMode()
        }
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    // 選択モード時にボトムへ表示するアクションバー
    private var selectionActionBar: some View {
        HStack(spacing: 10) {
            if isTaxSuiteProEnabled {
                Button {
                    showingBulkEdit = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "pencil")
                        Text(selectedExpenseIDs.isEmpty ? "編集" : "\(selectedExpenseIDs.count)件を編集")
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.primary.opacity(0.1))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(selectedExpenseIDs.isEmpty)
            }

            Button(action: { showingBulkDeleteConfirm = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "trash.fill")
                    Text(selectedExpenseIDs.isEmpty ? "削除" : "\(selectedExpenseIDs.count)件を削除")
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

    private var selectedExpenses: [ExpenseItem] {
        todayExpenses.filter { selectedExpenseIDs.contains($0.persistentModelID) }
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
                    .foregroundColor(Color(UIColor.systemBackground))
                    .frame(width: 56, height: 56)
                    .background(Color.primary)
                    .clipShape(Circle())
                    .shadow(color: Color.primary.opacity(0.22), radius: 6, x: 0, y: 4)
            }

            Spacer()

            Button(action: toggleShortcutBar) {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(Color(UIColor.systemBackground))
                    .frame(width: 56, height: 56)
                    .background(Color.primary)
                    .clipShape(Circle())
                    .shadow(color: Color.primary.opacity(0.22), radius: 6, x: 0, y: 4)
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
                    .fill(Color.primary.opacity(0.18))
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
                Color(UIColor.secondarySystemBackground)
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
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: 42, height: 42)
                    Image(systemName: shortcutSymbol(for: slot))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
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
            if isTaxSuiteProEnabled {
                Button(action: openReceiptImporter) {
                    Label("写真で追加", systemImage: "photo.on.rectangle")
                }
            }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary)
                        .frame(width: 42, height: 42)
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Color(UIColor.systemBackground))
                }

                Text("手入力")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.primary)
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
            do { try modelContext.save() } catch { saveError = error.localizedDescription }
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
                        .foregroundColor(.primary)
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
        .background(Color(UIColor.secondarySystemBackground))
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

                    // トップへ戻るボタン（経費が3件以上のときだけ表示）
                    if todayExpenses.count >= 3 {
                        Button {
                            scrollToTopTrigger.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("トップへ")
                                    .font(.caption2.weight(.semibold))
                            }
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 14)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
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
                .foregroundColor(.primary)
                .lineLimit(1)
            Text("¥\(Int(amount))")
                .taxSuiteAmountStyle(size: 17, weight: .bold, tracking: -0.2)
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .background(Color(UIColor.secondarySystemBackground))
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
    /// 長押しが発火する前の「押されている」状態。指が触れているあいだ true になり、
    /// カード全体に軽い縮小と色のオーバーレイをかけて押下感を出す。
    /// @GestureState を使うことでスクロール開始時に自動でリセットされる。
    @GestureState private var isPressing: Bool = false

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
                        // タイトルの右側の空きスペースに、コメントを薄文字 1 行で
                        // プレビュー表示する（溢れたら末尾を "…" で省略）。
                        // 「何となく雰囲気が分かる」くらいの軽い情報密度を狙い、
                        // タイトルには layoutPriority を持たせて常に優先表示。
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(expense.title)
                                .font(.subheadline)
                                .bold()
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .layoutPriority(1)
                            if !expense.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(expense.note)
                                    .font(.caption2)
                                    .foregroundColor(.secondary.opacity(0.85))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .layoutPriority(0)
                            }
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
                            .foregroundColor(.primary)
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
            // 長押しで押し込まれている間は、わずかにカードが暗くなる。
            // 押下感を出すために薄いブラックのオーバーレイを重ねる。
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color.primary.opacity(isPressing ? 0.06 : 0))
                    .allowsHitTesting(false)
            )
            .cornerRadius(15)
            .shadow(color: .black.opacity(0.02), radius: 3, x: 0, y: 2)
            // 長押し中に 0.97 まで縮む。release or 長押し完了で 1.0 に戻る。
            .scaleEffect(isPressing ? 0.97 : 1.0)
            .offset(x: effectiveOffset)
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isSwipeRevealed)
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isSelectionMode)
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isPressing)
            .gesture(swipeGesture)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            // simultaneousGesture を使うことで ScrollView のスクロールを妨げない。
            // @GestureState はスクロール開始でジェスチャが失敗した瞬間に自動で false へ戻る。
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.45)
                    .updating($isPressing) { _, state, _ in state = true }
                    .onEnded { _ in
                        let generator = UIImpactFeedbackGenerator(style: .medium)
                        generator.impactOccurred()
                        onLongPress()
                    }
            )
            .onChange(of: isPressing) { _, pressing in
                if pressing {
                    let tap = UIImpactFeedbackGenerator(style: .soft)
                    tap.impactOccurred()
                }
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
                            .listRowBackground(requiredFieldBackground(isEmpty: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    }
                    Section(header: Text("金額")) {
                        WalletChargeInputView(amountText: $amountText)
                            .listRowBackground(requiredFieldBackground(isEmpty: amountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    }
                    Section(header: Text("日付")) {
                        DatePicker(
                            "受取日",
                            selection: $selectedDate,
                            in: ...Date(),
                            displayedComponents: [.date]
                        )
                        .datePickerStyle(.compact)
                        .tint(.primary)
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

    /// 必須項目（案件名・金額）が空のときだけ行背景をほんのり赤くする。
    private func requiredFieldBackground(isEmpty: Bool) -> Color {
        isEmpty
            ? Color.red.opacity(0.08)
            : Color(UIColor.secondarySystemGroupedBackground)
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
    var initialNote: String = ""
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
                    // 必須項目（タイトル / 金額）が未入力のセルは、行の背景をほんのり赤く染めて
                    // 「ここが足りない」と視覚で伝える。保存ボタン側の disabled はそのまま。
                    Section(header: Text("項目名"), footer: suggestionFooter) {
                        TextField("例：タクシー代", text: $title)
                            .listRowBackground(requiredFieldBackground(isEmpty: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    }
                    Section(header: Text("金額")) {
                        WalletChargeInputView(amountText: $amountText)
                            .listRowBackground(requiredFieldBackground(isEmpty: amountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    }
                    Section(header: Text("日付")) {
                        DatePicker(
                            "発生日",
                            selection: $selectedDate,
                            in: ...Date(),
                            displayedComponents: [.date]
                        )
                        .datePickerStyle(.compact)
                        .tint(.primary)
                        .environment(\.locale, Locale(identifier: "ja_JP"))
                    }
                    Section(header: Text("分類")) {
                        Picker("カテゴリ", selection: categoryBinding) {
                            ForEach(categoryOptions, id: \.self) { item in
                                Text(item).tag(item)
                            }
                        }
                        .tint(.primary)

                        Picker("プロジェクト", selection: projectBinding) {
                            ForEach(projectOptions, id: \.self) { item in
                                Text(item).tag(item)
                            }
                        }
                        .tint(.primary)
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
                                        .foregroundColor(.primary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 8)
                                        .background(Color.primary.opacity(0.06))
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
                            Slider(value: $businessRatio, in: 0...1.0, step: 0.1).tint(.primary)
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

    /// 必須項目の行背景色を返す。空なら薄赤、そうでなければフォームの既定背景。
    private func requiredFieldBackground(isEmpty: Bool) -> Color {
        isEmpty
            ? Color.red.opacity(0.08)
            : Color(UIColor.secondarySystemGroupedBackground)
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
            note = initialNote
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
                .foregroundColor(Color(UIColor.systemBackground))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary)
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
                                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                                    // ジオフェンス由来なら設定と同じピンで「自動記録」を示す
                                                    if expense.locationTriggerName != nil {
                                                        Image(systemName: "mappin.circle.fill")
                                                            .font(.caption2)
                                                            .foregroundColor(Color(red: 0.22, green: 0.55, blue: 0.30))
                                                            .accessibilityLabel("自動記録")
                                                    }
                                                    Text(expense.title)
                                                        .font(.subheadline.weight(.semibold))
                                                        .foregroundColor(.primary)
                                                        .lineLimit(1)
                                                        .layoutPriority(1)
                                                    // タイトル右の空きスペースをコメントで埋める（1 行・末尾 "…" 省略）
                                                    if !expense.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                                        Text(expense.note)
                                                            .font(.caption2)
                                                            .foregroundColor(.secondary.opacity(0.85))
                                                            .lineLimit(1)
                                                            .truncationMode(.tail)
                                                            .layoutPriority(0)
                                                    }
                                                }
                                                Text(expense.project).font(.caption2).foregroundColor(.gray)
                                            }
                                            Spacer()
                                            Text("¥\(Int(expense.effectiveAmount).formatted())")
                                                .taxSuiteAmountStyle(size: 15, weight: .semibold, tracking: -0.2)
                                                .foregroundColor(.primary)
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
                        .foregroundColor(.primary)
                        .frame(width: 32, height: 32)
                        .background(Color.primary.opacity(0.05))
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
                                .foregroundColor(.primary)
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.bold))
                                .foregroundColor(.primary.opacity(0.6))
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
                        .foregroundColor(.primary)
                        .frame(width: 32, height: 32)
                        .background(Color.primary.opacity(0.05))
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
        .background(Color(UIColor.secondarySystemBackground))
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
                    isSelected ? Color.primary : (isToday ? Color.primary.opacity(0.22) : Color.clear),
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
                    Text(expense.title).font(.subheadline.weight(.semibold)).foregroundColor(.primary)
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
                    .foregroundColor(.primary)
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
                                            .foregroundColor(.primary)
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
                        .foregroundColor(.primary)
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

// MARK: - ExpenseGuideView

private struct ExpenseGuideTemplate: Identifiable {
    let id = UUID()
    let title: String
    let category: String
    let note: String
}

private struct ExpenseGuideProfession: Identifiable {
    let id: String
    let name: String
    let icon: String
    let templates: [ExpenseGuideTemplate]
}

struct ExpenseGuideView: View {
    @State private var selectedProfessionID: String = "common"
    @State private var addingTemplate: ExpenseGuideTemplate?

    private static let professions: [ExpenseGuideProfession] = [
        ExpenseGuideProfession(id: "common", name: "共通", icon: "person.fill", templates: [
            ExpenseGuideTemplate(title: "書籍・参考書",       category: "新聞図書費",   note: "仕事に関連する書籍・参考資料"),
            ExpenseGuideTemplate(title: "打ち合わせ交通費",   category: "旅費交通費",   note: "打ち合わせ先への往復交通費（電車・バス等）"),
            ExpenseGuideTemplate(title: "カフェ（打ち合わせ）", category: "会議費",     note: "取引先との打ち合わせ時のカフェ・飲食代"),
            ExpenseGuideTemplate(title: "スマホ通信費",       category: "通信費",       note: "業務用スマートフォンの月額通信費（按分あり）"),
            ExpenseGuideTemplate(title: "自宅家賃（在宅分）", category: "地代家賃",     note: "在宅ワーク分の家賃（事業割合で按分）"),
            ExpenseGuideTemplate(title: "電気代（在宅分）",   category: "水道光熱費",   note: "在宅作業時の電気代（事業割合で按分）"),
            ExpenseGuideTemplate(title: "SaaS・ツール月額",   category: "通信費",       note: "業務で使うソフトウェア・アプリの月額利用料"),
        ]),
        ExpenseGuideProfession(id: "engineer", name: "エンジニア", icon: "laptopcomputer", templates: [
            ExpenseGuideTemplate(title: "AWSサーバー代",       category: "通信費",     note: "本番・開発環境のクラウドインフラ費用"),
            ExpenseGuideTemplate(title: "ドメイン取得・更新", category: "通信費",       note: "サービスやポートフォリオ用ドメイン代"),
            ExpenseGuideTemplate(title: "GitHub / GitLab",    category: "通信費",       note: "ソースコード管理ツールの月額利用料"),
            ExpenseGuideTemplate(title: "技術書・オンライン講座", category: "新聞図書費", note: "スキルアップ用書籍・Udemy等の動画講座"),
            ExpenseGuideTemplate(title: "キーボード・マウス", category: "消耗品費",     note: "業務用入力デバイスの購入費"),
            ExpenseGuideTemplate(title: "モニター・ディスプレイ", category: "消耗品費", note: "作業効率向上のための外部ディスプレイ購入"),
        ]),
        ExpenseGuideProfession(id: "designer", name: "デザイナー", icon: "paintbrush.fill", templates: [
            ExpenseGuideTemplate(title: "Adobe Creative Cloud", category: "通信費",    note: "Illustrator・Photoshop等のサブスク月額"),
            ExpenseGuideTemplate(title: "Figma",               category: "通信費",     note: "UIデザイン・プロトタイプ作成ツールの月額利用料"),
            ExpenseGuideTemplate(title: "商用フォント購入",    category: "消耗品費",    note: "ロゴ・資料制作用フォントのライセンス料"),
            ExpenseGuideTemplate(title: "素材・ストック画像",  category: "消耗品費",    note: "写真・アイコン素材の購入費"),
            ExpenseGuideTemplate(title: "外付けSSD・HDD",      category: "消耗品費",    note: "制作データのバックアップ用ストレージ"),
            ExpenseGuideTemplate(title: "カラーキャリブレーター", category: "消耗品費", note: "モニター色精度管理ツールの購入"),
        ]),
        ExpenseGuideProfession(id: "writer", name: "ライター", icon: "pencil", templates: [
            ExpenseGuideTemplate(title: "取材交通費",           category: "旅費交通費", note: "記事・コラム取材のための現地移動費"),
            ExpenseGuideTemplate(title: "体験・入場料（取材）", category: "会議費",     note: "記事ネタのための施設・イベント参加費"),
            ExpenseGuideTemplate(title: "Webホスティング",      category: "通信費",     note: "ブログ・オウンドメディアのサーバー費用"),
            ExpenseGuideTemplate(title: "SEO・分析ツール",      category: "通信費",     note: "キーワード調査・アクセス解析ツールの月額費"),
            ExpenseGuideTemplate(title: "文具・ノート",         category: "消耗品費",   note: "取材メモ・構成案作成用の文房具類"),
        ]),
        ExpenseGuideProfession(id: "creator", name: "動画クリエイター", icon: "video.fill", templates: [
            ExpenseGuideTemplate(title: "動画編集ソフト",     category: "通信費",       note: "Premiere Pro・DaVinci Resolve等の利用料"),
            ExpenseGuideTemplate(title: "BGM・SE素材",        category: "消耗品費",     note: "動画BGM・効果音素材の購入・利用費"),
            ExpenseGuideTemplate(title: "撮影機材消耗品",     category: "消耗品費",     note: "SDカード・バッテリー・フィルター等"),
            ExpenseGuideTemplate(title: "マイク・音声機器",   category: "消耗品費",     note: "収録用マイクやオーディオインターフェース"),
            ExpenseGuideTemplate(title: "ロケ地交通費",       category: "旅費交通費",   note: "撮影現地への移動交通費"),
            ExpenseGuideTemplate(title: "クラウドストレージ", category: "通信費",       note: "動画素材・データ保管用クラウドの月額費"),
        ]),
        ExpenseGuideProfession(id: "photographer", name: "フォトグラファー", icon: "camera.fill", templates: [
            ExpenseGuideTemplate(title: "カメラ消耗品",         category: "消耗品費",   note: "SDカード・バッテリー・フィルター等"),
            ExpenseGuideTemplate(title: "現像・プリント費",     category: "消耗品費",   note: "写真の現像・印刷・プリントアウト費用"),
            ExpenseGuideTemplate(title: "スタジオレンタル",     category: "地代家賃",   note: "撮影スタジオの使用料"),
            ExpenseGuideTemplate(title: "写真編集ソフト",       category: "通信費",     note: "Lightroom・Photoshop等の月額利用料"),
            ExpenseGuideTemplate(title: "ポートフォリオサイト", category: "通信費",     note: "作品掲載サイトのサーバー・ドメイン代"),
        ]),
        ExpenseGuideProfession(id: "consultant", name: "コンサルタント", icon: "briefcase.fill", templates: [
            ExpenseGuideTemplate(title: "名刺・印刷物",   category: "消耗品費",         note: "商談・営業用の名刺印刷費"),
            ExpenseGuideTemplate(title: "接待・会食費",   category: "接待交際費",       note: "クライアントとの接待・会食費"),
            ExpenseGuideTemplate(title: "セミナー参加費", category: "新聞図書費",       note: "業界セミナー・研修への参加費"),
            ExpenseGuideTemplate(title: "提案書印刷・製本", category: "消耗品費",       note: "クライアント向け提案書の印刷・製本費"),
        ]),
        ExpenseGuideProfession(id: "instructor", name: "講師・インストラクター", icon: "person.2.fill", templates: [
            ExpenseGuideTemplate(title: "教材・テキスト費",   category: "新聞図書費",   note: "授業・講座で使用する教材・テキスト代"),
            ExpenseGuideTemplate(title: "会場使用料",         category: "地代家賃",     note: "講義・ワークショップ開催の会場費"),
            ExpenseGuideTemplate(title: "Zoom・配信ツール",   category: "通信費",       note: "オンライン授業・配信プラットフォームの月額費"),
            ExpenseGuideTemplate(title: "配布資料印刷費",     category: "消耗品費",     note: "受講者への配布レジュメ・テキスト印刷費"),
        ]),
    ]

    private var selectedProfession: ExpenseGuideProfession {
        Self.professions.first { $0.id == selectedProfessionID } ?? Self.professions[0]
    }

    var body: some View {
        TaxSuiteScreenSurface {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("職業別 経費ガイド")
                            .font(.title3.bold())
                        Text("よく使われる経費をサンプルとして追加できます。タップして金額を入力し保存してください。")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding(.vertical, 2)
                }

                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Self.professions) { profession in
                                Button {
                                    selectedProfessionID = profession.id
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: profession.icon)
                                            .font(.system(size: 11, weight: .semibold))
                                        Text(profession.name)
                                            .font(.subheadline.weight(.semibold))
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(
                                        selectedProfessionID == profession.id
                                            ? Color.accentColor
                                            : Color.primary.opacity(0.07)
                                    )
                                    .foregroundColor(
                                        selectedProfessionID == profession.id ? .white : .primary
                                    )
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .animation(.easeInOut(duration: 0.15), value: selectedProfessionID)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))

                Section("よく使われる経費") {
                    ForEach(selectedProfession.templates) { template in
                        Button {
                            addingTemplate = template
                        } label: {
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(template.title)
                                        .font(.body.weight(.medium))
                                        .foregroundColor(.primary)
                                    Text(template.note)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 6) {
                                    Text(template.category)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundColor(.blue)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.blue.opacity(0.1))
                                        .clipShape(Capsule())
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 22))
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 1)
                        Text("追加後に金額を入力してください。金額なしでは保存できません。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("経費ガイド")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $addingTemplate) { template in
            ExpenseEditView(
                expense: nil,
                initialTitle: template.title,
                initialCategory: template.category,
                initialNote: template.note
            )
        }
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
                    .foregroundColor(.primary)

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

    // Gmail 送信・下書き作成の状態
    @State private var gmailDraftStatus: GmailDraftStatus = .idle
    @State private var gmailSendStatus: GmailDraftStatus = .idle

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
                            .foregroundColor(.primary)

                        Text(preview.body)
                            .font(.subheadline)
                            .foregroundColor(.primary)
                            .lineSpacing(5)
                    }
                    .padding(.vertical, 4)
                }

                // Gmail 送信セクション
                Section {
                    // 直接送信ボタン（宛先が必須）
                    Button(action: { Task { await sendGmailDirectly() } }) {
                        HStack(spacing: 12) {
                            ZStack {
                                if gmailSendStatus == .creating {
                                    ProgressView().progressViewStyle(.circular).scaleEffect(0.85)
                                } else if gmailSendStatus == .success {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green).font(.system(size: 20))
                                } else {
                                    Image(systemName: "paperplane.fill")
                                        .foregroundColor(.white).font(.system(size: 16))
                                }
                            }
                            .frame(width: 24, height: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(gmailSendStatus == .success ? "送信しました！" : "Gmail で直接送信")
                                    .font(.headline).foregroundColor(.white)
                                Text(advisorEmail.isEmpty ? "宛先メールアドレスを入力してください" : "送信先: \(advisorEmail)")
                                    .font(.caption).foregroundColor(.white.opacity(0.8))
                            }
                            Spacer()
                        }
                        .padding(.vertical, 10).padding(.horizontal, 4)
                    }
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(gmailSendStatus == .success ? Color.green : Color.blue)
                            .padding(.vertical, 2)
                    )
                    .disabled(advisorEmail.isEmpty || gmailSendStatus == .creating)

                    if case .failure(let msg) = gmailSendStatus {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                            Text(msg).font(.caption).foregroundColor(.orange)
                        }
                        .padding(.vertical, 4)
                    }

                    // 下書き保存ボタン（確認してから送りたい場合）
                    Button(action: { Task { await createGmailDraft() } }) {
                        HStack(spacing: 12) {
                            ZStack {
                                if gmailDraftStatus == .creating {
                                    ProgressView().progressViewStyle(.circular).scaleEffect(0.85)
                                } else if gmailDraftStatus == .success {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green).font(.system(size: 20))
                                } else {
                                    Image(systemName: "tray.and.arrow.up.fill")
                                        .foregroundColor(.secondary).font(.system(size: 16))
                                }
                            }
                            .frame(width: 24, height: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(gmailDraftStatus == .success ? "下書きを保存しました" : "下書きとして保存")
                                    .font(.subheadline).foregroundColor(.primary)
                                Text("Gmail アプリの「下書き」から確認して送信")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 6).padding(.horizontal, 4)
                    }
                    .disabled(gmailDraftStatus == .creating)

                    if case .failure(let msg) = gmailDraftStatus {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                            Text(msg).font(.caption).foregroundColor(.orange)
                        }
                        .padding(.vertical, 4)
                    }
                } footer: {
                    Text("Gmail にログイン済みの場合のみ利用できます。直接送信は宛先メールアドレスが必須です。")
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

    // MARK: - Gmail 直接送信

    @MainActor
    private func sendGmailDirectly() async {
        guard GoogleAuthService.shared.isSignedIn else {
            gmailSendStatus = .failure("Googleアカウントにログインしてください（設定 → 連携）")
            return
        }
        guard !advisorEmail.isEmpty else { return }

        gmailSendStatus = .creating

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

            try await GmailAPIService.shared.sendEmail(
                to: advisorEmail,
                subject: pkg.subject,
                body: pkg.body,
                csvURL: pkg.attachments.first
            )

            withAnimation(.spring(response: 0.4)) { gmailSendStatus = .success }
            try? await Task.sleep(for: .seconds(3))
            withAnimation { gmailSendStatus = .idle }

        } catch {
            gmailSendStatus = .failure(error.localizedDescription)
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
    @State private var store = TaxSuiteStore.shared
    @State private var showingProModal = false
    @State private var exportFile: ExportFile?
    @State private var exportErrorMessage: String?
    @State private var selectedExportFormat: ExportFormat = .standard
    @State private var showingHowTo = false
    // Google Auth の状態を監視（@Observable singleton）
    @State private var authService = GoogleAuthService.shared

    var body: some View {
        NavigationStack {
            TaxSuiteScreenSurface {
                List {
                    // MARK: - Pro (featured)
                    Section {
                        Button { showingProModal = true } label: {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(alignment: .center, spacing: 12) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(
                                                LinearGradient(
                                                    colors: [
                                                        Color.yellow.opacity(0.9),
                                                        Color.orange.opacity(0.85)
                                                    ],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                            .frame(width: 38, height: 38)
                                        Image(systemName: "crown.fill")
                                            .font(.system(size: 18, weight: .semibold))
                                            .foregroundStyle(.white)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("TaxSuite Pro")
                                            .font(.title3.weight(.bold))
                                            .foregroundColor(.primary)
                                        Text(store.isPurchased ? "すべての機能を利用できます" : "もっと便利になる拡張機能")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    proStatusPill(isOn: store.isPurchased)
                                }
                                VStack(alignment: .leading, spacing: 8) {
                                    proFeatureRow(icon: "infinity",                 text: "経費・売上の登録数が無制限")
                                    proFeatureRow(icon: "doc.text.magnifyingglass", text: "レシートスキャン自動読み取り")
                                    proFeatureRow(icon: "icloud.fill",              text: "iCloud同期（今後対応予定）")
                                    proFeatureRow(icon: "sparkles",                 text: "AIによるカテゴリ自動提案")
                                }
                                .padding(.leading, 2)
                                Text(store.isPurchased
                                     ? "ご利用ありがとうございます。"
                                     : "タップして詳細・購入画面へ")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                    .sheet(isPresented: $showingProModal) { ProUpgradeView() }

                    // MARK: - 個人設定
                    Section {
                        NavigationLink(destination: PersonalSettingsView(taxRate: $taxRate)) {
                            settingsNavContent(
                                icon: "person.crop.circle.fill",
                                tint: .blue,
                                title: "個人設定",
                                subtitle: "税率・プロジェクト名を管理"
                            )
                        }
                    }

                    // MARK: - 入力を速く
                    Section {
                        NavigationLink(destination: WidgetButtonSettingsView()) {
                            settingsNavContent(
                                icon: "square.grid.2x2.fill",
                                tint: .purple,
                                title: "ショートカット",
                                subtitle: "ダッシュボードとホーム画面で共通"
                            )
                        }
                        NavigationLink(destination: RecurringExpensesSettingsView()) {
                            settingsNavContent(
                                icon: "arrow.triangle.2.circlepath",
                                tint: .blue,
                                title: "固定費",
                                subtitle: "毎月自動で登録される経費を管理"
                            )
                        }
                        NavigationLink(destination: LocationTriggersView()) {
                            settingsNavContent(
                                icon: "mappin.and.ellipse",
                                tint: .red,
                                title: "場所でリマインド",
                                subtitle: "到着通知で経費をワンタップ記録"
                            )
                        }
                    } header: {
                        Text("入力を速く")
                    }

                    // MARK: - データ
                    Section(header: Text("データ")) {
                        HStack {
                            settingsIconTile("doc.text", tint: .gray)
                            Text("書き出し形式")
                                .font(.body)
                                .foregroundColor(.primary)
                            Spacer()
                            Picker("書き出し形式", selection: $selectedExportFormat) {
                                ForEach(ExportFormat.allCases) { format in
                                    Text(format.rawValue).tag(format)
                                }
                            }
                            .labelsHidden()
                            .tint(.primary)
                        }
                        .padding(.vertical, 2)

                        NavigationLink(destination: CSVPreviewView(format: selectedExportFormat)) {
                            settingsNavContent(
                                icon: "doc.text.magnifyingglass",
                                tint: .blue,
                                title: "書き出し結果をプレビュー",
                                trailing: selectedExportFormat.rawValue
                            )
                        }

                        Button(action: exportCSV) {
                            HStack(spacing: 12) {
                                settingsIconTile("square.and.arrow.up.fill", tint: .orange)
                                Text("CSVを書き出す")
                                    .font(.body.weight(.medium))
                                    .foregroundColor(.primary)
                                Spacer()
                                Text(selectedExportFormat.rawValue)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    // MARK: - 連携
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
                                settingsNavContent(
                                    icon: "paperplane.fill",
                                    tint: .indigo,
                                    title: "Gmail 用の報告下書き",
                                    subtitle: "CSVを添付した報告メールを作成"
                                )
                            }

                            NavigationLink(destination: GmailReceiptInboxView()) {
                                settingsNavContent(
                                    icon: "envelope.open.fill",
                                    tint: .orange,
                                    title: "領収書メールを取り込む",
                                    subtitle: "Gmailから自動で経費登録"
                                )
                            }

                            NavigationLink(destination: GoogleDriveExportView(taxRate: taxRate)) {
                                settingsNavContent(
                                    icon: "arrow.up.doc.fill",
                                    tint: .green,
                                    title: "Google Drive にエクスポート",
                                    subtitle: "月別・日付別・カテゴリ別で自動整理"
                                )
                            }
                        } else {
                            HStack(spacing: 12) {
                                settingsIconTile("lock.fill", tint: .gray)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Gmail / Drive 連携機能")
                                        .font(.body.weight(.medium))
                                        .foregroundColor(.secondary)
                                    Text("ログイン後に解放されます")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    // MARK: - ヘルプ
                    Section(header: Text("ヘルプ")) {
                        Button {
                            showingHowTo = true
                        } label: {
                            settingsNavContent(
                                icon: "sparkles",
                                tint: .pink,
                                title: "使い方を見る",
                                subtitle: "かんたんな操作のおさらい"
                            )
                        }
                        NavigationLink(destination: TaxKnowledgeGlossaryView()) {
                            settingsNavContent(
                                icon: "book.closed.fill",
                                tint: .green,
                                title: "税の知識ミニ辞典",
                                subtitle: "用語や控除をすぐに確認"
                            )
                        }
                        NavigationLink(destination: ExpenseGuideView()) {
                            settingsNavContent(
                                icon: "list.bullet.rectangle.portrait.fill",
                                tint: .orange,
                                title: "職業別 経費ガイド",
                                subtitle: "職業から使える経費を確認・追加"
                            )
                        }
                    }

                    // MARK: - アプリについて
                    Section(header: Text("アプリについて")) {
                        HStack(spacing: 12) {
                            settingsIconTile("person.fill", tint: .blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("クリエイター")
                                    .font(.body.weight(.medium))
                                    .foregroundColor(.primary)
                                Text("Ben-Kei")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 2)

                        if let contactURL = URL(string: "mailto:support@taxsuite.app") {
                            Link(destination: contactURL) {
                                HStack(spacing: 12) {
                                    settingsIconTile("envelope.fill", tint: .orange)
                                    Text("お問い合わせ")
                                        .font(.body.weight(.medium))
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }

                        HStack(spacing: 12) {
                            settingsIconTile("info.circle.fill", tint: .gray)
                            Text("バージョン")
                                .font(.body.weight(.medium))
                                .foregroundColor(.primary)
                            Spacer()
                            Text(appVersionString)
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("設定")
            .sheet(item: $exportFile) { exportFile in
                ShareSheet(activityItems: [exportFile.url])
            }
            .sheet(isPresented: $showingHowTo) {
                OnboardingView(onComplete: { showingHowTo = false }, skipPermissions: true)
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

    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func proFeatureRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(text)
                .font(.caption)
                .foregroundColor(.primary.opacity(0.85))
            Spacer()
        }
    }

    /// Pro の ON/OFF をピルで表示。形＋色＋アイコンで識別できるよう配色に依存しない。
    private func proStatusPill(isOn: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: isOn ? "checkmark" : "circle.dashed")
                .font(.caption2.weight(.bold))
            Text(isOn ? "ON" : "OFF")
                .font(.caption.weight(.bold))
        }
        .foregroundColor(isOn ? .green : .secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(
                (isOn ? Color.green : Color.secondary).opacity(0.12)
            )
        )
        .overlay(
            Capsule().strokeBorder(
                (isOn ? Color.green : Color.secondary).opacity(0.25),
                lineWidth: 0.5
            )
        )
    }

    /// 設定行のアイコンタイル。すべての行で共通の形状（角丸正方形）を使うことで、
    /// 色に頼らず視覚的な整列と階層を作る。
    private func settingsIconTile(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(0.14))
            )
    }

    /// NavigationLink / Button 内に置く統一された行レイアウト。
    /// タイトル・サブタイトル・末尾要素を型の一貫した形で表示する。
    @ViewBuilder
    private func settingsNavContent(
        icon: String,
        tint: Color,
        title: String,
        subtitle: String? = nil,
        trailing: String? = nil
    ) -> some View {
        HStack(spacing: 12) {
            settingsIconTile(icon, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundColor(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

}

// MARK: - PersonalSettingsView

private struct PersonalSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Binding var taxRate: Double

    @State private var projectNameDrafts = TaxSuiteWidgetStore.loadProjectNames()
    @State private var savedProjectNames = TaxSuiteWidgetStore.loadProjectNames()
    @State private var isMigratingProjects = false
    @State private var projectMigrationErrorMessage: String?

    var body: some View {
        TaxSuiteScreenSurface {
            List {
                // MARK: 計算設定
                Section {
                    HStack {
                        iconTile("percent", tint: .teal)
                        Text("推定税率")
                            .font(.body)
                            .foregroundColor(.primary)
                        Spacer()
                        Picker("", selection: $taxRate) {
                            Text("10%").tag(0.1)
                            Text("20%").tag(0.2)
                            Text("30%").tag(0.3)
                        }
                        .tint(.primary)
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("計算")
                } footer: {
                    Text("売上規模によって目安の税率を選択してください。わからなければ20%のままで問題ありません。")
                }

                // MARK: プロジェクト
                Section(
                    header: Text("プロジェクト"),
                    footer: Text("デフォルトの3つに加えて最大\(TaxSuiteWidgetSupport.maxProjectCount)個まで追加できます。名前は自由に変更でき、空欄は「メイン業 / 副業 / その他」に戻ります。")
                ) {
                    ForEach(projectNameDrafts.indices, id: \.self) { index in
                        HStack(spacing: 12) {
                            projectBadge(index: index)
                            TextField("プロジェクト\(index + 1)", text: Binding(
                                get: { projectNameDrafts[index] },
                                set: { projectNameDrafts[index] = $0 }
                            ))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(saveProjectNames)
                        }
                    }
                    .onDelete { indexSet in deleteProjectRows(at: indexSet) }

                    if projectNameDrafts.count < TaxSuiteWidgetSupport.maxProjectCount {
                        Button { addProjectRow() } label: {
                            HStack(spacing: 12) {
                                iconTile("plus", tint: .blue)
                                Text("プロジェクトを追加")
                                    .font(.body.weight(.medium))
                                    .foregroundColor(.blue)
                                Spacer()
                                Text("\(projectNameDrafts.count) / \(TaxSuiteWidgetSupport.maxProjectCount)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    } else {
                        HStack(spacing: 12) {
                            iconTile("checkmark", tint: .gray)
                            Text("上限に達しました")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(projectNameDrafts.count) / \(TaxSuiteWidgetSupport.maxProjectCount)")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("個人設定")
        .overlay {
            if isMigratingProjects {
                ZStack {
                    Color.primary.opacity(0.08).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().progressViewStyle(.circular)
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
        .alert("プロジェクト名を更新できませんでした", isPresented: Binding(
            get: { projectMigrationErrorMessage != nil },
            set: { if !$0 { projectMigrationErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(projectMigrationErrorMessage ?? "不明なエラーが発生しました。")
        }
        .onAppear {
            let loaded = TaxSuiteWidgetStore.loadProjectNames()
            projectNameDrafts = loaded
            savedProjectNames = loaded
        }
        .onDisappear(perform: saveProjectNames)
    }

    // MARK: Helpers

    private func iconTile(_ name: String, tint: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.opacity(0.15))
                .frame(width: 32, height: 32)
            Image(systemName: name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(tint)
        }
    }

    private func projectBadge(index: Int) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.07))
                .frame(width: 26, height: 26)
            Text("\(index + 1)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundColor(.secondary)
        }
    }

    // MARK: Project management

    private func saveProjectNames() {
        let previousNames = savedProjectNames
        let normalizedNames = TaxSuiteWidgetStore.saveProjectNames(projectNameDrafts)
        projectNameDrafts = normalizedNames
        savedProjectNames = normalizedNames
        let renamePairs = renamedProjectPairs(from: previousNames, to: normalizedNames)
        guard !renamePairs.isEmpty else { return }
        Task { await migrateProjectReferences(using: renamePairs) }
    }

    private func addProjectRow() {
        guard projectNameDrafts.count < TaxSuiteWidgetSupport.maxProjectCount else { return }
        projectNameDrafts.append("")
    }

    private func deleteProjectRows(at offsets: IndexSet) {
        let minCount = TaxSuiteWidgetSupport.minProjectCount
        guard projectNameDrafts.count > minCount else { return }
        let maxDeletable = projectNameDrafts.count - minCount
        let allowedOffsets = Array(Array(offsets).sorted().prefix(maxDeletable))
        var updated = projectNameDrafts
        for offset in allowedOffsets.reversed() {
            guard updated.indices.contains(offset) else { continue }
            updated.remove(at: offset)
        }
        projectNameDrafts = updated
        saveProjectNames()
    }

    private func renamedProjectPairs(from previousNames: [String], to nextNames: [String]) -> [(old: String, new: String)] {
        guard previousNames.count == nextNames.count else { return [] }
        return zip(previousNames, nextNames).compactMap { prev, next in
            let p = prev.trimmingCharacters(in: .whitespacesAndNewlines)
            let n = next.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty, !n.isEmpty, p != n else { return nil }
            return (old: p, new: n)
        }
    }

    @MainActor
    private func migrateProjectReferences(using renamePairs: [(old: String, new: String)]) async {
        guard !renamePairs.isEmpty else { return }
        isMigratingProjects = true
        defer { isMigratingProjects = false }
        await Task.yield()
        let lookup = Dictionary(uniqueKeysWithValues: renamePairs.map { ($0.old, $0.new) })
        do {
            var didChange = false
            let expensesToUpdate = try modelContext.fetch(FetchDescriptor<ExpenseItem>())
            for (i, item) in expensesToUpdate.enumerated() {
                if let n = lookup[item.project], item.project != n { item.project = n; didChange = true }
                if i > 0 && i.isMultiple(of: 40) { await Task.yield() }
            }
            let incomesToUpdate = try modelContext.fetch(FetchDescriptor<IncomeItem>())
            for (i, item) in incomesToUpdate.enumerated() {
                if let n = lookup[item.project], item.project != n { item.project = n; didChange = true }
                if i > 0 && i.isMultiple(of: 40) { await Task.yield() }
            }
            let recurringToUpdate = try modelContext.fetch(FetchDescriptor<RecurringExpense>())
            for (i, item) in recurringToUpdate.enumerated() {
                if let n = lookup[item.project], item.project != n { item.project = n; didChange = true }
                if i > 0 && i.isMultiple(of: 40) { await Task.yield() }
            }
            var slots = TaxSuiteWidgetStore.loadButtonSlots()
            var slotsChanged = false
            for i in slots.indices {
                if let n = lookup[slots[i].project], slots[i].project != n { slots[i].project = n; slotsChanged = true }
            }
            if slotsChanged { TaxSuiteWidgetStore.saveButtonSlots(slots) }
            if didChange { try modelContext.save() }
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
    @State private var deleteError: String?

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
                                            .foregroundColor(.primary)
                                        HStack(spacing: 8) {
                                            Text(recurringExpense.project)
                                                .font(.caption2)
                                                .foregroundColor(.gray)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.gray.opacity(0.1))
                                                .cornerRadius(6)
                                            Text(recurringExpense.frequencyDisplayLabel)
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
                                        .foregroundColor(.primary)
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
        .alert("削除エラー", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    private func deleteRecurringExpenses(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(recurringExpenses[index])
        }
        do { try modelContext.save() } catch { deleteError = error.localizedDescription }
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
    @State private var saveError: String?
    @State private var frequency: RecurringFrequency = .monthly
    @State private var dayOfWeek: Int = 2  // 1=日, 2=月, …, 7=土

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
                    Section("繰り返し頻度") {
                        Picker("頻度", selection: $frequency) {
                            ForEach(RecurringFrequency.allCases, id: \.self) { f in
                                Text(f.label).tag(f)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    if frequency == .weekly || frequency == .biweekly {
                        Section("実行曜日") {
                            Picker("曜日", selection: $dayOfWeek) {
                                Text("月曜日").tag(2)
                                Text("火曜日").tag(3)
                                Text("水曜日").tag(4)
                                Text("木曜日").tag(5)
                                Text("金曜日").tag(6)
                                Text("土曜日").tag(7)
                                Text("日曜日").tag(1)
                            }
                            .pickerStyle(.menu)
                        }
                    }

                    if frequency == .monthly || frequency == .quarterly {
                        Section(frequency == .quarterly ? "各四半期の引き落とし日" : "引き落とし日") {
                            Stepper(value: $dayOfMonth, in: 1...31) {
                                Text(frequency == .quarterly ? "各四半期 \(dayOfMonth) 日" : "毎月 \(dayOfMonth) 日")
                            }
                            Text("存在しない日付はその月の末日に自動調整します。")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
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
                                        .foregroundColor(.primary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 8)
                                        .background(Color.primary.opacity(0.06))
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
            .alert("保存エラー", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK") { saveError = nil }
            } message: {
                Text(saveError ?? "")
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
                frequency = RecurringFrequency(rawValue: recurringExpense.frequency) ?? .monthly
                dayOfWeek = recurringExpense.dayOfWeek
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
            recurringExpense.frequency = frequency.rawValue
            recurringExpense.dayOfWeek = dayOfWeek
        } else {
            modelContext.insert(
                RecurringExpense(
                    title: title,
                    amount: amount,
                    project: project,
                    dayOfMonth: dayOfMonth,
                    note: note,
                    frequency: frequency.rawValue,
                    dayOfWeek: dayOfWeek
                )
            )
        }

        do {
            try modelContext.save()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
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
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.green.opacity(0.14))
                    .frame(width: 30, height: 30)
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.green)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(authService.userDisplayName.isEmpty ? "Google アカウント" : authService.userDisplayName)
                    .font(.body.weight(.medium))
                    .foregroundColor(.primary)
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
        .padding(.vertical, 2)
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
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.blue.opacity(0.14))
                        .frame(width: 30, height: 30)
                    if isSigningIn {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.blue)
                            .controlSize(.small)
                    } else {
                        Image(systemName: "person.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.blue)
                    }
                }

                Text(isSigningIn ? "認証中…" : "Google でログイン")
                    .font(.body.weight(.medium))
                    .foregroundColor(isSigningIn ? .secondary : .primary)

                Spacer()

                if !isSigningIn {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 2)
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

// MARK: - GoogleDriveExportView

enum DriveOrganizationStyle: String, CaseIterable, Identifiable {
    case byDate     = "日付別"
    case byCategory = "カテゴリ別"
    case both       = "両方"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .byDate:     return "calendar"
        case .byCategory: return "tag.fill"
        case .both:       return "square.grid.2x2.fill"
        }
    }

    var description: String {
        switch self {
        case .byDate:     return "日ごとに1ファイル出力"
        case .byCategory: return "カテゴリごとに1ファイル出力"
        case .both:       return "日付別・カテゴリ別の両方のフォルダを作成"
        }
    }
}

struct GoogleDriveExportView: View {
    @Query(sort: \ExpenseItem.timestamp, order: .forward) private var allExpenses: [ExpenseItem]
    @Query(sort: \IncomeItem.timestamp, order: .forward)  private var allIncomes: [IncomeItem]

    let taxRate: Double

    @State private var authService = GoogleAuthService.shared

    // 対象期間
    private var currentYear: Int { Calendar.current.component(.year, from: Date()) }
    @State private var startYear: Int  = Calendar.current.component(.year, from: Date())
    @State private var startMonth: Int = Calendar.current.component(.month, from: Date())
    @State private var endYear: Int    = Calendar.current.component(.year, from: Date())
    @State private var endMonth: Int   = Calendar.current.component(.month, from: Date())

    // オプション
    @State private var organizationStyle: DriveOrganizationStyle = .both
    @State private var exportFormat: ExportFormat = .standard

    // 状態
    @State private var isExporting    = false
    @State private var progressMessage = ""
    @State private var exportError: String?
    @State private var exportSuccess  = false

    private let calendar   = Calendar.current
    private let monthNames = ["1月","2月","3月","4月","5月","6月","7月","8月","9月","10月","11月","12月"]

    var body: some View {
        TaxSuiteScreenSurface {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Google Drive エクスポート")
                            .font(.title3.bold())
                        Text("経費データをフォルダ構造で整理してGoogle Driveへ保存します。税理士への共有や自分管理にご活用ください。")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding(.vertical, 2)
                }

                // 期間選択
                Section("対象期間") {
                    HStack {
                        Text("開始月")
                            .font(.body.weight(.medium))
                        Spacer()
                        Picker("年", selection: $startYear) {
                            ForEach((currentYear - 2)...currentYear, id: \.self) { y in
                                Text("\(y)年").tag(y)
                            }
                        }
                        .pickerStyle(.menu).tint(.primary)
                        Picker("月", selection: $startMonth) {
                            ForEach(1...12, id: \.self) { m in
                                Text(monthNames[m - 1]).tag(m)
                            }
                        }
                        .pickerStyle(.menu).tint(.primary)
                    }

                    HStack {
                        Text("終了月")
                            .font(.body.weight(.medium))
                        Spacer()
                        Picker("年", selection: $endYear) {
                            ForEach((currentYear - 2)...currentYear, id: \.self) { y in
                                Text("\(y)年").tag(y)
                            }
                        }
                        .pickerStyle(.menu).tint(.primary)
                        Picker("月", selection: $endMonth) {
                            ForEach(1...12, id: \.self) { m in
                                Text(monthNames[m - 1]).tag(m)
                            }
                        }
                        .pickerStyle(.menu).tint(.primary)
                    }

                    if monthCount > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "calendar.badge.checkmark")
                                .font(.caption).foregroundColor(.blue)
                            Text("\(monthCount)ヶ月分をエクスポートします")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.caption).foregroundColor(.orange)
                            Text("開始月が終了月より後になっています")
                                .font(.caption).foregroundColor(.orange)
                        }
                    }
                }

                // フォルダ構成
                Section("フォルダ構成") {
                    ForEach(DriveOrganizationStyle.allCases) { style in
                        Button { organizationStyle = style } label: {
                            HStack(spacing: 12) {
                                Image(systemName: style.icon)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(organizationStyle == style ? .white : .accentColor)
                                    .frame(width: 28, height: 28)
                                    .background(organizationStyle == style ? Color.accentColor : Color.accentColor.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(style.rawValue)
                                        .font(.body.weight(.medium))
                                        .foregroundColor(.primary)
                                    Text(style.description)
                                        .font(.caption2).foregroundColor(.secondary)
                                }
                                Spacer()
                                if organizationStyle == style {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }

                    folderStructurePreview
                }

                // CSV形式
                Section("CSV形式") {
                    Picker("書き出し形式", selection: $exportFormat) {
                        ForEach(ExportFormat.allCases) { f in Text(f.rawValue).tag(f) }
                    }
                    .pickerStyle(.menu).tint(.primary)
                    Text(exportFormat.subtitle)
                        .font(.caption2).foregroundColor(.secondary)
                }

                // エクスポートボタン
                Section {
                    if isExporting {
                        VStack(spacing: 14) {
                            ProgressView().scaleEffect(1.2)
                            Text(progressMessage)
                                .font(.caption).foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    } else {
                        Button { Task { await exportToDrive() } } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.up.doc.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                Text("Google Drive にエクスポート")
                                    .fontWeight(.semibold)
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(monthCount > 0 ? Color.blue : Color.gray.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(monthCount <= 0)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("Drive 連携")
        .navigationBarTitleDisplayMode(.inline)
        .alert("エクスポートエラー", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .alert("エクスポート完了", isPresented: $exportSuccess) {
            Button("OK") {}
        } message: {
            Text("TaxSuiteフォルダにエクスポートしました。\nGoogle Driveアプリでご確認ください。")
        }
    }

    // MARK: - Folder structure preview

    private var folderStructurePreview: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("フォルダ構成のプレビュー")
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.bottom, 2)

            previewRow("📁 TaxSuite/", indent: 0)
            previewRow("📁 2026年04月/", indent: 1)

            switch organizationStyle {
            case .byDate:
                previewRow("📄 2026-04-01.csv  ← 1日分の経費",  indent: 2)
                previewRow("📄 2026-04-15.csv",                   indent: 2)
                previewRow("📄 月次サマリー.csv ← 収支・税額",   indent: 2)
                previewRow("📄 売上.csv",                          indent: 2)
            case .byCategory:
                previewRow("📄 交通費.csv  ← 月の交通費まとめ", indent: 2)
                previewRow("📄 会議費.csv",                        indent: 2)
                previewRow("📄 月次サマリー.csv ← 収支・税額",   indent: 2)
                previewRow("📄 売上.csv",                          indent: 2)
            case .both:
                previewRow("📁 日付別/",                           indent: 2)
                previewRow("📄 2026-04-01.csv",                    indent: 3)
                previewRow("📁 カテゴリ別/",                       indent: 2)
                previewRow("📄 交通費.csv",                        indent: 3)
                previewRow("📄 月次サマリー.csv ← 収支・税額",   indent: 2)
                previewRow("📄 売上.csv",                          indent: 2)
            }
        }
        .padding(.vertical, 4)
    }

    private func previewRow(_ text: String, indent: Int) -> some View {
        Text(String(repeating: "  ", count: indent) + text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.secondary)
    }

    // MARK: - Computed

    private var monthCount: Int {
        let s = firstDay(year: startYear, month: startMonth)
        let e = firstDay(year: endYear,   month: endMonth)
        guard e >= s else { return 0 }
        return (calendar.dateComponents([.month], from: s, to: e).month ?? 0) + 1
    }

    private func firstDay(year: Int, month: Int) -> Date {
        var c = DateComponents(); c.year = year; c.month = month; c.day = 1
        return calendar.date(from: c) ?? Date()
    }

    private func monthsInRange() -> [(year: Int, month: Int)] {
        var result: [(Int, Int)] = []
        var y = startYear; var m = startMonth
        let endDate = firstDay(year: endYear, month: endMonth)
        repeat {
            result.append((y, m))
            let cur = firstDay(year: y, month: m)
            guard cur < endDate else { break }
            m += 1; if m > 12 { m = 1; y += 1 }
        } while true
        return result
    }

    // MARK: - Export

    @MainActor
    private func exportToDrive() async {
        isExporting = true
        progressMessage = "準備中..."

        do {
            let token  = try await GoogleAuthService.shared.freshAccessToken()
            let drive  = GoogleDriveService.shared
            let months = monthsInRange()

            progressMessage = "TaxSuiteフォルダを確認中..."
            let rootID = try await drive.findOrCreateRootFolder(token: token)

            for (index, (year, month)) in months.enumerated() {
                let label = "\(year)年\(String(format: "%02d", month))月"
                progressMessage = "\(label) をエクスポート中... (\(index + 1)/\(months.count))"

                let monthFolderID = try await drive.findOrCreateFolder(
                    name: "\(year)年\(String(format: "%02d", month))月",
                    parentID: rootID, token: token
                )
                let monthDate = firstDay(year: year, month: month)

                let expenses = allExpenses.filter {
                    calendar.isDate($0.timestamp, equalTo: monthDate, toGranularity: .month)
                }
                let incomes = allIncomes.filter {
                    calendar.isDate($0.timestamp, equalTo: monthDate, toGranularity: .month)
                }

                // 月次サマリー（常に出力）
                try await drive.uploadCSV(
                    csvString: makeSummaryCSV(expenses: expenses, incomes: incomes),
                    fileName: "月次サマリー.csv",
                    parentID: monthFolderID, token: token
                )

                // 売上 CSV
                if !incomes.isEmpty {
                    try await drive.uploadCSV(
                        csvString: makeIncomeCSV(incomes: incomes),
                        fileName: "売上.csv",
                        parentID: monthFolderID, token: token
                    )
                }

                // 日付別
                if organizationStyle == .byDate || organizationStyle == .both {
                    let targetID: String
                    if organizationStyle == .both {
                        targetID = try await drive.findOrCreateFolder(name: "日付別", parentID: monthFolderID, token: token)
                    } else {
                        targetID = monthFolderID
                    }
                    let byDay = Dictionary(grouping: expenses) { isoDate(from: $0.timestamp) }
                    for (dateStr, dayExpenses) in byDay.sorted(by: { $0.key < $1.key }) {
                        try await drive.uploadCSV(
                            csvString: makeDailyCSV(expenses: dayExpenses),
                            fileName: "\(dateStr).csv",
                            parentID: targetID, token: token
                        )
                    }
                }

                // カテゴリ別
                if organizationStyle == .byCategory || organizationStyle == .both {
                    let targetID: String
                    if organizationStyle == .both {
                        targetID = try await drive.findOrCreateFolder(name: "カテゴリ別", parentID: monthFolderID, token: token)
                    } else {
                        targetID = monthFolderID
                    }
                    let byCategory = Dictionary(grouping: expenses) { $0.category }
                    for (category, catExpenses) in byCategory.sorted(by: { $0.key < $1.key }) {
                        let safeName = category.replacingOccurrences(of: "/", with: "・")
                        try await drive.uploadCSV(
                            csvString: makeCategoryCSV(expenses: catExpenses),
                            fileName: "\(safeName).csv",
                            parentID: targetID, token: token
                        )
                    }
                }
            }

            isExporting  = false
            exportSuccess = true

        } catch {
            isExporting  = false
            exportError  = error.localizedDescription
        }
    }

    // MARK: - CSV builders

    private func makeSummaryCSV(expenses: [ExpenseItem], incomes: [IncomeItem]) -> String {
        let revenue     = incomes.reduce(0)  { $0 + $1.amount }
        let expTotal    = expenses.reduce(0) { $0 + $1.effectiveAmount }
        let tax         = TaxCalculator.calculateTax(revenue: revenue, expenses: expTotal, taxRate: taxRate)
        let takeHome    = TaxCalculator.calculateTakeHome(revenue: revenue, expenses: expTotal, taxRate: taxRate)

        var lines = ["項目,金額"]
        lines += [
            "売上合計,\(Int(revenue))",
            "経費合計,\(Int(expTotal))",
            "推定税額,\(Int(tax))",
            "推定手取り,\(Int(takeHome))",
            "経費件数,\(expenses.count)",
            "売上件数,\(incomes.count)",
            ",",
            "カテゴリ,経費合計"
        ]
        let byCategory = Dictionary(grouping: expenses) { $0.category }
        for (cat, items) in byCategory.sorted(by: { $0.key < $1.key }) {
            lines.append("\(q(cat)),\(Int(items.reduce(0) { $0 + $1.effectiveAmount }))")
        }
        return lines.joined(separator: "\n")
    }

    private func makeDailyCSV(expenses: [ExpenseItem]) -> String {
        let header = "日時,項目名,金額,カテゴリ,プロジェクト,事業割合,実質金額,コメント"
        let rows = expenses.sorted { $0.timestamp < $1.timestamp }.map { e in
            [isoDatetime(from: e.timestamp), q(e.title), "\(Int(e.amount))",
             q(e.category), q(e.project), String(format: "%.2f", e.businessRatio),
             "\(Int(e.effectiveAmount))", q(e.note)].joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n")
    }

    private func makeCategoryCSV(expenses: [ExpenseItem]) -> String {
        let header = "日時,項目名,金額,プロジェクト,事業割合,実質金額,コメント"
        let rows = expenses.sorted { $0.timestamp < $1.timestamp }.map { e in
            [isoDatetime(from: e.timestamp), q(e.title), "\(Int(e.amount))",
             q(e.project), String(format: "%.2f", e.businessRatio),
             "\(Int(e.effectiveAmount))", q(e.note)].joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n")
    }

    private func makeIncomeCSV(incomes: [IncomeItem]) -> String {
        let header = "日時,項目名,金額,プロジェクト"
        let rows = incomes.sorted { $0.timestamp < $1.timestamp }.map { i in
            [isoDate(from: i.timestamp), q(i.title), "\(Int(i.amount))", q(i.project)].joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n")
    }

    // MARK: - Helpers

    private func isoDate(from date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func isoDatetime(from date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    private func q(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
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
    @State private var saveError: String?

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
        .alert("保存エラー", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
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
        do { try modelContext.save() } catch { saveError = error.localizedDescription }
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
                    .foregroundColor(.primary)
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
                        .foregroundColor(.primary)
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
    @State private var saveError: String?

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
                            .background(Color.primary)
                            .foregroundColor(Color(UIColor.systemBackground))
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
                                        Slider(value: $draft.businessRatio, in: 0...1.0, step: 0.1).tint(.primary)
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
                                .foregroundColor(.primary)
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
            .alert("保存エラー", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK") { saveError = nil }
            } message: {
                Text(saveError ?? "")
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
        do {
            try modelContext.save()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

// MARK: - BulkExpenseEditView

private struct BulkEditDraft: Identifiable {
    let id: PersistentIdentifier
    var title: String
    var amountText: String
    var category: String
    var project: String
    var note: String
    var businessRatio: Double
    var timestamp: Date

    init(expense: ExpenseItem) {
        id             = expense.persistentModelID
        title          = expense.title
        amountText     = String(Int(expense.amount))
        category       = expense.category
        project        = expense.project
        note           = expense.note
        businessRatio  = expense.businessRatio
        timestamp      = expense.timestamp
    }
}

struct BulkExpenseEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let expenses: [ExpenseItem]

    @State private var drafts: [BulkEditDraft] = []
    @State private var saveError: String?

    private var categoryOptions: [String] { ExpenseAutofillPredictor.defaultCategories }
    private var projectOptions: [String]  { TaxSuiteWidgetStore.projectNameOptions(including: []) }

    var body: some View {
        NavigationStack {
            TaxSuiteScreenSurface {
                Form {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("まとめて編集")
                                .font(.title3.bold())
                            Text("\(expenses.count)件の経費をまとめて修正できます。")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        .padding(.vertical, 2)
                    }

                    ForEach($drafts) { $draft in
                        Section {
                            TextField("項目名", text: $draft.title)
                            WalletChargeInputView(amountText: $draft.amountText)
                            DatePicker("日付", selection: $draft.timestamp, in: ...Date(), displayedComponents: .date)
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
                                        Text("事業用: \(Int(draft.businessRatio * 100))%")
                                            .font(.caption).bold()
                                        Spacer()
                                        if let amt = Double(draft.amountText) {
                                            Text("計上: ¥\(Int(amt * draft.businessRatio))")
                                                .font(.caption2).foregroundColor(.gray)
                                        }
                                    }
                                    Slider(value: $draft.businessRatio, in: 0...1.0, step: 0.1).tint(.primary)
                                }
                            } else {
                                Button {
                                    withAnimation { draft.businessRatio = 0.5 }
                                } label: {
                                    Label("按分を設定する", systemImage: "percent")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                            }
                            TextField("コメント（任意）", text: $draft.note, axis: .vertical)
                                .lineLimit(2, reservesSpace: false)
                        } header: {
                            Text(draft.title.isEmpty ? "経費" : draft.title)
                        }
                    }
                }
            }
            .navigationTitle("まとめて編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存", action: saveEdits)
                        .fontWeight(.bold)
                        .disabled(drafts.isEmpty)
                }
            }
            .alert("保存エラー", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK") { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
            .onAppear {
                drafts = expenses.map { BulkEditDraft(expense: $0) }
            }
        }
    }

    private func saveEdits() {
        for draft in drafts {
            guard let expense = expenses.first(where: { $0.persistentModelID == draft.id }) else { continue }
            expense.title         = draft.title
            expense.amount        = Double(draft.amountText) ?? expense.amount
            expense.category      = draft.category
            expense.project       = draft.project
            expense.note          = draft.note
            expense.businessRatio = draft.businessRatio
            expense.timestamp     = draft.timestamp
        }
        do {
            try modelContext.save()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

struct ProUpgradeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = TaxSuiteStore.shared

    var body: some View {
        TaxSuiteScreenSurface {
            VStack(spacing: 0) {
                // アイコン + タイトル
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.yellow.opacity(0.9), Color.orange.opacity(0.85)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 72, height: 72)
                        Image(systemName: "crown.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    Text("TaxSuite Pro")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    if let product = store.proProduct {
                        Text(product.displayPrice + "　買い切り")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 40)
                .padding(.bottom, 32)

                // 機能一覧
                VStack(alignment: .leading, spacing: 14) {
                    proFeatureRow(icon: "infinity",                 text: "経費・売上の登録数が無制限")
                    proFeatureRow(icon: "doc.text.magnifyingglass", text: "レシートスキャン自動読み取り")
                    proFeatureRow(icon: "icloud.fill",              text: "iCloud同期（今後対応予定）")
                    proFeatureRow(icon: "sparkles",                 text: "AIによるカテゴリ自動提案")
                }
                .padding(.horizontal, 32)

                Spacer()

                // エラー表示
                if let error = store.purchaseError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                }

                // CTA
                VStack(spacing: 12) {
                    if store.isPurchased {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                            Text("購入済み - すべての機能が使えます")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.green.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(.horizontal, 24)
                    } else {
                        Button {
                            Task { await store.purchase() }
                        } label: {
                            Group {
                                if store.isLoading {
                                    ProgressView().tint(Color(UIColor.systemBackground))
                                } else if let product = store.proProduct {
                                    Text("購入する - \(product.displayPrice)")
                                } else {
                                    Text("読み込み中...")
                                }
                            }
                            .font(.headline)
                            .foregroundColor(Color(UIColor.systemBackground))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                        }
                        .background(Color.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(.horizontal, 24)
                        .disabled(store.proProduct == nil || store.isLoading)

                        Button("購入を復元") {
                            Task { await store.restore() }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .disabled(store.isLoading)
                    }

                    Button("閉じる") { dismiss() }
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 32)
                }
            }
        }
    }

    private func proFeatureRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.primary.opacity(0.85))
            Spacer()
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
                                .foregroundColor(.primary)
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
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
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
