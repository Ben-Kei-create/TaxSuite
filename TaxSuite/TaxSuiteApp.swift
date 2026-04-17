import SwiftUI
import SwiftData
#if canImport(GoogleMobileAds)
import GoogleMobileAds
#endif

@main
struct TaxSuiteApp: App {
    init() {
        TaxSuiteWidgetStore.markAppLaunched()
        // StoreKit2 の購入状態を起動時に同期
        Task { await TaxSuiteStore.shared.refreshPurchaseStatus() }
#if canImport(GoogleMobileAds)
        MobileAds.shared.start(completionHandler: nil)
#endif
        // Google Sign-In: 前回のセッションを非同期で復元
        Task { await GoogleAuthService.shared.restorePreviousSignIn() }
        // LocationManager をメインスレッドで初期化し、通知デリゲートを登録
        _ = LocationManager.shared
    }

    var sharedModelContainer: ModelContainer = {
        // 1st try: CloudKit 同期あり（通常起動）
        if let container = try? TaxSuitePersistence.makeContainer() {
            return container
        }
        // 2nd try: iCloud 不使用でローカル保存（iCloud 未サインインなどで CloudKit 初期化失敗時）
        if let container = try? TaxSuitePersistence.makeContainerLocalOnly() {
            return container
        }
        // 最終手段: インメモリ（起動は維持されるがデータは永続しない）
        return try! TaxSuitePersistence.makeContainer(inMemory: true)
    }()
    var body: some Scene {
        WindowGroup {
            TaxSuiteLaunchContainerView()
                .onOpenURL { url in
                    GoogleAuthService.shared.handle(url)
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
