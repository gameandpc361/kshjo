import Foundation

final class APIClient {
    private let baseURL: URL
    private let token: String
    private let notesPath: String
    private let filesPath: String
    private let signupPath: String

    init(baseURL: URL, token: String,
         notesPath: String, filesPath: String, signupPath: String) {
        self.baseURL = baseURL
        self.token = token
        self.notesPath = notesPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.filesPath = filesPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.signupPath = signupPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: 共通POST(JSON)

    private func post(json: [String: Any], to path: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(message: "無効なレスポンスです")
        }
        return (data, http)
    }

    private func check(_ http: HTTPURLResponse, data: Data) throws {
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw APIError(message: "HTTP \(http.statusCode) \(detail.prefix(200))")
        }
    }

    // MARK: ノート投稿

    func createNote(text: String?, fileIds: [String] = [], visibility: String) async throws -> Note? {
        var body: [String: Any] = ["i": token, "visibility": visibility]
        if let text, !text.isEmpty { body["text"] = text }
        if !fileIds.isEmpty {
            body["fileIds"] = fileIds     // Misskey v13以降
            body["mediaIds"] = fileIds    // v12互換
        }
        let (data, http) = try await post(json: body, to: notesPath)
        try check(http, data: data)
        return try? JSONDecoder().decode(Note.self, from: data)
    }

    // MARK: 画像アップロード(multipart)

    func uploadFile(_ data: Data, filename: String, mimeType: String) async throws -> DriveFile? {
        let boundary = "KashejoBot-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appendingPathComponent(filesPath))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"i\"\r\n\r\n")
        append("\(token)\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        let (respData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(message: "無効なレスポンスです")
        }
        try check(http, data: respData)
        return try? JSONDecoder().decode(DriveFile.self, from: respData)
    }

    // MARK: トークン確認

    func fetchAccount() async throws -> AccountInfo? {
        let (data, http) = try await post(json: ["i": token], to: "api/i")
        try check(http, data: data)
        return try? JSONDecoder().decode(AccountInfo.self, from: data)
    }

    // MARK: アカウント自動作成(Misskey互換サインアップ)

    func createAccount(username: String, password: String) async throws -> String? {
        let (data, http) = try await post(json: ["username": username, "password": password], to: signupPath)
        try check(http, data: data)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let t = obj["token"] as? String { return t }
        if let acc = obj["account"] as? [String: Any], let t = acc["token"] as? String { return t }
        return nil
    }
}
