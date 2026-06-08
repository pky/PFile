@testable import PFile
import XCTest

@MainActor
final class SettingsViewModelTests: XCTestCase {

    private var mockWatchHistoryRepository: MockWatchHistoryRepository!
    private var mockThumbnailService: MockThumbnailService!
    private var mockBackupService: MockAppDataBackupService!
    private var mockPurchaseService: MockPurchaseService!
    private var sut: SettingsViewModel!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: WatchHistoryLimitSettings.key)
        UserDefaults.standard.removeObject(forKey: VideoPlayerHomeButtonSettings.key)
        UserDefaults.standard.removeObject(forKey: "Purchase.debugShowsAds")
        mockWatchHistoryRepository = MockWatchHistoryRepository()
        mockThumbnailService = MockThumbnailService()
        mockBackupService = MockAppDataBackupService()
        mockPurchaseService = MockPurchaseService()
        sut = SettingsViewModel(
            watchHistoryRepository: mockWatchHistoryRepository,
            thumbnailService: mockThumbnailService,
            backupService: mockBackupService,
            purchaseService: mockPurchaseService
        )
    }

    override func tearDown() {
        sut = nil
        mockWatchHistoryRepository = nil
        mockThumbnailService = nil
        mockBackupService = nil
        mockPurchaseService = nil
        UserDefaults.standard.removeObject(forKey: WatchHistoryLimitSettings.key)
        UserDefaults.standard.removeObject(forKey: VideoPlayerHomeButtonSettings.key)
        UserDefaults.standard.removeObject(forKey: "Purchase.debugShowsAds")
        super.tearDown()
    }

    // MARK: - デフォルト値

    func test_thumbnailCacheLimitMB_defaultIs500() {
        XCTAssertEqual(sut.thumbnailCacheLimitMB, 500)
    }

    func test_resumePlayback_defaultIsTrue() {
        XCTAssertTrue(sut.resumePlayback)
    }

    func test_showVideoHomeButtonAlways_defaultIsFalse() {
        XCTAssertFalse(sut.showVideoHomeButtonAlways)
    }

    func test_watchHistoryLimit_defaultIs100() {
        XCTAssertEqual(sut.watchHistoryLimit, 100)
    }

    func test_watchHistoryLimitChange_persistsNewLimit() {
        sut.watchHistoryLimit = 500

        XCTAssertEqual(UserDefaults.standard.integer(forKey: WatchHistoryLimitSettings.key), 500)
    }

    func test_watchHistoryLimitChange_trimsHistoryToNewLimit() async {
        sut.watchHistoryLimit = 50
        await Task.yield()

        XCTAssertEqual(mockWatchHistoryRepository.trimmedLimit, 50)
    }

    func test_showVideoHomeButtonAlwaysChange_persistsNewValue() {
        sut.showVideoHomeButtonAlways = true

        XCTAssertTrue(UserDefaults.standard.bool(forKey: VideoPlayerHomeButtonSettings.key))
    }

    func test_showVideoHomeButtonAlways_restoresSavedValue() {
        UserDefaults.standard.set(true, forKey: VideoPlayerHomeButtonSettings.key)

        sut = SettingsViewModel(
            watchHistoryRepository: mockWatchHistoryRepository,
            thumbnailService: mockThumbnailService,
            backupService: mockBackupService,
            purchaseService: mockPurchaseService
        )

        XCTAssertTrue(sut.showVideoHomeButtonAlways)
    }

    // MARK: - clearThumbnailCache

    func test_clearThumbnailCache_callsClearCache() async {
        await sut.clearThumbnailCache()
        XCTAssertTrue(mockThumbnailService.clearCacheCalled)
    }

    // MARK: - deleteAllWatchHistory

    func test_deleteAllWatchHistory_callsDeleteAll() async {
        await sut.deleteAllWatchHistory()
        XCTAssertTrue(mockWatchHistoryRepository.deleteAllCalled)
    }

    func test_deleteAllWatchHistory_onError_setsErrorMessage() async {
        mockWatchHistoryRepository.shouldThrow = true
        await sut.deleteAllWatchHistory()
        XCTAssertNotNil(sut.errorMessage)
    }

    // MARK: - Backup

    func test_restoreLatestBackup_callsBackupService() async {
        await sut.restoreLatestBackup()
        XCTAssertTrue(mockBackupService.restoreLatestBackupCalled)
    }

    func test_restoreBackupFromURL_callsBackupServiceWithSelectedURL() async {
        let backupURL = URL(fileURLWithPath: "/tmp/external-backup.json")

        await sut.restoreBackup(from: backupURL)

        XCTAssertEqual(mockBackupService.restoreBackupURL, backupURL)
    }

    func test_restoreBackupFromURL_onError_setsErrorMessage() async {
        mockBackupService.shouldThrow = true

        await sut.restoreBackup(from: URL(fileURLWithPath: "/tmp/external-backup.json"))

        XCTAssertNotNil(sut.errorMessage)
    }

    // MARK: - Purchase

    func test_refreshPurchaseState_readsPurchaseServiceState() async {
        mockPurchaseService.isAdsRemoved = true
        mockPurchaseService.removeAdsDisplayPrice = "¥500"

        await sut.refreshPurchaseState()

        XCTAssertTrue(sut.isAdsRemoved)
        XCTAssertEqual(sut.removeAdsDisplayPrice, "¥500")
    }

    func test_purchaseRemoveAds_callsPurchaseService() async {
        await sut.purchaseRemoveAds()

        XCTAssertTrue(mockPurchaseService.purchaseRemoveAdsCalled)
    }

    func test_restorePurchases_callsPurchaseService() async {
        await sut.restorePurchases()

        XCTAssertTrue(mockPurchaseService.restorePurchasesCalled)
    }

#if DEBUG
    func test_debugShowsAdsChange_updatesPurchaseService() {
        sut.debugShowsAds = false

        XCTAssertFalse(mockPurchaseService.debugShowsAds)
    }
#endif
}

// MARK: - MockThumbnailService

final class MockThumbnailService: ThumbnailServiceProtocol {
    var clearCacheCalled = false

    func clearCache() {
        clearCacheCalled = true
    }
}

@MainActor
final class MockPurchaseService: PurchaseServiceProtocol {
    var isAdsRemoved = false
    var shouldShowAds: Bool {
#if DEBUG
        debugShowsAds && !isAdsRemoved
#else
        !isAdsRemoved
#endif
    }
#if DEBUG
    var debugShowsAds = true
#endif
    var removeAdsDisplayPrice: String?
    var statusMessage: String?
    var isLoading = false
    var configureCalled = false
    var purchaseRemoveAdsCalled = false
    var restorePurchasesCalled = false

    func configure() async {
        configureCalled = true
    }

    func purchaseRemoveAds() async {
        purchaseRemoveAdsCalled = true
        isAdsRemoved = true
    }

    func restorePurchases() async {
        restorePurchasesCalled = true
    }
}
