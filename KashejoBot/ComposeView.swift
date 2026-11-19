import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

struct ComposeView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var history = HistoryStore.shared

    @State private var text = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var imageData: Data?
    @State private var sending = false
    @State private var statusText = ""
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
                        HStack {
                            PhotosPicker(selection: $pickerItem, matching: .images) {
                                Label("写真", systemImage: "photo.on.rectangle")
                            }
                            Spacer()
                            Button {
                                showFileImporter = true
                            } label: {
                                Label("ファイル", systemImage: "folder")
                            }
                        }
                    }
                }

                Section("アカウント") {
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
                            Text(sending ? (statusText.isEmpty ? "送信中…" : statusText) : "投稿する").bold()
                            Spacer()
                        }
                    }
                    .disabled(sending || (trimmed.isEmpty && imageData == nil) || overLimit || accounts.active == nil)
                } footer: {
                    if overLimit { Text("文字数が上限を超えています").foregroundStyle(.red) }
                }
            }
            .dismissibleKeyboard()
            .navigationTitle("bot投稿")
            .onChange(of: pickerItem) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        applyImage(data)
                    }
                    pickerItem = nil
                }
            }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.image],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        let secured = url.startAccessingSecurityScopedResource()
                        defer { if secured { url.stopAccessingSecurityScopedResource() } }
                        if let data = try? Data(contentsOf: url) {
                            applyImage(data)
                        }
                    }
                case .failure(let error):
                    LogStore.shared.log(.warning, "api", "ファイル選択エラー: \(error.localizedDescription)")
                }
            }
            .alert(item: $alert) { item in
                Alert(title: Text(item.title), message: Text(item.message),
                      dismissButton: .default(Text("OK")))
            }
        }
    }

    private func applyImage(_ data: Data) {
        switch ImageUtil.process(data, suggestedName: nil) {
        case .success(let m):
            imageData = m.data
            LogStore.shared.log(.debug, "api", "画像設定: \(m.mimeType) \(m.data.count) bytes")
        case .failure(let message):
            alert = AlertItem(title: "この画像は使えません", message: message)
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
                statusText = "画像アップロード中"
                let mime = ImageUtil.detectFormat(data)?.mimeType ?? "image/jpeg"
                let name = "post_\(Int(Date().timeIntervalSince1970)).jpg"
                let id = try await client.uploadFile(MediaItem(data: data, filename: name, mimeType: mime))
                fileIds.append(id)
                LogStore.shared.log(.debug, "api", "アップロード完了: \(id)")
            }
            statusText = "投稿中…"
            let content = text
            let response = try await client.createPost(text: content.isEmpty ? nil : content,
                                                       fileIds: fileIds)
            history.add(HistoryEntry(id: UUID(), date: Date(), account: account.label,
                                     kind: fileIds.isEmpty ? "text" : "image",
                                     text: content, hasImage: !fileIds.isEmpty,
                                     success: true,
                                     message: String(response.prefix(150))))
            LogStore.shared.log(.info, "api", "手動投稿成功: \(String(response.prefix(300)))")
            text = ""
            imageData = nil
            pickerItem = nil
            statusText = ""
        } catch {
            statusText = ""
            history.add(HistoryEntry(id: UUID(), date: Date(), account: account.label,
                                     kind: imageData == nil ? "text" : "image",
                                     text: text, hasImage: imageData != nil,
                                     success: false, message: error.localizedDescription))
            LogStore.shared.log(.error, "api", "手動投稿失敗: \(error.localizedDescription)")
            alert = AlertItem(title: "投稿失敗", message: error.localizedDescription)
        }
    }
}
