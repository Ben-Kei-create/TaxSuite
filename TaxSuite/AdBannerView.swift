import SwiftUI

// AdMob SDK (google-mobile-ads-swift) がインストールされたら自動で有効化される
// SDK 未インストール時はグレーのプレースホルダーを表示してビルドが通る

#if canImport(GoogleMobileAds)
import GoogleMobileAds

struct AdBannerView: UIViewRepresentable {
    typealias UIViewType = BannerView

    // ⚠️ リリース前に AdMob コンソールで取得した本番 ID に変更する
    // Google公式の iOS バナー向けテスト用広告ユニット ID
    // テスト用:  ca-app-pub-3940256099942544/2435281174
    // 本番用:   ca-app-pub-XXXXXXXXXXXXXXXX/XXXXXXXXXX
    var adUnitID: String = "ca-app-pub-3940256099942544/2435281174"

    func makeUIView(context: Context) -> BannerView {
        let banner = BannerView(adSize: AdSizeBanner)
        banner.adUnitID = adUnitID

        let request = Request()
        request.scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        banner.load(request)

        return banner
    }

    func updateUIView(_ uiView: BannerView, context: Context) {}
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
