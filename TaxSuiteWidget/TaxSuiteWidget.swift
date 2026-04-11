import WidgetKit
import SwiftUI

// ⚠️ Item.swift の kAppGroupID と必ず一致させること
private let appGroupID = "group.com.yourname.taxsuite"

// MARK: - Timeline Entry

struct TaxSuiteEntry: TimelineEntry {
    let date: Date
    let estimatedIncome: Double
    let totalExpense: Double
    let taxRate: Double
}

// MARK: - Provider

struct TaxSuiteProvider: TimelineProvider {

    func placeholder(in context: Context) -> TaxSuiteEntry {
        TaxSuiteEntry(date: .now, estimatedIncome: 320_000, totalExpense: 80_000, taxRate: 0.2)
    }

    func getSnapshot(in context: Context, completion: @escaping (TaxSuiteEntry) -> Void) {
        completion(readEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TaxSuiteEntry>) -> Void) {
        let entry = readEntry()
        // 1時間後に再取得（アプリ側からも reloadAllTimelines() で即時更新される）
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: .now)!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func readEntry() -> TaxSuiteEntry {
        let d = UserDefaults(suiteName: appGroupID)
        return TaxSuiteEntry(
            date:            .now,
            estimatedIncome: d?.double(forKey: "estimatedIncome") ?? 0,
            totalExpense:    d?.double(forKey: "totalExpense")    ?? 0,
            taxRate:         d?.double(forKey: "taxRate")         ?? 0.2
        )
    }
}

// MARK: - Views

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

    // ── スモール ──────────────────────────────
    var smallView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("推定手取り")
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer()
            Text("¥\(formatted(entry.estimatedIncome))")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text("経費 ¥\(formatted(entry.totalExpense))")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.top, 2)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.white)
    }

    // ── ミディアム ────────────────────────────
    var mediumView: some View {
        HStack(alignment: .center, spacing: 0) {
            // 左: 手取り
            VStack(alignment: .leading, spacing: 4) {
                Text("今月の推定手取り")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("¥\(formatted(entry.estimatedIncome))")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
            Spacer()
            // 右: 経費 / 税金
            VStack(alignment: .trailing, spacing: 10) {
                stat(label: "経費", value: entry.totalExpense)
                stat(label: "推定税金",
                     value: (entry.estimatedIncome + entry.totalExpense) * entry.taxRate)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
    }

    private func stat(label: String, value: Double) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label).font(.caption2).foregroundColor(.secondary)
            Text("¥\(formatted(value))").font(.caption).bold()
        }
    }

    private func formatted(_ v: Double) -> String {
        Int(v).formatted()
    }
}

// MARK: - Widget 定義

@main
struct TaxSuiteWidget: Widget {
    let kind = "TaxSuiteWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TaxSuiteProvider()) { entry in
            TaxSuiteWidgetView(entry: entry)
                .containerBackground(.white, for: .widget)
        }
        .configurationDisplayName("TaxSuite")
        .description("今月の推定手取りをホーム画面で確認")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
