import Foundation
import SwiftUI

// MARK: - 設定

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    // 接続先
    @Published var baseURLString: String { didSet { defaults.set(baseURLString, forKey: "k.baseURL") } }
    @Published var notesPath: String { didSet { defaults.set(notesPath, forKey: "k.notesPath") } }
    @Published var filesPath: String { didSet { defaults.set(filesPath, forKey: "k.filesPath") } }
    @Published var signupPath: String { didSet { defaults.set(signupPath, forKey: "k.signupPath") } }

    // 投稿設定
    @Published var visibility: Visibility { didSet { defaults.set(visibility.rawValue, forKey: "k.visibility") } }
    @Published var maxChars: Int { didSet { defaults.set(maxChars, forKey: "k.maxChars") } }
    @Published var templates: [String] { didSet { defaults.set(templates, forKey: "k.templates") } }

    // 連投設定
    @Published var burstCount: Int { didSet { defaults.set(burstCount, forKey: "k.burstCount") } }
    @Published var intervalValue: Double { didSet { defaults.set(intervalValue, forKey: "k.intervalValue") } }
    @Published var intervalUnit: IntervalUnit { didSet { defaults.set(intervalUnit.rawValue, forKey: "k.intervalUnit") } }
    @Published var orderRandom: Bool { didSet { defaults.set(orderRandom, forKey: "k.orderRandom") } }
    @Published var attachImages: Bool { didSet { defaults.set(attachImages, forKey: "k.attachImages") } }
    @Published var retryLimit: Int { didSet { defaults.set(retryLimit, forKey: "k.retryLimit") } }
    @Published var failureThreshold: Int { didSet { defaults.set(failureThreshold, forKey: "k.failureThreshold") } }
    @Published var autoRecreate: Bool { didSet { defaults.set(autoRecreate, forKey: "k.autoRecreate") } }

    private let defaults = UserDefaults.standard

    private init() {
        baseURLString = defaults.string(forKey: "k.baseURL") ?? "https://kashejo.f5.si"
        notesPath = defaults.string(forKey: "k.notesPath") ?? "api/notes/create"
        filesPath = defaults.string(forKey: "k.filesPath") ?? "api/drive/files/create"
        signupPath = defaults.string(forKey: "k.signupPath") ?? "api/accounts/create"
        visibility = Visibility(rawValue: defaults.string(forKey: "k.visibility") ?? "") ?? .public
        maxChars = defaults.object(forKey: "k.maxChars") as? Int ?? 3000
        templates = defaults.stringArray(forKey: "k.templates") ?? [
            "おはようございます☀️",
            "定期投稿です 🤖",
            "今日も良い一日を!"
        ]
        burstCount = defaults.object(forKey: "k.burstCount") as? Int ?? 5
        intervalValue = defaults.object(forKey: "k.intervalValue") as? Double ?? 5
        intervalUnit = IntervalUnit(rawValue: defaults.string(forKey: "k.intervalUnit") ?? "") ?? .minutes
        orderRandom = defaults.object(forKey: "k.orderRandom") as? Bool ?? false
        attachImages = defaults.object(forKey: "k.attachImages") as? Bool ?? false
        retryLimit = defaults.object(forKey: "k.retryLimit") as? Int ?? 1
        failureThreshold = defaults.object(forKey: "k.failureThreshold") as? Int ?? 3
        autoRecreate = defaults.object(forKey: "k.autoRecreate") as? Bool ?? false
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
            throw APIError(message: "APIトークンが未設定です(アカウント管理で登録)")
        }
        return APIClient(baseURL: base, token: token,
                         notesPath: notesPath, filesPath: filesPath, signupPath: signupPath)
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

    /// 次のアカウントへローテーション(失敗時の自動切替用)
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
