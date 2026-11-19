import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var accounts = AccountStore.shared

    @State private var testing = false
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
                }

                Section {
                    TextField("https://kashejo.f5.si", text: $settings.baseURLString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("接続先URL")
                }

                Section {
                    TextField("api/notes/create", text: $settings.notesPath)
                    TextField("api/drive/files/create", text: $settings.filesPath)
                    TextField("api/accounts/create", text: $settings.signupPath)
                } header: {
                    Text("APIパス(上級者向け)")
                } footer: {
                    Text("サイトのAPIドキュメントの仕様に合わせて変更できます。通常は変更不要。")
                }

                Section {
                    Button(testing ? "確認中…" : "接続テスト(アクティブアカウント)") {
                        Task { await testConnection() }
                    }
                    .disabled(testing || accounts.active == nil)
                }

                Section("投稿設定") {
                    Picker("公開範囲", selection: $settings.visibility) {
                        ForEach(Visibility.allCases) { v in Text(v.label).tag(v) }
                    }
                    Stepper("文字数上限: \(settings.maxChars)",
                            value: $settings.maxChars, in: 100...5000, step: 100)
                    NavigationLink("テンプレートを編集") { TemplatesEditor() }
                }
            }
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
        do {
            let client = try settings.makeClient(token: acc.token)
            if let info = try await client.fetchAccount() {
                alert = AlertItem(title: "接続OK",
                                  message: "@\(info.username)" + (info.name.map { " (\($0))" } ?? ""))
            } else {
                alert = AlertItem(title: "接続OK", message: "サーバーに応答がありました(形式は未確認)")
            }
        } catch {
            alert = AlertItem(title: "接続テスト失敗", message: error.localizedDescription)
        }
    }
}
