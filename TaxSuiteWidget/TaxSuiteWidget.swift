import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Timeline Entry

struct TaxSuiteEntry: TimelineEntry {
    let date: Date
    let snapshot: TaxSuiteWidgetSnapshot
    let buttonSlots: [WidgetButtonSlot]
    let hasAppLaunched: Bool
}

// MARK: - Timeline Provider

struct TaxSuiteProvider: TimelineProvider {
    func placeholder(in context: Context) -> TaxSuiteEntry {
        TaxSuiteEntry(date: .now, snapshot: .preview, buttonSlots: WidgetButtonSlot.defaultSlots, hasAppLaunched: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (TaxSuiteEntry) -> Void) {
        completion(readEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TaxSuiteEntry>) -> Void) {
        let entry = readEntry()
        // 翌日 0:00 と 1 時間後の早い方でリフレッシュ
        // → 「今日の経費」が日付変更時に即座に更新される
        let calendar = Calendar.current
        let tomorrow = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: .now) ?? .now)
        let oneHourLater = Date().addingTimeInterval(3600)
        let nextRefresh = min(tomorrow, oneHourLater)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func readEntry() -> TaxSuiteEntry {
        TaxSuiteEntry(
            date: .now,
            snapshot: TaxSuiteWidgetStore.load() ?? .preview,
            buttonSlots: TaxSuiteWidgetStore.loadButtonSlots(),
            hasAppLaunched: TaxSuiteWidgetStore.hasAppLaunched
        )
    }
}

// MARK: - Widget View（ファミリーごとに切り替え）

struct TaxSuiteWidgetView: View {
    var entry: TaxSuiteEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemMedium:
            if entry.hasAppLaunched { mediumView } else { notReadyView }
        case .accessoryRectangular:
            accessoryRectangularView
        case .accessoryCircular:
            accessoryCircularView
        case .accessoryInline:
            accessoryInlineView
        default:
            if entry.hasAppLaunched { mediumView } else { notReadyView }
        }
    }

    // MARK: - Not Ready（アプリ未起動）

    var notReadyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.pie.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("TaxSuite")
                .font(.headline.weight(.bold))
            Text("アプリを開いてウィジェットを有効化")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(URL(string: "taxsuite://dashboard"))
        .containerBackground(for: .widget) { widgetBackground }
    }

    // MARK: - systemMedium（左：手取り、右：ショートカット）

    var mediumView: some View {
        HStack(alignment: .top, spacing: 10) {

            Link(destination: URL(string: "taxsuite://dashboard")!) {
                VStack(alignment: .leading, spacing: 6) {
                    headerRow

                    VStack(alignment: .leading, spacing: 2) {
                        Text("推定手取り")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(currency(entry.snapshot.takeHome))
                            .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .foregroundStyle(.primary)
                    }

                    progressBar

                    VStack(spacing: 4) {
                        compactMetricRow(icon: "sun.max.fill", value: currency(entry.snapshot.todayExpensesTotal))
                        compactMetricRow(icon: "calendar",     value: currency(entry.snapshot.currentMonthExpenses))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.white.opacity(0.62))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("すぐ記録")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 2)

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
                    spacing: 6
                ) {
                    ForEach(entry.buttonSlots) { slot in
                        quickAddButton(slot: slot)
                    }
                }
            }
            .frame(width: 138, alignment: .topLeading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) { widgetBackground }
    }

    // MARK: - accessoryRectangular（ロック画面：横長）

    var accessoryRectangularView: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "yensign.circle.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text("推定手取り")
                    .font(.system(size: 10, weight: .medium))
                Spacer()
                Text(entry.snapshot.monthLabel)
                    .font(.system(size: 10))
            }
            .foregroundStyle(.secondary)

            Text(currency(entry.snapshot.takeHome))
                .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .widgetAccentable()

            Gauge(value: takeHomeProgress) {
                EmptyView()
            } currentValueLabel: {
                Text("\(Int(takeHomeProgress * 100))%")
            }
            .gaugeStyle(.accessoryLinear)
            .tint(.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(URL(string: "taxsuite://dashboard"))
        .containerBackground(for: .widget) { Color.clear }
    }

    // MARK: - accessoryCircular（ロック画面：丸）

    var accessoryCircularView: some View {
        Gauge(value: takeHomeProgress) {
            Image(systemName: "yensign")
                .font(.system(size: 8, weight: .bold))
        } currentValueLabel: {
            Text("\(Int(takeHomeProgress * 100))%")
                .font(.system(size: 11, weight: .bold, design: .rounded))
        }
        .gaugeStyle(.accessoryCircular)
        .widgetAccentable()
        .widgetURL(URL(string: "taxsuite://dashboard"))
        .containerBackground(for: .widget) { Color.clear }
    }

    // MARK: - accessoryInline（ロック画面：1行テキスト）

    var accessoryInlineView: some View {
        Label(
            "\(currency(entry.snapshot.takeHome))  残り\(Int(takeHomeProgress * 100))%",
            systemImage: "yensign.circle"
        )
        .widgetAccentable()
        .widgetURL(URL(string: "taxsuite://dashboard"))
        .containerBackground(for: .widget) { Color.clear }
    }

    // MARK: - Header Row

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text(entry.snapshot.monthLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .layoutPriority(0)
            Spacer(minLength: 6)
            Text(progressLabel)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color(red: 0.12, green: 0.33, blue: 0.18))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(red: 0.88, green: 0.95, blue: 0.89))
                .clipShape(Capsule())
        }
    }

    // MARK: - Quick Add Button

    private func quickAddButton(slot: WidgetButtonSlot) -> some View {
        Button(
            intent: WidgetQuickExpenseIntent(
                title: slot.title,
                amount: slot.amount,
                category: slot.category,
                project: slot.project,
                note: slot.note
            )
        ) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: iconName(for: slot))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(slot.title.isEmpty ? Color.secondary : Color.black.opacity(0.7))
                    Text(slot.title.isEmpty ? "未設定" : slot.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(slot.title.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Text(slot.amount > 0 ? currency(slot.amount) : "---")
                    .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(slot.amount > 0 ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.88))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.black.opacity(0.05), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(minHeight: 52)
        .disabled(slot.title.isEmpty || slot.amount <= 0)
    }

    private func iconName(for slot: WidgetButtonSlot) -> String {
        if slot.title.isEmpty { return "questionmark.circle" }
        let title = slot.title
        let category = slot.category

        let titleMap: [(String, String)] = [
            ("カフェ",   "cup.and.saucer.fill"),
            ("コーヒー", "cup.and.saucer.fill"),
            ("スタバ",   "cup.and.saucer.fill"),
            ("ランチ",   "fork.knife"),
            ("昼食",     "fork.knife"),
            ("夕食",     "fork.knife"),
            ("電車",     "tram.fill"),
            ("新幹線",   "tram.fill"),
            ("バス",     "bus.fill"),
            ("タクシー", "car.fill"),
            ("ガソリン", "fuelpump.fill"),
            ("書籍",     "book.fill"),
            ("本",       "book.fill"),
            ("消耗品",   "shippingbox.fill")
        ]
        for (keyword, icon) in titleMap where title.contains(keyword) {
            return icon
        }

        switch category {
        case "交通費":       return "tram.fill"
        case "会議費":       return "cup.and.saucer.fill"
        case "接待交際費":   return "wineglass.fill"
        case "福利厚生費":   return "fork.knife"
        case "通信費":       return "wifi"
        case "消耗品費":     return "shippingbox.fill"
        case "水道光熱費":   return "bolt.fill"
        case "広告宣伝費":   return "megaphone.fill"
        case "旅費交通費":   return "airplane"
        case "新聞図書費":   return "book.fill"
        case "支払手数料":   return "creditcard.fill"
        case "租税公課":     return "building.columns.fill"
        case "固定費":       return "arrow.triangle.2.circlepath"
        case "未分類":       return "tag"
        default:             return "yensign.circle.fill"
        }
    }

    // MARK: - Shared helpers

    private var widgetBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.985, green: 0.985, blue: 0.975),
                Color(red: 0.956, green: 0.961, blue: 0.985)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.08))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.12, green: 0.58, blue: 0.42),
                                Color(red: 0.18, green: 0.42, blue: 0.84)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(proxy.size.width * takeHomeProgress, 18))
            }
        }
        .frame(height: 10)
    }

    private func compactMetricRow(icon: String, value: String) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var takeHomeProgress: Double {
        guard entry.snapshot.currentMonthRevenue > 0 else { return 0.08 }
        return min(max(entry.snapshot.takeHome / entry.snapshot.currentMonthRevenue, 0.08), 1.0)
    }

    private var progressLabel: String {
        "残り \(Int((takeHomeProgress * 100).rounded()))%"
    }

    private func currency(_ value: Double) -> String {
        "¥\(Int(value.rounded()).formatted())"
    }
}

// MARK: - Widget Declaration

@main
struct TaxSuiteWidget: Widget {
    let kind = "TaxSuiteWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TaxSuiteProvider()) { entry in
            TaxSuiteWidgetView(entry: entry)
        }
        .configurationDisplayName("TaxSuite")
        .description("推定手取りの確認と、よく使う経費の即時追加")
        .supportedFamilies([
            .systemMedium,
            .accessoryRectangular,
            .accessoryCircular,
            .accessoryInline
        ])
    }
}

// MARK: - Preview Helpers

private extension TaxSuiteWidgetSnapshot {
    static let preview = TaxSuiteWidgetSnapshot(
        generatedAt: .now,
        monthLabel: "2026年4月",
        taxRate: 0.2,
        currentMonthRevenue: 480000,
        currentMonthExpenses: 96200,
        estimatedTax: 76760,
        takeHome: 307040,
        todayExpensesTotal: 1780,
        todayExpenseCount: 3,
        recentExpenseTitle: "カフェ"
    )
}

#Preview("Medium", as: .systemMedium) {
    TaxSuiteWidget()
} timeline: {
    TaxSuiteEntry(date: .now, snapshot: .preview, buttonSlots: WidgetButtonSlot.defaultSlots, hasAppLaunched: true)
}

#Preview("Medium (未起動)", as: .systemMedium) {
    TaxSuiteWidget()
} timeline: {
    TaxSuiteEntry(date: .now, snapshot: .preview, buttonSlots: WidgetButtonSlot.defaultSlots, hasAppLaunched: false)
}

#Preview("ロック画面: 横長", as: .accessoryRectangular) {
    TaxSuiteWidget()
} timeline: {
    TaxSuiteEntry(date: .now, snapshot: .preview, buttonSlots: WidgetButtonSlot.defaultSlots, hasAppLaunched: true)
}

#Preview("ロック画面: 丸", as: .accessoryCircular) {
    TaxSuiteWidget()
} timeline: {
    TaxSuiteEntry(date: .now, snapshot: .preview, buttonSlots: WidgetButtonSlot.defaultSlots, hasAppLaunched: true)
}

#Preview("ロック画面: 1行", as: .accessoryInline) {
    TaxSuiteWidget()
} timeline: {
    TaxSuiteEntry(date: .now, snapshot: .preview, buttonSlots: WidgetButtonSlot.defaultSlots, hasAppLaunched: true)
}
