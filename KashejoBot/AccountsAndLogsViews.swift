import SwiftUI

// MARK: - アカウント管理

struct AccountsView: View {
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var settings = SettingsStore.shared

    @State private var showAdd = false
    @State private var alert: AlertItem?

    var body: some View {
        List {
            if accounts.accounts.isEmpty {
                Text("アカウントがありません。「+」からbotトークンを登録してください")
                    .foregroundStyle(.secondary)
            }
            ForEach(accounts.accounts) { acc in
                Button {
                    accounts.setActive(acc.id)
                } label: {
                    HStack {
                        Image(systemName: acc.id == accounts.active?.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(acc.id == accounts.active?.id ? Color.pink : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(acc.label)
                            Text("@\(acc.username)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if acc.isAutoCreated {
                            Text("自動")
                                .font(.caption2).bold()
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Color.orange.opacity(0.2))
                                .clipShape(Capsule())
                        }
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        accounts.remove(acc.id)
                    } label: { Label("削除", systemImage: "trash") }

                    Button {
                        test(acc)
                    } label: { Label("テスト", systemImage: "network") }
                    .tint(.blue)
                }
            }
        }
        .navigationTitle("アカウント管理")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showAdd) {
            AddAccountSheet()
        }
        .alert(item: $alert) { item in
            Alert(title: Text(item.title), message: Text(item.message),
                  dismissButton: .default(Text("OK")))
        }
    }

    private func test(_ acc: AccountProfile) {
        Task {
            do {
                let client = try settings.makeClient(token: acc.token)
                let info = try await client.fetchAccount()
                if let info {
                    alert = AlertItem(title: "接続OK",
                                      message: "@\(info.username)" + (info.name.map { " (\($0))" } ?? ""))
                } else {
                    alert = AlertItem(title: "接続OK", message: "サーバーに応答がありました(形式は未確認)")
                }
            } catch {
                alert = AlertItem(title: "接続失敗", message: error.localizedDescription)
            }
        }
    }
}

struct AddAccountSheet: View {
    @ObservedObject private var accounts = AccountStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var username = ""
    @State private var token = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("ラベル(任意)") {
                    TextField("例: メインbot", text: $label)
                }
                Section {
                    TextField("ユーザー名(@なし)", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("ユーザー名")
                }
                Section {
                    SecureField("サイトで発行したAPIトークン", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("APIトークン")
                } footer: {
                    Text("トークンはキーチェーンに暗号化して保存されます。")
                }
            }
            .navigationTitle("アカウント追加")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("追加") {
                        accounts.addManual(label: label,
                                           username: username.isEmpty ? "unknown" : username,
                                           token: token.trimmingCharacters(in: .whitespaces))
                        dismiss()
                    }
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - ログ閲覧

struct LogsView: View {
    @ObservedObject private var logs = LogStore.shared

    @State private var filter: LogLevel?
    @State private var showShare = false
    @State private var exportURL: URL?
    @State private var confirmClear = false

    private var filtered: [LogEntry] {
        let base = filter == nil ? logs.entries : logs.entries.filter { $0.level == filter }
        return base.reversed() // 新しい順
    }

    var body: some View {
        List {
            Section {
                Picker("フィルタ", selection: $filter) {
                    Text("すべて").tag(LogLevel?.none)
                    ForEach(LogLevel.allCases) { lv in
                        Text(lv.label).tag(LogLevel?.some(lv))
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Button {
                        if let url = logs.exportFile() {
                            exportURL = url
                            showShare = true
                        }
                    } label: {
                        Label("書き出し", systemImage: "square.and.arrow.up")
                    }
                    Spacer()
                    Button("全消去", role: .destructive) { confirmClear = true }
                }
            }

            if filtered.isEmpty {
                Text("ログはまだありません").foregroundStyle(.secondary)
            }
            ForEach(filtered) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: icon(for: entry.level))
                            .foregroundStyle(color(for: entry.level))
                            .font(.caption)
                        Text(entry.level.label)
                            .font(.caption2).bold()
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(color(for: entry.level).opacity(0.15))
                            .clipShape(Capsule())
                        Text("[\(entry.category)]")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text(entry.date, format: .dateTime.month().day().hour().minute().second())
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(entry.message)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("ログ")
        .sheet(isPresented: $showShare) {
            if let url = exportURL {
                ActivityView(url: url)
            }
        }
        .confirmationDialog("ログを全消去しますか?(ファイルも削除)",
                            isPresented: $confirmClear, titleVisibility: .visible) {
            Button("全消去", role: .destructive) { logs.clear() }
            Button("キャンセル", role: .cancel) {}
        }
    }

    private func icon(for level: LogLevel) -> String {
        switch level {
        case .debug:   return "ant.circle"
        case .info:    return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error:   return "xmark.octagon"
        }
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug:   return .gray
        case .info:    return .blue
        case .warning: return .orange
        case .error:   return .red
        }
    }
}

// 共有シート(iOS 16対応のためUIKitラッパ)
import UIKit

struct ActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
