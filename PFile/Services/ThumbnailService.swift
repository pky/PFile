import UIKit
import CryptoKit
import MobileVLCKit

enum ThumbnailGenerationPolicy {
    static let choicePositions: [Float] = [0.04, 0.20, 0.38, 0.56, 0.74, 0.92]
    static let supplementalChoicePositions: [Float] = [0.11, 0.28, 0.47, 0.65, 0.83, 0.97]
    static let maximumChoiceCount = 8

    static let automaticPositions: [Float] = [0.10, 0.20]

}

typealias ThumbnailChoiceProgressHandler = @MainActor (_ candidateCount: Int, _ maximumCount: Int) -> Void

enum ThumbnailImageAnalyzer {
    static func isBlack(_ image: UIImage) -> Bool {
        image.thumbnailCandidate(at: 0).isBlack
    }

    static func isLowInformation(_ image: UIImage) -> Bool {
        image.thumbnailCandidate(at: 0).isLowInformation
    }
}

// MARK: - Protocol

protocol ThumbnailServiceProtocol {
    func clearCache() -> Int
}

extension Notification.Name {
    static let thumbnailCacheDidClear = Notification.Name("thumbnailCacheDidClear")
}

final class ThumbnailCacheClearObserver {
    private var observer: NSObjectProtocol?

    init(onClear: @escaping @MainActor () -> Void) {
        observer = NotificationCenter.default.addObserver(
            forName: .thumbnailCacheDidClear,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                onClear()
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

/// ネットワークファイルのサムネイルを非同期で生成・キャッシュする
final class ThumbnailService: ThumbnailServiceProtocol {

    private let memoryCache = NSCache<NSString, UIImage>()
    private let cacheDir: URL
    @MainActor private var generationWaiters: [String: [CheckedContinuation<UIImage?, Never>]] = [:]
    @MainActor private var activeGenerationCount = 0
    @MainActor private var generationPermitWaiters: [CheckedContinuation<Void, Never>] = []
    // 同一SMBクライアント内のreadは直列化しつつ、別動画は2本まで並行生成する。
    private let maxConcurrentGenerationCount = 2

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
            if shouldDiscardCachedThumbnail(cached, key: key) {
                removeCachedThumbnail(for: key)
                return nil
            }
            return cached
        }
        if let diskImage = loadFromDisk(key: key) {
            if shouldDiscardCachedThumbnail(diskImage, key: key) {
                removeCachedThumbnail(for: key)
                return nil
            }
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

    func clearCache() -> Int {
        let removedFileCount = (try? FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: nil
        ).count) ?? 0
        memoryCache.removeAllObjects()
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        NotificationCenter.default.post(name: .thumbnailCacheDidClear, object: nil)
        print("[ThumbnailService] Thumbnail cache cleared | files: \(removedFileCount)")
        return removedFileCount
    }

    // MARK: - サムネイル生成

    /// 10%地点を取得し、黒または失敗時だけ20%地点を試す
    @MainActor
    func generateVideoThumbnail(
        for item: DirectoryItem,
        connection: RemoteConnection,
        smbClientManager: SMBClientManager
    ) async -> UIImage? {
        let key = cacheKey(connection: connection, item: item)
        if let cached = thumbnail(for: key) { return cached }
        guard !Task.isCancelled else { return nil }

        if generationWaiters[key] != nil {
            return await withCheckedContinuation { continuation in
                generationWaiters[key, default: []].append(continuation)
            }
        }

        generationWaiters[key] = []
        await acquireGenerationPermit()
        let image: UIImage?
        if Task.isCancelled {
            image = nil
        } else {
            image = await generateUncachedVideoThumbnail(
                for: item,
                connection: connection,
                smbClientManager: smbClientManager
            )
            if let image { store(image, for: key) }
        }
        releaseGenerationPermit()

        let waiters = generationWaiters.removeValue(forKey: key) ?? []
        waiters.forEach { $0.resume(returning: image) }
        return image
    }

    @MainActor
    func generateVideoThumbnailChoices(
        for item: DirectoryItem,
        connection: RemoteConnection,
        smbClientManager: SMBClientManager,
        progress: @escaping ThumbnailChoiceProgressHandler = { _, _ in }
    ) async -> [UIImage] {
        guard !Task.isCancelled else { return [] }
        await acquireGenerationPermit()
        let candidates = await generateUncachedVideoThumbnailChoices(
            for: item,
            connection: connection,
            smbClientManager: smbClientManager,
            progress: progress
        )
        releaseGenerationPermit()
        return candidates
            .filter { !$0.isBlack }
            .sorted { $0.position < $1.position }
            .prefix(ThumbnailGenerationPolicy.maximumChoiceCount)
            .map(\.image)
    }

    @MainActor
    private func acquireGenerationPermit() async {
        if activeGenerationCount < maxConcurrentGenerationCount {
            activeGenerationCount += 1
#if DEBUG
            print("[ThumbnailService] Generation started | active: \(activeGenerationCount)")
#endif
            return
        }

        await withCheckedContinuation { continuation in
            generationPermitWaiters.append(continuation)
        }
#if DEBUG
        print("[ThumbnailService] Queued generation started | active: \(activeGenerationCount)")
#endif
    }

    @MainActor
    private func releaseGenerationPermit() {
        if generationPermitWaiters.isEmpty {
            activeGenerationCount = max(0, activeGenerationCount - 1)
        } else {
            generationPermitWaiters.removeFirst().resume()
        }
#if DEBUG
        print("[ThumbnailService] Generation finished | active: \(activeGenerationCount) | queued: \(generationPermitWaiters.count)")
#endif
    }

    @MainActor
    private func generateUncachedVideoThumbnail(
        for item: DirectoryItem,
        connection: RemoteConnection,
        smbClientManager: SMBClientManager
    ) async -> UIImage? {
        return await generateUsingAvailableMedia(
            for: item,
            connection: connection,
            smbClientManager: smbClientManager
        ) { media in
            for position in ThumbnailGenerationPolicy.automaticPositions {
                guard let image = await VLCThumbnailFetcher().fetch(
                    media: media,
                    position: position
                ), !ThumbnailImageAnalyzer.isBlack(image) else {
                    continue
                }
                return image
            }
            return nil
        }
    }

    @MainActor
    private func generateUncachedVideoThumbnailChoices(
        for item: DirectoryItem,
        connection: RemoteConnection,
        smbClientManager: SMBClientManager,
        progress: @escaping ThumbnailChoiceProgressHandler
    ) async -> [ThumbnailCandidate] {
        progress(0, ThumbnailGenerationPolicy.maximumChoiceCount)
        return await generateUsingAvailableMedia(
            for: item,
            connection: connection,
            smbClientManager: smbClientManager
        ) { media in
            let candidates = await self.fetchVideoCandidates(media: media) { candidateCount in
                progress(candidateCount, ThumbnailGenerationPolicy.maximumChoiceCount)
            }
            return candidates.isEmpty ? nil : candidates
        } ?? []
    }

    @MainActor
    private func generateUsingAvailableMedia<Result>(
        for item: DirectoryItem,
        connection: RemoteConnection,
        smbClientManager: SMBClientManager,
        operation: (VLCMedia) async -> Result?
    ) async -> Result? {

#if !targetEnvironment(simulator)
        // 実機: SMBStreamingServer（AMSMB2）経由でHTTP URLを使用。
        // VLCKit の SMB クライアントでは NFD/NFC 不一致によるエラーが起きるため、
        // SMBStreamingServer の resolveFilePath で正しいパスを自動判定する。
        guard let credential = try? smbClientManager.loadCredential(for: connection) else { return nil }
        func generateDirect() async -> Result? {
            guard !Task.isCancelled,
                  let directURL = buildSMBURL(
                    for: connection,
                    path: item.path,
                    smbClientManager: smbClientManager
                  ) else { return nil }
            let directMedia = VLCMedia(url: directURL)
            directMedia.addOption(":network-caching=300")
            directMedia.addOption(":smb-caching=300")
            directMedia.addOption(":file-caching=300")
            directMedia.addOption(":input-fast-seek")
            if !credential.username.isEmpty {
                directMedia.addOption(":smb-user=\(credential.username)")
            }
            if !credential.password.isEmpty {
                directMedia.addOption(":smb-pwd=\(credential.password)")
            }
            return await operation(directMedia)
        }

        guard let dedicatedClient = try? smbClientManager.makeDedicatedClient(for: connection) else {
            return await generateDirect()
        }
        let shareName = (credential.shareName.isEmpty || credential.shareName == "/") ? "" : credential.shareName
        let server = SMBStreamingServer(ownerID: "thumbnail-\(item.path)")
        do {
            try await SMB2OperationGate.runAsync {
                try await dedicatedClient.connectShare(name: shareName)
            }
            // AMSMB2はタイムアウト後もlibsmb2側のコールバックが残り、
            // 解放済みの待機データを参照するため、接続後のreadはタイムアウトさせない。
            dedicatedClient.timeout = 0
            try await server.start(client: dedicatedClient, filePath: item.path, fileSize: item.size)
        } catch {
            print("[ThumbnailService] Failed to start streaming server: \(error)")
            server.stop()
            return await generateDirect()
        }
        guard let localURL = server.localURL else {
            server.stop()
            return await generateDirect()
        }
        defer { server.stop() }
        let proxyMedia = VLCMedia(url: localURL)
        if let proxyResult = await operation(proxyMedia) {
            return proxyResult
        }

        // 再生できるのにHTTPプロキシ経路だけ失敗する形式は、再生側と同じdirect SMBを試す。
        server.stop()
        return await generateDirect()
#else
        // シミュレーター: 直接 SMB URL（AMSMB2 は実機専用のため）
        guard let url = buildSMBURL(for: connection, path: item.path, smbClientManager: smbClientManager) else {
            return nil
        }
        let media = VLCMedia(url: url)
        return await operation(media)
#endif
    }

    @MainActor
    private func fetchVideoCandidates(
        media: VLCMedia,
        progress: @escaping @MainActor (_ candidateCount: Int) -> Void
    ) async -> [ThumbnailCandidate] {
        var candidates = await fetchCandidates(
            media: media,
            positions: ThumbnailGenerationPolicy.choicePositions,
            progress: progress
        )
        if Self.visuallyDistinctCandidates(candidates).count
            < ThumbnailGenerationPolicy.maximumChoiceCount {
            let supplementalCandidates = await fetchCandidates(
                media: media,
                positions: ThumbnailGenerationPolicy.supplementalChoicePositions,
                existingCandidates: candidates,
                maximumDistinctCandidateCount: ThumbnailGenerationPolicy.maximumChoiceCount,
                progress: progress
            )
            candidates += supplementalCandidates
        }
        return Self.visuallyDistinctCandidates(candidates)
    }

    @MainActor
    private func fetchCandidates(
        media: VLCMedia,
        positions: [Float],
        existingCandidates: [ThumbnailCandidate] = [],
        maximumDistinctCandidateCount: Int? = nil,
        progress: @escaping @MainActor (_ candidateCount: Int) -> Void
    ) async -> [ThumbnailCandidate] {
        var candidates: [ThumbnailCandidate] = []
        for position in positions {
            guard !Task.isCancelled else { return candidates }
            let candidate = await VLCThumbnailFetcher().fetch(media: media, position: position)
            guard !Task.isCancelled else { return candidates }
            if let candidate {
                let thumbnailCandidate = candidate.thumbnailCandidate(at: position)
                candidates.append(thumbnailCandidate)
                let distinctCandidateCount = Self.visuallyDistinctCandidates(
                    existingCandidates + candidates
                ).count
                progress(distinctCandidateCount)
                if let maximumDistinctCandidateCount,
                   distinctCandidateCount >= maximumDistinctCandidateCount {
                    return candidates
                }
            }
        }
        return candidates
    }

    private static func visuallyDistinctCandidates(
        _ candidates: [ThumbnailCandidate]
    ) -> [ThumbnailCandidate] {
        var result: [ThumbnailCandidate] = []
        for candidate in candidates where !candidate.isBlack && !candidate.isLowInformation {
            guard !result.contains(where: { candidate.isVisuallySimilar(to: $0) }) else { continue }
            result.append(candidate)
        }
        return result
    }

    // MARK: - キー生成

    static func remoteVideoCacheKey(connectionID: UUID, itemPath: String) -> String {
        "remote-video-v2|remote:\(connectionID.uuidString)|\(itemPath)"
    }

    func cacheKey(connection: RemoteConnection, item: DirectoryItem) -> String {
        Self.remoteVideoCacheKey(connectionID: connection.id, itemPath: item.path)
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

    private func shouldDiscardCachedThumbnail(_ image: UIImage, key: String) -> Bool {
        key.hasPrefix("remote-video-v2|") && ThumbnailImageAnalyzer.isBlack(image)
    }

    private func removeCachedThumbnail(for key: String) {
        memoryCache.removeObject(forKey: key as NSString)
        try? FileManager.default.removeItem(at: diskURL(for: key))
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

// MARK: - サムネイル品質判定

private struct ThumbnailCandidate {
    let image: UIImage
    let position: Float
    let brightness: CGFloat
    let darkPixelRatio: CGFloat
    let upperDecileBrightness: CGFloat
    let brightnessRange: CGFloat
    let visualSignature: [UInt8]

    var isBlack: Bool {
        brightness < 0.12
            || darkPixelRatio > 0.62
            || upperDecileBrightness < 0.22
            || (brightness < 0.20 && darkPixelRatio > 0.45)
    }

    var isLowInformation: Bool {
        brightnessRange < 0.04
    }

    func isVisuallySimilar(to other: ThumbnailCandidate) -> Bool {
        guard visualSignature.count == other.visualSignature.count,
              !visualSignature.isEmpty else { return false }
        let totalDifference = zip(visualSignature, other.visualSignature).reduce(0) {
            $0 + abs(Int($1.0) - Int($1.1))
        }
        let normalizedDifference = CGFloat(totalDifference)
            / CGFloat(visualSignature.count * 255)
        return normalizedDifference < 0.05
    }
}

private extension UIImage {
    func thumbnailCandidate(at position: Float) -> ThumbnailCandidate {
        let metrics = thumbnailImageMetrics()
        return ThumbnailCandidate(
            image: self,
            position: position,
            brightness: metrics.brightness,
            darkPixelRatio: metrics.darkPixelRatio,
            upperDecileBrightness: metrics.upperDecileBrightness,
            brightnessRange: metrics.brightnessRange,
            visualSignature: metrics.visualSignature
        )
    }

    private func thumbnailImageMetrics() -> (
        brightness: CGFloat,
        darkPixelRatio: CGFloat,
        upperDecileBrightness: CGFloat,
        brightnessRange: CGFloat,
        visualSignature: [UInt8]
    ) {
        let w = 24, h = 24
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cg = cgImage else {
            return (0, 1, 0, 0, [])
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var brightnessValues: [CGFloat] = []
        brightnessValues.reserveCapacity(w * h)
        var brightnessTotal: CGFloat = 0
        var darkPixelCount: CGFloat = 0
        for i in 0..<(w * h) {
            let o = i * 4
            let r = CGFloat(pixels[o]) / 255
            let g = CGFloat(pixels[o + 1]) / 255
            let b = CGFloat(pixels[o + 2]) / 255
            let brightness = (r + g + b) / 3
            brightnessValues.append(brightness)
            brightnessTotal += brightness
            if brightness < 0.12 { darkPixelCount += 1 }
        }

        let count = CGFloat(w * h)
        let averageBrightness = brightnessTotal / count
        let sortedBrightnessValues = brightnessValues.sorted()
        let upperDecileIndex = min(Int(count * 0.9), sortedBrightnessValues.count - 1)
        let upperDecileBrightness = sortedBrightnessValues[upperDecileIndex]
        let lowerDecileIndex = min(Int(count * 0.1), sortedBrightnessValues.count - 1)
        let brightnessRange = upperDecileBrightness - sortedBrightnessValues[lowerDecileIndex]
        var visualSignature: [UInt8] = []
        visualSignature.reserveCapacity(64)
        for y in 0..<8 {
            for x in 0..<8 {
                var total: CGFloat = 0
                for sampleY in 0..<3 {
                    for sampleX in 0..<3 {
                        let pixelX = x * 3 + sampleX
                        let pixelY = y * 3 + sampleY
                        total += brightnessValues[pixelY * w + pixelX]
                    }
                }
                visualSignature.append(UInt8(clamping: Int(total / 9 * 255)))
            }
        }
        return (
            averageBrightness,
            darkPixelCount / count,
            upperDecileBrightness,
            brightnessRange,
            visualSignature
        )
    }
}

// MARK: - VLCThumbnailFetcher

@MainActor
private final class VLCThumbnailFetcher: NSObject {

    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var thumbnailer: VLCMediaThumbnailer?
    private var timeoutTask: Task<Void, Never>?
    private var done = false

    func fetch(media: VLCMedia, position: Float) async -> UIImage? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
                self.continuation = continuation
                let t = VLCMediaThumbnailer(media: media, andDelegate: self)
                self.thumbnailer = t
                t.snapshotPosition = position
                t.thumbnailWidth = 320
                t.thumbnailHeight = 180
                t.fetchThumbnail()
                timeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(9))
                    } catch {
                        return
                    }
                    self?.resume(with: nil)
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.resume(with: nil)
            }
        }
    }

    private func resume(with image: UIImage?) {
        guard !done else { return }
        done = true
        timeoutTask?.cancel()
        timeoutTask = nil
        thumbnailer?.delegate = nil
        thumbnailer = nil
        let c = continuation
        continuation = nil
        c?.resume(returning: image)
    }
}

extension VLCThumbnailFetcher: VLCMediaThumbnailerDelegate {

    nonisolated func mediaThumbnailerDidTimeOut(_ mediaThumbnailer: VLCMediaThumbnailer) {
        Task { @MainActor [weak self] in
            self?.resume(with: nil)
        }
    }

    nonisolated func mediaThumbnailer(
        _ mediaThumbnailer: VLCMediaThumbnailer,
        didFinishThumbnail thumbnail: CGImage
    ) {
        let image = UIImage(cgImage: thumbnail)
        Task { @MainActor [weak self] in
            self?.resume(with: image)
        }
    }
}
