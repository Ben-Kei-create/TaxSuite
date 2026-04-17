// MARK: - GoogleDriveService.swift
//
// Google Drive REST API v3 への通信基盤。
// 認証トークンは GoogleAuthService.shared.freshAccessToken() から取得する。
//
// 必要な OAuth スコープ（Google Cloud Console の OAuth 同意画面で追加してください）:
//   https://www.googleapis.com/auth/drive.file
//   （TaxSuite が作成したファイル・フォルダのみにアクセス）
//
// 追加後、ユーザーはサインアウト→再サインインで新しいスコープが有効になります。

import Foundation

// MARK: - Error

enum GoogleDriveError: Error, LocalizedError {
    case notSignedIn
    case folderCreationFailed(String)
    case uploadFailed(String)
    case missingDriveScope

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Googleアカウントにサインインしてください。"
        case .folderCreationFailed(let msg):
            return "フォルダの作成に失敗しました: \(msg)"
        case .uploadFailed(let msg):
            return "ファイルのアップロードに失敗しました: \(msg)"
        case .missingDriveScope:
            return "Google Driveのアクセス権がありません。設定 → 連携 からサインアウトして再ログインしてください。"
        }
    }
}

// MARK: - Service

actor GoogleDriveService {
    static let shared = GoogleDriveService()

    private let filesURL    = "https://www.googleapis.com/drive/v3/files"
    private let uploadURL   = "https://www.googleapis.com/upload/drive/v3/files"

    // MARK: - Public

    /// アプリのルートフォルダ「TaxSuite」を取得または作成してIDを返す。
    func findOrCreateRootFolder(token: String) async throws -> String {
        try await findOrCreateFolder(name: "TaxSuite", parentID: nil, token: token)
    }

    /// 指定名のフォルダを検索し、なければ作成してIDを返す。
    func findOrCreateFolder(name: String, parentID: String?, token: String) async throws -> String {
        let safeName = name.replacingOccurrences(of: "'", with: "\\'")
        var query = "mimeType='application/vnd.google-apps.folder' and name='\(safeName)' and trashed=false"
        if let parentID { query += " and '\(parentID)' in parents" }

        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = URL(string: "\(filesURL)?q=\(encoded)&fields=files(id)")!

        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: req)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let files = json["files"] as? [[String: Any]],
           let id = files.first?["id"] as? String {
            return id
        }
        return try await createFolder(name: name, parentID: parentID, token: token)
    }

    /// CSV文字列をマルチパートアップロードする。
    func uploadCSV(csvString: String, fileName: String, parentID: String, token: String) async throws {
        let url = URL(string: "\(uploadURL)?uploadType=multipart&fields=id")!
        let boundary = UUID().uuidString.replacingOccurrences(of: "-", with: "")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let metadata: [String: Any] = [
            "name": fileName,
            "parents": [parentID],
            "mimeType": "text/csv"
        ]
        let metaData  = try JSONSerialization.data(withJSONObject: metadata)
        let csvData   = csvString.data(using: .utf8) ?? Data()

        var body = Data()
        func a(_ s: String) { body.append(s.data(using: .utf8)!) }
        a("--\(boundary)\r\n")
        a("Content-Type: application/json; charset=UTF-8\r\n\r\n")
        body.append(metaData)
        a("\r\n--\(boundary)\r\n")
        a("Content-Type: text/csv\r\n\r\n")
        body.append(csvData)
        a("\r\n--\(boundary)--")
        req.httpBody = body

        let (respData, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 403 {
                throw GoogleDriveError.missingDriveScope
            }
            guard (200...299).contains(http.statusCode) else {
                throw GoogleDriveError.uploadFailed(String(data: respData, encoding: .utf8) ?? "HTTP \(http.statusCode)")
            }
        }
    }

    // MARK: - Private

    private func createFolder(name: String, parentID: String?, token: String) async throws -> String {
        let url = URL(string: filesURL)!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "name": name,
            "mimeType": "application/vnd.google-apps.folder"
        ]
        if let parentID { body["parents"] = [parentID] }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            if (response as? HTTPURLResponse)?.statusCode == 403 {
                throw GoogleDriveError.missingDriveScope
            }
            throw GoogleDriveError.folderCreationFailed(String(data: data, encoding: .utf8) ?? "")
        }
        return id
    }
}
