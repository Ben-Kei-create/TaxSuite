import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Timeline Entry

struct TaxSuiteEntry: TimelineEntry {
    let date: Date
    let snapshot: TaxSuiteWidgetSnapshot
    /// App Group から読み込んだクイック追加ボタンのスロット設定（4 件）
    let buttonSlots: [WidgetButtonSlot]
}

// MARK: - Timeline Provider

struct TaxSuiteProvider: TimelineProvider {
    func placeholder(in context: Context) -> TaxSuiteEntry {
        TaxSuiteEntry(date: .now, snapshot: .preview, buttonSlots: WidgetButtonSlot.defaultSlots)
    }

    func getSnapshot(in context: Context, completion: @escaping (TaxSuiteEntry) -> Void) {
        completion(readEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TaxSuiteEntry>) -> Void) {
        let entry = readEntry()
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: .now)!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func readEntry() -> TaxSuiteEntry {
        TaxSuiteEntry(
            date: .now,
            snapshot: TaxSuiteWidgetStore.load() ?? .preview,
            buttonSlots: TaxSuiteWidgetStore.loadButtonSlots()
        )
    }
}

// MARK: - Widget View

struct TaxSuiteWidgetView: View {
    var entry: TaxSuiteEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:  smallView
        case .systemMedium: mediumView
        default:            smallView
        }
    }

    // MARK: Small

    var smallView: some View {
        VStack(alignment: .leading, spacing: 12) {
            widgetHeader

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "yensign.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("推定手取り")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(currency(entry.snapshot.takeHome))
                    .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .foregroundStyle(.primary)
            }

            progressBar

            HStack(spacing: 8) {
                summaryPill(icon: "sun.max.fill", value: currency(entry.snapshot.todayExpensesTotal))
                summaryPill(icon: "clock.fill", value: entry.snapshot.recentExpenseTitle ?? "未記録")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(URL(string: "taxsuite://dashboard"))
        .containerBackground(for: .widget) { widgetBackground }
    }

    // MARK: Medium

    var mediumView: some View {
        VStack(alignment: .leading, spacing: 10) {
            widgetHeader

            HStack(alignment: .top, spacing: 10) {
                // 左パネル: 財務サマリー
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 4) {
                        Image(systemName: "yensign.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("推定手取り")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(currency(entry.snapshot.takeHome))
                        .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                        .foregroundStyle(.primary)

                    progressBar

                    VStack(spacing: 6) {
                        compactMetricRow(icon: "sun.max.fill",    value: currency(entry.snapshot.todayExpensesTotal))
                        compactMetricRow(icon: "calendar",        value: currency(entry.snapshot.currentMonthExpenses))
                        compactMetricRow(icon: "clock.fill",      value: entry.snapshot.recentExpenseTitle ?? "未記録")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.white.opacity(0.62))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                // 右パネル: 動的クイック追加ボタン（App Group から読み込み）
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("すぐ記録")
                            .font(.caption2.weight(.semibold))
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
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) { widgetBackground }
    }

    // MARK: - Quick Add Button（動的スロットから生成）

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

    /// カテゴリまたはタイトルから最適な SF Symbol 名を推定する
    private func iconName(for slot: WidgetButtonSlot) -> String {
        if slot.title.isEmpty { return "questionmark.circle" }
        let title = slot.title
        let category = slot.category

        // タイトル優先のキーワードマッチ（よく使う固有表現）
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

        // カテゴリへのフォールバック
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

    // MARK: - Shared sub-views

    private var widgetHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.pie.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(entry.snapshot.monthLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Spacer()
            HStack(spacing: 3) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 9, weight: .bold))
                Text(progressLabel)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Color(red: 0.12, green: 0.33, blue: 0.18))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color(red: 0.88, green: 0.95, blue: 0.89))
            .clipShape(Capsule())
        }
    }

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

    private func summaryPill(icon: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        .supportedFamilies([.systemSmall, .systemMedium])
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

#Preview("Small", as: .systemSmall) {
    TaxSuiteWidget()
} timeline: {
    TaxSuiteEntry(date: .now, snapshot: .preview, buttonSlots: WidgetButtonSlot.defaultSlots)
}

#Preview("Medium", as: .systemMedium) {
    TaxSuiteWidget()
} timeline: {
    TaxSuiteEntry(date: .now, snapshot: .preview, buttonSlots: WidgetButtonSlot.defaultSlots)
}

#Preview("Medium (カスタム)", as: .systemMedium) {
    TaxSuiteWidget()
} timeline: {
    TaxSuiteEntry(
        date: .now,
        snapshot: .preview,
        buttonSlots: [
            WidgetButtonSlot(id: 0, title: "スタバ",   amount: 750,  category: "会議費",     project: TaxSuiteWidgetSupport.defaultProjectNames[0]),
            WidgetButtonSlot(id: 1, title: "新幹線",   amount: 6600, category: "交通費",     project: TaxSuiteWidgetSupport.defaultProjectNames[1]),
            WidgetButtonSlot(id: 2, title: "AWS",      amount: 3200, category: "通信費",     project: TaxSuiteWidgetSupport.defaultProjectNames[0]),
            WidgetButtonSlot(id: 3, title: "書籍",     amount: 2200, category: "消耗品費",   project: TaxSuiteWidgetSupport.defaultProjectNames[2])
        ]
    )
}
