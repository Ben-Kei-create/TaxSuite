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

    // MARK: Stored accessors

    private var selectedAxis: AnalyticsAxis {
        AnalyticsAxis(rawValue: analyticsAxisRaw) ?? .accounting
    }

    // MARK: Filtered base data

    private var filteredExpenses: [ExpenseItem] {
        expenses.filter { selectedRange.contains($0.timestamp, reference: Date()) }
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
            String(format: "%.0f", totalSpent)
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
            }
            .padding(.top, 8)

            Spacer()
            Text("\(selectedRange.title)のデータがありません")
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
        }
    }

    private var overviewSection: some View {
        Section(header: Text("概要").taxSuiteListHeaderStyle()) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedRange.title + "の合計支出")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.black)
                    Text("\(filteredExpenses.count)件")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("¥\(Int(totalSpent).formatted())")
                    .taxSuiteAmountStyle(size: 22, weight: .bold, tracking: -0.4)
                    .foregroundColor(.black)
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
                    .foregroundColor(.black)
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
                .foregroundColor(.black)
            Text("¥\(Int(amount).formatted())")
                .taxSuiteAmountStyle(size: 22, weight: .bold, tracking: -0.4)
                .foregroundColor(.black)
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
                    .foregroundColor(.black)
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
            Text("¥\(Int(amount).formatted())").font(.caption.weight(.semibold)).foregroundColor(.black)
        }
    }
}
