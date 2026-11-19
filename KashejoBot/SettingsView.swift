import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var accounts = AccountStore.shared

    @State private var testing = false
    @State private var testResult: String?
    @State private var alert: AlertItem?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        AccountsView()
                    } label: {
                        HStack {
                            Label("アカウント管理", systemImage: "person.crop.circle")
                            Spacer()
                            Text(accounts.active?.label ?? "未設定")
                                .foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink {
                        LogsView()
                    } label: {
                        Label("ログ閲覧・書き出し", systemImage: "doc.text.magnifyingglass")
                    }
                    NavigationLink {
                        APIExplorerView()
                    } label: {
                        Label("API探索ツール", systemImage: "terminal")
                    }
                }

                Section {
                    TextField("https://kashejo.f5.si", text: $settings.baseURLString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("接続先URL")
                } footer: {
                    Text("認証: Authorization: Bearer / 現在のエンドポイント: me=\(KashejoAPI.mePath), posts=\(KashejoAPI.postsPath), files=\(KashejoAPI.filesPath)。READMEの「API」の節と異なる場合はAPIClient.swift冒頭のenum KashejoAPIを編集してください。")
                }

                Section {
                    Button(testing ? "確認中…" : "接続テスト(アクティブアカウント)") {
                        Task { await testConnection() }
                    }
                    .disabled(testing || accounts.active == nil)
                    if let testResult {
                        Text(testResult).font(.footnote).textSelection(.enabled)
                    }
                }

                Section("投稿設定") {
                    Stepper("文字数上限: \(settings.maxChars)",
                            value: $settings.maxChars, in: 100...5000, step: 100)
                    NavigationLink("テンプレート編集") { TemplatesEditor() }
                }
            }
            .dismissibleKeyboard()
            .navigationTitle("設定")
            .alert(item: $alert) { item in
                Alert(title: Text(item.title), message: Text(item.message),
                      dismissButton: .default(Text("OK")))
            }
        }
    }

    @MainActor
    private func testConnection() async {
        guard let acc = accounts.active else { return }
        testing = true
        defer { testing = false }
        testResult = nil
        do {
            let client = try settings.makeClient(token: acc.token)
            let raw = try await client.fetchMe()
            testResult = "接続OK: \(String(raw.prefix(300)))"
            LogStore.shared.log(.info, "api", "接続テスト成功: \(String(raw.prefix(300)))")
        } catch {
            alert = AlertItem(title: "接続テスト失敗", message: error.localizedDescription)
            LogStore.shared.log(.error, "api", "接続テスト失敗: \(error.localizedDescription)")
        }
    }
}

// MARK: - API探索ツール

struct APIExplorerView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var accounts = AccountStore.shared

    @State private var method = "GET"
    @State private var path = "api/v1/me"
    @State private var bodyText = ""
    @State private var result = ""
    @State private var running = false

    private let methods = ["GET", "POST", "PUT", "PATCH", "DELETE"]

    var body: some View {
        Form {
            Section {
                Picker("メソッド", selection: $method) {
                    ForEach(methods, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)

                TextField("api/v1/me", text: $path)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))

                if method != "GET" {
                    TextField("{\"text\": \"hello\"}", text: $bodyText, axis: .vertical)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Button {
                    Task { await run() }
                } label: {
                    HStack {
                        Spacer()
                        if running { ProgressView().padding(.trailing, 8) }
                        Text(running ? "実行中…" : "送信")
                        Spacer()
                    }
                }
                .disabled(running || accounts.active == nil)
            } header: {
                Text("リクエスト")
            } footer: {
                Text("アクティブアカウントのキーで Authorization: Bearer を自動付与します。任意のパス・JSONボディを試してAPI仕様を確認してください。")
            }

            Section("レスポンス") {
                if result.isEmpty {
                    Text("(まだ実行していません)").foregroundStyle(.secondary)
                } else {
                    Text(result)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .dismissibleKeyboard()
        .navigationTitle("API探索")
    }

    @MainActor
    private func run() async {
        guard let acc = accounts.active else { return }
        running = true
        defer { running = false }
        do {
            let client = try settings.makeClient(token: acc.token)
            let (status, raw) = try await client.rawRequest(method: method, path: path, jsonBody: bodyText)
            result = "HTTP \(status)\n\n\(String(raw.prefix(2000)))"
            LogStore.shared.log(.info, "api", "探索 \(method) /\(path) → HTTP \(status)")
        } catch {
            result = "ERROR: \(error.localizedDescription)"
            LogStore.shared.log(.error, "api", "探索失敗: \(error.localizedDescription)")
        }
    }
}
