import Foundation

// MARK: - 画像形式

enum ImageFormat: String, CaseIterable {
    case png, jpeg, gif, webp, avif

    var mimeType: String {
        switch self {
        case .png:  return "image/png"
        case .jpeg: return "image/jpeg"
        case .gif:  return "image/gif"
        case .webp: return "image/webp"
        case .avif: return "image/avif"
        }
    }

    var fileExtension: String {
        switch self {
        case .png:  return "png"
        case .jpeg: return "jpg"
        case .gif:  return "gif"
        case .webp: return "webp"
        case .avif: return "avif"
        }
    }

    static func from(fileExtension ext: String) -> ImageFormat? {
        let lower = ext.lowercased()
        return allCases.first { $0.fileExtension == lower || $0.rawValue == lower }
    }
}

struct MediaItem: Identifiable {
    let id = UUID()
    let data: Data
    let filename: String
    let mimeType: String
}

// MARK: - テンプレート

struct PostTemplate: Identifiable, Codable {
    let id: UUID
    var text: String        // {rand} / {rand:N} を含められる
    var images: [String]    // TemplateImageStore 内のファイル名
}

// MARK: - 履歴

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
    var isConfigError: Bool = false
    var errorDescription: String? { message }
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
    let retryLimit: Int
    let failureThreshold: Int

    init(from s: SettingsStore) {
        count = max(1, s.burstCount)
        interval = max(1, s.intervalValue) * s.intervalUnit.factor
        orderRandom = s.orderRandom
        retryLimit = s.retryLimit
        failureThreshold = s.failureThreshold
    }
}
