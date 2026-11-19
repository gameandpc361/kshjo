import UIKit

enum ImageUtil {
    static let maxCount = 4
    static let maxBytes = 10 * 1024 * 1024 // 10MiB

    // 先頭バイト(マジックナンバー)で形式判定
    static func detectFormat(_ data: Data) -> ImageFormat? {
        guard data.count > 12 else { return nil }
        let b = [UInt8](data.prefix(12))
        // PNG: 89 50 4E 47
        if b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 { return .png }
        // JPEG: FF D8
        if b[0] == 0xFF && b[1] == 0xD8 { return .jpeg }
        // GIF: "GIF"
        if b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 { return .gif }
        // WebP: "RIFF"...."WEBP"
        if b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46,
           data[8] == 0x57 && data[9] == 0x45 && data[10] == 0x42 && data[11] == 0x50 {
            return .webp
        }
        // ISO-BMFF: 4〜7バイト目が"ftyp" → ブランド名で判定
        if b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70 {
            let brand = String(bytes: data.subdata(in: 8..<12), encoding: .ascii) ?? ""
            if brand.hasPrefix("avif") || brand.hasPrefix("avis") { return .avif }
        }
        return nil // HEICなどはここでnil → 後段でJPEGに変換
    }

    /// 読み込んだ画像データを検証し、投稿可能な形に整える
    static func process(_ data: Data, suggestedName: String?) -> Result<MediaItem, String> {
        // 10MiB超: GIFは不可、それ以外は自動縮小
        if data.count > maxBytes {
            if detectFormat(data) == .gif {
                return .failure("GIFが10MiBを超えています。より小さいGIFをお選びください。")
            }
            var shrunk: Data?
            var scale: CGFloat = 0.85
            for _ in 0..<6 {
                shrunk = shrink(data, scale: scale)
                if let s = shrunk, s.count <= maxBytes { break }
                scale -= 0.15
            }
            guard let out = shrunk, out.count <= maxBytes else {
                return .failure("10MiBを超えており、自動縮小もできませんでした")
            }
            let name = "image-\(Int(Date().timeIntervalSince1970)).jpg"
            return .success(MediaItem(data: out, filename: name, mimeType: "image/jpeg"))
        }

        // 10MiB以下で対応形式 → そのまま使う(GIFのアニメーションも保持)
        if let format = detectFormat(data) {
            let name = suggestedName ?? "image-\(Int(Date().timeIntervalSince1970)).\(format.fileExtension)"
            return .success(MediaItem(data: data, filename: name, mimeType: format.mimeType))
        }

        // 未対応形式(HEICなど) → JPEGに変換
        guard let image = UIImage(data: data),
              let jpg = image.jpegData(compressionQuality: 0.9) else {
            return .failure("対応形式は PNG / JPEG / GIF / WebP / AVIF です")
        }
        let name = "image-\(Int(Date().timeIntervalSince1970)).jpg"
        return .success(MediaItem(data: jpg, filename: name, mimeType: "image/jpeg"))
    }

    private static func shrink(_ data: Data, scale: CGFloat) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let newSize = CGSize(width: max(1, image.size.width * scale),
                             height: max(1, image.size.height * scale))
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.jpegData(compressionQuality: 0.85)
    }
}
