import UIKit
import CryptoKit
import MobileVLCKit

enum ThumbnailGenerationPolicy {
    static let choicePositions: [Float] = [0.04, 0.20, 0.38, 0.56, 0.74, 0.92]
    static let supplementalChoicePositions: [Float] = [0.11, 0.28, 0.47, 0.65, 0.83, 0.97]
    static let maximumChoiceCount = 8
    static let maximumConsecutiveChoiceFailures = 2

    static let automaticPositions: [Float] = [0.10, 0.20, 0.50]
    /// 通常地点が黒画面・タイムアウトだった動画だけに使う追加候補。
    /// 手動候補で取得できる動画を、自動生成でも取りこぼさないためのもの。
    static let automaticFallbackPositions: [Float] = [0.04, 0.38, 0.56, 0.74, 0.92]

    static func shouldIncludeChoice(isBlack: Bool) -> Bool {
        !isBlack
    }

    static func shouldStopChoiceSearch(consecutiveFailures: Int) -> Bool {
        consecutiveFailures >= maximumConsecutiveChoiceFailures
    }
}

typealias ThumbnailChoiceProgressHandler = @MainActor (_ candidateCount: Int, _ maximumCount: Int) -> Void

private enum AutomaticThumbnailAttempt {
    case accepted(UIImage)
    case framesRejected

    var image: UIImage? {
        guard case .accepted(let image) = self else { return nil }
        return image
    }
}

@MainActor
final class ThumbnailGenerationLimiter {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let limit: Int
    private var waiters: [Waiter] = []
    private(set) var activeCount = 0

    var queuedCount: Int { waiters.count }

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if activeCount < limit {
            activeCount += 1
            return true
        }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(id: id)
            }
        }
    }

    func release() {
        if waiters.isEmpty {
            activeCount = max(0, activeCount - 1)
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

enum ThumbnailImageAnalyzer {
    static func isBlack(_ image: UIImage) -> Bool {
        image.thumbnailCandidate(at: 0).isBlack
    }

    static func isLowInformation(_ image: UIImage) -> Bool {
        image.thumbnailCandidate(at: 0).isLowInformation
    }

    static func areVisuallySimilar(_ lhs: UIImage, _ rhs: UIImage) -> Bool {
        lhs.thumbnailCandidate(at: 0).isVisuallySimilar(to: rhs.thumbnailCandidate(at: 0))
    }
}

// MARK: - Protocol

protocol ThumbnailServiceProtocol {
    func clearCache() -> Int
}

extension Notification.Name {
    static let thumbnailCacheDidClear = Notification.Name("thumbnailCacheDidClear")
    /// ユーザーが選び直したサムネイルを、同じキーを表示中の全画面へ伝える
    static let thumbnailDidUpdate = Notification.Name("thumbnailDidUpdate")
}

/// 選び直したサムネイルを受け取り、表示中の画面が持つ表示用キャッシュを差し替える。
/// ブラウズ・リスト・視聴履歴が別々に持つ表示用キャッシュを、保存先と同じ 1 つの状態に揃える。
final class ThumbnailUpdateObserver {
    static let keyUserInfoKey = "key"
    static let imageUserInfoKey = "image"

    private var observer: NSObjectProtocol?

    init(onUpdate: @escaping @MainActor (_ key: String, _ image: UIImage) -> Void) {
        observer = NotificationCenter.default.addObserver(
            forName: .thumbnailDidUpdate,
            object: nil,
            queue: nil
        ) { notification in
            guard let key = notification.userInfo?[Self.keyUserInfoKey] as? String,
                  let image = notification.userInfo?[Self.imageUserInfoKey] as? UIImage else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated { onUpdate(key, image) }
            } else {
                Task { @MainActor in onUpdate(key, image) }
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
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

    private struct GenerationResultWaiter {
        let id: UUID
        let continuation: CheckedContinuation<UIImage?, Never>
    }

    private struct CandidateFetchResult {
        let candidates: [ThumbnailCandidate]
        let stoppedAfterConsecutiveFailures: Bool
    }

    private let memoryCache = NSCache<NSString, UIImage>()
    private let cacheDir: URL
    private let diskQueue = DispatchQueue(label: "jp.pky.pfile.thumbnail-disk", qos: .utility)
    @MainActor private var generationWaiters: [String: [GenerationResultWaiter]] = [:]
    // 同一SMBクライアント内のreadは直列化しつつ、別動画は2本まで並行生成する。
    @MainActor private let generationLimiter = ThumbnailGenerationLimiter(limit: 2)

    init() {
        memoryCache.countLimit = 500
        memoryCache.totalCostLimit = 50 * 1024 * 1024

        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = base.appendingPathComponent("thumbnails-v4")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // v3以前はパスをキーにしていたため、ファイル移動後に参照不能な画像が残る。
        // v4ではfileIdを優先するので、旧領域は移行せず一度だけ破棄して再生成する。
        let legacyCacheDir = base.appendingPathComponent("thumbnails")
        diskQueue.async {
            try? FileManager.default.removeItem(at: legacyCacheDir)
        }

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
        guard let cached = memoryCache.object(forKey: key as NSString) else { return nil }
        if !ThumbnailImageNormalizer.isCanonical(cached) {
            removeCachedThumbnail(for: key)
            return nil
        }
        return cached
    }

    func loadCachedThumbnail(for key: String) async -> UIImage? {
        if let cached = thumbnail(for: key) { return cached }
        let url = diskURL(for: key)
        let image: UIImage? = await withCheckedContinuation { continuation in
            diskQueue.async {
                guard let data = try? Data(contentsOf: url),
                      let image = UIImage(data: data),
                      Self.isValidStoredThumbnail(image, key: key) else {
                    try? FileManager.default.removeItem(at: url)
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: image)
            }
        }
        guard let image else { return nil }
        let cost = Int(image.size.width * image.size.height * 4)
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)
        return image
    }

    @discardableResult
    func store(_ image: UIImage, for key: String) -> UIImage? {
        guard let normalized = ThumbnailImageNormalizer.normalize(image),
              Self.isValidStoredThumbnail(normalized, key: key) else { return nil }
        let cost = Int(normalized.size.width * normalized.size.height * 4)
        memoryCache.setObject(normalized, forKey: key as NSString, cost: cost)
        saveToDiskAsync(normalized, key: key)
        NotificationCenter.default.post(
            name: .thumbnailDidUpdate,
            object: nil,
            userInfo: [
                ThumbnailUpdateObserver.keyUserInfoKey: key,
                ThumbnailUpdateObserver.imageUserInfoKey: normalized,
            ]
        )
        return normalized
    }

    func storeAsync(_ image: UIImage, for key: String) async -> UIImage? {
        let normalized: UIImage? = await withCheckedContinuation { continuation in
            diskQueue.async {
                guard let normalized = ThumbnailImageNormalizer.normalize(image),
                      Self.isValidStoredThumbnail(normalized, key: key) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: normalized)
            }
        }
        guard let normalized else { return nil }
        let cost = Int(normalized.size.width * normalized.size.height * 4)
        memoryCache.setObject(normalized, forKey: key as NSString, cost: cost)
        saveToDiskAsync(normalized, key: key)
        return normalized
    }

    func clearCache() -> Int {
        memoryCache.removeAllObjects()
        let removedFileCount = diskQueue.sync {
            let count = (try? FileManager.default.contentsOfDirectory(
                at: cacheDir,
                includingPropertiesForKeys: nil
            ).count) ?? 0
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            return count
        }
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
        let mediaID = MediaDiagnostics.mediaID(
            sourceID: "remote:\(connection.id.uuidString)",
            path: item.path
        )
        if let cached = thumbnail(for: key) {
            MediaDiagnostics.thumbnail("event=cache_hit mediaID=\(mediaID)")
            return cached
        }
        if let cached = await loadCachedThumbnail(for: key) {
            MediaDiagnostics.thumbnail("event=disk_cache_hit mediaID=\(mediaID)")
            return cached
        }
        guard !Task.isCancelled else { return nil }

        if generationWaiters[key] != nil {
            return await waitForInFlightGeneration(for: key)
        }

        generationWaiters[key] = []
        let interval = MediaDiagnostics.begin("ThumbnailGeneration", mediaID: mediaID)
        MediaDiagnostics.thumbnail("event=generation_begin mediaID=\(mediaID)")
        guard await acquireGenerationPermit() else {
            let waiters = generationWaiters.removeValue(forKey: key) ?? []
            waiters.forEach { $0.continuation.resume(returning: nil) }
            MediaDiagnostics.thumbnail("event=generation_end mediaID=\(mediaID) result=cancelled")
            MediaDiagnostics.end(interval, mediaID: mediaID, result: "cancelled")
            return nil
        }
        defer { releaseGenerationPermit() }
        let image: UIImage?
        if Task.isCancelled {
            image = nil
        } else {
            let generated = await generateUncachedVideoThumbnail(
                for: item,
                connection: connection,
                smbClientManager: smbClientManager
            )
            if let generated {
                image = await storeAsync(generated, for: key)
            } else {
                image = nil
            }
        }
        let result = image == nil ? "failed" : "success"
        MediaDiagnostics.thumbnail("event=generation_end mediaID=\(mediaID) result=\(result)")
        MediaDiagnostics.end(interval, mediaID: mediaID, result: result)

        let waiters = generationWaiters.removeValue(forKey: key) ?? []
        waiters.forEach { $0.continuation.resume(returning: image) }
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
        guard await acquireGenerationPermit() else { return [] }
        defer { releaseGenerationPermit() }
        guard !Task.isCancelled else { return [] }
        let candidates = await generateUncachedVideoThumbnailChoices(
            for: item,
            connection: connection,
            smbClientManager: smbClientManager,
            progress: progress
        )
        return candidates
            .filter { !$0.isBlack }
            .sorted { $0.position < $1.position }
            .prefix(ThumbnailGenerationPolicy.maximumChoiceCount)
            .map(\.image)
    }

    /// ユーザーが指定した動画位置のプレビューを取得する。保存は選択確定時だけ行う。
    @MainActor
    func generateVideoThumbnailPreview(
        for item: DirectoryItem,
        connection: RemoteConnection,
        smbClientManager: SMBClientManager,
        position: Float
    ) async -> UIImage? {
        guard !Task.isCancelled,
              await acquireGenerationPermit() else { return nil }
        defer { releaseGenerationPermit() }

        let mediaID = MediaDiagnostics.mediaID(
            sourceID: "remote:\(connection.id.uuidString)",
            path: item.path
        )
        let clampedPosition = min(max(position, 0), 1)
        return await generateUsingAvailableMedia(
            for: item,
            connection: connection,
            smbClientManager: smbClientManager
        ) { media in
            guard let image = await VLCThumbnailFetcher().fetch(
                media: media,
                position: clampedPosition,
                mediaID: mediaID
            ), !ThumbnailImageAnalyzer.isBlack(image) else {
                return nil
            }
            return image
        }
    }

    @MainActor
    private func acquireGenerationPermit() async -> Bool {
        let acquired = await generationLimiter.acquire()
#if DEBUG
        MediaDiagnostics.performance(
            "event=thumbnail_slot_\(acquired ? "acquired" : "cancelled") active=\(generationLimiter.activeCount) queued=\(generationLimiter.queuedCount)"
        )
#endif
        return acquired
    }

    @MainActor
    private func releaseGenerationPermit() {
        generationLimiter.release()
#if DEBUG
        MediaDiagnostics.performance(
            "event=thumbnail_slot_released active=\(generationLimiter.activeCount) queued=\(generationLimiter.queuedCount)"
        )
#endif
    }

    @MainActor
    private func waitForInFlightGeneration(for key: String) async -> UIImage? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                guard generationWaiters[key] != nil else {
                    continuation.resume(returning: thumbnail(for: key))
                    return
                }
                generationWaiters[key, default: []].append(
                    GenerationResultWaiter(id: id, continuation: continuation)
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelGenerationResultWaiter(key: key, id: id)
            }
        }
    }

    @MainActor
    private func cancelGenerationResultWaiter(key: String, id: UUID) {
        guard let index = generationWaiters[key]?.firstIndex(where: { $0.id == id }),
              let waiter = generationWaiters[key]?.remove(at: index) else { return }
        waiter.continuation.resume(returning: nil)
    }

    @MainActor
    private func generateUncachedVideoThumbnail(
        for item: DirectoryItem,
        connection: RemoteConnection,
        smbClientManager: SMBClientManager
    ) async -> UIImage? {
        let mediaID = MediaDiagnostics.mediaID(
            sourceID: "remote:\(connection.id.uuidString)",
            path: item.path
        )
        let attempt: AutomaticThumbnailAttempt? = await generateUsingAvailableMedia(
            for: item,
            connection: connection,
            smbClientManager: smbClientManager
        ) { media in
            var didReceiveFrame = false
            var consecutiveFetchFailures = 0
            for position in ThumbnailGenerationPolicy.automaticPositions
                + ThumbnailGenerationPolicy.automaticFallbackPositions {
                guard let image = await VLCThumbnailFetcher().fetch(
                    media: media,
                    position: position,
                    mediaID: mediaID
                ) else {
                    consecutiveFetchFailures += 1
                    // 到達不能な動画で全候補を9秒ずつ待たないよう、連続失敗は早期終了する。
                    if ThumbnailGenerationPolicy.shouldStopChoiceSearch(
                        consecutiveFailures: consecutiveFetchFailures
                    ) {
                        break
                    }
                    continue
                }
                didReceiveFrame = true
                consecutiveFetchFailures = 0
                guard !ThumbnailImageAnalyzer.isBlack(image) else {
                    MediaDiagnostics.thumbnail(
                        "event=frame_rejected mediaID=\(mediaID) position=\(position) reason=black"
                    )
                    continue
                }
                return .accepted(image)
            }
            return didReceiveFrame ? .framesRejected : nil
        }
        return attempt?.image
    }

    @MainActor
    private func generateUncachedVideoThumbnailChoices(
        for item: DirectoryItem,
        connection: RemoteConnection,
        smbClientManager: SMBClientManager,
        progress: @escaping ThumbnailChoiceProgressHandler
    ) async -> [ThumbnailCandidate] {
        let mediaID = MediaDiagnostics.mediaID(
            sourceID: "remote:\(connection.id.uuidString)",
            path: item.path
        )
        progress(0, ThumbnailGenerationPolicy.maximumChoiceCount)
        return await generateUsingAvailableMedia(
            for: item,
            connection: connection,
            smbClientManager: smbClientManager
        ) { media in
            let candidates = await self.fetchVideoCandidates(
                media: media,
                mediaID: mediaID
            ) { candidateCount in
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

        let mediaID = MediaDiagnostics.mediaID(
            sourceID: "remote:\(connection.id.uuidString)",
            path: item.path
        )

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
            MediaDiagnostics.thumbnail("event=route_begin mediaID=\(mediaID) route=vlc_direct_smb")
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
        let server = SMBStreamingServer(ownerID: "thumbnail-\(mediaID)")
        do {
            try await SMB2OperationGate.runAsync {
                try await dedicatedClient.connectShare(name: shareName)
            }
            // AMSMB2はタイムアウト後もlibsmb2側のコールバックが残り、
            // 解放済みの待機データを参照するため、接続後のreadはタイムアウトさせない。
            dedicatedClient.timeout = 0
            try await server.start(client: dedicatedClient, filePath: item.path, fileSize: item.size)
        } catch {
            MediaDiagnostics.thumbnail(
                "event=route_failed mediaID=\(mediaID) route=http_proxy \(MediaDiagnostics.errorCode(error))"
            )
            server.stop()
            return await generateDirect()
        }
        guard let localURL = server.localURL else {
            server.stop()
            return await generateDirect()
        }
        defer { server.stop() }
        MediaDiagnostics.thumbnail("event=route_begin mediaID=\(mediaID) route=http_proxy")
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
        mediaID: String,
        progress: @escaping @MainActor (_ candidateCount: Int) -> Void
    ) async -> [ThumbnailCandidate] {
        let initialResult = await fetchCandidates(
            media: media,
            positions: ThumbnailGenerationPolicy.choicePositions,
            mediaID: mediaID,
            progress: progress
        )
        var candidates = initialResult.candidates
        if !initialResult.stoppedAfterConsecutiveFailures,
           Self.visuallyDistinctCandidates(candidates).count
            < ThumbnailGenerationPolicy.maximumChoiceCount {
            let supplementalResult = await fetchCandidates(
                media: media,
                positions: ThumbnailGenerationPolicy.supplementalChoicePositions,
                mediaID: mediaID,
                existingCandidates: candidates,
                maximumDistinctCandidateCount: ThumbnailGenerationPolicy.maximumChoiceCount,
                progress: progress
            )
            candidates += supplementalResult.candidates
        }
        return Self.visuallyDistinctCandidates(candidates)
    }

    @MainActor
    private func fetchCandidates(
        media: VLCMedia,
        positions: [Float],
        mediaID: String,
        existingCandidates: [ThumbnailCandidate] = [],
        maximumDistinctCandidateCount: Int? = nil,
        progress: @escaping @MainActor (_ candidateCount: Int) -> Void
    ) async -> CandidateFetchResult {
        var candidates: [ThumbnailCandidate] = []
        var consecutiveFailures = 0
        for position in positions {
            guard !Task.isCancelled else {
                return CandidateFetchResult(
                    candidates: candidates,
                    stoppedAfterConsecutiveFailures: true
                )
            }
            let candidate = await VLCThumbnailFetcher().fetch(
                media: media,
                position: position,
                mediaID: mediaID
            )
            guard !Task.isCancelled else {
                return CandidateFetchResult(
                    candidates: candidates,
                    stoppedAfterConsecutiveFailures: true
                )
            }
            guard let candidate else {
                consecutiveFailures += 1
                MediaDiagnostics.thumbnail(
                    "event=choice_frame_failed mediaID=\(mediaID) position=\(position) consecutiveFailures=\(consecutiveFailures)"
                )
                if ThumbnailGenerationPolicy.shouldStopChoiceSearch(
                    consecutiveFailures: consecutiveFailures
                ) {
                    MediaDiagnostics.thumbnail(
                        "event=choice_search_stopped mediaID=\(mediaID) reason=consecutive_failures candidates=\(Self.visuallyDistinctCandidates(existingCandidates + candidates).count)"
                    )
                    return CandidateFetchResult(
                        candidates: candidates,
                        stoppedAfterConsecutiveFailures: true
                    )
                }
                continue
            }
            consecutiveFailures = 0
            let thumbnailCandidate = candidate.thumbnailCandidate(at: position)
            candidates.append(thumbnailCandidate)
            let distinctCandidateCount = Self.visuallyDistinctCandidates(
                existingCandidates + candidates
            ).count
            progress(distinctCandidateCount)
            if let maximumDistinctCandidateCount,
               distinctCandidateCount >= maximumDistinctCandidateCount {
                return CandidateFetchResult(
                    candidates: candidates,
                    stoppedAfterConsecutiveFailures: false
                )
            }
        }
        return CandidateFetchResult(
            candidates: candidates,
            stoppedAfterConsecutiveFailures: false
        )
    }

    private static func visuallyDistinctCandidates(
        _ candidates: [ThumbnailCandidate]
    ) -> [ThumbnailCandidate] {
        var result: [ThumbnailCandidate] = []
        for candidate in candidates where ThumbnailGenerationPolicy.shouldIncludeChoice(
            isBlack: candidate.isBlack
        ) {
            guard !result.contains(where: { candidate.isVisuallySimilar(to: $0) }) else { continue }
            result.append(candidate)
        }
        return result
    }

    // MARK: - キー生成

    static func remoteVideoCacheKey(
        connectionID: UUID,
        itemPath: String,
        fileId: UInt64? = nil
    ) -> String {
        if let fileId, fileId > 0 {
            return "remote-video-v4|remote:\(connectionID.uuidString)|fileId:\(fileId)"
        }
        return "remote-video-v4|remote:\(connectionID.uuidString)|path:\(itemPath)"
    }

    func cacheKey(connection: RemoteConnection, item: DirectoryItem) -> String {
        Self.remoteVideoCacheKey(
            connectionID: connection.id,
            itemPath: item.path,
            fileId: item.fileId
        )
    }

    // MARK: - Disk Cache

    private func diskURL(for key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent(hash + ".jpg")
    }

    private func saveToDiskAsync(_ image: UIImage, key: String) {
        let url = diskURL(for: key)
        diskQueue.async {
            guard let data = image.jpegData(compressionQuality: 0.7) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func isValidStoredThumbnail(_ image: UIImage, key: String) -> Bool {
        ThumbnailImageNormalizer.isCanonical(image)
            && !(key.hasPrefix("remote-video-v4|") && ThumbnailImageAnalyzer.isBlack(image))
    }

    private func removeCachedThumbnail(for key: String) {
        memoryCache.removeObject(forKey: key as NSString)
        let url = diskURL(for: key)
        diskQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
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
        brightness < 0.035
            || upperDecileBrightness < 0.08
            || (brightness < 0.10 && darkPixelRatio > 0.93)
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
        return normalizedDifference < 0.02
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
        visualSignature.reserveCapacity(8 * 8 * 3)
        for y in 0..<8 {
            for x in 0..<8 {
                var redTotal: CGFloat = 0
                var greenTotal: CGFloat = 0
                var blueTotal: CGFloat = 0
                for sampleY in 0..<3 {
                    for sampleX in 0..<3 {
                        let pixelX = x * 3 + sampleX
                        let pixelY = y * 3 + sampleY
                        let offset = (pixelY * w + pixelX) * 4
                        redTotal += CGFloat(pixels[offset]) / 255
                        greenTotal += CGFloat(pixels[offset + 1]) / 255
                        blueTotal += CGFloat(pixels[offset + 2]) / 255
                    }
                }
                visualSignature.append(UInt8(clamping: Int(redTotal / 9 * 255)))
                visualSignature.append(UInt8(clamping: Int(greenTotal / 9 * 255)))
                visualSignature.append(UInt8(clamping: Int(blueTotal / 9 * 255)))
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
    private var mediaID = "unknown"
    private var position: Float = 0
    private var startedAt: CFAbsoluteTime = 0

    func fetch(media: VLCMedia, position: Float, mediaID: String) async -> UIImage? {
        self.mediaID = mediaID
        self.position = position
        startedAt = CFAbsoluteTimeGetCurrent()
        return await withTaskCancellationHandler {
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
                    guard let self else { return }
                    MediaDiagnostics.thumbnail(
                        "event=frame_timeout mediaID=\(self.mediaID) position=\(self.position) elapsedMs=\(Int((CFAbsoluteTimeGetCurrent() - self.startedAt) * 1000))"
                    )
                    self.resume(with: nil)
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
        let rawImage = UIImage(cgImage: thumbnail)
        let image = ThumbnailImageNormalizer.normalize(rawImage)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let normalizedSize = image?.size ?? .zero
            MediaDiagnostics.thumbnail(
                "event=frame_ready mediaID=\(self.mediaID) position=\(self.position) raw=\(thumbnail.width)x\(thumbnail.height) normalized=\(Int(normalizedSize.width))x\(Int(normalizedSize.height)) elapsedMs=\(Int((CFAbsoluteTimeGetCurrent() - self.startedAt) * 1000))"
            )
            self.resume(with: image)
        }
    }
}
