import SwiftUI
import VisionKit
import Vision
import SwiftData

// MARK: - ParsedReceipt

struct ParsedReceipt: Identifiable {
    let id = UUID()
    var amount: Double?
    var date: Date?
    var suggestedTitle: String
    var rawText: String
}

// MARK: - ReceiptParser

enum ReceiptParser {

    static func parse(from lines: [String]) -> ParsedReceipt {
        ParsedReceipt(
            amount: extractAmount(from: lines),
            date: extractDate(from: lines),
            suggestedTitle: extractTitle(from: lines),
            rawText: lines.joined(separator: "\n")
        )
    }

    // MARK: Amount

    static func extractAmount(from lines: [String]) -> Double? {
        // Priority 1: explicit total labels (合計, お会計, ご請求, etc.)
        let totalLabelPattern = #"(?:合計|小計|お会計|ご請求額?|請求合計|お支払い合計|お支払合計)[　 ]*[¥￥]?[　 ]*([\d,]+)"#
        for line in lines {
            if let value = extractCaptureGroup(pattern: totalLabelPattern, from: line), value > 0 {
                return value
            }
        }

        // Priority 2: yen sign (¥ or ￥) preceding the number
        let yenSignPattern = #"[¥￥][　 ]*([\d,]+)"#
        for line in lines {
            if let value = extractCaptureGroup(pattern: yenSignPattern, from: line), value > 0 {
                return value
            }
        }

        // Priority 3: 円 suffix
        let enSuffixPattern = #"([\d,]+)[　 ]*円"#
        for line in lines {
            if let value = extractCaptureGroup(pattern: enSuffixPattern, from: line), value > 0 {
                return value
            }
        }

        // Fallback: largest plausible number on the receipt
        return largestNumber(in: lines)
    }

    private static func extractCaptureGroup(pattern: String, from text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1 else { return nil }
        let capRange = match.range(at: 1)
        guard capRange.location != NSNotFound else { return nil }
        let numStr = nsText.substring(with: capRange).replacingOccurrences(of: ",", with: "")
        return Double(numStr)
    }

    private static func largestNumber(in lines: [String]) -> Double? {
        guard let pattern = try? NSRegularExpression(pattern: #"[\d,]{3,}"#) else { return nil }
        var largest: Double = 0
        for line in lines {
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            let matches = pattern.matches(in: line, range: range)
            for match in matches {
                let numStr = nsLine.substring(with: match.range).replacingOccurrences(of: ",", with: "")
                if let value = Double(numStr), value > largest, value < 10_000_000 {
                    largest = value
                }
            }
        }
        return largest > 0 ? largest : nil
    }

    // MARK: Date

    static func extractDate(from lines: [String]) -> Date? {
        for line in lines {
            // Full Gregorian: 2024/04/12, 2024-04-12, 2024年4月12日
            if let date = matchGregorian(in: line) { return date }
            // Japanese era: 令和6年4月12日, R6.4.12
            if let date = matchJapaneseEra(in: line) { return date }
            // Short M/D with current year
            if let date = matchShortDate(in: line) { return date }
        }
        return nil
    }

    private static func matchGregorian(in text: String) -> Date? {
        let patterns = [
            #"(\d{4})[/\-](\d{1,2})[/\-](\d{1,2})"#,
            #"(\d{4})年[　 ]*(\d{1,2})月[　 ]*(\d{1,2})日"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsText = text as NSString
            let range = NSRange(location: 0, length: nsText.length)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges == 4 else { continue }
            let yr = nsText.substring(with: match.range(at: 1))
            let mo = nsText.substring(with: match.range(at: 2))
            let dy = nsText.substring(with: match.range(at: 3))
            guard let year = Int(yr), let month = Int(mo), let day = Int(dy),
                  year >= 2000, year <= 2100,
                  month >= 1, month <= 12,
                  day >= 1, day <= 31 else { continue }
            var comps = DateComponents()
            comps.year = year; comps.month = month; comps.day = day
            if let date = Calendar.current.date(from: comps) { return date }
        }
        return nil
    }

    private static func matchJapaneseEra(in text: String) -> Date? {
        // 令和X年M月D日 or R X.M.D
        let patterns: [(String, Int)] = [
            (#"令和[　 ]*(\d{1,2})年[　 ]*(\d{1,2})月[　 ]*(\d{1,2})日"#, 2018),
            (#"R[　 ]*(\d{1,2})[./](\d{1,2})[./](\d{1,2})"#, 2018)
        ]
        for (pattern, baseYear) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsText = text as NSString
            let range = NSRange(location: 0, length: nsText.length)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges == 4 else { continue }
            guard let eraYear = Int(nsText.substring(with: match.range(at: 1))),
                  let month = Int(nsText.substring(with: match.range(at: 2))),
                  let day = Int(nsText.substring(with: match.range(at: 3))),
                  month >= 1, month <= 12,
                  day >= 1, day <= 31 else { continue }
            let year = baseYear + eraYear
            var comps = DateComponents()
            comps.year = year; comps.month = month; comps.day = day
            if let date = Calendar.current.date(from: comps) { return date }
        }
        return nil
    }

    private static func matchShortDate(in text: String) -> Date? {
        // M/D or MM/DD — assume current year
        guard let regex = try? NSRegularExpression(pattern: #"(\d{1,2})/(\d{1,2})"#) else { return nil }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges == 3 else { return nil }
        guard let month = Int(nsText.substring(with: match.range(at: 1))),
              let day = Int(nsText.substring(with: match.range(at: 2))),
              month >= 1, month <= 12,
              day >= 1, day <= 31 else { return nil }
        let now = Date()
        let year = Calendar.current.component(.year, from: now)
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        guard let date = Calendar.current.date(from: comps), date <= now else { return nil }
        return date
    }

    // MARK: Title

    static func extractTitle(from lines: [String]) -> String {
        // Known vendor keyword → canonical title
        let vendorRules: [(keywords: [String], title: String)] = [
            (["スタバ", "スターバックス", "starbucks"], "スタバ"),
            (["マクドナルド", "mcdonald", "マック"], "マクドナルド"),
            (["aws", "amazon web services"], "AWS"),
            (["gcp", "google cloud"], "GCP"),
            (["タクシー", "taxi"], "タクシー"),
            (["suica", "pasmo", "icoca"], "交通費"),
            (["uber eats", "ウーバーイーツ"], "Uber Eats"),
            (["uber", "ウーバー"], "Uber"),
            (["カフェ", "珈琲", "coffee", "コーヒー"], "カフェ"),
            (["コンビニ", "ファミマ", "セブン", "ローソン", "familymart", "7-eleven"], "コンビニ"),
            (["ガソリン", "給油", "エネオス", "出光", "eneos"], "ガソリン代"),
            (["本", "書籍", "amazon books", "kindle", "書店"], "書籍"),
            (["adobe"], "Adobe"),
            (["figma"], "Figma"),
            (["notion"], "Notion"),
            (["github"], "GitHub"),
            (["slack"], "Slack"),
            (["dropbox"], "Dropbox")
        ]
        let combined = lines.joined(separator: " ").lowercased()
        for rule in vendorRules {
            if rule.keywords.contains(where: { combined.contains($0.lowercased()) }) {
                return rule.title
            }
        }

        // Heuristic: first non-numeric, reasonably short line near the top
        let skipPatterns = try? NSRegularExpression(pattern: #"^[\d/\-:\s¥￥,円.]+$"#)
        for line in lines.prefix(6) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2, trimmed.count <= 24 else { continue }
            let nsLine = trimmed as NSString
            let isAllNumeric = skipPatterns?.firstMatch(
                in: trimmed, range: NSRange(location: 0, length: nsLine.length)
            ) != nil
            if !isAllNumeric { return trimmed }
        }

        return ""
    }
}

// MARK: - ReceiptScannerView

struct ReceiptScannerView: UIViewControllerRepresentable {
    /// 複数ページを撮影した場合、ページごとに1件の ParsedReceipt を返す
    var onParsedAll: ([ParsedReceipt]) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onParsedAll: onParsedAll, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onParsedAll: ([ParsedReceipt]) -> Void
        let onCancel: () -> Void

        init(onParsedAll: @escaping ([ParsedReceipt]) -> Void, onCancel: @escaping () -> Void) {
            self.onParsedAll = onParsedAll
            self.onCancel = onCancel
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var receipts: [ParsedReceipt] = []

                // ページ（撮影枚数）ごとに独立した ParsedReceipt を生成
                for pageIndex in 0..<scan.pageCount {
                    let pageImage = scan.imageOfPage(at: pageIndex)
                    guard let cgImage = pageImage.cgImage else { continue }

                    let request = VNRecognizeTextRequest()
                    request.recognitionLanguages = ["ja-JP", "en-US"]
                    request.usesLanguageCorrection = true
                    request.recognitionLevel = .accurate

                    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                    try? handler.perform([request])

                    let lines = (request.results ?? [])
                        .compactMap { $0.topCandidates(1).first?.string }

                    receipts.append(ReceiptParser.parse(from: lines))
                }

                DispatchQueue.main.async { self?.onParsedAll(receipts) }
            }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onCancel()
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            onCancel()
        }
    }
}

// MARK: - ScannedReceiptReviewView

struct ScannedReceiptReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ExpenseItem.timestamp, order: .reverse) private var expenseHistory: [ExpenseItem]

    let parsed: ParsedReceipt
    /// 確認完了時に ReceiptImportView 側へドラフトを渡すコールバック
    var onConfirmed: (ReceiptBatchDraft) -> Void
    /// スキップ（この1枚を無視して次へ進む）
    var onSkip: () -> Void
    /// 何枚目 / 合計枚数（進捗表示用）
    var queueIndex: Int = 0
    var queueTotal: Int = 1

    @State private var title: String
    @State private var amountText: String
    @State private var date: Date
    @State private var category: String
    @State private var project: String
    @State private var businessRatio: Double
    @State private var note: String
    @State private var showRawText = false
    @State private var rawTextCopied = false

    @State private var suggestion: ExpenseAutofillSuggestion?
    @State private var hasManualCategoryOverride = false
    @State private var hasManualProjectOverride = false
    @State private var isApplyingSuggestion = false

    private let categoryOptions = ExpenseAutofillPredictor.defaultCategories
    private var projectOptions: [String] {
        TaxSuiteWidgetStore.projectNameOptions(including: expenseHistory.map(\.project) + [project])
    }

    init(parsed: ParsedReceipt) {
        self.parsed = parsed
        _title = State(initialValue: parsed.suggestedTitle)
        _amountText = State(initialValue: parsed.amount.map { String(Int($0)) } ?? "")
        // 常に「今日」をデフォルトにする（OCR 日付は参考表示のみ）
        _date = State(initialValue: Date())
        _category = State(initialValue: "未分類")
        _project = State(initialValue: TaxSuiteWidgetStore.fallbackProjectName())
        _businessRatio = State(initialValue: 1.0)
        _note = State(initialValue: "")
    }

    var body: some View {
        NavigationStack {
            TaxSuiteScreenSurface {
                Form {
                    // OCR confidence banner
                    if parsed.amount == nil || parsed.suggestedTitle.isEmpty {
                        Section {
                            Label(
                                "一部の項目を読み取れませんでした。手入力で補完してください。",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.caption)
                            .foregroundColor(.orange)
                        }
                    }

                    Section(header: Text("項目名"), footer: suggestionFooter) {
                        TextField("例：タクシー代", text: $title)
                    }

                    Section(header: Text("金額")) {
                        WalletChargeInputView(amountText: $amountText)
                    }

                    Section(header: Text("日付")) {
                        DatePicker("日付", selection: $date, in: ...Date(), displayedComponents: .date)
                            .datePickerStyle(.compact)
                            .environment(\.locale, Locale(identifier: "ja_JP"))

                        if let ocrDate = parsed.date {
                            let formatter = {
                                let f = DateFormatter()
                                f.locale = Locale(identifier: "ja_JP")
                                f.dateStyle = .medium
                                return f
                            }()
                            Button {
                                date = ocrDate
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.text.magnifyingglass")
                                        .font(.caption2)
                                    Text("領収書の日付: \(formatter.string(from: ocrDate))")
                                        .font(.caption)
                                    Spacer()
                                    Text("適用")
                                        .font(.caption.bold())
                                }
                                .foregroundColor(.blue)
                            }
                        }
                    }

                    Section(header: Text("分類")) {
                        Picker("カテゴリ", selection: categoryBinding) {
                            ForEach(categoryOptions, id: \.self) { Text($0).tag($0) }
                        }
                        .tint(.black)

                        Picker("プロジェクト", selection: projectBinding) {
                            ForEach(projectOptions, id: \.self) { Text($0).tag($0) }
                        }
                        .tint(.black)
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

                    Section(header: Text("コメント（任意）")) {
                        TextField("メモを入力", text: $note, axis: .vertical)
                            .lineLimit(3, reservesSpace: false)
                    }

                    // Raw OCR text (debug / verification)
                    if !parsed.rawText.isEmpty {
                        Section {
                            HStack {
                                Button {
                                    showRawText.toggle()
                                } label: {
                                    Label(
                                        showRawText ? "読み取りテキストを隠す" : "読み取りテキストを表示",
                                        systemImage: showRawText ? "chevron.up" : "doc.text.magnifyingglass"
                                    )
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                }

                                Spacer()

                                Button {
                                    UIPasteboard.general.string = parsed.rawText
                                    rawTextCopied = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                        rawTextCopied = false
                                    }
                                } label: {
                                    Image(systemName: rawTextCopied ? "checkmark" : "doc.on.doc")
                                        .font(.caption)
                                        .foregroundColor(rawTextCopied ? .green : .secondary)
                                }
                                .buttonStyle(.plain)
                                .animation(.easeInOut(duration: 0.2), value: rawTextCopied)
                            }

                            if showRawText {
                                Text(parsed.rawText)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .navigationTitle(queueTotal > 1 ? "\(queueIndex + 1) / \(queueTotal)枚目を確認" : "スキャン結果の確認")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("スキップ") {
                        onSkip()
                        dismiss()
                    }
                    .foregroundColor(.secondary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("リストへ追加", action: confirm)
                        .fontWeight(.bold)
                        .disabled(isSaveDisabled)
                }
            }
            .onAppear { applySuggestion(for: title) }
            .onChange(of: title) { _, newTitle in applySuggestion(for: newTitle) }
        }
    }

    // MARK: - Bindings with override tracking

    private var categoryBinding: Binding<String> {
        Binding(
            get: { category },
            set: { newValue in
                category = newValue
                if !isApplyingSuggestion { hasManualCategoryOverride = true }
            }
        )
    }

    private var projectBinding: Binding<String> {
        Binding(
            get: { project },
            set: { newValue in
                project = newValue
                if !isApplyingSuggestion { hasManualProjectOverride = true }
            }
        )
    }

    // MARK: - Autofill

    private func applySuggestion(for rawTitle: String) {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        suggestion = ExpenseAutofillPredictor.predict(for: trimmed, from: expenseHistory)

        if trimmed.isEmpty {
            if !hasManualCategoryOverride { category = "未分類" }
            if !hasManualProjectOverride { project = TaxSuiteWidgetStore.fallbackProjectName() }
            return
        }

        guard let s = suggestion else { return }
        isApplyingSuggestion = true
        if let predicted = s.category, !hasManualCategoryOverride { category = predicted }
        if let predicted = s.project, !hasManualProjectOverride { project = predicted }
        isApplyingSuggestion = false
    }

    @ViewBuilder
    private var suggestionFooter: some View {
        if let s = suggestion {
            if let matched = s.matchedTitle, s.project != nil {
                Text("過去の「\(matched)」を参考に、カテゴリとプロジェクトを提案しています。")
                    .foregroundColor(.blue)
            } else if s.category != nil {
                Text("項目名からカテゴリを自動提案しています。必要なら手動で変更できます。")
                    .foregroundColor(.blue)
            }
        }
    }

    // MARK: - Confirm (ドラフトとして返却)

    private var isSaveDisabled: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || amountText.isEmpty
    }

    private func confirm() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !(Double(amountText) ?? 0).isZero else { return }
        var draft = ReceiptBatchDraft()
        draft.title         = trimmed
        draft.amountText    = amountText
        draft.category      = category
        draft.project       = project
        draft.note          = note
        draft.date          = date
        draft.businessRatio = businessRatio
        onConfirmed(draft)
        dismiss()
    }
}
