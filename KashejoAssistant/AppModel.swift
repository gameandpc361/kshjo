import Foundation
import Combine
import WebKit
import PhotosUI
import UIKit
import UserNotifications

struct PostItem: Identifiable, Codable {
    var id = UUID()
    var body: String
    var images: [Data]
    var createdAt = Date()
    var scheduledAt: Date? = nil
}
struct HistoryItem: Identifiable, Codable {
    var id = UUID()
    var body: String
    var date = Date()
    var resultURL: String
    var imageCount: Int
}
private struct StoreData: Codable {
    var drafts: [PostItem]
    var history: [HistoryItem]
}
enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let value) = self { return value }
        return "不明なエラー"
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var webView: WKWebView
    @Published var drafts: [PostItem] = []
    @Published var history: [HistoryItem] = []
    @Published var status = "未ログイン"
    @Published var isSending = false
    @Published var lastError: String?
    @Published var siteBaseURL: String {
        didSet { UserDefaults.standard.set(siteBaseURL, forKey: "siteBaseURL") }
    }
    @Published var accountID: String {
        didSet { UserDefaults.standard.set(accountID, forKey: "accountID") }
    }
    @Published var queueIntervalSeconds: Double {
        didSet { UserDefaults.standard.set(queueIntervalSeconds, forKey: "queueIntervalSeconds") }
    }
    @Published var queueMaxCount: Int {
        didSet { UserDefaults.standard.set(queueMaxCount, forKey: "queueMaxCount") }
    }
    @Published var maxImageCount: Int {
        didSet { UserDefaults.standard.set(maxImageCount, forKey: "maxImageCount") }
    }
    private var queueTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        siteBaseURL = defaults.string(forKey: "siteBaseURL") ?? "https://kashejo.f5.si"
        accountID = defaults.string(forKey: "accountID") ?? "135"
        queueIntervalSeconds = defaults.object(forKey: "queueIntervalSeconds") as? Double ?? 15
        queueMaxCount = defaults.object(forKey: "queueMaxCount") as? Int ?? 10
        maxImageCount = defaults.object(forKey: "maxImageCount") as? Int ?? 8
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        loadStore()
        webView.load(URLRequest(url: normalizedBaseURL ?? URL(string: "https://kashejo.f5.si")!))
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    var normalizedBaseURL: URL? {
        let trimmed = siteBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              components.host != nil else { return nil }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return components.url
    }

    var postPageURL: URL? {
        guard let base = normalizedBaseURL else { return nil }
        let id = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.allSatisfy({ $0.isNumber }) else { return nil }
        return base.appendingPathComponent("a").appendingPathComponent(id).appendingPathComponent("posts")
    }

    func openPostPage() {
        guard let url = postPageURL else {
            lastError = "サイトURLまたはアカウントIDの設定を確認してください。"
            return
        }
        webView.load(URLRequest(url: url))
    }

    func openHomePage() {
        guard let url = normalizedBaseURL else {
            lastError = "サイトURLが正しくありません。"
            return
        }
        webView.load(URLRequest(url: url))
    }

    func saveDraft(body: String, images: [Data], scheduledAt: Date?) {
        let item = PostItem(body: body, images: images, scheduledAt: scheduledAt)
        drafts.insert(item, at: 0)
        persist()
        if let date = scheduledAt { scheduleReminder(for: item, at: date) }
    }

    func deleteDraft(_ item: PostItem) {
        drafts.removeAll { $0.id == item.id }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [item.id.uuidString])
        persist()
    }

    func post(_ item: PostItem) async -> Bool {
        guard !isSending else { return false }
        isSending = true
        defer { isSending = false }

        do {
            let payload: [String: Any] = [
                "body": item.body,
                "images": item.images.map { $0.base64EncodedString() }
            ]
            let jsonData = try JSONSerialization.data(withJSONObject: payload)
            guard let json = String(data: jsonData, encoding: .utf8) else {
                throw AppError.message("投稿データを作成できませんでした")
            }
            let script = """
            (async()=>{const p=\(json);
            const forms=Array.from(document.forms);
            const form=forms.find(f=>f.querySelector('[name="csrf"]')&&(f.querySelector('[name="body"]')||f.querySelector('textarea')));
            if(!form)return JSON.stringify({ok:false,error:"投稿フォームが見つかりません。ログイン後、投稿画面を開いてください。"});
            if(!form.querySelector('[name="body"]'))return JSON.stringify({ok:false,error:"body入力欄が見つかりません。"});
            const fd=new FormData(form);fd.set("body",p.body);fd.delete("images");
            for(let i=0;i<p.images.length;i++){const raw=atob(p.images[i]);const bytes=new Uint8Array(raw.length);for(let j=0;j<raw.length;j++)bytes[j]=raw.charCodeAt(j);const blob=new Blob([bytes],{type:"image/jpeg"});fd.append("images",new File([blob],`photo-${i+1}.jpg`,{type:"image/jpeg"}));const alt=`alt_${i}`;if(fd.has(alt))fd.set(alt,"");else fd.append(alt,"");}
            const action=form.getAttribute("action")||location.href;
            const response=await fetch(action,{method:"POST",body:fd,credentials:"same-origin",redirect:"follow"});
            const finalURL=response.url||"";const text=await response.text();
            const ok=response.ok&&(finalURL.includes("/posts/")||!text.includes("JSONが読めません"));
            return JSON.stringify({ok,status:response.status,url:finalURL,error:ok?"":text.slice(0,500)});
            })()
            """
            let result = try await evaluate(script)
            guard let data = result.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AppError.message("サーバー応答を解析できませんでした")
            }
            if object["ok"] as? Bool == true {
                let url = object["url"] as? String ?? ""
                history.insert(HistoryItem(body: item.body, resultURL: url, imageCount: item.images.count), at: 0)
                drafts.removeAll { $0.id == item.id }
                persist()
                status = "投稿成功"
                return true
            }
            lastError = object["error"] as? String ?? "投稿に失敗しました"
            status = "投稿失敗"
            return false
        } catch {
            lastError = error.localizedDescription
            status = "投稿失敗"
            return false
        }
    }

    func startQueue() {
        guard queueTask == nil else { return }
        let batch = Array(drafts.prefix(max(1, min(queueMaxCount, 50))))
        guard !batch.isEmpty else { return }
        queueTask = Task {
            for (index, item) in batch.enumerated() {
                if Task.isCancelled { break }
                if !(await post(item)) { break }
                if index < batch.count - 1 { try? await Task.sleep(for: .seconds(max(1, queueIntervalSeconds))) }
            }
            queueTask = nil
        }
    }
    func stopQueue() { queueTask?.cancel(); queueTask = nil }

    func checkDuePosts() {
        let due = drafts.filter { ($0.scheduledAt ?? .distantFuture) <= Date() }
        guard !due.isEmpty, !isSending else { return }
        Task {
            for item in due {
                if !(await post(item)) { break }
            }
        }
    }

    private func evaluate(_ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: value as? String ?? "")
            }
        }
    }

    private func scheduleReminder(for item: PostItem, at date: Date) {
        guard date > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Kashejoの予約投稿"
        content.body = "アプリを開くと、予約投稿を確認・実行します。"
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        let request = UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    private var storeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("kashejo-data.json")
    }
    private func loadStore() {
        do {
            let data = try Data(contentsOf: storeURL)
            let store = try JSONDecoder().decode(StoreData.self, from: data)
            drafts = store.drafts
            history = store.history
        } catch { }
    }
    private func persist() {
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(StoreData(drafts: drafts, history: history))
            try data.write(to: storeURL, options: .atomic)
        } catch { lastError = "保存失敗: \(error.localizedDescription)" }
    }
}
