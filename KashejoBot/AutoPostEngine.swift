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
    private var images: [Data] = []   // リサイズ済みJPEG

    func setImages(_ data: [Data]) {
        images = data
    }

    // MARK: 連投開始

    func start(settings: SettingsStore, accounts: AccountStore) {
        guard !isRunning else { return }
        guard accounts.active != nil else {
            LogStore.shared.log(.error, "auto", "アカウントが未設定のため開始できません")
            lastMessage = "アカウント未設定"
            return
        }
        let config = BurstConfig(from: settings)
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

    /// 今すぐ1件だけ投稿(テスト用)
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

    // MARK: メインループ

    private func run(config: BurstConfig, settings: SettingsStore, accounts: AccountStore) async {
        isRunning = true
        let intervalDesc = "\(Int(config.interval))秒間隔"
        LogStore.shared.log(.info, "auto", "連投開始: \(config.count)件 / \(intervalDesc) / リトライ\(config.retryLimit)回")
        lastMessage = "連投開始"

        for index in 1...config.count {
            if Task.isCancelled { break }
            currentIndex = index

            let ok = await postWithRetry(index: index, config: config, settings: settings, accounts: accounts)
            if !ok && !Task.isCancelled {
                lastMessage = "連続失敗のため中断"
                LogStore.shared.log(.error, "auto", "回復不能なため連投を中断しました")
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

    // MARK: 1件の投稿(リトライ+回復処理つき)

    private func postWithRetry(index: Int, config: BurstConfig, settings: SettingsStore, accounts: AccountStore) async -> Bool {
        for attempt in 1...max(1, config.retryLimit + 1) {
            if Task.isCancelled { return false }
            do {
                try await postOnce(index: index, config: config, settings: settings, accounts: accounts)
                failureStreak = 0
                lastMessage = "第\(index)件 投稿完了"
                return true
            } catch {
                LogStore.shared.log(.error, "auto",
                    "投稿失敗(\(index)件目 試行\(attempt)/\(config.retryLimit + 1)): \(error.localizedDescription)")
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
        return true // しきい値未満なら続行
    }

    /// しきい値到達時の回復: アカウント切替 → (ONなら)自動再作成
    private func recover(settings: SettingsStore, accounts: AccountStore) async -> Bool {
        // 1) 登録済みの別アカウントへ切替
        if accounts.accounts.count > 1, let next = accounts.rotate() {
            LogStore.shared.log(.info, "auto", "アカウントを切替して続行: \(next.label)")
            failureStreak = 0
            return true
        }
        // 2) サインアップAPIで新規アカウントを自動作成
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
                    LogStore.shared.log(.error, "auto",
                        "サインアップ応答にトークンがありません(サイトがAPI作成に非対応の可能性があります)")
                }
            } catch {
                LogStore.shared.log(.error, "auto", "アカウント再作成失敗: \(error.localizedDescription)")
            }
        } else {
            LogStore.shared.log(.warning, "auto", "自動再作成はOFFのため手動対応が必要です")
        }
        return false
    }

    // MARK: 1回の投稿処理

    private func postOnce(index: Int, config: BurstConfig, settings: SettingsStore, accounts: AccountStore) async throws {
        guard let account = accounts.active else {
            throw APIError(message: "アクティブなアカウントがありません")
        }
        let client = try settings.makeClient(token: account.token)

        // 画像アップロード
        var fileIds: [String] = []
        if config.attachImages && !images.isEmpty {
            let data: Data
            if config.orderRandom {
                data = images.randomElement()!
            } else {
                data = images[(index - 1) % images.count]
            }
            let name = "burst_\(Int(Date().timeIntervalSince1970))_\(index).jpg"
            LogStore.shared.log(.debug, "api", "画像アップロード: \(name) (\(data.count) bytes)")
            if let file = try await client.uploadFile(data, filename: name, mimeType: "image/jpeg") {
                fileIds = [file.id]
                LogStore.shared.log(.debug, "api", "アップロード成功: fileID=\(file.id)")
            } else {
                LogStore.shared.log(.warning, "api", "アップロード応答を解析できず、テキストのみで投稿します")
            }
        }

        // テキスト選択
        let templates = settings.templates
        let text: String?
        if templates.isEmpty {
            text = nil
        } else if config.orderRandom {
            text = templates.randomElement()
        } else {
            text = templates[(index - 1) % templates.count]
        }

        let note = try await client.createNote(text: text, fileIds: fileIds,
                                               visibility: settings.visibility.rawValue)
        HistoryStore.shared.add(HistoryEntry(
            id: UUID(), date: Date(), account: account.label,
            kind: fileIds.isEmpty ? "text" : "image",
            text: text ?? "(テキストなし)", hasImage: !fileIds.isEmpty,
            success: true,
            message: note.map { "ID: \($0.id)" } ?? "投稿しました"
        ))
        LogStore.shared.log(.info, "api", "投稿成功: \(note?.id ?? "ID不明") @\(account.username)")
    }

    // MARK: ユーティリティ

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
