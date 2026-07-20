import UIKit

/// すべてのサムネイル画像を、引き伸ばさず固定16:9へ揃える。
enum ThumbnailImageNormalizer {
    static let pixelSize = CGSize(width: 320, height: 180)

    static func normalize(_ image: UIImage) -> UIImage? {
        let sourceSize = image.size
        guard sourceSize.width.isFinite,
              sourceSize.height.isFinite,
              sourceSize.width > 0,
              sourceSize.height > 0 else {
            return nil
        }

        if isCanonical(image) {
            return image
        }

        let scale = max(
            pixelSize.width / sourceSize.width,
            pixelSize.height / sourceSize.height
        )
        let drawSize = CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
        let drawRect = CGRect(
            x: (pixelSize.width - drawSize.width) / 2,
            y: (pixelSize.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: pixelSize, format: format).image { _ in
            image.draw(in: drawRect)
        }
    }

    static func isCanonical(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        return image.imageOrientation == .up
            && cgImage.width == Int(pixelSize.width)
            && cgImage.height == Int(pixelSize.height)
    }
}
