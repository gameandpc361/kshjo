import Foundation

// MARK: - APIレスポンス

struct Note: Codable, Identifiable {
    let id: String
    let createdAt: String
    let text: String?
}

struct DriveFile: Codable {
    let id: String
}

struct AccountInfo: Codable {
    let username: String
    let name: String?
}

// MARK: - アプリ内部モデル

struct HistoryEntry: Identifiable, Codable {
    let id: UUID
    let date: Date
    let account: String
    let kind: String        // "text" / "image"
    let text: String
    let hasImage: Bool
    let success: Bool
    let message: String
}

struct AlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Visibility: String, CaseIterable, Codable, Identifiable {
    case `public`, home, followers, spec
    var id: String { rawValue }
    var label: String {
        switch self {
        case .public:    return "パブリック"
        case .home:      return "ホーム"
        case .followers: return "フォロワー"
        case .spec:      return "ダイレクト"
        }
    }
}

// MARK: - ログ

enum LogLevel: String, Codable, CaseIterable, Identifiable {
    case debug, info, warning, error
    var id: String { rawValue }
    var label: String {
        switch self {
        case .debug:   return "デバッグ"
        case .info:    return "情報"
        case .warning: return "警告"
        case .error:   return "エラー"
        }
    }
    var colorName: String {
        switch self {
        case .debug:   return "gray"
        case .info:    return "blue"
        case .warning: return "orange"
        case .error:   return "red"
        }
    }
}

struct LogEntry: Identifiable, Codable {
    let id: UUID
    let date: Date
    let level: LogLevel
    let category: String
    let message: String
}

// MARK: - アカウント

struct AccountProfile: Identifiable, Codable {
    let id: UUID
    var label: String
    var username: String
    var token: String
    var createdAt: Date
    var isAutoCreated: Bool
}

// MARK: - 連投設定

enum IntervalUnit: String, CaseIterable, Identifiable {
    case seconds, minutes, hours
    var id: String { rawValue }
    var label: String {
        switch self {
        case .seconds: return "秒"
        case .minutes: return "分"
        case .hours:   return "時間"
        }
    }
    var factor: TimeInterval {
        switch self {
        case .seconds: return 1
        case .minutes: return 60
        case .hours:   return 3600
        }
    }
}

struct BurstConfig {
    let count: Int
    let interval: TimeInterval
    let orderRandom: Bool
    let attachImages: Bool
    let retryLimit: Int
    let failureThreshold: Int

    init(from s: SettingsStore) {
        count = max(1, s.burstCount)
        interval = max(1, s.intervalValue) * s.intervalUnit.factor
        orderRandom = s.orderRandom
        attachImages = s.attachImages
        retryLimit = s.retryLimit
        failureThreshold = s.failureThreshold
    }
}
