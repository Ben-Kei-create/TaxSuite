// MARK: - GoogleAuthService.swift
//
// 依存関係: GoogleSignIn-iOS (SPM)
//   Package URL: https://github.com/google/GoogleSignIn-iOS
//   推奨バージョン: 7.0 以上
//
// Info.plist に必須のエントリ:
//   1. GIDClientID  → YOUR_CLIENT_ID_HERE
//   2. CFBundleURLTypes[0].CFBundleURLSchemes[0]
//      → com.googleusercontent.apps.YOUR_REVERSED_CLIENT_ID
//      （Google Cloud Console からダウンロードした GoogleService-Info.plist の
//        REVERSED_CLIENT_ID をそのまま使用してください）
//
// ============================================================
// ⚠️  リリース前チェックリスト（Google API 関連）
// ============================================================
// [ ] 1. clientID を本番の OAuth クライアント ID に差し替え
//        → console.cloud.google.com > 認証情報 > OAuth 2.0 クライアント ID (iOS)
//
// [ ] 2. OAuth 同意画面に以下のスコープを追加
//        → console.cloud.google.com > API とサービス > OAuth 同意画面 > スコープを追加
//        - https://mail.google.com/              （Gmail 送受信）
//        - https://www.googleapis.com/auth/gmail.readonly  （領収書取り込み）
//        - https://www.googleapis.com/auth/gmail.compose   （下書き作成）
//        - https://www.googleapis.com/auth/drive.file      （Google Drive エクスポート）
//          ※ drive.file はアプリが作成したファイルのみアクセス可能な最小権限スコープ
//
// [ ] 3. スコープ追加後はユーザーが「サインアウト→再サインイン」で有効になる
//        （既存ユーザーは次回サインイン時に追加のアクセス許可画面が表示される）
//
// [ ] 4. AdMob 広告ユニット ID を本番 ID に差し替え（AdBannerView.swift）
//
// [ ] 5. App Store Connect で IAP 商品を作成
//        商品ID: com.fumiakiMogi777.TaxSuite.pro（非消耗型）
// ============================================================

import Foundation
import UIKit

#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

// MARK: - GoogleAuthService

/// Google OAuth 認証の状態管理・トークン供給を行うシングルトンサービス。
///
/// - SwiftUI から `GoogleAuthService.shared.isSignedIn` 等を参照することで、
///   認証状態の変化が自動的にビューへ反映される。
/// - アクセストークンは Google Sign-In SDK の Keychain に保持され、
///   このクラスが独自にトークン文字列をメモリ外に永続化することはない。
@MainActor
@Observable
final class GoogleAuthService {

    // MARK: - Singleton

    static let shared = GoogleAuthService()

    // MARK: - Configuration (プレースホルダー。実際の値に差し替えてください)

    // ⚠️ RELEASE前必須: console.cloud.google.com → 認証情報 → OAuth 2.0 クライアント ID (iOS) で取得
    nonisolated static let clientID = "YOUR_CLIENT_ID_HERE"

    // MARK: - Observable state

    /// ログイン済みかどうか
    private(set) var isSignedIn = false

    /// ログイン中のアカウントのメールアドレス
    private(set) var userEmail = ""

    /// ログイン中のアカウントの表示名
    private(set) var userDisplayName = ""

    /// サインイン / サインアウト操作中かどうか（ボタンの多重タップ防止用）
    private(set) var isLoading = false

    // MARK: - Init

    private init() {
#if canImport(GoogleSignIn)
        // SDK にクライアント ID を設定
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(
            clientID: GoogleAuthService.clientID
        )
#endif
    }

    // MARK: - Session lifecycle

    /// 前回のセッションを復元する。アプリ起動時（`App.init` 等）に一度だけ呼ぶ。
    func restorePreviousSignIn() async {
#if canImport(GoogleSignIn)
        do {
            let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
            applyState(from: user)
        } catch {
            // 前回セッションなし、またはトークン失効 → ログアウト状態を明示
            clearState()
        }
#endif
    }

    /// Google Sign-In ダイアログを表示してサインインする。
    /// - Throws: `GoogleAuthError`（UI を呼び出せない場合、SDK エラーなど）
    func signIn() async throws {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

#if canImport(GoogleSignIn)
        guard let vc = keyWindowRootViewController() else {
            throw GoogleAuthError.noPresentingViewController
        }
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: vc)
        applyState(from: result.user)
#else
        // SDK 未導入時のフォールバック（Xcode プレビュー・テスト用）
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 秒の擬似待機
        isSignedIn = true
        userEmail = "dev@example.com"
        userDisplayName = "Dev User (SDK なし)"
#endif
    }

    /// サインアウトして認証状態をクリアする。
    func signOut() {
#if canImport(GoogleSignIn)
        GIDSignIn.sharedInstance.signOut()
#endif
        clearState()
    }

    // MARK: - OAuth URL ハンドリング

    /// `onOpenURL` / `application(_:open:options:)` から受け取った URL を処理する。
    /// OAuth リダイレクト以外の URL は `false` を返す。
    @discardableResult
    nonisolated func handle(_ url: URL) -> Bool {
#if canImport(GoogleSignIn)
        return GIDSignIn.sharedInstance.handle(url)
#else
        return false
#endif
    }

    // MARK: - Token access

    /// 有効なアクセストークンを返す。期限切れの場合は自動でリフレッシュする。
    ///
    /// - Returns: Bearer トークン文字列
    /// - Throws: `GoogleAuthError.notAuthenticated` / `GoogleAuthError.tokenRefreshFailed`
    func freshAccessToken() async throws -> String {
        guard isSignedIn else { throw GoogleAuthError.notAuthenticated }

#if canImport(GoogleSignIn)
        guard let user = GIDSignIn.sharedInstance.currentUser else {
            throw GoogleAuthError.notAuthenticated
        }
        do {
            let refreshed = try await user.refreshTokensIfNeeded()
            let token = refreshed.accessToken.tokenString
            guard !token.isEmpty else { throw GoogleAuthError.tokenUnavailable }
            return token
        } catch let err as GoogleAuthError {
            throw err
        } catch {
            throw GoogleAuthError.tokenRefreshFailed(underlying: error)
        }
#else
        throw GoogleAuthError.notAuthenticated
#endif
    }

    // MARK: - Private helpers

#if canImport(GoogleSignIn)
    private func applyState(from user: GIDGoogleUser) {
        isSignedIn        = true
        userEmail         = user.profile?.email ?? ""
        userDisplayName   = user.profile?.name ?? ""
    }
#endif

    private func clearState() {
        isSignedIn        = false
        userEmail         = ""
        userDisplayName   = ""
    }

    private func keyWindowRootViewController() -> UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: \.isKeyWindow)?
            .rootViewController
    }
}

// MARK: - GoogleAuthError

enum GoogleAuthError: LocalizedError {
    case noPresentingViewController
    case notAuthenticated
    case tokenUnavailable
    case tokenRefreshFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .noPresentingViewController:
            return "ログイン画面を表示できませんでした。"
        case .notAuthenticated:
            return "Googleアカウントにログインしていません。"
        case .tokenUnavailable:
            return "アクセストークンを取得できませんでした。"
        case .tokenRefreshFailed(let err):
            return "トークンの更新に失敗しました: \(err.localizedDescription)"
        }
    }
}
