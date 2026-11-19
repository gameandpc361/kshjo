import Foundation

// ====================================================================
//  ★READMEの「API」の節と照合し、違っていたらここだけ編集★
// ====================================================================
enum KashejoAPI {
    static let mePath       = "api/v1/me"       // 自分の情報取得(GET) ※確認済み
    static let postsPath    = "api/v1/posts"    // 投稿作成(POST)
    static let filesPath    = "api/v1/files"    // 画像アップロード(POST / multipart)
    static let textField    = "text"            // 投稿本文のJSONフィールド名
    static let fileIdsField = "fileIds"         // 添付画像ID配列のJSONフィールド名
    static let uploadField  = "file"            // アップロードmultipartのファイルフィールド名
    static let signupPath   = "api/v1/accounts" // アカウント自動作成(POST) ※README要確認
}
// ====================================================================

final class APIClient {
    private let baseURL: URL
    private let token: String

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    private func makeRequest(path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        return request
    }

    private func check(_ http: HTTPURLResponse, data: Data) throws {
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw APIError(message: "HTTP \(http.statusCode) \(detail.prefix(300))")
        }
    }

    // MARK: 自分の情報(接続テスト用)

    func fetchMe() async throws -> String {
        let request = makeRequest(path: KashejoAPI.mePath)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(message: "無効なレスポンスです")
        }
        try check(http, data: data)
        return String(data: data, encoding: .utf8) ?? "(空のレスポンス)"
    }

    // MARK: 画像アップロード(multipart) → 画像IDを返す

    func uploadFile(_ media: MediaItem) async throws -> String {
        let boundary = "KashejoBot-\(UUID().uuidString)"
        var request = makeRequest(path: KashejoAPI.filesPath, method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")

        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(KashejoAPI.uploadField)\"; filename=\"\(media.filename)\"\r\n")
        append("Content-Type: \(media.mimeType)\r\n\r\n")
        body.append(media.data)
        append("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(message: "無効なレスポンスです")
        }
        try check(http, data: data)

        if let id = Self.extractId(from: data) {
            return id
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        throw APIError(message: "アップロード成功ですがIDを解析できませんでした。応答: \(raw.prefix(200))")
    }

    // MARK: 投稿作成

    func createPost(text: String?, fileIds: [String]) async throws -> String {
        var request = makeRequest(path: KashejoAPI.postsPath, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [KashejoAPI.textField: text ?? ""]
        if !fileIds.isEmpty {
            body[KashejoAPI.fileIdsField] = fileIds
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(message: "無効なレスポンスです")
        }
        try check(http, data: data)
        return String(data: data, encoding: .utf8) ?? "(空のレスポンス)"
    }

    // MARK: アカウント自動作成(自動再作成機能用)

    func createAccount(username: String, password: String) async throws -> String? {
        var request = makeRequest(path: KashejoAPI.signupPath, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "username": username, "password": password
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(message: "無効なレスポンスです")
        }
        try check(http, data: data)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for key in ["token", "apiKey", "api_key", "key"] {
            if let t = obj[key] as? String { return t }
        }
        if let sub = obj["data"] as? [String: Any] {
            for key in ["token", "apiKey", "api_key", "key"] {
                if let t = sub[key] as? String { return t }
            }
        }
        return nil
    }

    // MARK: 任意リクエスト(API探索ツール用) — エラーでもステータスと生レスポンスを返す

    func rawRequest(method: String, path: String, jsonBody: String) async throws -> (Int, String) {
        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let url = trimmedPath.isEmpty ? baseURL : baseURL.appendingPathComponent(trimmedPath)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

        let body = jsonBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if method != "GET" && !body.isEmpty {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body.data(using: .utf8)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let raw = String(data: data, encoding: .utf8) ?? "(バイナリ \(data.count) bytes)"
        return (status, raw)
    }

    // MARK: 応答JSONからIDらしき文字列を探す

    private static func extractId(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let keys = ["id", "fileId", "file_id", "mediaId", "media_id", "imageId", "image_id"]
        for key in keys {
            if let s = obj[key] as? String { return s }
        }
        for container in ["data", "media", "file", "image"] {
            if let sub = obj[container] as? [String: Any] {
                for key in keys {
                    if let s = sub[key] as? String { return s }
                }
            }
        }
        return nil
    }
}
