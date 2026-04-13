// MARK: - LocationManager.swift
//
// ジオフェンシング（位置情報によるリマインダー）の中核。
// CLLocationManager のセットアップ・権限要求・領域監視と
// UNUserNotificationCenter によるローカル通知発火を担う。
//
// 必要な Info.plist キー:
//   NSLocationAlwaysAndWhenInUseUsageDescription
//   NSLocationWhenInUseUsageDescription
//
// 必要な UIBackgroundModes: location
// 最大同時監視領域数: iOS 上限 20 件（CoreLocation 制約）

import CoreLocation
import UserNotifications
import SwiftUI

// MARK: - LocationAuthStatus

enum LocationAuthStatus {
    case notDetermined, restricted, denied, whenInUse, always

    var displayText: String {
        switch self {
        case .notDetermined: return "未設定"
        case .restricted:    return "制限中"
        case .denied:        return "拒否済み"
        case .whenInUse:     return "使用中のみ"
        case .always:        return "常に許可"
        }
    }

    var isMonitoringCapable: Bool {
        self == .always
    }
}

// MARK: - PendingGeofenceExpense
// 通知タップ時にアプリ側で受け取る構造体

struct PendingGeofenceExpense: Equatable {
    let triggerName: String
    let amount: Double
    let project: String
    let category: String
}

// MARK: - LocationManager

@MainActor
@Observable
final class LocationManager: NSObject {

    // MARK: Singleton
    static let shared = LocationManager()

    // MARK: Published state
    private(set) var authStatus: LocationAuthStatus = .notDetermined
    private(set) var notificationAuthGranted = false

    /// 通知タップ時にセットされる。ContentView が監視して ExpenseEditView を開く。
    var pendingGeofenceExpense: PendingGeofenceExpense?

    // MARK: Private
    private let clManager = CLLocationManager()
    private let notificationCenter = UNUserNotificationCenter.current()

    private override init() {
        super.init()
        clManager.delegate = self
        notificationCenter.delegate = self
        refreshAuthStatus()
    }

    // MARK: - Authorization

    func requestLocationPermission() {
        switch clManager.authorizationStatus {
        case .notDetermined:
            clManager.requestAlwaysAuthorization()
        case .authorizedWhenInUse:
            clManager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    func requestNotificationPermission() async {
        let granted = (try? await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        notificationAuthGranted = granted
    }

    private func refreshAuthStatus() {
        let status = clManager.authorizationStatus
        switch status {
        case .notDetermined:        authStatus = .notDetermined
        case .restricted:           authStatus = .restricted
        case .denied:               authStatus = .denied
        case .authorizedWhenInUse:  authStatus = .whenInUse
        case .authorizedAlways:     authStatus = .always
        @unknown default:           authStatus = .notDetermined
        }
    }

    // MARK: - Region monitoring

    /// トリガーの領域監視を開始する
    func startMonitoring(_ trigger: LocationTrigger) {
        guard authStatus.isMonitoringCapable else { return }
        let region = makeRegion(for: trigger)
        clManager.startMonitoring(for: region)
    }

    /// トリガーの領域監視を停止する
    func stopMonitoring(_ trigger: LocationTrigger) {
        let identifier = regionIdentifier(for: trigger)
        if let region = clManager.monitoredRegions.first(where: { $0.identifier == identifier }) {
            clManager.stopMonitoring(for: region)
        }
    }

    /// 登録済みトリガーをすべて再同期する（起動時やデータ変更後に呼ぶ）
    func syncMonitoredRegions(triggers: [LocationTrigger]) {
        guard authStatus.isMonitoringCapable else { return }

        // 現在の監視リストから TaxSuite のものだけを削除
        for region in clManager.monitoredRegions where region.identifier.hasPrefix("taxsuite.geo.") {
            clManager.stopMonitoring(for: region)
        }

        // 有効なトリガーを再登録（iOS 上限 20 件を考慮）
        for trigger in triggers.filter(\.isEnabled).prefix(20) {
            clManager.startMonitoring(for: makeRegion(for: trigger))
        }
    }

    // MARK: - Notification

    func fireGeofenceNotification(triggerName: String, amount: Double, project: String, category: String) {
        let content = UNMutableNotificationContent()
        content.title = "📍 \(triggerName) に到着しました"
        content.body = amount > 0
            ? "¥\(Int(amount).formatted()) の経費を記録しますか？"
            : "経費を記録しますか？"
        content.sound = .default
        content.categoryIdentifier = "GEOFENCE_EXPENSE"
        content.userInfo = [
            "triggerName": triggerName,
            "amount":      amount,
            "project":     project,
            "category":    category
        ]

        let request = UNNotificationRequest(
            identifier: "taxsuite.geofence.\(triggerName).\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil  // 即時発行
        )
        notificationCenter.add(request)
    }

    // MARK: - Helpers

    private func regionIdentifier(for trigger: LocationTrigger) -> String {
        "taxsuite.geo.\(trigger.id.uuidString)"
    }

    private func makeRegion(for trigger: LocationTrigger) -> CLCircularRegion {
        let center = CLLocationCoordinate2D(latitude: trigger.latitude, longitude: trigger.longitude)
        let radius = max(50, min(trigger.radius, 500))  // 50m〜500m にクランプ
        let region = CLCircularRegion(center: center, radius: radius, identifier: regionIdentifier(for: trigger))
        region.notifyOnEntry = true
        region.notifyOnExit  = false
        return region
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            refreshAuthStatus()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let circular = region as? CLCircularRegion,
              circular.identifier.hasPrefix("taxsuite.geo.") else { return }

        // UserDefaults から対応するトリガーの情報を取得（SwiftData はここからアクセス不可）
        let key = "taxsuite.trigger.\(circular.identifier)"
        let name     = UserDefaults.standard.string(forKey: "\(key).name")     ?? circular.identifier
        let amount   = UserDefaults.standard.double(forKey: "\(key).amount")
        let project  = UserDefaults.standard.string(forKey: "\(key).project")  ?? "その他"
        let category = UserDefaults.standard.string(forKey: "\(key).category") ?? "未分類"

        Task { @MainActor in
            fireGeofenceNotification(triggerName: name, amount: amount, project: project, category: category)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        print("[LocationManager] monitoringDidFail: \(error.localizedDescription)")
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension LocationManager: UNUserNotificationCenterDelegate {
    // フォアグラウンドでも通知バナーを表示
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // 通知タップ → ExpenseEditView をトリガー
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        guard let name = info["triggerName"] as? String else {
            completionHandler()
            return
        }
        let amount   = info["amount"]   as? Double ?? 0
        let project  = info["project"]  as? String ?? "その他"
        let category = info["category"] as? String ?? "未分類"

        Task { @MainActor in
            LocationManager.shared.pendingGeofenceExpense = PendingGeofenceExpense(
                triggerName: name,
                amount: amount,
                project: project,
                category: category
            )
        }
        completionHandler()
    }
}

// MARK: - UserDefaults cache helpers

extension LocationTrigger {
    /// ジオフェンスのデリゲートからアクセスできるよう、情報を UserDefaults にキャッシュ
    func cacheToUserDefaults() {
        let key = "taxsuite.trigger.taxsuite.geo.\(id.uuidString)"
        UserDefaults.standard.set(name,            forKey: "\(key).name")
        UserDefaults.standard.set(defaultAmount,   forKey: "\(key).amount")
        UserDefaults.standard.set(defaultProject,  forKey: "\(key).project")
        UserDefaults.standard.set(defaultCategory, forKey: "\(key).category")
    }

    func removeFromUserDefaultsCache() {
        let key = "taxsuite.trigger.taxsuite.geo.\(id.uuidString)"
        UserDefaults.standard.removeObject(forKey: "\(key).name")
        UserDefaults.standard.removeObject(forKey: "\(key).amount")
        UserDefaults.standard.removeObject(forKey: "\(key).project")
        UserDefaults.standard.removeObject(forKey: "\(key).category")
    }
}
