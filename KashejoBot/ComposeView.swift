import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

struct ComposeView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var history = HistoryStore.shared

    @State private var text = ""
    @State private var media: [MediaItem] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false
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

                Section("画像(最大\(ImageUtil.maxCount)枚・各10MiB)") {
                    if !media.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(media) { item in
                                    thumbnail(item)
                                }
                            }
                        }
                    }
                    HStack {
                        PhotosPicker(selection: $pickerItems,
                                     maxSelectionCount: max(1, ImageUtil.maxCount - media.count),
                                     matching: .images) {
                            Label("写真から", systemImage: "photo.on.rectangle")
                        }
                        .disabled(media.count >= ImageUtil.maxCount)

                        Button {
                            showFileImporter = true
                        } label: {
                            Label("ファイルから", systemImage: "folder")
                        }
                        .disabled(media.count >= ImageUtil.maxCount)
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
                    .disabled(sending || (trimmed.isEmpty && media.isEmpty) || overLimit || accounts.active == nil)
                } footer: {
                    if overLimit { Text("文字数が上限を超えています").foregroundStyle(.red) }
                }
            }
            .dismissibleKeyboard()
            .navigationTitle("bot投稿")
            .onChange(of: pickerItems) { items in
                guard !items.isEmpty else { return }
                Task {
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            addData(data, suggestedName: nil)
                        }
                    }
                    pickerItems = []
                }
            }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.image],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    for url in urls {
                        let secured = url.startAccessingSecurityScopedResource()
                        defer { if secured { url.stopAccessingSecurityScopedResource() } }
                        if let data = try? Data(contentsOf: url) {
                            addData(data, suggestedName: url.lastPathComponent)
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

    private func thumbnail(_ item: MediaItem) -> some View {
        Group {
            if let ui = UIImage(data: item.data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 70, height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 70, height: 70)
                    .overlay {
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                media.removeAll { $0.id == item.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .offset(x: 6, y: -6)
        }
    }

    private func addData(_ data: Data, suggestedName: String?) {
        guard media.count < ImageUtil.maxCount else {
            alert = AlertItem(title: "追加できません", message: "画像は最大\(ImageUtil.maxCount)枚までです")
            return
        }
        switch ImageUtil.process(data, suggestedName: suggestedName) {
        case .success(let item):
            media.append(item)
            LogStore.shared.log(.debug, "api", "画像追加: \(item.filename) \(item.data.count) bytes \(item.mimeType)")
        case .failure(let message):
            alert = AlertItem(title: "画像を追加できません", message: message)
        }
    }

    @MainActor
    private func send() async {
        guard !sending, let account = accounts.active else { return }
        sending = true
        defer { sending = false }
        let content = text
        LogStore.shared.log(.info, "api", "手動投稿開始 @\(account.username) 画像\(media.count)枚")

        do {
            let client = try settings.makeClient(token: account.token)
            var fileIds: [String] = []
            for (index, item) in media.enumerated() {
                statusText = "画像アップロード中 (\(index + 1)/\(media.count))"
                let id = try await client.uploadFile(item)
                fileIds.append(id)
                LogStore.shared.log(.debug, "api", "アップロード完了: \(id)")
            }
            statusText = "投稿中…"
            let response = try await client.createPost(text: content.isEmpty ? nil : content,
                                                       fileIds: fileIds)
            history.add(HistoryEntry(id: UUID(), date: Date(), account: account.label,
                                     kind: fileIds.isEmpty ? "text" : "image",
                                     text: content, hasImage: !fileIds.isEmpty,
                                     success: true,
                                     message: String(response.prefix(150))))
            LogStore.shared.log(.info, "api", "投稿成功: \(String(response.prefix(300)))")
            text = ""
            media = []
            pickerItems = []
            statusText = ""
        } catch {
            statusText = ""
            history.add(HistoryEntry(id: UUID(), date: Date(), account: account.label,
                                     kind: media.isEmpty ? "text" : "image",
                                     text: content, hasImage: !media.isEmpty,
                                     success: false, message: error.localizedDescription))
            LogStore.shared.log(.error, "api", "手動投稿失敗: \(error.localizedDescription)")
            alert = AlertItem(title: "投稿失敗", message: error.localizedDescription)
        }
    }
}
