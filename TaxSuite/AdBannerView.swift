import SwiftUI

// AdMob SDK (google-mobile-ads-swift) がインストールされたら自動で有効化される
// SDK 未インストール時はグレーのプレースホルダーを表示してビルドが通る

#if canImport(GoogleMobileAds)
import GoogleMobileAds

struct AdBannerView: UIViewRepresentable {
    // ⚠️ リリース前に AdMob コンソールで取得した本番 ID に変更する
    // テスト用:  ca-app-pub-3940256099942544/2934735716
    // 本番用:   ca-app-pub-XXXXXXXXXXXXXXXX/XXXXXXXXXX
    var adUnitID: String = "ca-app-pub-3940256099942544/2934735716"

    func makeUIView(context: Context) -> GADBannerView {
        let banner = GADBannerView(adSize: GADAdSizeBanner)
        banner.adUnitID = adUnitID
        banner.rootViewController = UIApplication.shared
            .connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.rootViewController
        banner.load(GADRequest())
        return banner
    }

    func updateUIView(_ uiView: GADBannerView, context: Context) {}
}

#else

/// SDK 未インストール時のプレースホルダー
/// ─────────────────────────────────────────────
/// 有効化の手順:
///   Xcode → File → Add Package Dependencies
///   → https://github.com/googleads/swift-package-manager-google-mobile-ads
///   → バージョン: Up to Next Major (11.x 以降)
/// ─────────────────────────────────────────────
struct AdBannerView: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.04)
            Text("広告スペース")
                .font(.caption2)
                .foregroundColor(Color.gray.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 50)
    }
}

#endif
