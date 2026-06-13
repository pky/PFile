@testable import PFile
import XCTest

@MainActor
final class VideoPlayerViewModelTests: XCTestCase {

    private var mockRepository: MockWatchHistoryRepository!
    private var playbackHistoryService: PlaybackHistoryService!
    private var connection: RemoteConnection!
    private var item: DirectoryItem!

    override func setUp() {
        super.setUp()
        mockRepository = MockWatchHistoryRepository()
        playbackHistoryService = PlaybackHistoryService(repository: mockRepository)
        connection = ModelFactory.makeConnection()
        item = DirectoryItem(
            name: "test.mp4",
            path: "/Videos/test.mp4",
            itemType: .video,
            size: 1_000_000,
            modifiedAt: nil,
            createdAt: nil
        )
    }

    private func makeViewModel() -> VideoPlayerViewModel {
        VideoPlayerViewModel(
            connection: connection,
            item: item,
            playbackHistoryService: playbackHistoryService,
            smbClientManager: SMBClientManager(),
            startPositionSeconds: 0
        )
    }

    // MARK: - isBuffering

    func test_isBuffering_isTrueOnInit() {
        let vm = makeViewModel()
        XCTAssertTrue(vm.isBuffering)
    }

    // MARK: - saveWatchPosition

    func test_saveWatchPosition_doesNotCallUpsert_whenDurationIsZero() async {
        let vm = makeViewModel()
        vm.durationSeconds = 0

        await vm.saveWatchPosition()

        XCTAssertTrue(mockRepository.upsertedCalls.isEmpty)
    }

    func test_saveWatchPosition_callsUpsert_whenDurationIsPositive() async {
        let vm = makeViewModel()
        vm.durationSeconds = 120
        vm.currentPositionSeconds = 60

        await vm.saveWatchPosition()

        XCTAssertEqual(mockRepository.upsertedCalls.count, 1)
        XCTAssertEqual(mockRepository.upsertedCalls[0].filePath, "/Videos/test.mp4")
        XCTAssertEqual(mockRepository.upsertedCalls[0].position, 60)
    }

    func test_saveWatchPosition_savesZero_whenPlaybackIsNearEnd() async {
        let vm = makeViewModel()
        vm.durationSeconds = 5_300
        vm.currentPositionSeconds = 5_291

        await vm.saveWatchPosition()

        XCTAssertEqual(mockRepository.upsertedCalls.count, 1)
        XCTAssertEqual(mockRepository.upsertedCalls[0].position, 0)
    }

    func test_saveWatchPosition_keepsPosition_whenPlaybackIsNotNearEnd() async {
        let vm = makeViewModel()
        vm.durationSeconds = 5_300
        vm.currentPositionSeconds = 5_189.507

        await vm.saveWatchPosition()

        XCTAssertEqual(mockRepository.upsertedCalls.count, 1)
        XCTAssertEqual(mockRepository.upsertedCalls[0].position, 5_189.507)
    }

    func test_saveWatchPosition_doesNotCrash_whenRepositoryThrows() async {
        let vm = makeViewModel()
        vm.durationSeconds = 120
        vm.currentPositionSeconds = 30
        mockRepository.shouldThrow = true

        await vm.saveWatchPosition()

        XCTAssertTrue(mockRepository.upsertedCalls.isEmpty)
    }

    // MARK: - VideoPlayerCachingPolicy

    func test_directSMBCachingPolicy_keepsSmallFilesResponsive() {
        let policy = VideoPlayerCachingPolicy.directSMB(fileSize: 1_000_000)

        XCTAssertEqual(policy.networkCachingMilliseconds, 500)
        XCTAssertEqual(policy.inputCachingMilliseconds, 3000)
    }

    func test_directSMBCachingPolicy_increasesBufferForHeavyFiles() {
        let policy = VideoPlayerCachingPolicy.directSMB(fileSize: 8 * 1024 * 1024 * 1024)

        XCTAssertEqual(policy.networkCachingMilliseconds, 1000)
        XCTAssertEqual(policy.inputCachingMilliseconds, 6000)
    }

    func test_interactiveSeekPolicy_keepsDirectSMBPreviewDisabled() {
        XCTAssertFalse(VideoPlayerInteractiveSeekPolicy.directSMBPreviewEnabled)
        XCTAssertEqual(VideoPlayerInteractiveSeekPolicy.previewIntervalMilliseconds, 300)
        XCTAssertEqual(VideoPlayerInteractiveSeekPolicy.minimumPreviewDeltaSeconds, 0.25)
    }
}
