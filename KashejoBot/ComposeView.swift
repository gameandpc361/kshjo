import SwiftUI
import PhotosUI

struct ComposeView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var history = HistoryStore.shared

    @State private var text = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var sending = false
    @State private var alert: AlertItem?

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var overLimit: Bool { text.count > settings.maxChars }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 140)
                } header: {
                    Text("本文")
                } footer: {
                    Text("\(text.count) / \(settings.maxChars) 文字")
                        .foregroundStyle(overLimit ? Color.red : Color.secondary)
                }

                Section("画像(任意・1枚)") {
                    if let data = imageData, let ui = UIImage(data: data) {
                        HStack(alignment: .top) {
                            Image(uiImage: ui)
                                .resizable().scaledToFit()
                                .frame(maxHeight: 150)
                                .cornerRadius(8)
                            Spacer()
                            Button("取り消す", role: .destructive) {
                                imageData = nil
                                pickerItem = nil
                            }
                        }
                    } else {
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Label("画像を選ぶ", systemImage: "photo.on.rectangle")
                        }
                    }
                }

                Section("公開範囲 / アカウント") {
                    Picker("公開範囲", selection: $settings.visibility) {
                        ForEach(Visibility.allCases) { v in Text(v.label).tag(v) }
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Text("送信元")
                        Spacer()
                        Text(accounts.active.map { "\($0.label)" } ?? "未設定")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        Task { await send() }
                    } label: {
                        HStack {
                            Spacer()
                            if sending { ProgressView().padding(.trailing, 8) }
                            Text(sending ? "送信中…" : "投稿する").bold()
                            Spacer()
                        }
                    }
                    .disabled(sending || (trimmed.isEmpty && imageData == nil) || overLimit || accounts.active == nil)
                } footer: {
                    if overLimit { Text("文字数が上限を超えています").foregroundStyle(.red) }
                }
            }
            .navigationTitle("bot投稿")
            .onChange(of: pickerItem) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        imageData = ImageUtil.jpegData(from: data)
                    }
                }
            }
            .alert(item: $alert) { item in
                Alert(title: Text(item.title), message: Text(item.message),
                      dismissButton: .default(Text("OK")))
            }
        }
    }

    @MainActor
    private func send() async {
        guard !sending, let account = accounts.active else { return }
        sending = true
        defer { sending = false }
        LogStore.shared.log(.info, "api", "手動投稿開始 @\(account.username)")

        do {
            let client = try settings.makeClient(token: account.token)
            var fileIds: [String] = []
            if let data = imageData {
                LogStore.shared.log(.debug, "api", "画像アップロード (\(data.count) bytes)")
                if let file = try await client.uploadFile(data, filename: "post_\(Int(Date().timeIntervalSince1970)).jpg",
                                                          mimeType: "image/jpeg") {
                    fileIds = [file.id]
                } else {
                    LogStore.shared.log(.warning, "api", "アップロード応答を解析できずテキストのみ投稿")
                }
            }
            let note = try await client.createNote(text: text, fileIds: fileIds,
                                                   visibility: settings.visibility.rawValue)
            history.add(HistoryEntry(id: UUID(), date: Date(), account: account.label,
                                     kind: fileIds.isEmpty ? "text" : "image",
                                     text: trimmed, hasImage: !fileIds.isEmpty,
                                     success: true,
                                     message: note.map { "ID: \($0.id)" } ?? "投稿しました"))
            LogStore.shared.log(.info, "api", "手動投稿成功 \(note?.id ?? "")")
            text = ""
            imageData = nil
            pickerItem = nil
        } catch {
            history.add(HistoryEntry(id: UUID(), date: Date(), account: account.label,
                                     kind: imageData == nil ? "text" : "image",
                                     text: trimmed, hasImage: imageData != nil,
                                     success: false, message: error.localizedDescription))
            LogStore.shared.log(.error, "api", "手動投稿失敗: \(error.localizedDescription)")
            alert = AlertItem(title: "投稿失敗", message: error.localizedDescription)
        }
    }
}
