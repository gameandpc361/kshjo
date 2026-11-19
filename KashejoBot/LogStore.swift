import Foundation
import SwiftUI

final class LogStore: ObservableObject {
    static let shared = LogStore()

    @Published private(set) var entries: [LogEntry] = []

    private let fileURL: URL
    private let memoryLimit = 1000

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("kashejo_bot_log.jsonl")
        loadTail()
    }

    /// ログ記録(メモリ+JSONLファイルへの逐次追記)
    func log(_ level: LogLevel, _ category: String, _ message: String) {
        let entry = LogEntry(id: UUID(), date: Date(), level: level,
                             category: category, message: message)
        DispatchQueue.main.async {
            self.entries.append(entry)
            if self.entries.count > self.memoryLimit {
                self.entries.removeFirst(self.entries.count - self.memoryLimit)
            }
        }
        appendToFile(entry)
    }

    private func appendToFile(_ entry: LogEntry) {
        let line: String
        if let data = try? JSONEncoder().encode(entry),
           let json = String(data: data, encoding: .utf8) {
            line = json
        } else {
            line = "{\"level\":\"\(entry.level.rawValue)\",\"message\":\"\(entry.message.replacingOccurrences(of: "\"", with: "'"))\"}"
        }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write((line + "\n").data(using: .utf8)!)
            try? handle.close()
        }
    }

    private func loadTail() {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        let lines = raw.split(separator: "\n").suffix(memoryLimit)
        let loaded = lines.compactMap { line -> LogEntry? in
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(LogEntry.self, from: data) else { return nil }
            return entry
        }
        entries = loaded
    }

    /// 書き出し用テキストファイルを作成
    func exportFile() -> URL? {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var text = "KashejoBot ログ書き出し \(df.string(from: Date()))\n----\n"
        for e in entries {
            text += "[\(df.string(from: e.date))] [\(e.level.rawValue)] [\(e.category)] \(e.message)\n"
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kashejo_bot_log_\(Int(Date().timeIntervalSince1970)).txt")
        do {
            try text.data(using: .utf8)?.write(to: tmp)
            return tmp
        } catch {
            return nil
        }
    }

    func clear() {
        entries = []
        try? FileManager.default.removeItem(at: fileURL)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    }
}
