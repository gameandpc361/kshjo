import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

struct AutoPostView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var accounts = AccountStore.shared

    @StateObject private var engine = AutoPostEngine()

    var body: some View {
        NavigationStack {
            Form {
                Section("実行状況") {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Circle()
                                    .fill(engine.isRunning ? Color.green : Color.gray)
                                    .frame(width: 10, height: 10)
                                Text(engine.isRunning ? "稼働中" : "停止中")
                                    .font(.subheadline)
                                Spacer()
                                Text("\(engine.currentIndex) / \(engine.totalCount)")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            if engine.isRunning {
                                if let next = engine.nextPostAt {
                                    let remain = max(0, Int(next.timeIntervalSince(context.date)))
                                    Text("次の投稿まで 残り \(remain) 秒")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text("処理中…").font(.caption).foregroundStyle(.secondary)
                                }
                                if engine.failureStreak > 0 {
                                    Text("連続失敗: \(engine.failureStreak) / しきい値 \(settings.failureThreshold)")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Text(engine.lastMessage)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Button {
                            if engine.isRunning {
                                engine.stop()
                            } else {
                                startBurst()
                            }
                        } label: {
                            Label(engine.isRunning ? "停止" : "連投開始",
                                  systemImage: engine.isRunning ? "stop.fill" : "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            engine.postOneNow(settings: settings, accounts: accounts)
                        } label: {
                            Label("1件テスト", systemImage: "paperplane")
                        }
                        .buttonStyle(.bordered)
                        .disabled(engine.isRunning || accounts.active == nil)
                    }
                    .listRowInsets(EdgeInsets())
                    .padding()
                }

                Section {
                    Stepper("投稿件数: \(settings.burstCount)件", value: $settings.burstCount, in: 1...200)
                    HStack {
                        Text("間隔")
                        TextField("数値", value: $settings.intervalValue, format: .number)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                        Picker("", selection: $settings.intervalUnit) {
                            ForEach(IntervalUnit.allCases) { u in Text(u.label).tag(u) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                    }
                } header: {
                    Text("連投設定")
                } footer: {
                    Text("実質間隔: 約\(Int(max(1, settings.intervalValue) * settings.intervalUnit.factor))秒")
                }

                Section {
                    Picker("選択順", selection: $settings.orderRandom) {
                        Text("順番").tag(false)
                        Text("ランダム").tag(true)
                    }
                    .pickerStyle(.segmented)

                    NavigationLink("テンプレート編集(\(settings.postTemplates.count)件)") {
                        TemplatesEditor()
                    }
                } header: {
                    Text("投稿内容")
                } footer: {
                    Text("本文の {rand} はランダム英数字に置換され、テンプレートの固定画像が添付されます。テンプレートを順番/ランダムに選んで連投します。")
                }

                Section {
                    Stepper("1件あたり試行: \(settings.retryLimit + 1)回", value: $settings.retryLimit, in: 0...5)
                    Stepper("連続失敗しきい値: \(settings.failureThreshold)回", value: $settings.failureThreshold, in: 1...10)
                    Toggle("しきい値到達時: アカウント自動再作成", isOn: $settings.autoRecreate)
                } header: {
                    Text("エラー時の動作")
                } footer: {
                    Text("しきい値到達で別アカウントへ自動切替。自動再作成はサイトがサインアップAPIに対応している場合のみ動作します(規約で禁止なら必ずOFF)。")
                }

                Section {
                    NavigationLink("アカウント管理") { AccountsView() }
                }
            }
            .dismissibleKeyboard()
            .navigationTitle("自動連投")
        }
    }

    private func startBurst() {
        guard accounts.active != nil else { return }
        guard !settings.postTemplates.isEmpty else { return }
        engine.start(settings: settings, accounts: accounts)
    }
}

// MARK: - テンプレート編集

struct TemplatesEditor: View {
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.dismiss) private var dismiss

    struct Item: Identifiable {
        let id: UUID
        var text: String
        var images: [String]
    }

    @State private var items: [Item] = []
    @State private var photoTarget: UUID?
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var fileTarget: UUID?
    @State private var showFileImporter = false
    @State private var alert: AlertItem?

    var body: some View {
        Form {
            Section {
                ForEach($items) { $item in
                    templateRow($item)
                }
                .onDelete { offsets in
                    for i in offsets {
                        items[i].images.forEach { TemplateImageStore.shared.delete($0) }
                    }
                    items.remove(atOffsets: offsets)
                }
            } header: {
                Text("テンプレート一覧")
            } footer: {
                Text("本文の {rand} はランダム英数字10文字({rand:20}なら20文字)に置換されます。テンプレートごとに固定画像を最大\(ImageUtil.maxCount)枚・各10MiBまで添付できます(PNG/JPEG/GIF/WebP/AVIF)。")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("テンプレート編集")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button { UIApplication.hideKeyboard() } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                }
            }
            ToolbarItem(placement: .navigationBarLeading) {
                Button { items.append(Item(id: UUID(), text: "", images: [])) } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("保存") {
                    settings.postTemplates = items.map { PostTemplate(id: $0.id, text: $0.text, images: $0.images) }
                    TemplateImageStore.shared.deleteAllExcept(items.flatMap(\.images))
                    dismiss()
                }
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickedPhoto, matching: .images)
        .onChange(of: pickedPhoto) { item in
            guard let row = photoTarget, let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    addImage(to: row, data: data)
                }
                pickedPhoto = nil
            }
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.image],
                      allowsMultipleSelection: true) { result in
            let row = fileTarget
            fileTarget = nil
            guard let row else { return }
            switch result {
            case .success(let urls):
                for url in urls {
                    let secured = url.startAccessingSecurityScopedResource()
                    defer { if secured { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url) {
                        addImage(to: row, data: data)
                    }
                }
            case .failure(let error):
                LogStore.shared.log(.warning, "template", "ファイル選択エラー: \(error.localizedDescription)")
            }
        }
        .alert(item: $alert) { item in
            Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("OK")))
        }
        .onAppear {
            items = settings.postTemplates.map { Item(id: $0.id, text: $0.text, images: $0.images) }
        }
    }

    @ViewBuilder
    private func templateRow(_ item: Binding<Item>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("本文({rand} / {rand:N} を使用可)", text: item.text, axis: .vertical)
                .frame(minHeight: 40)

            if !item.wrappedValue.images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(item.wrappedValue.images, id: \.self) { name in
                            imageThumb(item, name)
                        }
                    }
                }
            }

            HStack {
                Button {
                    photoTarget = item.wrappedValue.id
                    showPhotoPicker = true
                } label: { Label("写真", systemImage: "photo") }
                .disabled(item.wrappedValue.images.count >= ImageUtil.maxCount)

                Button {
                    fileTarget = item.wrappedValue.id
                    showFileImporter = true
                } label: { Label("ファイル", systemImage: "folder") }
                .disabled(item.wrappedValue.images.count >= ImageUtil.maxCount)

                Spacer()
                Text("{rand} = ランダム文字列")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private func imageThumb(_ item: Binding<Item>, _ name: String) -> some View {
        Group {
            if let data = TemplateImageStore.shared.load(name), let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable().scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 56, height: 56)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                item.wrappedValue.images.removeAll { $0 == name }
                TemplateImageStore.shared.delete(name)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .offset(x: 5, y: -5)
        }
    }

    private func addImage(to rowID: UUID, data: Data) {
        guard let idx = items.firstIndex(where: { $0.id == rowID }) else { return }
        guard items[idx].images.count < ImageUtil.maxCount else {
            alert = AlertItem(title: "追加できません", message: "画像はテンプレートごとに最大\(ImageUtil.maxCount)枚です")
            return
        }
        switch ImageUtil.process(data, suggestedName: nil) {
        case .success(let m):
            let ext = (m.filename as NSString).pathExtension
            if let name = TemplateImageStore.shared.save(m.data, ext: ext) {
                items[idx].images.append(name)
                LogStore.shared.log(.debug, "template", "テンプレ画像追加: \(name) (\(m.mimeType))")
            } else {
                alert = AlertItem(title: "保存失敗", message: "画像を保存できませんでした")
            }
        case .failure(let message):
            alert = AlertItem(title: "画像を追加できません", message: message)
        }
    }
}
