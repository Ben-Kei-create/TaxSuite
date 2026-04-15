// MARK: - LocationTriggerView.swift
//
// ジオフェンシング設定 UI。
// 登録済みの場所をリストで管理し、MapKit で新規ピンをドロップして追加できる。

import SwiftUI
import SwiftData
import MapKit
import CoreLocation

// MARK: - LocationTriggersView（一覧）

struct LocationTriggersView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LocationTrigger.createdAt, order: .reverse) private var triggers: [LocationTrigger]

    @State private var locationManager = LocationManager.shared
    @State private var showingAddSheet = false
    @State private var editingTrigger: LocationTrigger?
    @State private var showPermissionAlert = false

    var body: some View {
        TaxSuiteScreenSurface {
            List {
                // 権限ステータスバナー
                if locationManager.authStatus != .always {
                    permissionBanner
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("場所でリマインド")
                            .font(.title3.bold())
                        Text("指定した場所に到着すると通知が届き、ワンタップで経費を記録できます。")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding(.vertical, 4)
                }

                Section(header: Text("登録済みの場所").font(.subheadline).foregroundColor(.secondary)) {
                    if triggers.isEmpty {
                        Label("場所が登録されていません", systemImage: "mappin.slash")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(triggers) { trigger in
                            triggerRow(trigger)
                        }
                        .onDelete(perform: deleteTriggers)
                    }
                }

                Section {
                    Button {
                        handleAddTap()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.black)
                                .font(.system(size: 20))
                            Text("場所を追加")
                                .font(.headline)
                                .foregroundColor(.black)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("場所でリマインド")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingAddSheet, onDismiss: syncRegions) {
            LocationTriggerEditView(trigger: nil)
        }
        .sheet(item: $editingTrigger, onDismiss: syncRegions) { t in
            LocationTriggerEditView(trigger: t)
        }
        .alert("位置情報の権限が必要です", isPresented: $showPermissionAlert) {
            Button("設定を開く") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("ジオフェンシングを使用するには「設定」→「プライバシー」→「位置情報」で「常に許可」に変更してください。")
        }
        .task { syncRegions() }
    }

    // MARK: Sub-views

    private var permissionBanner: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "location.slash.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 20))
                VStack(alignment: .leading, spacing: 3) {
                    Text("位置情報の権限が必要です")
                        .font(.subheadline.weight(.semibold))
                    Text("現在: \(locationManager.authStatus.displayText)  →  「常に許可」が必要です")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("許可する") {
                    locationManager.requestLocationPermission()
                }
                .font(.caption.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black)
                .clipShape(Capsule())
            }
            .padding(.vertical, 4)
        }
    }

    private func triggerRow(_ trigger: LocationTrigger) -> some View {
        Button { editingTrigger = trigger } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(trigger.isEnabled ? Color.black : Color.gray.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: "mappin.circle.fill")
                        .foregroundColor(trigger.isEnabled ? .white : .gray)
                        .font(.system(size: 18))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(trigger.name.isEmpty ? "（名前なし）" : trigger.name)
                        .font(.body.weight(.semibold))
                        .foregroundColor(.primary)
                    HStack(spacing: 6) {
                        Text("半径 \(Int(trigger.radius))m")
                        if trigger.defaultAmount > 0 {
                            Text("¥\(Int(trigger.defaultAmount).formatted())")
                        }
                        Text(trigger.defaultProject)
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }
                Spacer()

                Toggle("", isOn: Binding(
                    get: { trigger.isEnabled },
                    set: { newValue in
                        trigger.isEnabled = newValue
                        if newValue {
                            LocationManager.shared.startMonitoring(trigger)
                        } else {
                            LocationManager.shared.stopMonitoring(trigger)
                        }
                        try? modelContext.save()
                    }
                ))
                .labelsHidden()
                .tint(.black)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Actions

    private func handleAddTap() {
        if locationManager.authStatus == .notDetermined {
            locationManager.requestLocationPermission()
        }
        showingAddSheet = true
    }

    private func deleteTriggers(at offsets: IndexSet) {
        for index in offsets {
            let trigger = triggers[index]
            LocationManager.shared.stopMonitoring(trigger)
            trigger.removeFromUserDefaultsCache()
            modelContext.delete(trigger)
        }
        try? modelContext.save()
    }

    private func syncRegions() {
        for trigger in triggers where trigger.isEnabled {
            trigger.cacheToUserDefaults()
        }
        LocationManager.shared.syncMonitoredRegions(triggers: triggers)
    }
}

// MARK: - LocationTriggerEditView（追加・編集）

struct LocationTriggerEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var trigger: LocationTrigger?

    // Fields
    @State private var name: String = ""
    @State private var radius: Double = 100
    @State private var defaultAmount: String = ""
    @State private var defaultProject: String = "その他"
    @State private var defaultCategory: String = "未分類"

    // Map
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 35.6812, longitude: 139.7671),
            latitudinalMeters: 600,
            longitudinalMeters: 600
        )
    )
    @State private var pinCoordinate: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 35.6812, longitude: 139.7671)
    @State private var searchText: String = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var isSearching = false
    @State private var showingSearchResults = false

    // 登録前の確認ダイアログ
    @State private var showingSaveConfirmation = false
    // 登録完了トースト
    @State private var showingSavedToast = false

    private let categoryOptions = ExpenseAutofillPredictor.defaultCategories
    private let projectOptions  = ExpenseAutofillPredictor.defaultProjects

    var body: some View {
        NavigationStack {
            TaxSuiteScreenSurface {
                Form {
                    // 地図セクション
                    Section(header: Text("場所を選択")) {
                        VStack(spacing: 10) {
                            // 検索バー
                            HStack {
                                Image(systemName: "magnifyingglass")
                                    .foregroundColor(.secondary)
                                TextField("カフェ名・住所で検索", text: $searchText)
                                    .onSubmit { Task { await search() } }
                                if !searchText.isEmpty {
                                    Button { searchText = ""; searchResults = [] } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                                    }
                                }
                            }
                            .padding(10)
                            .background(Color.black.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                            // 検索結果
                            if !searchResults.isEmpty {
                                VStack(spacing: 0) {
                                    ForEach(searchResults.prefix(4), id: \.self) { item in
                                        Button {
                                            selectSearchResult(item)
                                        } label: {
                                            HStack {
                                                Image(systemName: "mappin")
                                                    .foregroundColor(.black)
                                                    .frame(width: 20)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(item.name ?? "")
                                                        .font(.subheadline.weight(.medium))
                                                        .foregroundColor(.primary)
                                                    Text(item.placemark.title ?? "")
                                                        .font(.caption2)
                                                        .foregroundColor(.secondary)
                                                        .lineLimit(1)
                                                }
                                                Spacer()
                                            }
                                            .padding(.vertical, 8)
                                        }
                                        .buttonStyle(.plain)
                                        if item != searchResults.prefix(4).last {
                                            Divider()
                                        }
                                    }
                                }
                                .padding(.horizontal, 4)
                            }

                            // 地図
                            Map(position: $cameraPosition) {
                                Annotation(name.isEmpty ? "📍" : name, coordinate: pinCoordinate) {
                                    ZStack {
                                        Circle()
                                            .fill(Color.black.opacity(0.15))
                                            .frame(width: radius / 5, height: radius / 5)
                                            .blur(radius: 4)
                                        Image(systemName: "mappin.circle.fill")
                                            .font(.system(size: 32))
                                            .foregroundColor(.black)
                                            .shadow(radius: 4)
                                    }
                                }
                            }
                            .mapStyle(.standard)
                            .frame(height: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .onTapGesture(coordinateSpace: .local) { _ in
                                // Map内タップでピン移動（MapReader代替：カメラ中心を使用）
                            }

                            Text("地図をドラッグして中心にピンを合わせ、「中心に設定」を押してください")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)

                            Button {
                                setToCameraCenter()
                            } label: {
                                Label("現在の地図中心を場所に設定", systemImage: "scope")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.black)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(Color.black.opacity(0.07))
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                    }

                    // 基本情報
                    Section(header: Text("リマインダー設定")) {
                        TextField("場所の名前（例: いつものスタバ）", text: $name)

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("通知半径")
                                Spacer()
                                Text("\(Int(radius)) m")
                                    .font(.subheadline.monospacedDigit().weight(.semibold))
                            }
                            Slider(value: $radius, in: 50...500, step: 25)
                                .tint(.black)
                        }
                    }

                    // デフォルト経費
                    Section(header: Text("経費のデフォルト値（任意）")) {
                        WalletChargeInputView(amountText: $defaultAmount)
                        Picker("カテゴリ", selection: $defaultCategory) {
                            ForEach(categoryOptions, id: \.self) { Text($0).tag($0) }
                        }
                        Picker("プロジェクト", selection: $defaultProject) {
                            ForEach(projectOptions, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
            }
            .navigationTitle(trigger == nil ? "場所を追加" : "場所を編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") { showingSaveConfirmation = true }
                        .fontWeight(.bold)
                        .disabled(name.isEmpty)
                }
            }
            .alert(trigger == nil ? "この内容で登録しますか？" : "この内容で更新しますか？",
                   isPresented: $showingSaveConfirmation) {
                Button(trigger == nil ? "登録する" : "更新する") { save() }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text(saveConfirmationMessage)
            }
            .overlay(alignment: .top) {
                if showingSavedToast {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(trigger == nil ? "ジオフェンスを登録しました" : "ジオフェンスを更新しました")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.85))
                    .clipShape(Capsule())
                    .shadow(radius: 6)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onAppear(perform: configureOnAppear)
        }
    }

    private var saveConfirmationMessage: String {
        var lines: [String] = []
        lines.append("名前: \(name.isEmpty ? "（名前なし）" : name)")
        lines.append(String(format: "半径: %d m", Int(radius)))
        lines.append(String(format: "座標: %.5f, %.5f", pinCoordinate.latitude, pinCoordinate.longitude))
        if let amount = Double(defaultAmount), amount > 0 {
            lines.append("金額のデフォルト: ¥\(Int(amount).formatted())")
        }
        lines.append("カテゴリ: \(defaultCategory)")
        lines.append("プロジェクト: \(defaultProject)")
        lines.append("")
        lines.append("登録すると、この場所への到着時に通知が届きます。位置情報の利用許可が必要です。")
        return lines.joined(separator: "\n")
    }

    // MARK: - Actions

    private func configureOnAppear() {
        if let t = trigger {
            name            = t.name
            radius          = t.radius
            defaultAmount   = t.defaultAmount > 0 ? String(Int(t.defaultAmount)) : ""
            defaultProject  = t.defaultProject
            defaultCategory = t.defaultCategory
            pinCoordinate   = CLLocationCoordinate2D(latitude: t.latitude, longitude: t.longitude)
            cameraPosition  = .region(MKCoordinateRegion(
                center: pinCoordinate,
                latitudinalMeters: max(t.radius * 6, 400),
                longitudinalMeters: max(t.radius * 6, 400)
            ))
        } else {
            // 現在地があれば中心に移動
            let status = CLLocationManager().authorizationStatus
            if status == .authorizedAlways || status == .authorizedWhenInUse,
               let loc = CLLocationManager().location {
                pinCoordinate = loc.coordinate
                cameraPosition = .region(MKCoordinateRegion(
                    center: loc.coordinate, latitudinalMeters: 600, longitudinalMeters: 600
                ))
            }
        }
    }

    private func setToCameraCenter() {
        // カメラポジションから座標を抽出
        if let region = cameraPosition.region {
            pinCoordinate = region.center
        }
    }

    @MainActor
    private func search() async {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSearching = true
        defer { isSearching = false }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchText
        request.region = MKCoordinateRegion(
            center: pinCoordinate,
            latitudinalMeters: 5000,
            longitudinalMeters: 5000
        )

        let search = MKLocalSearch(request: request)
        let response = try? await search.start()
        searchResults = response?.mapItems ?? []
    }

    private func selectSearchResult(_ item: MKMapItem) {
        let coord = item.placemark.coordinate
        pinCoordinate = coord
        name = item.name ?? name
        cameraPosition = .region(MKCoordinateRegion(
            center: coord, latitudinalMeters: 600, longitudinalMeters: 600
        ))
        searchResults = []
        searchText = item.name ?? ""
    }

    private func save() {
        let amount = Double(defaultAmount) ?? 0

        if let t = trigger {
            t.name            = name
            t.latitude        = pinCoordinate.latitude
            t.longitude       = pinCoordinate.longitude
            t.radius          = radius
            t.defaultAmount   = amount
            t.defaultProject  = defaultProject
            t.defaultCategory = defaultCategory
            t.cacheToUserDefaults()
            if t.isEnabled {
                LocationManager.shared.stopMonitoring(t)
                LocationManager.shared.startMonitoring(t)
            }
        } else {
            let newTrigger = LocationTrigger(
                name: name,
                latitude: pinCoordinate.latitude,
                longitude: pinCoordinate.longitude,
                radius: radius,
                defaultAmount: amount,
                defaultProject: defaultProject,
                defaultCategory: defaultCategory
            )
            modelContext.insert(newTrigger)
            newTrigger.cacheToUserDefaults()
            LocationManager.shared.startMonitoring(newTrigger)
        }

        try? modelContext.save()

        // 登録完了のフィードバック → 少し表示してから閉じる
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            showingSavedToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            dismiss()
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        LocationTriggersView()
    }
    .modelContainer(for: LocationTrigger.self, inMemory: true)
}
