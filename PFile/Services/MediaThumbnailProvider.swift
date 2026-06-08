import AVFoundation
import ImageIO
import Photos
import UIKit

final class MediaThumbnailProvider {
    private let thumbnailService: ThumbnailService
    private let smbClientManager: SMBClientManager

    init(thumbnailService: ThumbnailService, smbClientManager: SMBClientManager) {
        self.thumbnailService = thumbnailService
        self.smbClientManager = smbClientManager
    }

    func thumbnail(for source: ContentSource, item: DirectoryItem) -> UIImage? {
        thumbnailService.thumbnail(for: cacheKey(source: source, item: item))
    }

    func loadThumbnail(
        for source: ContentSource,
        item: DirectoryItem,
        connection: RemoteConnection?
    ) async -> UIImage? {
        let key = cacheKey(source: source, item: item)
        if let cached = thumbnailService.thumbnail(for: key) {
            return cached
        }

        let image: UIImage?
        switch source {
        case .photoLibrary:
            guard let assetID = PhotoAssetItem.assetID(from: item.path) else { return nil }
            image = await loadPhotoThumbnail(assetID: assetID)
        case .localFolder:
            image = await loadLocalThumbnail(path: item.path, isVideo: item.isVideo)
        case .remote:
            guard let connection, item.isVideo else { return nil }
            image = await thumbnailService.generateVideoThumbnail(
                for: item,
                connection: connection,
                smbClientManager: smbClientManager
            )
        }

        if let image {
            thumbnailService.store(image, for: key)
        }
        return image
    }

    func cacheKey(source: ContentSource, item: DirectoryItem) -> String {
        "\(source.id)|\(item.path)"
    }

    private func loadPhotoThumbnail(assetID: String) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
            return nil
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        return await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 400, height: 400),
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                if resumed { return }
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let hasError = info?[PHImageErrorKey] != nil
                let wasCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                if hasError || wasCancelled || !isDegraded {
                    resumed = true
                    continuation.resume(returning: image)
                }
            }
        }
    }

    private func loadLocalThumbnail(path: String, isVideo: Bool) async -> UIImage? {
        let data = await Task.detached(priority: .utility) {
            if isVideo {
                return Self.makeLocalVideoThumbnailData(path: path)
            } else {
                return Self.makeLocalImageThumbnailData(path: path)
            }
        }.value
        guard let data else { return nil }
        return UIImage(data: data)
    }

    private static func makeLocalImageThumbnailData(path: String) -> Data? {
        let url = URL(fileURLWithPath: path) as CFURL
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url, sourceOptions) else { return nil }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: 400,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.8)
    }

    private static func makeLocalVideoThumbnailData(path: String) -> Data? {
        let asset = AVAsset(url: URL(fileURLWithPath: path))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)
        let time = CMTime(seconds: 1, preferredTimescale: 600)
        do {
            let image = try generator.copyCGImage(at: time, actualTime: nil)
            return UIImage(cgImage: image).jpegData(compressionQuality: 0.8)
        } catch {
            return nil
        }
    }
}
