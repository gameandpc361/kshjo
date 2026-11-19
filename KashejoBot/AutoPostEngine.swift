import Foundation
import SwiftUI

@MainActor
final class AutoPostEngine: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var currentIndex = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var nextPostAt: Date?
    @Published private(set) var failureStreak = 0
    @Published private(set) var lastMessage = "停止中"

    private var task: Task<Void, Never>?
    private var uploadCache: [String: String] = [:]   // "アカウントID|画像ファイル名" → 画像ID

    func start(settings: SettingsStore, accounts: AccountStore) {
        guard !isRunning else { return }
        guard accounts.active != nil else {
            LogStore.shared.log(.error, "auto", "アカウントが未設定のため開始できません")
            lastMessage = "アカウント未設定"
            return
        }
        let config = BurstConfig(from: settings)
        totalCount = config.count
        task = Task { [weak self] in
            await self?.run(config: config, settings: settings, accounts: accounts)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        nextPostAt = nil
        lastMessage = "停止中"
        LogStore.shared.log(.info, "auto", "連投を停止しました")
    }

    func postOneNow(settings: SettingsStore, accounts: AccountStore) {
        guard accounts.active != nil else {
            LogStore.shared.log(.error, "auto", "アカウント未設定のためテスト投稿できません")
            lastMessage = "アカウント未設定"
            return
        }
        let config = BurstConfig(from: settings)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.postOnce(index: 1, config: config, settings: settings, accounts: accounts)
                self.lastMessage = "テスト投稿しました"
            } catch {
                self.lastMessage = "テスト投稿失敗: \(error.localizedDescription)"
            }
        }
    }

    private func run(config: BurstConfig, settings: SettingsStore, accounts: AccountStore) async {
        isRunning = true
        uploadCache = [:]  // 連投ごとに画像IDキャッシュをリセット
        LogStore.shared.log(.info, "auto", "連投開始: \(config.count)件 / \(Int(config.interval))秒間隔 / リトライ\(config.retryLimit)回")
        lastMessage = "連投開始"

        for index in 1...config.count {
            if Task.isCancelled { break }
            currentIndex = index

            let ok = await postWithRetry(index: index, config: config, settings: settings, accounts: accounts)
            if !ok && !Task.isCancelled {
                LogStore.shared.log(.error, "auto", "連投を中断しました(\(lastMessage))")
                break
            }

            if index < config.count && !Task.isCancelled {
                nextPostAt = Date().addingTimeInterval(config.interval)
                await sleep(seconds: config.interval)
                nextPostAt = nil
            }
        }
        if !Task.isCancelled {
            LogStore.shared.log(.info, "auto", "連投終了")
        }
        isRunning = false
        nextPostAt = nil
    }

    private func postWithRetry(index: Int, config: BurstConfig, settings: SettingsStore, accounts: AccountStore) async -> Bool {
        for attempt in 1...max(1, config.retryLimit + 1) {
            if Task.isCancelled { return false }
            do {
                try await postOnce(index: index, config: config, settings: settings, accounts: accounts)
                failureStreak = 0
                lastMessage = "第\(index)件 投稿完了"
                return true
            } catch {
                // 設定ミスはリトライ・アカウント切替をせず即中断
                if let apiError = error as? APIError, apiError.isConfigError {
                    LogStore.shared.log(.error, "auto", "設定エラー: \(error.localizedDescription)")
                    lastMessage = "設定エラー: \(error.localizedDescription)"
                    return false
                }
                LogStore.shared.log(.error, "auto",
                    "投稿失敗(\(index)件目 試行\(attempt)/\(config.retryLimit + 1)): \(error.localizedDescription)")
                // 画像IDキャッシュが原因の可能性に備えてクリア
                if !uploadCache.isEmpty {
                    uploadCache = [:]
                    LogStore.shared.log(.warning, "auto", "画像IDキャッシュをクリアしました(次回は再アップロード)")
                }
                if attempt <= config.retryLimit {
                    await sleep(seconds: 2)
                }
            }
        }
        failureStreak += 1
        LogStore.shared.log(.warning, "auto",
            "連続失敗ストリーク: \(failureStreak) / しきい値 \(config.failureThreshold)")
        if failureStreak >= config.failureThreshold {
            return await recover(settings: settings, accounts: accounts)
        }
        return true
    }

    private func recover(settings: SettingsStore, accounts: AccountStore) async -> Bool {
        if accounts.accounts.count > 1, let next = accounts.rotate() {
            LogStore.shared.log(.info, "auto", "アカウントを切替して続行: \(next.label)")
            failureStreak = 0
            return true
        }
        if settings.autoRecreate {
            LogStore.shared.log(.info, "auto", "アカウント自動再作成を試行します")
            do {
                let username = Self.randomUsername()
                let password = Self.randomPassword()
                let client = try settings.makeClient(token: accounts.active?.token ?? "")
                if let newToken = try await client.createAccount(username: username, password: password),
                   !newToken.isEmpty {
                    let acc = accounts.addAutoCreated(username: username, token: newToken)
                    accounts.setActive(acc.id)
                    LogStore.shared.log(.info, "auto", "新アカウント作成&切替: @\(username)")
                    failureStreak = 0
                    return true
                } else {
                    LogStore.shared.log(.error, "auto", "サインアップ応答にトークンがありません(サイトがAPI作成に非対応の可能性)")
                }
            } catch {
                LogStore.shared.log(.error, "auto", "アカウント再作成失敗: \(error.localizedDescription)")
            }
        } else {
            LogStore.shared.log(.warning, "auto", "自動再作成はOFFのため手動対応が必要です")
        }
        return false
    }

    private func pickTemplate(index: Int, config: BurstConfig, settings: SettingsStore) -> PostTemplate? {
        let templates = settings.postTemplates
        guard !templates.isEmpty else { return nil }
        if config.orderRandom {
            return templates.randomElement()
        }
        return templates[(index - 1) % templates.count]
    }

    private func postOnce(index: Int, config: BurstConfig, settings: SettingsStore, accounts: AccountStore) async throws {
        guard let account = accounts.active else {
            throw APIError(message: "アクティブなアカウントがありません")
        }
        let client = try settings.makeClient(token: account.token)

        guard let template = pickTemplate(index: index, config: config, settings: settings) else {
            throw APIError(message: "テンプレートがありません。「テンプレート編集」で設定してください", isConfigError: true)
        }
        if template.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && template.images.isEmpty {
            throw APIError(message: "テンプレートが空です(本文または画像を設定してください)", isConfigError: true)
        }
        let worst = RandomText.worstLength(template.text)
        if worst > settings.maxChars {
            throw APIError(message: "「\(template.text.prefix(15))…」は上限超過の可能性(\(worst)/\(settings.maxChars)文字)", isConfigError: true)
        }

        let text = RandomText.expand(template.text)

        var fileIds: [String] = []
        for (i, name) in template.images.enumerated() {
            let cacheKey = "\(account.id.uuidString)|\(name)"
            if let cached = uploadCache[cacheKey] {
                fileIds.append(cached)
                LogStore.shared.log(.debug, "api", "画像はキャッシュ済み: \(name) (\(i + 1)/\(template.images.count))")
                continue
            }
            guard let item = TemplateImageStore.shared.mediaItem(name) else {
                throw APIError(message: "テンプレート画像ファイルが見つかりません: \(name)", isConfigError: true)
            }
            LogStore.shared.log(.debug, "api", "アップロード: \(name) (\(i + 1)/\(template.images.count))")
            let id = try await client.uploadFile(item)
            uploadCache[cacheKey] = id
            fileIds.append(id)
        }

        let response = try await client.createPost(text: text.isEmpty ? nil : text, fileIds: fileIds)
        HistoryStore.shared.add(HistoryEntry(
            id: UUID(), date: Date(), account: account.label,
            kind: fileIds.isEmpty ? "text" : "image",
            text: text, hasImage: !fileIds.isEmpty,
            success: true,
            message: String(response.prefix(150))
        ))
        LogStore.shared.log(.info, "api", "投稿成功: \(String(response.prefix(300)))")
    }

    private func sleep(seconds: TimeInterval) async {
        do {
            try await Task.sleep(nanoseconds: UInt64(max(0.1, seconds) * 1_000_000_000))
        } catch { /* キャンセル */ }
    }

    static func randomUsername() -> String {
        "bot_\(Int(Date().timeIntervalSince1970) % 100000)\(Int.random(in: 10...99))"
    }

    static func randomPassword() -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<16).map { _ in chars.randomElement()! })
    }
}
