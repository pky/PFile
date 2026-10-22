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

    func test_interactiveSeekPolicy_enablesDirectSMBPreview() {
        XCTAssertTrue(VideoPlayerInteractiveSeekPolicy.directSMBPreviewEnabled)
        XCTAssertEqual(VideoPlayerInteractiveSeekPolicy.previewMinimumInterval, 0.1)
    }

    // MARK: - VideoPlayerEnginePolicy

    func test_enginePolicy_routesMP4FamilyToVLC() {
        XCTAssertFalse(VideoPlayerEnginePolicy.avPlayerEnabledForMP4Family)
        XCTAssertFalse(VideoPlayerEnginePolicy.usesAVPlayer(fileName: "movie.mp4"))
        XCTAssertFalse(VideoPlayerEnginePolicy.usesAVPlayer(fileName: "movie.M4V"))
        XCTAssertFalse(VideoPlayerEnginePolicy.usesAVPlayer(fileName: "movie.mov"))
        XCTAssertFalse(VideoPlayerEnginePolicy.usesAVPlayer(fileName: "movie.mkv"))
    }

    // MARK: - VLC 一時停止中ドラッグの pause 遅延

    func test_endInteractiveSeek_withoutMedia_doesNotDeferPause() {
        // media 未設定では確定 seek が出ないので、完了待ちの pause 遅延を残してはいけない。
        let vm = makeViewModel()
        vm.durationSeconds = 100
        vm.updateInteractiveSeek(to: 10)
        vm.endInteractiveSeek()
        XCTAssertFalse(vm.isVLCDeferredPausePending)
    }

    func test_tearDown_clearsDeferredPause() {
        // 再生破棄後に遅延 pause が残ると、破棄済み player へ pause を送ることになる。
        let vm = makeViewModel()
        vm.durationSeconds = 100
        vm.updateInteractiveSeek(to: 10)
        vm.endInteractiveSeek()
        vm.tearDownPlayback(trigger: "test")
        XCTAssertFalse(vm.isVLCDeferredPausePending)
    }

    // MARK: - ドラッグ開始時の再生意図

    func test_updateInteractiveSeek_usesPlaybackIntent_whenPlayerNotYetPlaying() {
        // 読み込み中は isPlaying が false でも、再生意図があれば指を離した後に再開しなければならない。
        let vm = makeViewModel()
        vm.durationSeconds = 100
        vm.playIfReady(trigger: "test")
        vm.updateInteractiveSeek(to: 10)
        XCTAssertTrue(vm.willResumePlaybackAfterInteractiveSeek)
    }

    func test_updateInteractiveSeek_keepsPausedIntent() {
        // 一時停止中にドラッグを始めたら、指を離した後も停止のままにする。
        let vm = makeViewModel()
        vm.durationSeconds = 100
        vm.pausePlayback(trigger: "test")
        vm.updateInteractiveSeek(to: 10)
        XCTAssertFalse(vm.willResumePlaybackAfterInteractiveSeek)
    }

    // MARK: - 一時的な消音再生中の消音切替

    func test_playerMuted_forcesMuteDuringTemporaryScrubPlayback() {
        // ドラッグ中の消音解除は設定だけ更新し、ずれた位置の音を出さない。
        XCTAssertTrue(VideoPlayerViewModel.playerMuted(preference: false, temporaryScrubPlayback: true))
        XCTAssertTrue(VideoPlayerViewModel.playerMuted(preference: true, temporaryScrubPlayback: true))
        XCTAssertFalse(VideoPlayerViewModel.playerMuted(preference: false, temporaryScrubPlayback: false))
        XCTAssertTrue(VideoPlayerViewModel.playerMuted(preference: true, temporaryScrubPlayback: false))
    }

    func test_vlcScrubPlaybackActive_duringInteractiveSeekOnly() {
        // 強制消音の対象期間はドラッグ中と pause 遅延中だけで、通常再生へ戻ったら解除する。
        let vm = makeViewModel()
        vm.durationSeconds = 100
        XCTAssertFalse(vm.isVLCScrubPlaybackActive)
        vm.updateInteractiveSeek(to: 10)
        XCTAssertTrue(vm.isVLCScrubPlaybackActive)
        vm.endInteractiveSeek()
        XCTAssertFalse(vm.isVLCScrubPlaybackActive)
    }
}
