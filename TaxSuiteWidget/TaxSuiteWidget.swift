import WidgetKit
import SwiftUI

struct TaxSuiteEntry: TimelineEntry {
    let date: Date
    let snapshot: TaxSuiteWidgetSnapshot
}

struct TaxSuiteProvider: TimelineProvider {
    func placeholder(in context: Context) -> TaxSuiteEntry {
        TaxSuiteEntry(date: .now, snapshot: .preview)
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
        TaxSuiteEntry(date: .now, snapshot: TaxSuiteWidgetStore.load() ?? .preview)
    }
}

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

    var smallView: some View {
        VStack(alignment: .leading, spacing: 14) {
            widgetHeader

            VStack(alignment: .leading, spacing: 6) {
                Text("推定手取り")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(currency(entry.snapshot.takeHome))
                    .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .foregroundStyle(.primary)
            }

            progressBar

            HStack(spacing: 8) {
                summaryPill(label: "今日", value: currency(entry.snapshot.todayExpensesTotal))
                summaryPill(label: "件数", value: "\(entry.snapshot.todayExpenseCount)件")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) {
            widgetBackground
        }
    }

    var mediumView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    widgetHeader

                    VStack(alignment: .leading, spacing: 6) {
                        Text("今月の推定手取り")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(currency(entry.snapshot.takeHome))
                            .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                    }

                    progressBar
                }

                VStack(spacing: 10) {
                    metricCard(title: "売上", value: entry.snapshot.currentMonthRevenue, tint: Color(red: 0.17, green: 0.39, blue: 0.82))
                    metricCard(title: "経費", value: entry.snapshot.currentMonthExpenses, tint: Color(red: 0.91, green: 0.49, blue: 0.18))
                    metricCard(title: "税金", value: entry.snapshot.estimatedTax, tint: Color(red: 0.82, green: 0.26, blue: 0.26))
                }
                .frame(maxWidth: 132)
            }

            HStack(spacing: 10) {
                summaryPill(label: "今日の支出", value: currency(entry.snapshot.todayExpensesTotal))
                summaryPill(label: "最新", value: entry.snapshot.recentExpenseTitle ?? "まだ記録なし")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) {
            widgetBackground
        }
    }

    private var widgetHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("TaxSuite")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(entry.snapshot.monthLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text(progressLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color(red: 0.12, green: 0.33, blue: 0.18))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
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
                Capsule()
                    .fill(Color.black.opacity(0.08))

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

    private func metricCard(title: String, value: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(currency(value))
                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(tint.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(tint.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func summaryPill(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var takeHomeProgress: Double {
        guard entry.snapshot.currentMonthRevenue > 0 else { return 0.08 }
        let ratio = entry.snapshot.takeHome / entry.snapshot.currentMonthRevenue
        return min(max(ratio, 0.08), 1.0)
    }

    private var progressLabel: String {
        let percentage = Int((takeHomeProgress * 100).rounded())
        return "残り \(percentage)%"
    }

    private func currency(_ value: Double) -> String {
        "¥\(Int(value.rounded()).formatted())"
    }
}

@main
struct TaxSuiteWidget: Widget {
    let kind = "TaxSuiteWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TaxSuiteProvider()) { entry in
            TaxSuiteWidgetView(entry: entry)
                .widgetURL(URL(string: "taxsuite://dashboard"))
        }
        .configurationDisplayName("TaxSuite")
        .description("推定手取りと今日の支出をホーム画面で素早く確認")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private extension TaxSuiteWidgetSnapshot {
    static let preview = TaxSuiteWidgetSnapshot(
        generatedAt: .now,
        monthLabel: "2026年4月",
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
    TaxSuiteEntry(date: .now, snapshot: .preview)
}

#Preview("Medium", as: .systemMedium) {
    TaxSuiteWidget()
} timeline: {
    TaxSuiteEntry(date: .now, snapshot: .preview)
}
