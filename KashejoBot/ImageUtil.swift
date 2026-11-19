import UIKit

enum ImageUtil {
    /// 長辺をmaxDimensionに収まるようJPEG再エンコード(アップロード軽量化)
    static func jpegData(from data: Data, maxDimension: CGFloat = 1280, quality: CGFloat = 0.85) -> Data {
        guard let image = UIImage(data: data) else { return data }
        let maxSide = max(image.size.width, image.size.height)
        guard maxSide > maxDimension else { return data }
        let scale = maxDimension / maxSide
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.jpegData(compressionQuality: quality) ?? data
    }
}
