import UIKit
import CryptoKit
import MobileVLCKit

// MARK: - Protocol

protocol ThumbnailServiceProtocol {
    func clearCache()
}

/// ネットワークファイルのサムネイルを非同期で生成・キャッシュする
final class ThumbnailService: ThumbnailServiceProtocol {

    private let memoryCache = NSCache<NSString, UIImage>()
    private let cacheDir: URL

    init() {
        memoryCache.countLimit = 500
        memoryCache.totalCostLimit = 50 * 1024 * 1024

        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = base.appendingPathComponent("thumbnails")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.memoryCache.removeAllObjects()
        }
    }

    // MARK: - キャッシュアクセス

    func thumbnail(for key: String) -> UIImage? {
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }
        if let diskImage = loadFromDisk(key: key) {
            store(diskImage, for: key)
            return diskImage
        }
        return nil
    }

    func store(_ image: UIImage, for key: String) {
        let cost = Int(image.size.width * image.size.height * 4)
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)
        saveToDisk(image, key: key)
    }

    func clearCache() {
        memoryCache.removeAllObjects()
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - サムネイル生成

    /// 動画ファイルのサムネイルを VLCMediaThumbnailer で生成する
    /// サムネイルが黒一色の場合、再生位置を変えて最大3回まで再試行する
    @MainActor
    func generateVideoThumbnail(
        for item: DirectoryItem,
        connection: RemoteConnection,
        smbClientManager: SMBClientManager
    ) async -> UIImage? {
        let key = cacheKey(connection: connection, item: item)
        if let cached = thumbnail(for: key) { return cached }

        let positions: [Float] = [0.1, 0.3, 0.5]

#if !targetEnvironment(simulator)
        // 実機: SMBStreamingServer（AMSMB2）経由でHTTP URLを使用。
        // VLCKit の SMB クライアントでは NFD/NFC 不一致によるエラーが起きるため、
        // SMBStreamingServer の resolveFilePath で正しいパスを自動判定する。
        guard let credential = try? smbClientManager.loadCredential(for: connection),
              let dedicatedClient = try? smbClientManager.makeDedicatedClient(for: connection) else {
            return nil
        }
        let shareName = (credential.shareName.isEmpty || credential.shareName == "/") ? "" : credential.shareName
        let server = SMBStreamingServer(ownerID: "thumbnail-\(item.path)")
        do {
            try await dedicatedClient.connectShare(name: shareName)
            try await server.start(client: dedicatedClient, filePath: item.path, fileSize: item.size)
        } catch {
            print("[ThumbnailService] Failed to start streaming server: \(error)")
            server.stop()
            return nil
        }
        guard let localURL = server.localURL else { server.stop(); return nil }
        let media = VLCMedia(url: localURL)
        var image: UIImage?
        for position in positions {
            let candidate = await VLCThumbnailFetcher().fetch(media: media, position: position)
            if let candidate {
                if !candidate.isNearlyBlack() { image = candidate; break }
                if image == nil { image = candidate }
            }
        }
        server.stop()
#else
        // シミュレーター: 直接 SMB URL（AMSMB2 は実機専用のため）
        guard let url = buildSMBURL(for: connection, path: item.path, smbClientManager: smbClientManager) else {
            return nil
        }
        let media = VLCMedia(url: url)
        var image: UIImage?
        for position in positions {
            let candidate = await VLCThumbnailFetcher().fetch(media: media, position: position)
            if let candidate {
                if !candidate.isNearlyBlack() { image = candidate; break }
                if image == nil { image = candidate }
            }
        }
#endif

        if let image { store(image, for: key) }
        return image
    }

    // MARK: - キー生成

    func cacheKey(connection: RemoteConnection, item: DirectoryItem) -> String {
        "\(connection.id.uuidString)/\(item.path)"
    }

    // MARK: - Disk Cache

    private func diskURL(for key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent(hash + ".jpg")
    }

    private func loadFromDisk(key: String) -> UIImage? {
        let url = diskURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    private func saveToDisk(_ image: UIImage, key: String) {
        guard let data = image.jpegData(compressionQuality: 0.7) else { return }
        let url = diskURL(for: key)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - SMB URL 構築

    private func buildSMBURL(
        for connection: RemoteConnection,
        path: String,
        smbClientManager: SMBClientManager
    ) -> URL? {
        guard let credential = try? smbClientManager.loadCredential(for: connection),
              let host = connection.host else { return nil }
        var components = URLComponents()
        components.scheme = "smb"
        if !credential.username.isEmpty { components.user = credential.username }
        if !credential.password.isEmpty { components.password = credential.password }
        components.host = host
        if let port = connection.port, port != 445 { components.port = port }
        let share = (credential.shareName.isEmpty || credential.shareName == "/")
            ? "" : "/\(credential.shareName)"
        // NFD→NFC 正規化: iOS String の NFD に対し Samba (NFC保存) が OBJECT_NAME_NOT_FOUND を返すのを防ぐ
        components.path = "\(share)\(path)".precomposedStringWithCanonicalMapping
        return components.url
    }
}

// MARK: - UIImage 黒判定

private extension UIImage {
    /// ほぼ黒一色の画像かどうかを判定する（平均輝度が threshold 未満なら true）
    func isNearlyBlack(threshold: CGFloat = 0.05) -> Bool {
        let w = 8, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cg = cgImage else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var total: CGFloat = 0
        for i in 0..<(w * h) {
            let o = i * 4
            total += (CGFloat(pixels[o]) + CGFloat(pixels[o+1]) + CGFloat(pixels[o+2])) / (3 * 255)
        }
        return (total / CGFloat(w * h)) < threshold
    }
}

// MARK: - VLCThumbnailFetcher

@MainActor
private final class VLCThumbnailFetcher: NSObject, VLCMediaThumbnailerDelegate {

    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var thumbnailer: VLCMediaThumbnailer?
    private var done = false

    func fetch(media: VLCMedia, position: Float) async -> UIImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            self.continuation = continuation
            let t = VLCMediaThumbnailer(media: media, andDelegate: self)
            self.thumbnailer = t
            t.snapshotPosition = position
            t.thumbnailWidth = 320
            t.thumbnailHeight = 180
            t.fetchThumbnail()
        }
    }

    func mediaThumbnailerDidTimeOut(_ mediaThumbnailer: VLCMediaThumbnailer) {
        resume(with: nil)
    }

    func mediaThumbnailer(_ mediaThumbnailer: VLCMediaThumbnailer, didFinishThumbnail thumbnail: CGImage) {
        resume(with: UIImage(cgImage: thumbnail))
    }

    private func resume(with image: UIImage?) {
        guard !done else { return }
        done = true
        thumbnailer = nil
        let c = continuation
        continuation = nil
        c?.resume(returning: image)
    }
}
