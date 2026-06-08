import Foundation

@Observable
@MainActor
final class SettingsViewModel {

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let thumbnailCacheLimitMB = "Settings.thumbnailCacheLimitMB"
        static let defaultSortKey = "Settings.defaultSortKey"
        static let resumePlayback = "Settings.resumePlayback"
        // orientationMode は OrientationService が管理するため Keys 不要
    }

    // MARK: - Thumbnail cache limit options

    static let thumbnailCacheLimitOptions: [Int] = [100, 250, 500, 1024]

    // MARK: - Watch history limit options

    static let watchHistoryLimitOptions: [Int] = [50, 100, 200, 500]

    // MARK: - Settings properties

    var thumbnailCacheLimitMB: Int = 500 {
        didSet { UserDefaults.standard.set(thumbnailCacheLimitMB, forKey: Keys.thumbnailCacheLimitMB) }
    }

    var defaultSortKey: String = "nameAsc" {
        didSet { UserDefaults.standard.set(defaultSortKey, forKey: Keys.defaultSortKey) }
    }

    var resumePlayback: Bool = true {
        didSet { UserDefaults.standard.set(resumePlayback, forKey: Keys.resumePlayback) }
    }

    var showVideoHomeButtonAlways: Bool = VideoPlayerHomeButtonSettings.defaultValue {
        didSet { VideoPlayerHomeButtonSettings.save(showVideoHomeButtonAlways) }
    }

    var showVideoShareButton: Bool = VideoPlayerShareButtonSettings.defaultValue {
        didSet { VideoPlayerShareButtonSettings.save(showVideoShareButton) }
    }

    var showVideoAirPlayButton: Bool = VideoPlayerAirPlayButtonSettings.defaultValue {
        didSet { VideoPlayerAirPlayButtonSettings.save(showVideoAirPlayButton) }
    }

    var showVideoClock: Bool = VideoPlayerClockSettings.defaultValue {
        didSet { VideoPlayerClockSettings.save(showVideoClock) }
    }

    var watchHistoryLimit: Int = 100 {
        didSet {
            WatchHistoryLimitSettings.save(watchHistoryLimit)
            Task { await trimWatchHistory(to: watchHistoryLimit) }
        }
    }

    var orientationMode: OrientationMode = .system {
        didSet { OrientationService.shared.setMode(orientationMode) }
    }

    // MARK: - State

    var errorMessage: String?
    var isClearing = false
    var isExportingBackup = false
    var isRestoringBackup = false
    var isPurchasing = false
    var isAdsRemoved = false
#if DEBUG
    var debugShowsAds = true {
        didSet { purchaseService.debugShowsAds = debugShowsAds }
    }
#endif
    var removeAdsDisplayPrice: String?
    var purchaseStatusMessage: String?
    var backupStatusMessage: String?
    var lastExportURL: URL?
    var lastRestoreSnapshotURL: URL?
    var backupDirectoryPath: String = ""
    var lastAutoBackupDescription: String?

    let appVersion: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }()

    // MARK: - Dependencies

    private let watchHistoryRepository: any WatchHistoryRepository
    private let thumbnailService: any ThumbnailServiceProtocol
    private let backupService: any AppDataBackupServiceProtocol
    private let purchaseService: any PurchaseServiceProtocol

    // MARK: - Init

    init(
        watchHistoryRepository: any WatchHistoryRepository,
        thumbnailService: any ThumbnailServiceProtocol,
        backupService: any AppDataBackupServiceProtocol,
        purchaseService: any PurchaseServiceProtocol
    ) {
        self.watchHistoryRepository = watchHistoryRepository
        self.thumbnailService = thumbnailService
        self.backupService = backupService
        self.purchaseService = purchaseService
        loadFromUserDefaults()
        loadBackupMetadata()
        syncPurchaseState()
    }

    // MARK: - Load

    private func loadFromUserDefaults() {
        let defaults = UserDefaults.standard

        if let limit = defaults.object(forKey: Keys.thumbnailCacheLimitMB) as? Int {
            thumbnailCacheLimitMB = limit
        }
        if let key = defaults.string(forKey: Keys.defaultSortKey) {
            defaultSortKey = key
        }
        if defaults.object(forKey: Keys.resumePlayback) != nil {
            resumePlayback = defaults.bool(forKey: Keys.resumePlayback)
        }
        showVideoHomeButtonAlways = VideoPlayerHomeButtonSettings.isAlwaysVisible
        showVideoShareButton = VideoPlayerShareButtonSettings.isVisible
        showVideoAirPlayButton = VideoPlayerAirPlayButtonSettings.isVisible
        showVideoClock = VideoPlayerClockSettings.isVisible
        if let limit = defaults.object(forKey: WatchHistoryLimitSettings.key) as? Int {
            watchHistoryLimit = limit
        }
        orientationMode = OrientationService.shared.mode
    }

    // MARK: - Actions

    func clearThumbnailCache() async {
        isClearing = true
        defer { isClearing = false }
        thumbnailService.clearCache()
    }

    func deleteAllWatchHistory() async {
        do {
            try await watchHistoryRepository.deleteAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshPurchaseState() async {
        await purchaseService.configure()
        syncPurchaseState()
    }

    func purchaseRemoveAds() async {
        isPurchasing = true
        defer { isPurchasing = false }
        await purchaseService.purchaseRemoveAds()
        syncPurchaseState()
    }

    func restorePurchases() async {
        isPurchasing = true
        defer { isPurchasing = false }
        await purchaseService.restorePurchases()
        syncPurchaseState()
    }

    private func syncPurchaseState() {
        isAdsRemoved = purchaseService.isAdsRemoved
#if DEBUG
        debugShowsAds = purchaseService.debugShowsAds
#endif
        removeAdsDisplayPrice = purchaseService.removeAdsDisplayPrice
        purchaseStatusMessage = purchaseService.statusMessage
        isPurchasing = purchaseService.isLoading
    }

    private func trimWatchHistory(to limit: Int) async {
        do {
            try await watchHistoryRepository.trim(to: limit)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportBackup() async {
        isExportingBackup = true
        defer { isExportingBackup = false }
        do {
            let url = try backupService.exportBackup()
            lastExportURL = url
            backupStatusMessage = "接続情報・リスト・履歴を書き出しました: \(url.lastPathComponent)"
            loadBackupMetadata()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restoreLatestBackup() async {
        isRestoringBackup = true
        defer { isRestoringBackup = false }
        do {
            let result = try backupService.restoreLatestBackup()
            lastRestoreSnapshotURL = result.preRestoreSnapshotURL
            backupStatusMessage = "復元しました: \(result.restoredFromURL.lastPathComponent) / 復元前データ: \(result.preRestoreSnapshotURL.lastPathComponent)"
            loadBackupMetadata()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restoreBackup(from url: URL) async {
        isRestoringBackup = true
        defer { isRestoringBackup = false }
        do {
            let result = try backupService.restoreBackup(from: url)
            lastRestoreSnapshotURL = result.preRestoreSnapshotURL
            backupStatusMessage = "復元しました: \(result.restoredFromURL.lastPathComponent) / 復元前データ: \(result.preRestoreSnapshotURL.lastPathComponent)"
            loadBackupMetadata()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadBackupMetadata() {
        backupDirectoryPath = (try? backupService.backupDirectoryURLForDisplay().path) ?? ""
        if let lastAutoBackupAt = backupService.lastAutoBackupAt {
            lastAutoBackupDescription = Self.backupDateFormatter.string(from: lastAutoBackupAt)
        } else {
            lastAutoBackupDescription = "まだ実行されていません"
        }
    }

    private static let backupDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
