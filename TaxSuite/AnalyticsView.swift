import SwiftUI
import Charts
import SwiftData

// MARK: - AnalyticsAxis

enum AnalyticsAxis: String, CaseIterable, Identifiable {
    case accounting      = "カテゴリ別"
    case project         = "プロジェクト別"
    case fixedVsVariable = "固定 vs 変動"

    var id: String { rawValue }

    var dimensionLabel: String {
        switch self {
        case .accounting:      "勘定科目"
        case .project:         "プロジェクト"
        case .fixedVsVariable: "分類"
        }
    }

    var chartHeader: String {
        switch self {
        case .accounting:      "カテゴリ別グラフ"
        case .project:         "プロジェクト別グラフ"
        case .fixedVsVariable: "固定費 vs 変動費グラフ"
        }
    }

    var breakdownHeader: String {
        switch self {
        case .accounting:      "勘定科目の内訳"
        case .project:         "プロジェクトの内訳"
        case .fixedVsVariable: "固定費 vs 変動費の内訳"
        }
    }
}

// MARK: - AnalyticsView

struct AnalyticsView: View {
    @Query private var expenses: [ExpenseItem]
    @AppStorage("analyticsAxis") private var analyticsAxisRaw = AnalyticsAxis.accounting.rawValue

    @State private var selectedRange: AnalyticsRange = .month
    @State private var animatedData: [CategorySum]   = []
    // 分析対象の基準日。カレンダー画面と同様にユーザーが任意の年月日へ変更できるようにする。
    @State private var referenceDate: Date = Date()
    @State private var showingRangePicker = false

    private var analyticsCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ja_JP")
        return calendar
    }

    // MARK: Stored accessors

    private var selectedAxis: AnalyticsAxis {
        AnalyticsAxis(rawValue: analyticsAxisRaw) ?? .accounting
    }

    // MARK: Filtered base data

    private var filteredExpenses: [ExpenseItem] {
        expenses.filter { selectedRange.contains($0.timestamp, reference: referenceDate) }
    }

    // 分析表示のタイトル。参照日が「今日」の範囲内ならば「今日/今週/今月」、そうでなければ具体的な日付を表示する。
    private var rangeTitle: String {
        selectedRange.title(for: referenceDate, calendar: analyticsCalendar)
    }
    private var subscriptionExpenses: [ExpenseItem] { filteredExpenses.filter(\.isSubscription) }
    private var variableExpenses: [ExpenseItem]     { filteredExpenses.filter { !$0.isSubscription } }

    private var subscriptionTotal: Double { subscriptionExpenses.reduce(0) { $0 + $1.effectiveAmount } }
    private var variableTotal: Double     { variableExpenses.reduce(0) { $0 + $1.effectiveAmount } }
    private var totalSpent: Double        { subscriptionTotal + variableTotal }
    private var subscriptionShare: Double { totalSpent > 0 ? subscriptionTotal / totalSpent : 0 }

    // MARK: Axis-driven chart data

    private var currentAxisData: [CategorySum] {
        switch selectedAxis {
        case .accounting:      return accountingCategoryData
        case .project:         return projectData
        case .fixedVsVariable: return fixedVsVariableData
        }
    }

    private var accountingCategoryData: [CategorySum] {
        Dictionary(grouping: filteredExpenses) { $0.accountingCategory }
            .map { name, items in
                CategorySum(
                    name: name,
                    total: items.reduce(0) { $0 + $1.effectiveAmount },
                    subscriptionTotal: items.filter(\.isSubscription).reduce(0) { $0 + $1.effectiveAmount }
                )
            }
            .sorted { $0.total > $1.total }
    }

    private var projectData: [CategorySum] {
        Dictionary(grouping: filteredExpenses) {
            let p = $0.project.trimmingCharacters(in: .whitespacesAndNewlines)
            return p.isEmpty ? TaxSuiteWidgetStore.fallbackProjectName() : p
        }
        .map { name, items in
            CategorySum(
                name: name,
                total: items.reduce(0) { $0 + $1.effectiveAmount },
                subscriptionTotal: items.filter(\.isSubscription).reduce(0) { $0 + $1.effectiveAmount }
            )
        }
        .sorted { $0.total > $1.total }
    }

    private var fixedVsVariableData: [CategorySum] {
        [
            CategorySum(name: "固定費", total: subscriptionTotal, subscriptionTotal: subscriptionTotal),
            CategorySum(name: "変動費", total: variableTotal,     subscriptionTotal: 0)
        ].filter { $0.total > 0 }
    }

    // MARK: Animation fingerprint

    private var analyticsFingerprint: String {
        [
            selectedRange.rawValue,
            analyticsAxisRaw,
            String(filteredExpenses.count),
            String(format: "%.0f", totalSpent),
            ISO8601DateFormatter().string(from: referenceDate)
        ].joined(separator: "|")
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            TaxSuiteScreenSurface {
                if filteredExpenses.isEmpty {
                    emptyStateView
                } else {
                    List {
                        controlsSection
                        overviewSection
                        fixedVariableCardsSection
                        chartSection
                        breakdownSection
                    }
                    .listStyle(.insetGrouped)
                    .onAppear(perform: animateChart)
                    .onChange(of: analyticsFingerprint) { _, _ in animateChart() }
                }
            }
            .navigationTitle("分析")
            .sheet(isPresented: $showingRangePicker) {
                rangePickerSheet
            }
        }
    }

    // MARK: - Empty state

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            VStack(spacing: 10) {
                Picker("期間", selection: $selectedRange) {
                    ForEach(AnalyticsRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)

                Picker("分析の軸", selection: axisBinding) {
                    ForEach(AnalyticsAxis.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)

                rangeNavigator
                    .padding(.horizontal, 20)
            }
            .padding(.top, 8)

            Spacer()
            Text("\(rangeTitle)のデータがありません")
                .foregroundColor(.gray)
            Spacer()
        }
    }

    // MARK: - Sections

    private var controlsSection: some View {
        Section {
            Picker("期間", selection: $selectedRange) {
                ForEach(AnalyticsRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.vertical, 4)

            Picker("分析の軸", selection: axisBinding) {
                ForEach(AnalyticsAxis.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.vertical, 4)

            rangeNavigator
                .padding(.vertical, 4)
        }
    }

    // 参照日を前後に移動するナビゲータ。中央のラベルをタップで任意の年月日を選択できる。
    private var rangeNavigator: some View {
        HStack(spacing: 8) {
            Button(action: { shiftReferenceDate(by: -1) }) {
                Image(systemName: "chevron.left")
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(.primary)
                    .frame(width: 32, height: 32)
                    .background(Color.black.opacity(0.05))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: { showingRangePicker = true }) {
                HStack(spacing: 4) {
                    Text(rangeTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.black.opacity(0.6))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("対象期間を選択")

            Spacer()

            Button(action: { shiftReferenceDate(by: 1) }) {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(.primary)
                    .frame(width: 32, height: 32)
                    .background(Color.black.opacity(0.05))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            // 未来方向への移動は、基準日が今日と同じ期間なら制限する
            .disabled(isAtOrBeyondToday)
            .opacity(isAtOrBeyondToday ? 0.4 : 1.0)
        }
    }

    // 未来の期間には進めないようにするための判定
    private var isAtOrBeyondToday: Bool {
        selectedRange.contains(Date(), reference: referenceDate, calendar: analyticsCalendar)
    }

    // 選択中の粒度で前後へシフトする
    private func shiftReferenceDate(by value: Int) {
        let component: Calendar.Component
        switch selectedRange {
        case .day:   component = .day
        case .week:  component = .weekOfYear
        case .month: component = .month
        }
        if let shifted = analyticsCalendar.date(byAdding: component, value: value, to: referenceDate) {
            referenceDate = shifted
        }
    }

    // 選択中の粒度に応じて日付または年月ピッカーを表示する
    @ViewBuilder
    private var rangePickerSheet: some View {
        switch selectedRange {
        case .month:
            MonthYearPickerSheet(
                initialMonth: referenceDate,
                calendar: analyticsCalendar
            ) { picked in
                referenceDate = picked
            }
            .presentationDetents([.medium])
        case .day, .week:
            AnalyticsDatePickerSheet(
                initialDate: referenceDate,
                title: selectedRange == .day ? "日付を選択" : "週を選択"
            ) { picked in
                referenceDate = picked
            }
            .presentationDetents([.medium])
        }
    }

    private var overviewSection: some View {
        Section(header: Text("概要").taxSuiteListHeaderStyle()) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(rangeTitle + "の合計支出")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Text("\(filteredExpenses.count)件")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("¥\(Int(totalSpent).formatted())")
                    .taxSuiteAmountStyle(size: 22, weight: .bold, tracking: -0.4)
                    .foregroundColor(.primary)
            }
            .padding(.vertical, 4)

            if selectedAxis == .fixedVsVariable {
                spendingTypeBreakdownCard
            }
        }
    }

    @ViewBuilder
    private var fixedVariableCardsSection: some View {
        if selectedAxis == .fixedVsVariable {
            Section {
                analyticsSummaryCard(
                    title: "固定費（サブスク）",
                    amount: subscriptionTotal,
                    count: subscriptionExpenses.count,
                    tint: Color(red: 0.14, green: 0.44, blue: 0.82)
                )
                analyticsSummaryCard(
                    title: "変動費",
                    amount: variableTotal,
                    count: variableExpenses.count,
                    tint: Color(red: 0.88, green: 0.47, blue: 0.17)
                )
            }
        }
    }

    private var chartSection: some View {
        Section(header: Text(selectedAxis.chartHeader).taxSuiteListHeaderStyle()) {
            donutChart
                .frame(height: 260)
                .padding(.vertical, 8)
                .animation(.spring(response: 0.6, dampingFraction: 0.75), value: animatedData)
        }
    }

    @ViewBuilder
    private var breakdownSection: some View {
        if selectedAxis != .fixedVsVariable {
            Section(header: Text(selectedAxis.breakdownHeader).taxSuiteListHeaderStyle()) {
                ForEach(currentAxisData) { item in
                    breakdownRow(for: item)
                }
            }
        }
    }

    // MARK: - Donut Chart (only)

    private var donutChart: some View {
        Chart(animatedData) { item in
            SectorMark(
                angle: .value("金額", item.total),
                innerRadius: .ratio(0.58),
                angularInset: 2
            )
            .foregroundStyle(by: .value(selectedAxis.dimensionLabel, item.name))
        }
        .chartLegend(.visible)
    }

    // MARK: - Breakdown row

    private func breakdownRow(for item: CategorySum) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .foregroundColor(.primary)
                if item.subscriptionTotal > 0 {
                    Text("サブスク ¥\(Int(item.subscriptionTotal).formatted()) を含む")
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
                let pct = totalSpent > 0 ? item.total / totalSpent * 100 : 0
                Text(String(format: "%.1f%%", pct))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text("¥\(Int(item.total).formatted())")
                .taxSuiteAmountStyle(size: 16, weight: .bold, tracking: -0.2)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Bindings

    private var axisBinding: Binding<AnalyticsAxis> {
        Binding(
            get: { AnalyticsAxis(rawValue: analyticsAxisRaw) ?? .accounting },
            set: { analyticsAxisRaw = $0.rawValue }
        )
    }

    // MARK: - Animation

    private func animateChart() {
        let next = currentAxisData
        animatedData = next.map {
            CategorySum(name: $0.name, total: 0, subscriptionTotal: $0.subscriptionTotal)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) {
                animatedData = next
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func analyticsSummaryCard(title: String, amount: Double, count: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.primary)
            Text("¥\(Int(amount).formatted())")
                .taxSuiteAmountStyle(size: 22, weight: .bold, tracking: -0.4)
                .foregroundColor(.primary)
            Text("\(count)件")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
        .listRowBackground(tint.opacity(0.10))
    }

    private var spendingTypeBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("支出の内訳")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                Spacer()
                Text("\(Int((subscriptionShare * 100).rounded()))% が固定費")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.blue)
            }

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let fixedWidth = max(width * subscriptionShare, subscriptionTotal > 0 ? 20 : 0)
                let varWidth   = max(width - fixedWidth, variableTotal > 0 ? 20 : 0)

                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(red: 0.14, green: 0.44, blue: 0.82))
                        .frame(width: fixedWidth)
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(red: 0.88, green: 0.47, blue: 0.17))
                        .frame(width: varWidth)
                }
            }
            .frame(height: 14)
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: subscriptionShare)

            HStack(spacing: 12) {
                legendPill(title: "固定費", amount: subscriptionTotal,
                           tint: Color(red: 0.14, green: 0.44, blue: 0.82))
                legendPill(title: "変動費", amount: variableTotal,
                           tint: Color(red: 0.88, green: 0.47, blue: 0.17))
            }
        }
        .padding(.vertical, 6)
    }

    private func legendPill(title: String, amount: Double, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(title).font(.caption).foregroundColor(.secondary)
            Text("¥\(Int(amount).formatted())").font(.caption.weight(.semibold)).foregroundColor(.primary)
        }
    }
}

// 分析画面から日付（日別・週別）を選ぶための簡易シート。
// 本日を上限とし、未来は選べないようにする。
struct AnalyticsDatePickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let initialDate: Date
    let title: String
    let onPick: (Date) -> Void

    @State private var selectedDate: Date

    init(initialDate: Date, title: String, onPick: @escaping (Date) -> Void) {
        self.initialDate = initialDate
        self.title = title
        self.onPick = onPick
        _selectedDate = State(initialValue: initialDate)
    }

    var body: some View {
        NavigationStack {
            VStack {
                DatePicker(
                    "",
                    selection: $selectedDate,
                    in: ...Date(),
                    displayedComponents: [.date]
                )
                .datePickerStyle(.graphical)
                .environment(\.locale, Locale(identifier: "ja_JP"))
                .padding()

                Spacer()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("表示") {
                        onPick(selectedDate)
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }
}
