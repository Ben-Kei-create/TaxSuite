// MARK: - GmailAPIService.swift
//
// Gmail REST API v1 への通信基盤。
// 認証トークンは GoogleAuthService.shared.freshAccessToken() から取得する。
//
// 必要な Gmail API スコープ（Google Cloud Console > OAuth 同意画面で追加）:
//   - https://www.googleapis.com/auth/gmail.compose    （下書き作成・送信）
//
// GoogleAuthService.clientID に設定したクライアント ID と同じプロジェクトで
// Gmail API を有効にしてください。

import Foundation

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

    // MARK: - Draft creation

    /// Gmail Drafts API create レスポンス（ID のみ使用）
    private struct GmailDraftCreateResponse: Decodable { let id: String }

    /// 件名・本文・CSV 添付で Gmail の下書きを作成する。
    ///
    /// - Parameters:
    ///   - to:          宛先メールアドレス（空の場合は To 欄が空の下書きとして保存）
    ///   - subject:     件名
    ///   - body:        プレーンテキスト本文
    ///   - csvURL:      添付 CSV の一時ファイル URL（nil で添付なし）
    /// - Returns:       作成された Gmail 下書きの ID
    ///
    /// 必要スコープ: `https://www.googleapis.com/auth/gmail.compose`
    @discardableResult
    func createDraft(to: String, subject: String, body: String, csvURL: URL? = nil) async throws -> String {
        let token = try await GoogleAuthService.shared.freshAccessToken()

        // MIME メッセージを組み立て
        let mimeString: String
        if let csvURL, let csvData = try? Data(contentsOf: csvURL) {
            mimeString = buildMultipartMime(
                to: to, subject: subject, body: body,
                csvData: csvData, csvFileName: csvURL.lastPathComponent
            )
        } else {
            mimeString = buildPlainMime(to: to, subject: subject, body: body)
        }

        // Gmail API は raw を base64url で要求
        guard let mimeData = mimeString.data(using: .utf8) else {
            throw GmailAPIError.invalidRequest
        }
        let encoded = base64URLEncoded(mimeData)

        guard let url = URL(string: "\(baseURL)/drafts") else {
            throw GmailAPIError.invalidRequest
        }
        var request = authorizedRequest(url: url, token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = ["message": ["raw": encoded]]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        do {
            let draft = try JSONDecoder().decode(GmailDraftCreateResponse.self, from: data)
            return draft.id
        } catch {
            throw GmailAPIError.decodingError(error)
        }
    }

    /// メールを直接送信する（下書き保存ではなく即時送信）。
    /// 必要スコープ: `https://www.googleapis.com/auth/gmail.send`
    func sendEmail(to: String, subject: String, body: String, csvURL: URL? = nil) async throws {
        let token = try await GoogleAuthService.shared.freshAccessToken()

        let mimeString: String
        if let csvURL, let csvData = try? Data(contentsOf: csvURL) {
            mimeString = buildMultipartMime(
                to: to, subject: subject, body: body,
                csvData: csvData, csvFileName: csvURL.lastPathComponent
            )
        } else {
            mimeString = buildPlainMime(to: to, subject: subject, body: body)
        }

        guard let mimeData = mimeString.data(using: .utf8) else {
            throw GmailAPIError.invalidRequest
        }
        let encoded = base64URLEncoded(mimeData)

        guard let url = URL(string: "\(baseURL)/messages/send") else {
            throw GmailAPIError.invalidRequest
        }
        var request = authorizedRequest(url: url, token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = ["raw": encoded]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)
    }

    // MARK: - MIME builders

    /// 添付なしのシンプルな text/plain メッセージ
    private func buildPlainMime(to: String, subject: String, body: String) -> String {
        let encodedSubject = Data(subject.utf8).base64EncodedString()
        let encodedBody    = Data(body.utf8).base64EncodedString()
        return [
            "MIME-Version: 1.0",
            "To: \(to)",
            "Subject: =?UTF-8?B?\(encodedSubject)?=",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: base64",
            "",
            encodedBody
        ].joined(separator: "\r\n")
    }

    /// text/plain + CSV 添付の multipart/mixed メッセージ
    private func buildMultipartMime(
        to: String, subject: String, body: String,
        csvData: Data, csvFileName: String
    ) -> String {
        let boundary      = "TaxSuite_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let encodedSubject = Data(subject.utf8).base64EncodedString()
        let encodedBody    = Data(body.utf8).base64EncodedString()
        let encodedCSV     = csvData.base64EncodedString()

        return [
            "MIME-Version: 1.0",
            "To: \(to)",
            "Subject: =?UTF-8?B?\(encodedSubject)?=",
            "Content-Type: multipart/mixed; boundary=\"\(boundary)\"",
            "",
            "--\(boundary)",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: base64",
            "",
            encodedBody,
            "",
            "--\(boundary)",
            "Content-Type: text/csv; name=\"\(csvFileName)\"",
            "Content-Disposition: attachment; filename=\"\(csvFileName)\"",
            "Content-Transfer-Encoding: base64",
            "",
            encodedCSV,
            "",
            "--\(boundary)--"
        ].joined(separator: "\r\n")
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

// MARK: - Data + base64url

private func base64URLEncoded(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
