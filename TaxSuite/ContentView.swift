import SwiftUI
import SwiftData
import Charts
import UniformTypeIdentifiers
import VisionKit
import Vision
import WidgetKit

struct ContentView: View {
    @Query private var recurringExpenses: [RecurringExpense]
    @Environment(\.modelContext) private var modelContext
    @State private var selectedTab = 0
    @State private var taxRate: Double = 0.2

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(taxRate: taxRate)
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
        .accentColor(.black)
        .onAppear { applyRecurringExpenses() }
    }

    // アプリ起動時に固定費を自動入力
    private func applyRecurringExpenses() {
        let calendar = Calendar.current
        let now = Date()
        let currentYear  = calendar.component(.year,  from: now)
        let currentMonth = calendar.component(.month, from: now)
        let currentDay   = calendar.component(.day,   from: now)

        for recurring in recurringExpenses {
            // 今月すでに実行済みならスキップ
            if recurring.lastExecutedYear  == currentYear &&
               recurring.lastExecutedMonth == currentMonth { continue }
            // まだ実行日（毎月X日）が来ていないならスキップ
            if currentDay < recurring.dayOfMonth { continue }

            let expense = ExpenseItem(
                title: recurring.title,
                amount: recurring.amount,
                project: recurring.project
            )
            modelContext.insert(expense)
            recurring.lastExecutedYear  = currentYear
            recurring.lastExecutedMonth = currentMonth
        }
    }
}

// ----------------------------------------------------
// 1. ホーム画面
// ----------------------------------------------------
struct HomeView: View {
    @Query(sort: \ExpenseItem.timestamp, order: .reverse) private var expenses: [ExpenseItem]
    @Environment(\.modelContext) private var modelContext

    @AppStorage("isPro") private var isPro = false
    @State private var totalRevenue: Double = 500000
    @State private var selectedProject: String = kDefaultProjects[0]
    @State private var showingReceiptScanner = false
    @State private var parsedReceipt: ParsedReceipt? = nil
    var taxRate: Double

    var totalExpense: Double {
        expenses.reduce(0) { $0 + $1.amount }
    }

    var estimatedIncome: Double {
        let tax = (totalRevenue - totalExpense) * taxRate
        return totalRevenue - totalExpense - max(0, tax)
    }

    var body: some View {
        ZStack {
            Color(white: 0.97).ignoresSafeArea()

            VStack(spacing: 0) {
                // サマリー部分
                VStack(spacing: 10) {
                    Text("今月の推定手取り").font(.subheadline).foregroundColor(.gray)
                    Text("¥\(Int(estimatedIncome).formatted())").font(.system(size: 44, weight: .bold, design: .rounded))
                    HStack(spacing: 20) {
                        SummaryItem(label: "経費合計", value: totalExpense, color: .black)
                        SummaryItem(label: "推定税金", value: (totalRevenue - totalExpense) * taxRate, color: .gray)
                    }
                }
                .padding(.top, 20)
                .padding(.bottom, 20)

                // プロジェクト選択ピル
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(kDefaultProjects, id: \.self) { project in
                            ProjectPill(title: project, isSelected: selectedProject == project) {
                                selectedProject = project
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 12)

                // 入力ボタン
                HStack(spacing: 12) {
                    SmallQuickButton(icon: "🚃", title: "電車", amount: 500) { addExpense("電車", 500) }
                    SmallQuickButton(icon: "☕️", title: "カフェ", amount: 800) { addExpense("カフェ", 800) }
                    SmallQuickButton(icon: "🚕", title: "タクシー", amount: 2000) { addExpense("タクシー", 2000) }
                    SmallQuickButton(icon: "💻", title: "ツール", amount: 5000) { addExpense("ツール", 5000) }
                }
                .padding(.horizontal)
                .padding(.bottom, 10)

                // レシートスキャンボタン
                Button { showingReceiptScanner = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "camera.viewfinder").font(.subheadline)
                        Text("レシートをスキャン")
                            .font(.subheadline)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Color.white)
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.04), radius: 3, x: 0, y: 2)
                }
                .padding(.horizontal)
                .padding(.bottom, 15)

                // 履歴リスト
                List {
                    ForEach(expenses) { expense in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(expense.title).font(.headline)
                                HStack(spacing: 6) {
                                    Text(expense.timestamp, style: .time).font(.caption).foregroundColor(.gray)
                                    Text(expense.project)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.black.opacity(0.06))
                                        .cornerRadius(4)
                                }
                            }
                            Spacer()
                            Text("¥\(Int(expense.amount).formatted())")
                        }
                    }
                    .onDelete(perform: deleteExpense)
                }
                .listStyle(.insetGrouped)

                // 無料ユーザーにのみ広告バナーを表示
                if !isPro {
                    AdBannerView()
                        .padding(.bottom, 2)
                }
            }
        }
        .fullScreenCover(isPresented: $showingReceiptScanner) {
            DocumentScannerView { parsed in
                parsedReceipt = parsed
            }
        }
        .sheet(item: $parsedReceipt) { parsed in
            ReceiptConfirmView(parsed: parsed, selectedProject: selectedProject) { title, amount, project in
                addExpense(title, amount, project: project)
            }
        }
        // 経費が変わるたびにウィジェットへデータを同期
        .onChange(of: expenses) { _, _ in syncWidget() }
        .onAppear { syncWidget() }
    }

    private func addExpense(_ title: String, _ amount: Double, project: String? = nil) {
        withAnimation(.spring()) {
            let newExpense = ExpenseItem(title: title, amount: amount, project: project ?? selectedProject)
            modelContext.insert(newExpense)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    private func deleteExpense(offsets: IndexSet) {
        withAnimation {
            for index in offsets { modelContext.delete(expenses[index]) }
        }
    }

    /// App Group の UserDefaults にデータを書き込み、ウィジェットを即時リフレッシュ
    private func syncWidget() {
        guard let defaults = UserDefaults(suiteName: kAppGroupID) else { return }
        defaults.set(estimatedIncome, forKey: "estimatedIncome")
        defaults.set(totalExpense,    forKey: "totalExpense")
        defaults.set(taxRate,         forKey: "taxRate")
        WidgetCenter.shared.reloadAllTimelines()
    }
}

// ----------------------------------------------------
// 2. カレンダー履歴画面（✨New!）
// ----------------------------------------------------
struct CalendarHistoryView: View {
    @Query(sort: \ExpenseItem.timestamp, order: .reverse) private var expenses: [ExpenseItem]
    @State private var selectedDate = Date()
    
    // 選んだ日付の経費だけをフィルタリングする計算プロパティ
    var dailyExpenses: [ExpenseItem] {
        expenses.filter { Calendar.current.isDate($0.timestamp, inSameDayAs: selectedDate) }
    }
    
    var dailyTotal: Double {
        dailyExpenses.reduce(0) { $0 + $1.amount }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.97).ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Apple純正の美しいカレンダーUI
                    DatePicker(
                        "日付を選択",
                        selection: $selectedDate,
                        displayedComponents: [.date]
                    )
                    .datePickerStyle(.graphical)
                    .tint(.black) // アプリのテーマ色に合わせる
                    .padding()
                    .background(Color.white)
                    .cornerRadius(15)
                    .padding()
                    .shadow(color: .black.opacity(0.03), radius: 5, x: 0, y: 3)
                    
                    // その日の履歴リスト
                    List {
                        Section(header: Text("この日の経費: ¥\(Int(dailyTotal).formatted())")) {
                            if dailyExpenses.isEmpty {
                                Text("記録はありません")
                                    .foregroundColor(.gray)
                                    .padding(.vertical, 10)
                            } else {
                                ForEach(dailyExpenses) { expense in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(expense.title).font(.headline)
                                            HStack(spacing: 6) {
                                                Text(expense.timestamp, style: .time).font(.caption).foregroundColor(.gray)
                                                Text(expense.project)
                                                    .font(.caption2)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.black.opacity(0.06))
                                                    .cornerRadius(4)
                                            }
                                        }
                                        Spacer()
                                        Text("¥\(Int(expense.amount).formatted())")
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("カレンダー")
        }
    }
}

// ----------------------------------------------------
// 3. 分析画面
// ----------------------------------------------------
struct CategorySum: Identifiable, Equatable {
    var id = UUID(); var name: String; var total: Double
}

struct AnalyticsView: View {
    @Query private var expenses: [ExpenseItem]
    @State private var animatedData: [CategorySum] = []
    @State private var selectedProject: String = "すべて"

    private var filterOptions: [String] { ["すべて"] + kDefaultProjects }

    private var filteredExpenses: [ExpenseItem] {
        selectedProject == "すべて" ? expenses : expenses.filter { $0.project == selectedProject }
    }

    var expenseSummary: [CategorySum] {
        let grouped = Dictionary(grouping: filteredExpenses, by: { $0.title })
        return grouped.map { entry in CategorySum(name: entry.key, total: entry.value.reduce(0) { $0 + $1.amount }) }
            .sorted { $0.total > $1.total }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.97).ignoresSafeArea()
                VStack(spacing: 0) {
                    // プロジェクトフィルター
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(filterOptions, id: \.self) { project in
                                ProjectPill(title: project, isSelected: selectedProject == project) {
                                    selectedProject = project
                                    animatedData = expenseSummary.map { CategorySum(name: $0.name, total: 0.0) }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { animatedData = expenseSummary }
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                    .padding(.vertical, 12)
                    .background(Color(white: 0.97))

                    if expenseSummary.isEmpty {
                        Spacer()
                        Text("まだデータがありません").foregroundColor(.gray)
                        Spacer()
                    } else {
                        List {
                            Section {
                                Chart(animatedData) { item in
                                    BarMark(x: .value("金額", item.total), y: .value("項目", item.name))
                                        .foregroundStyle(by: .value("項目", item.name))
                                        .cornerRadius(8)
                                }
                                .frame(height: 250).padding(.vertical)
                                .animation(.spring(response: 0.7, dampingFraction: 0.6), value: animatedData)
                                .onAppear {
                                    animatedData = expenseSummary.map { CategorySum(name: $0.name, total: 0.0) }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { animatedData = expenseSummary }
                                }
                                .onChange(of: filteredExpenses) { _, _ in animatedData = expenseSummary }
                            }
                            Section(header: Text("内訳")) {
                                ForEach(expenseSummary) { item in
                                    HStack {
                                        Text(item.name); Spacer()
                                        Text("¥\(Int(item.total).formatted())").bold()
                                    }
                                }
                            }
                        }.listStyle(.insetGrouped)
                    }
                }
            }.navigationTitle("分析")
        }
    }
}

// ----------------------------------------------------
// 4. 設定画面
// ----------------------------------------------------
struct SettingsView: View {
    @Query(sort: \ExpenseItem.timestamp, order: .reverse) private var expenses: [ExpenseItem]
    @Query(sort: \RecurringExpense.title) private var recurringExpenses: [RecurringExpense]
    @Environment(\.modelContext) private var modelContext
    @Binding var taxRate: Double
    @State private var showingProModal = false
    @State private var showingAddRecurring = false

    private var csvFile: CSVFile { CSVFile(expenses: expenses) }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.97).ignoresSafeArea()
                List {
                    // Pro アップグレード
                    Section {
                        Button(action: { showingProModal = true }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("TaxSuite Pro にアップグレード").font(.headline).foregroundColor(.black)
                                    Text("広告非表示・領収書スキャン・無制限データ保存").font(.caption).foregroundColor(.gray)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundColor(.gray).font(.caption)
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    // 固定費
                    Section(header: Text("固定費の自動入力")) {
                        ForEach(recurringExpenses) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(.headline)
                                    Text("\(item.project) ・ 毎月\(item.dayOfMonth)日")
                                        .font(.caption).foregroundColor(.gray)
                                }
                                Spacer()
                                Text("¥\(Int(item.amount).formatted())").bold()
                            }
                        }
                        .onDelete { offsets in
                            for i in offsets { modelContext.delete(recurringExpenses[i]) }
                        }
                        Button(action: { showingAddRecurring = true }) {
                            Label("固定費を追加", systemImage: "plus.circle")
                                .foregroundColor(.black)
                        }
                    }

                    // 計算設定
                    Section(header: Text("計算設定")) {
                        HStack {
                            Text("推定税率"); Spacer()
                            Picker("", selection: $taxRate) {
                                Text("10%").tag(0.1); Text("20%").tag(0.2); Text("30%").tag(0.3)
                            }.tint(.black)
                        }
                    }

                    // データ管理
                    Section(header: Text("データ管理")) {
                        if expenses.isEmpty {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("税理士にデータを書き出す (CSV)")
                            }
                            .foregroundColor(.gray)
                        } else {
                            ShareLink(
                                item: csvFile,
                                preview: SharePreview("TaxSuite_経費データ.csv", image: Image(systemName: "doc.text"))
                            ) {
                                HStack {
                                    Image(systemName: "square.and.arrow.up")
                                    Text("税理士にデータを書き出す (CSV)")
                                }
                                .foregroundColor(.black)
                            }
                        }
                        HStack {
                            Image(systemName: "icloud.fill").foregroundColor(.blue)
                            Text("iCloud 同期"); Spacer(); Text("オン").foregroundColor(.gray)
                        }
                    }
                }.listStyle(.insetGrouped)
            }
            .navigationTitle("設定")
            .sheet(isPresented: $showingProModal) { ProUpgradeView() }
            .sheet(isPresented: $showingAddRecurring) { AddRecurringView() }
        }
    }
}

// ----------------------------------------------------
// 固定費追加フォーム
// ----------------------------------------------------
struct AddRecurringView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var amountText = ""
    @State private var project = kDefaultProjects[0]
    @State private var dayOfMonth = 1

    private var isValid: Bool { !title.isEmpty && Double(amountText) != nil }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.97).ignoresSafeArea()
                Form {
                    Section(header: Text("内容")) {
                        TextField("項目名（例: Adobe CC）", text: $title)
                        TextField("金額", text: $amountText)
                            .keyboardType(.numberPad)
                    }
                    Section(header: Text("プロジェクト")) {
                        Picker("プロジェクト", selection: $project) {
                            ForEach(kDefaultProjects, id: \.self) { Text($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    Section(header: Text("毎月の実行日")) {
                        Stepper("\(dayOfMonth)日", value: $dayOfMonth, in: 1...28)
                    }
                }
            }
            .navigationTitle("固定費を追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("追加") {
                        let amount = Double(amountText) ?? 0
                        let recurring = RecurringExpense(
                            title: title, amount: amount,
                            project: project, dayOfMonth: dayOfMonth
                        )
                        modelContext.insert(recurring)
                        dismiss()
                    }
                    .disabled(!isValid)
                    .bold()
                }
            }
        }
    }
}

// ----------------------------------------------------
// CSV書き出し
// ----------------------------------------------------
struct CSVFile: Transferable, @unchecked Sendable {
    let expenses: [ExpenseItem]

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd"
        f.locale = Locale(identifier: "ja_JP")
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "ja_JP")
        return f
    }()

    func generateCSV() -> String {
        // 列順: 日付, プロジェクト, カテゴリ, 内容, 金額
        var csv = "日付,プロジェクト,カテゴリ,内容,金額\n"
        let sorted = expenses.sorted { $0.timestamp < $1.timestamp }
        for item in sorted {
            let date     = Self.dateFormatter.string(from: item.timestamp)
            let project  = q(item.project)
            let category = q(item.category)
            let title    = q(item.title)
            csv += "\(date),\(project),\(category),\(title),\(Int(item.amount))\n"
        }
        return csv
    }

    // CSVインジェクション防止ダブルクォート包み
    private func q(_ s: String) -> String {
        "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { file in
            Data(file.generateCSV().utf8)
        }
    }
}

struct ProUpgradeView: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(spacing: 30) {
            Text("TaxSuite Pro").font(.system(size: 32, weight: .bold, design: .rounded)).padding(.top, 40)
            Text("あなたのビジネスを\nさらに「ホワイト」で快適に。").multilineTextAlignment(.center).font(.headline).foregroundColor(.gray)
            Spacer()
            Button("閉じる") { dismiss() }.padding().foregroundColor(.gray)
        }
    }
}

// ----------------------------------------------------
// 補助コンポーネント（HomeView用）
// ----------------------------------------------------
struct SummaryItem: View {
    var label: String; var value: Double; var color: Color
    var body: some View {
        VStack {
            Text(label).font(.caption).foregroundColor(.gray)
            Text("¥\(Int(value).formatted())").font(.headline).foregroundColor(color)
        }
    }
}

struct ProjectPill: View {
    var title: String
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline).fontWeight(isSelected ? .semibold : .regular)
                .foregroundColor(isSelected ? .white : .black)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isSelected ? Color.black : Color.white)
                .cornerRadius(20)
                .shadow(color: .black.opacity(0.05), radius: 3, x: 0, y: 1)
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)
    }
}

struct SmallQuickButton: View {
    var icon: String; var title: String; var amount: Int; var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(icon).font(.title3)
                Text(title).font(.caption2).foregroundColor(.gray)
                Text("¥\(amount)").font(.caption).bold().foregroundColor(.black)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12).background(Color.white).cornerRadius(12).shadow(color: .black.opacity(0.04), radius: 3, x: 0, y: 2)
        }
    }
}

// ----------------------------------------------------
// レシートスキャン
// ----------------------------------------------------
struct ParsedReceipt: Identifiable {
    let id = UUID()
    var title: String
    var amount: Double
}

struct DocumentScannerView: UIViewControllerRepresentable {
    var onScanned: (ParsedReceipt) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScannerView
        init(_ parent: DocumentScannerView) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let image = scan.imageOfPage(at: 0)
            let parsed = recognizeText(from: image)
            parent.onScanned(parsed)
            controller.dismiss(animated: true)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            controller.dismiss(animated: true)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            controller.dismiss(animated: true)
        }

        private func recognizeText(from image: UIImage) -> ParsedReceipt {
            var lines: [String] = []
            let request = VNRecognizeTextRequest { req, _ in
                lines = (req.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
            }
            request.recognitionLanguages = ["ja-JP", "en-US"]
            request.recognitionLevel = .accurate
            if let cg = image.cgImage {
                try? VNImageRequestHandler(cgImage: cg).perform([request])
            }
            return parse(lines: lines)
        }

        // レシートの文字列から金額と店名を抽出
        // MARK: OCR テキスト解析（チューニング済み）
        private func parse(lines: [String]) -> ParsedReceipt {
            var amount: Double = 0

            // ① 合計キーワード行を優先探索（網羅的・順序は信頼度順）
            let totalKeywords = [
                "税込合計", "お支払合計", "お会計合計", "合計金額",
                "お支払金額", "ご請求額", "お支払い", "お会計",
                "合 計", "合計", "小計", "TOTAL", "Total", "total"
            ]
            outer: for keyword in totalKeywords {
                for line in lines {
                    if line.contains(keyword) {
                        if let v = extractAmount(from: line), v >= 100 { amount = v; break outer }
                    }
                }
            }

            // ② 見つからなければ全行から金額候補を収集 → 最大値
            if amount == 0 {
                let candidates = lines
                    .compactMap { extractAmount(from: $0) }
                    .filter { $0 >= 100 && $0 < 10_000_000 }  // 100円〜1000万円
                amount = candidates.max() ?? 0
            }

            // ③ 店名: 日付・時刻・電話番号・金額行を除いた最初の意味ある行
            let skipPatterns: [String] = [
                #"^\d{4}[/\-年]\d{1,2}[/\-月]\d{1,2}"#,  // 日付 (2024/04/11)
                #"^\d{1,2}[:/：]\d{2}"#,                   // 時刻 (09:30)
                #"^[\d\-\(\)\+\s〒]+$"#,                   // 電話番号・郵便番号
                #"^[¥￥\d,\s円]+$"#,                        // 金額だけの行
            ]
            let title = lines.first(where: { line in
                guard line.count >= 2 else { return false }
                return !skipPatterns.contains(where: { line.range(of: $0, options: .regularExpression) != nil })
                    && !line.allSatisfy { $0.isNumber || ",.　 ".contains($0) }
            }) ?? "レシート"

            return ParsedReceipt(title: title, amount: amount)
        }

        /// ¥1,234 / 1,234円 / ¥ 1234 に対応した金額抽出
        private func extractAmount(from line: String) -> Double? {
            // コンマを除去した上で数値グループを探す
            let pattern = try? NSRegularExpression(
                pattern: "[¥￥]\\s*([\\d,]+)|([\\d,]+)\\s*[円]"
            )
            let ns = line as NSString
            var best: Double = 0
            pattern?.enumerateMatches(
                in: line, range: NSRange(location: 0, length: ns.length)
            ) { match, _, _ in
                guard let m = match else { return }
                // グループ 1 か 2 の片方が必ずマッチ
                for g in 1...2 {
                    let r = m.range(at: g)
                    if r.location != NSNotFound {
                        let raw = ns.substring(with: r).replacingOccurrences(of: ",", with: "")
                        if let v = Double(raw), v > best { best = v }
                    }
                }
            }
            return best > 0 ? best : nil
        }
    }
}

// ----------------------------------------------------
// レシート確認シート
// ----------------------------------------------------
struct ReceiptConfirmView: View {
    @State private var title: String
    @State private var amountText: String
    @State private var project: String
    @Environment(\.dismiss) private var dismiss
    let onConfirm: (String, Double, String) -> Void

    init(parsed: ParsedReceipt, selectedProject: String, onConfirm: @escaping (String, Double, String) -> Void) {
        _title      = State(initialValue: parsed.title)
        _amountText = State(initialValue: parsed.amount > 0 ? String(Int(parsed.amount)) : "")
        _project    = State(initialValue: selectedProject)
        self.onConfirm = onConfirm
    }

    private var isValid: Bool { !title.isEmpty && Double(amountText) != nil }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.97).ignoresSafeArea()
                Form {
                    // OCR結果の案内
                    Section(header: Text("OCRで読み取った内容")) {
                        LabeledContent("") {
                            Text("内容を確認・修正して「追加」してください")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    Section(header: Text("経費内容")) {
                        TextField("項目名", text: $title)
                        HStack {
                            Text("¥").foregroundColor(.gray)
                            TextField("金額", text: $amountText)
                                .keyboardType(.numberPad)
                        }
                    }
                    Section(header: Text("プロジェクト")) {
                        Picker("プロジェクト", selection: $project) {
                            ForEach(kDefaultProjects, id: \.self) { Text($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
            .navigationTitle("レシート確認")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }.foregroundColor(.gray)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("追加") {
                        if let amount = Double(amountText) {
                            onConfirm(title, amount, project)
                            let g = UIImpactFeedbackGenerator(style: .medium)
                            g.impactOccurred()
                            dismiss()
                        }
                    }
                    .bold()
                    .disabled(!isValid)
                }
            }
        }
    }
}
