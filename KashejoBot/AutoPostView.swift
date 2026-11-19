import SwiftUI
import PhotosUI

struct AutoPostView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var accounts = AccountStore.shared

    @StateObject private var engine = AutoPostEngine()

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var imageData: [Data] = []

    var body: some View {
        NavigationStack {
            Form {
                // 実行状況
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

                // 連投設定
                Section {
                    Stepper("投稿件数: \(settings.burstCount)件", value: $settings.burstCount, in: 1...200)

                    HStack {
                        Text("間隔")
                        TextField("数値", value: $settings.intervalValue, format: .number)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                        Picker("", selection: $settings.intervalUnit) {
                            ForEach(IntervalUnit.allCases) { u in
                                Text(u.label).tag(u)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                    }
                } header: {
                    Text("連投設定")
                } footer: {
                    Text("実質間隔: 約\(Int(max(1, settings.intervalValue) * settings.intervalUnit.factor))秒。秒単位の高頻度連投はサーバーに負荷をかけ、制限(BAN)される恐れがあります。")
                }

                // 内容
                Section {
                    Toggle("画像を添付する", isOn: $settings.attachImages)
                    Picker("選択順", selection: $settings.orderRandom) {
                        Text("順番").tag(false)
                        Text("ランダム").tag(true)
                    }
                    .pickerStyle(.segmented)

                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 10, matching: .images) {
                        Label("画像を選ぶ (\(imageData.count)枚)", systemImage: "photo.on.rectangle")
                    }

                    if !imageData.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(imageData.indices, id: \.self) { i in
                                    if let ui = UIImage(data: imageData[i]) {
                                        Image(uiImage: ui)
                                            .resizable().scaledToFill()
                                            .frame(width: 60, height: 60)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                            .overlay(alignment: .topTrailing) {
                                                Button {
                                                    imageData.remove(at: i)
                                                } label: {
                                                    Image(systemName: "xmark.circle.fill")
                                                        .foregroundStyle(.white, .black.opacity(0.6))
                                                }
                                                .offset(x: 4, y: -4)
                                            }
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("投稿内容")
                } footer: {
                    Text("テンプレート \(settings.templates.count)件から選ばれます。画像OFFならテキストのみ連投します。")
                }

                // エラー耐性
                Section {
                    Stepper("1件あたり試行: \(settings.retryLimit + 1)回", value: $settings.retryLimit, in: 0...5)
                    Stepper("連続失敗しきい値: \(settings.failureThreshold)回", value: $settings.failureThreshold, in: 1...10)
                    Toggle("しきい値到達時: アカウント自動再作成", isOn: $settings.autoRecreate)
                } header: {
                    Text("エラー時の動作")
                } footer: {
                    Text("失敗がしきい値に達すると、まず登録済みの別アカウントへ自動切替します。自動再作成がONの場合、サインアップAPIで新規アカウントを作って切り替えます(サイトがAPI作成に対応している必要あり。規約で禁止なら必ずOFF)。")
                }

                Section {
                    NavigationLink("テンプレートを編集 (\(settings.templates.count)件)") {
                        TemplatesEditor()
                    }
                    NavigationLink("アカウント管理") {
                        AccountsView()
                    }
                }
            }
            .navigationTitle("自動連投")
            .onChange(of: pickerItems) { items in
                Task {
                    var loaded: [Data] = []
                    for item in items {
                        if let d = try? await item.loadTransferable(type: Data.self) {
                            loaded.append(ImageUtil.jpegData(from: d))
                        }
                    }
                    imageData = loaded
                }
            }
        }
    }

    private func startBurst() {
        guard accounts.active != nil else { return }
        let hasContent = !settings.templates.isEmpty || (settings.attachImages && !imageData.isEmpty)
        guard hasContent else { return }
        engine.setImages(imageData)
        engine.start(settings: settings, accounts: accounts)
    }
}

struct TemplatesEditor: View {
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var items: [Item] = []

    struct Item: Identifiable {
        let id = UUID()
        var text: String
    }

    var body: some View {
        Form {
            ForEach($items) { $item in
                TextField("テンプレート", text: $item.text, axis: .vertical)
            }
            .onDelete { items.remove(atOffsets: $0) }
        }
        .navigationTitle("テンプレート")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { items.append(Item(text: "")) } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("保存") {
                    settings.templates = items.map(\.text)
                        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    dismiss()
                }
            }
        }
        .onAppear { items = settings.templates.map { Item(text: $0) } }
    }
}
