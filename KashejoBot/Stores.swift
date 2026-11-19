import Foundation
import SwiftUI

// MARK: - 設定

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var baseURLString: String { didSet { defaults.set(baseURLString, forKey: "k.baseURL") } }
    @Published var maxChars: Int { didSet { defaults.set(maxChars, forKey: "k.maxChars") } }
    @Published var postTemplates: [PostTemplate] { didSet { persistTemplates() } }

    @Published var burstCount: Int { didSet { defaults.set(burstCount, forKey: "k.burstCount") } }
    @Published var intervalValue: Double { didSet { defaults.set(intervalValue, forKey: "k.intervalValue") } }
    @Published var intervalUnit: IntervalUnit { didSet { defaults.set(intervalUnit.rawValue, forKey: "k.intervalUnit") } }
    @Published var orderRandom: Bool { didSet { defaults.set(orderRandom, forKey: "k.orderRandom") } }
    @Published var retryLimit: Int { didSet { defaults.set(retryLimit, forKey: "k.retryLimit") } }
    @Published var failureThreshold: Int { didSet { defaults.set(failureThreshold, forKey: "k.failureThreshold") } }
    @Published var autoRecreate: Bool { didSet { defaults.set(autoRecreate, forKey: "k.autoRecreate") } }

    private let defaults = UserDefaults.standard

    private init() {
        baseURLString = defaults.string(forKey: "k.baseURL") ?? "https://kashejo.f5.si"
        maxChars = defaults.object(forKey: "k.maxChars") as? Int ?? 3000

        // テンプレート(新形式 → 旧形式からの移行 → 初期値)
        if let data = defaults.data(forKey: "k.postTemplates"),
           let decoded = try? JSONDecoder().decode([PostTemplate].self, from: data) {
            postTemplates = decoded
        } else if let old = defaults.stringArray(forKey: "k.templates"), !old.isEmpty {
            postTemplates = old.map { PostTemplate(id: UUID(), text: $0, images: []) }
            persistTemplates()
            LogStore.shared.log(.info, "template", "旧テンプレート\(old.count)件を新形式に移行しました")
        } else {
            postTemplates = [
                PostTemplate(id: UUID(), text: "おはよう投稿 {rand}", images: []),
                PostTemplate(id: UUID(), text: "定期投稿 {datetime}", images: [])
            ]
            persistTemplates()
        }

        burstCount = defaults.object(forKey: "k.burstCount") as? Int ?? 5
        intervalValue = defaults.object(forKey: "k.intervalValue") as? Double ?? 5
        intervalUnit = IntervalUnit(rawValue: defaults.string(forKey: "k.intervalUnit") ?? "") ?? .minutes
        orderRandom = defaults.object(forKey: "k.orderRandom") as? Bool ?? false
        retryLimit = defaults.object(forKey: "k.retryLimit") as? Int ?? 1
        failureThreshold = defaults.object(forKey: "k.failureThreshold") as? Int ?? 3
        autoRecreate = defaults.object(forKey: "k.autoRecreate") as? Bool ?? false
    }

    private func persistTemplates() {
        if let data = try? JSONEncoder().encode(postTemplates) {
            defaults.set(data, forKey: "k.postTemplates")
        }
    }

    var baseURL: URL? {
        URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func makeClient(token: String) throws -> APIClient {
        guard let base = baseURL,
              let scheme = base.scheme?.lowercased(), ["https", "http"].contains(scheme) else {
            throw APIError(message: "ベースURLが不正です(設定を確認)")
        }
        guard !token.isEmpty else {
            throw APIError(message: "APIキーが未設定です(アカウント管理で登録)")
        }
        return APIClient(baseURL: base, token: token)
    }
}

// MARK: - テンプレート画像の保存領域

final class TemplateImageStore {
    static let shared = TemplateImageStore()

    private let dir: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("template_images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func save(_ data: Data, ext: String) -> String? {
        let cleanExt = ext.isEmpty ? "jpg" : ext
        let name = "\(UUID().uuidString).\(cleanExt)"
        do {
            try data.write(to: dir.appendingPathComponent(name))
            return name
        } catch {
            return nil
        }
    }

    func load(_ name: String) -> Data? {
        try? Data(contentsOf: dir.appendingPathComponent(name))
    }

    func delete(_ name: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }

    /// 保存時に不要になった画像ファイルの一括掃除
    func deleteAllExcept(_ keep: [String]) {
        let keepSet = Set(keep)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in files where !keepSet.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func mediaItem(_ name: String) -> MediaItem? {
        guard let data = load(name) else { return nil }
        let ext = (name as NSString).pathExtension
        let mime = ImageFormat.from(fileExtension: ext)?.mimeType ?? "application/octet-stream"
        return MediaItem(data: data, filename: name, mimeType: mime)
    }
}

// MARK: - ランダム文字列({rand} の展開)

enum RandomText {
    static func expand(_ template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\{rand(?::(\d{1,3}))?\}"#) else {
            return template
        }
        let ns = template as NSString
        var result = ns
        // 後方から置換すると前の位置がずれない
        for match in regex.matches(in: template, range: NSRange(location: 0, length: ns.length)).reversed() {
            var length = 10
            if match.range(at: 1).location != NSNotFound,
               let n = Int(ns.substring(with: match.range(at: 1))) {
                length = n
            }
            result = result.replacingCharacters(in: match.range, with: randomString(length))
        }
        return result as String
    }

    /// プレースホルダを最大長で展開した場合の文字数(上限チェック用)
    static func worstLength(_ template: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: #"\{rand(?::(\d{1,3}))?\}"#) else {
            return template.count
        }
        let ns = template as NSString
        var length = ns.length
        for match in regex.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            var n = 10
            if match.range(at: 1).location != NSNotFound,
               let v = Int(ns.substring(with: match.range(at: 1))) {
                n = v
            }
            length = length - match.range.length + max(1, min(500, n))
        }
        return length
    }

    static func randomString(_ length: Int) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<max(1, min(500, length))).map { _ in chars.randomElement()! })
    }
}

// MARK: - アカウント

final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published private(set) var accounts: [AccountProfile] = [] {
        didSet { persist() }
    }
    @Published var activeID: UUID? {
        didSet { UserDefaults.standard.set(activeID?.uuidString, forKey: "k.activeAccount") }
    }

    private init() {
        if let data = Keychain.loadData(account: "accounts"),
           let saved = try? JSONDecoder().decode([AccountProfile].self, from: data) {
            accounts = saved
        }
        if let s = UserDefaults.standard.string(forKey: "k.activeAccount") {
            activeID = UUID(uuidString: s)
        }
    }

    var active: AccountProfile? {
        accounts.first { $0.id == activeID } ?? accounts.first
    }

    func addManual(label: String, username: String, token: String) {
        let acc = AccountProfile(id: UUID(), label: label.isEmpty ? "@\(username)" : label,
                                 username: username, token: token,
                                 createdAt: Date(), isAutoCreated: false)
        accounts.append(acc)
        if activeID == nil { activeID = acc.id }
        LogStore.shared.log(.info, "account", "アカウント追加: \(acc.label)")
    }

    @discardableResult
    func addAutoCreated(username: String, token: String) -> AccountProfile {
        let acc = AccountProfile(id: UUID(), label: "@\(username)(自動)",
                                 username: username, token: token,
                                 createdAt: Date(), isAutoCreated: true)
        accounts.append(acc)
        activeID = acc.id
        return acc
    }

    func setActive(_ id: UUID) {
        activeID = id
        if let acc = accounts.first(where: { $0.id == id }) {
            LogStore.shared.log(.info, "account", "アクティブ切替: \(acc.label)")
        }
    }

    @discardableResult
    func rotate() -> AccountProfile? {
        guard accounts.count > 1 else { return nil }
        let currentIndex = accounts.firstIndex { $0.id == activeID } ?? -1
        let next = accounts[(currentIndex + 1) % accounts.count]
        activeID = next.id
        LogStore.shared.log(.info, "account", "自動切替: \(next.label)")
        return next
    }

    func remove(_ id: UUID) {
        accounts.removeAll { $0.id == id }
        if activeID == id { activeID = accounts.first?.id }
        LogStore.shared.log(.info, "account", "アカウント削除")
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) {
            Keychain.saveData(data, account: "accounts")
        }
    }
}

// MARK: - 履歴

final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry] = []

    private let key = "k.history"
    private let limit = 200

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = saved
        }
    }

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func clear() {
        entries = []
        UserDefaults.standard.removeObject(forKey: key)
    }
}
