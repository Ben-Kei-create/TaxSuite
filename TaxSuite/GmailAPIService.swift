// MARK: - GmailAPIService.swift
//
// Gmail REST API v1 への通信基盤。
// 認証トークンは GoogleAuthService.shared.freshAccessToken() から取得する。
//
// 必要な Gmail API スコープ（Google Cloud Console > OAuth 同意画面で追加）:
//   - https://www.googleapis.com/auth/gmail.readonly
//
// GoogleAuthService.clientID に設定したクライアント ID と同じプロジェクトで
// Gmail API を有効にしてください。

import Foundation

// MARK: - Domain models

/// メール一覧 API のレスポンス（メッセージ ID のリスト）
private struct GmailMessageList: Decodable {
    let messages: [GmailMessageRef]?
    let nextPageToken: String?
    let resultSizeEstimate: Int?
}

/// メッセージ ID への参照（一覧取得レスポンスの各要素）
private struct GmailMessageRef: Decodable {
    let id: String
    let threadId: String
}

/// メッセージ詳細 API のレスポンス（メタデータ形式）
private struct GmailMessageDetail: Decodable {
    let id: String
    let threadId: String
    let snippet: String
    let payload: Payload?
    let internalDate: String?  // Unix ミリ秒（文字列）

    struct Payload: Decodable {
        let headers: [Header]?
    }

    struct Header: Decodable {
        let name: String
        let value: String
    }

    // ヘッダーから Subject / From / Date を取り出す
    var subject: String { headerValue(for: "Subject") }
    var from: String    { headerValue(for: "From") }
    var date: String    { headerValue(for: "Date") }

    private func headerValue(for name: String) -> String {
        payload?.headers?.first(where: { $0.name == name })?.value ?? ""
    }
}

/// アプリ層で使う軽量なメールサマリー
struct GmailMessageSummary: Identifiable {
    let id: String
    let subject: String
    let from: String
    let dateString: String
    let snippet: String
    /// メール内の金額候補（ReceiptParser で抽出）
    let detectedAmount: Double?

    fileprivate init(from detail: GmailMessageDetail) {
        id            = detail.id
        subject       = detail.subject
        from          = detail.from
        dateString    = detail.date
        snippet       = detail.snippet
        detectedAmount = ReceiptParser.extractAmount(from: [detail.snippet, detail.subject])
    }
}

// MARK: - GmailAPIError

enum GmailAPIError: LocalizedError {
    case notAuthenticated
    case invalidRequest
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Googleアカウントにログインしていません。"
        case .invalidRequest:
            return "不正なリクエストです。"
        case .invalidResponse:
            return "サーバーから無効なレスポンスが返されました。"
        case .apiError(let code, let msg):
            return "Gmail API エラー (HTTP \(code)): \(msg)"
        case .decodingError(let err):
            return "レスポンスの解析に失敗しました: \(err.localizedDescription)"
        }
    }
}

// MARK: - GmailAPIService

/// Gmail REST API v1 への通信を担う Service 層。
///
/// `actor` にすることで、複数の非同期タスクが同時に実行されても
/// 内部状態（URLSession 等）への競合アクセスが発生しない。
actor GmailAPIService {

    // MARK: - Singleton

    static let shared = GmailAPIService()
    private init() {}

    // MARK: - Constants

    private let baseURL = "https://gmail.googleapis.com/gmail/v1/users/me"
    private let session = URLSession.shared

    /// 領収書・請求書メールを絞り込む検索クエリ（Gmail 検索構文）
    private static let receiptSearchQuery =
        "subject:(領収書 OR Receipt OR invoice OR レシート OR 請求書 OR お買い上げ) " +
        "newer_than:30d"

    /// 一度に取得するメッセージ数の上限
    private static let maxResults = 15

    // MARK: - Public API

    /// 直近30日間の領収書関連メールを取得して返す。
    ///
    /// 処理フロー:
    ///   1. `GoogleAuthService` からアクセストークンを取得
    ///   2. Gmail messages.list API でメッセージ ID を取得
    ///   3. 各 ID に対して messages.get API でメタデータを並列取得
    ///   4. `ReceiptParser` でスニペットから金額を抽出してサマリーを返す
    ///
    /// - Returns: 日付降順にソートされた `GmailMessageSummary` の配列
    func fetchRecentReceiptEmails() async throws -> [GmailMessageSummary] {
        // Step 1: トークン取得（期限切れなら自動リフレッシュ）
        let token = try await GoogleAuthService.shared.freshAccessToken()

        // Step 2: メッセージ ID 一覧を取得
        let refs = try await listMessages(
            query: GmailAPIService.receiptSearchQuery,
            token: token
        )

        guard !refs.isEmpty else { return [] }

        // Step 3: 各メッセージの詳細を並列取得
        let summaries: [GmailMessageSummary] = try await withThrowingTaskGroup(
            of: GmailMessageSummary?.self
        ) { group in
            for ref in refs.prefix(GmailAPIService.maxResults) {
                group.addTask {
                    try await self.fetchMessageDetail(id: ref.id, token: token)
                }
            }
            var results: [GmailMessageSummary] = []
            for try await summary in group {
                if let s = summary { results.append(s) }
            }
            return results
        }

        // 日付文字列（RFC 2822 形式）で降順ソート
        return summaries.sorted { $0.dateString > $1.dateString }
    }

    // MARK: - Private networking

    private func listMessages(query: String, token: String) async throws -> [GmailMessageRef] {
        guard var components = URLComponents(string: "\(baseURL)/messages") else {
            throw GmailAPIError.invalidRequest
        }
        components.queryItems = [
            URLQueryItem(name: "q",          value: query),
            URLQueryItem(name: "maxResults", value: "\(GmailAPIService.maxResults)")
        ]
        guard let url = components.url else { throw GmailAPIError.invalidRequest }

        let (data, response) = try await session.data(for: authorizedRequest(url: url, token: token))
        try validateHTTPResponse(response, data: data)

        do {
            let list = try JSONDecoder().decode(GmailMessageList.self, from: data)
            return list.messages ?? []
        } catch {
            throw GmailAPIError.decodingError(error)
        }
    }

    private func fetchMessageDetail(id: String, token: String) async throws -> GmailMessageSummary? {
        guard var components = URLComponents(string: "\(baseURL)/messages/\(id)") else {
            throw GmailAPIError.invalidRequest
        }
        // メタデータ形式で取得（Subject / From / Date ヘッダーのみ）
        components.queryItems = [
            URLQueryItem(name: "format",          value: "metadata"),
            URLQueryItem(name: "metadataHeaders", value: "Subject"),
            URLQueryItem(name: "metadataHeaders", value: "From"),
            URLQueryItem(name: "metadataHeaders", value: "Date")
        ]
        guard let url = components.url else { throw GmailAPIError.invalidRequest }

        let (data, response) = try await session.data(for: authorizedRequest(url: url, token: token))
        try validateHTTPResponse(response, data: data)

        do {
            let detail = try JSONDecoder().decode(GmailMessageDetail.self, from: data)
            return GmailMessageSummary(from: detail)
        } catch {
            throw GmailAPIError.decodingError(error)
        }
    }

    // MARK: - Helpers

    private func authorizedRequest(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json",  forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        return request
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw GmailAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GmailAPIError.apiError(statusCode: http.statusCode, message: message)
        }
    }
}
