import SwiftUI
import PhotosUI
import WebKit

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showLogin = false
    @State private var bodyText = ""
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var imageData: [Data] = []
    @State private var scheduleEnabled = false
    @State private var scheduleDate = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
    @State private var notice: String?
    @FocusState private var composeFocused: Bool

    var body: some View {
        TabView {
            composeView.tabItem { Label("投稿", systemImage: "square.and.pencil") }
            draftsView.tabItem { Label("下書き", systemImage: "doc.text") }
            historyView.tabItem { Label("履歴", systemImage: "clock.arrow.circlepath") }
            settingsView.tabItem { Label("設定", systemImage: "gear") }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.checkDuePosts() } }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if scenePhase == .active { model.checkDuePosts() }
            }
        }
        .alert("お知らせ", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") { notice = nil }
        } message: { Text(notice ?? "") }
        .sheet(isPresented: $showLogin) {
            NavigationStack {
                WebLoginView(webView: model.webView)
                    .navigationTitle("Kashejoログイン")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { Button("閉じる") { showLogin = false } }
                        ToolbarItem(placement: .topBarTrailing) { Button("投稿画面") { model.openPostPage() } }
                    }
            }
        }
    }

    private var composeView: some View {
        NavigationStack {
            Form {
                Section("投稿本文") {
                    TextEditor(text: $bodyText)
                        .focused($composeFocused)
                        .frame(minHeight: 120)
                }
                Section("画像") {
                    PhotosPicker(selection: $selectedPhotos, maxSelectionCount: model.maxImageCount, matching: .images) {
                        Label("写真を最大\(model.maxImageCount)枚選択", systemImage: "photo.on.rectangle.angled")
                    }
                    Text("\(imageData.count) 枚選択済み").foregroundStyle(.secondary)
                    if !imageData.isEmpty {
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(Array(imageData.enumerated()), id: \.offset) { _, data in
                                    if let image = UIImage(data: data) {
                                        Image(uiImage: image).resizable().scaledToFill()
                                            .frame(width: 76, height: 76).clipped().cornerRadius(8)
                                    }
                                }
                            }
                        }
                        Button("画像をクリア", role: .destructive) { selectedPhotos = []; imageData = [] }
                    }
                }
                Section("予約投稿") {
                    Toggle("予約する", isOn: $scheduleEnabled)
                    if scheduleEnabled {
                        DatePicker("投稿予定", selection: $scheduleDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    }
                    Text("予約時刻にアプリが開いていれば投稿します。閉じている場合は通知でお知らせします。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("下書き保存") {
                        model.saveDraft(body: bodyText, images: imageData, scheduledAt: scheduleEnabled ? scheduleDate : nil)
                        bodyText = ""; imageData = []; selectedPhotos = []; scheduleEnabled = false
                        notice = "下書きを保存しました"
                    }
                    .disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button {
                        Task {
                            let ok = await model.post(PostItem(body: bodyText, images: imageData))
                            notice = ok ? "投稿しました" : (model.lastError ?? "投稿に失敗しました")
                        }
                    } label: {
                        if model.isSending { ProgressView() } else { Label("今すぐ投稿", systemImage: "paperplane.fill") }
                    }
                    .disabled(model.isSending || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Kashejo Assistant")
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button { showLogin = true } label: { Image(systemName: "person.crop.circle") } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("キーボードを閉じる") { composeFocused = false }
                }
            }
            .task(id: selectedPhotos) {
                var loaded: [Data] = []
                for item in selectedPhotos {
                    if let raw = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: raw),
                       let jpeg = image.jpegData(compressionQuality: 0.78) {
                        loaded.append(jpeg)
                    }
                }
                imageData = loaded
            }
        }
    }

    private var draftsView: some View {
        NavigationStack {
            List {
                if model.drafts.isEmpty { ContentUnavailableView("下書きはありません", systemImage: "doc.text") }
                ForEach(model.drafts) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.body).lineLimit(3)
                        Text("\(item.images.count)枚・\(item.scheduledAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "未予約")")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("投稿") {
                                Task {
                                    let ok = await model.post(item)
                                    notice = ok ? "投稿しました" : (model.lastError ?? "失敗しました")
                                }
                            }
                            Button("削除", role: .destructive) { model.deleteDraft(item) }
                        }.buttonStyle(.bordered)
                    }.padding(.vertical, 4)
                }
                Section {
                    Button("下書きを順番に投稿（最大10件・15秒間隔）") {
                        model.startQueue()
                        notice = "投稿キューを開始しました。失敗時は停止します。"
                    }
                    Button("キューを停止", role: .destructive) { model.stopQueue() }
                }
            }.navigationTitle("下書き・キュー")
        }
    }

    private var historyView: some View {
        NavigationStack {
            List {
                if model.history.isEmpty { ContentUnavailableView("投稿履歴はありません", systemImage: "clock") }
                ForEach(model.history) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.body).lineLimit(3)
                        Text("\(item.date.formatted(date: .numeric, time: .shortened)) ・画像 \(item.imageCount)枚")
                            .font(.caption).foregroundStyle(.secondary)
                        if !item.resultURL.isEmpty,
                           let url = URL(string: item.resultURL, relativeTo: model.normalizedBaseURL)?.absoluteURL {
                            Link("投稿を開く", destination: url)
                        }
                    }.padding(.vertical, 4)
                }
            }.navigationTitle("投稿履歴")
        }
    }

    private var settingsView: some View {
        SettingsView(showLogin: $showLogin)
            .environmentObject(model)
    }

}


struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var showLogin: Bool
    @FocusState private var settingsFocused: Bool
    @State private var accountIDText = ""
    @State private var siteURLText = ""
    @State private var queueInterval = 15.0
    @State private var queueCount = 10.0
    @State private var imageCount = 8.0
    @State private var savedMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Kashejo接続設定") {
                    TextField("サイトURL", text: $siteURLText)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .focused($settingsFocused)
                    TextField("アカウントID", text: $accountIDText)
                        .keyboardType(.numberPad)
                        .focused($settingsFocused)
                    Text("投稿ページ: \(siteURLText.trimmingCharacters(in: .whitespacesAndNewlines))/a/\(accountIDText)/posts")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("接続設定を保存") { saveSettings() }
                    Button("投稿画面を開く") {
                        saveSettings()
                        model.openPostPage()
                    }
                    Button("トップページを開く") {
                        saveSettings()
                        model.openHomePage()
                    }
                }
                Section("連続投稿") {
                    VStack(alignment: .leading) {
                        LabeledContent("投稿間隔", value: "\(Int(queueInterval))秒")
                        Slider(value: $queueInterval, in: 5...300, step: 5)
                    }
                    VStack(alignment: .leading) {
                        LabeledContent("1回の最大投稿数", value: "\(Int(queueCount))件")
                        Slider(value: $queueCount, in: 1...50, step: 1)
                    }
                    Button("連続投稿設定を保存") { saveSettings() }
                    Text("連続投稿は下書きキューから実行します。投稿間隔は5〜300秒、最大件数は1〜50件です。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("画像") {
                    VStack(alignment: .leading) {
                        LabeledContent("最大選択枚数", value: "\(Int(imageCount))枚")
                        Slider(value: $imageCount, in: 1...20, step: 1)
                    }
                    Button("画像設定を保存") { saveSettings() }
                    Text("Kashejo側の上限を超える枚数を設定しても、投稿が成功するとは限りません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("ログイン") {
                    Button("Kashejoにログイン / セッション確認") {
                        model.openHomePage()
                        showLogin = true
                    }
                    Text("ログイン情報はアプリ内WebViewに保存されます。SafariのCookieとは共有されません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("状態") {
                    LabeledContent("状態", value: model.status)
                    if let error = model.lastError { Text(error).foregroundStyle(.red) }
                    if let message = savedMessage { Text(message).foregroundStyle(.green) }
                }
                Section("予約投稿") {
                    Text("予約投稿はアプリが前面で動作している間に実行します。アプリ終了中はiOSの制約により自動投稿を保証できません。予約時刻の通知でお知らせします。")
                }
                Section {
                    Button("設定を初期値に戻す", role: .destructive) {
                        siteURLText = "https://kashejo.f5.si"
                        accountIDText = "135"
                        queueInterval = 15
                        queueCount = 10
                        imageCount = 8
                        saveSettings()
                    }
                }
            }
            .navigationTitle("設定")
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("キーボードを閉じる") { settingsFocused = false }
                }
            }
            .onAppear {
                accountIDText = model.accountID
                siteURLText = model.siteBaseURL
                queueInterval = model.queueIntervalSeconds
                queueCount = Double(model.queueMaxCount)
                imageCount = Double(model.maxImageCount)
            }
        }
    }

    private func saveSettings() {
        model.siteBaseURL = siteURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        model.accountID = accountIDText.trimmingCharacters(in: .whitespacesAndNewlines)
        model.queueIntervalSeconds = queueInterval
        model.queueMaxCount = Int(queueCount)
        model.maxImageCount = Int(imageCount)
        if model.normalizedBaseURL == nil {
            savedMessage = "サイトURLを確認してください（https:// から入力）。"
        } else if model.accountID.isEmpty || !model.accountID.allSatisfy({ $0.isNumber }) {
            savedMessage = "アカウントIDは数字で入力してください。"
        } else {
            savedMessage = "設定を保存しました。"
        }
        settingsFocused = false
    }
}

struct WebLoginView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) { }
}
