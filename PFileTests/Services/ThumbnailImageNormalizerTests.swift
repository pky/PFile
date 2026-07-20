@testable import PFile
import XCTest

final class ThumbnailImageNormalizerTests: XCTestCase {
    func testNormalize横長画像を320x180へ揃える() throws {
        let image = makeImage(size: CGSize(width: 400, height: 200), color: .red)

        let normalized = try XCTUnwrap(ThumbnailImageNormalizer.normalize(image))

        XCTAssertEqual(normalized.size, CGSize(width: 320, height: 180))
        XCTAssertEqual(normalized.imageOrientation, .up)
    }

    func testNormalize縦長画像を320x180へ揃える() throws {
        let image = makeImage(size: CGSize(width: 180, height: 320), color: .blue)

        let normalized = try XCTUnwrap(ThumbnailImageNormalizer.normalize(image))

        XCTAssertEqual(normalized.size, CGSize(width: 320, height: 180))
        XCTAssertEqual(normalized.imageOrientation, .up)
    }

    func testNormalize正規化済み画像は再利用する() throws {
        let image = makeImage(size: CGSize(width: 320, height: 180), color: .green)

        let normalized = try XCTUnwrap(ThumbnailImageNormalizer.normalize(image))

        XCTAssertTrue(normalized === image)
    }

    func testNormalize無効寸法を拒否する() {
        XCTAssertNil(ThumbnailImageNormalizer.normalize(UIImage()))
    }

    private func makeImage(size: CGSize, color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: size))
        }
    }
}

@MainActor
final class ThumbnailGenerationLimiterTests: XCTestCase {
    func test待機中の要求をキャンセルすると待ち行列から除外する() async {
        let limiter = ThumbnailGenerationLimiter(limit: 1)
        let firstAcquired = await limiter.acquire()
        XCTAssertTrue(firstAcquired)

        let waitingTask = Task { @MainActor in
            await limiter.acquire()
        }
        await waitUntil { limiter.queuedCount == 1 }

        waitingTask.cancel()

        let cancelledResult = await waitingTask.value
        XCTAssertFalse(cancelledResult)
        XCTAssertEqual(limiter.queuedCount, 0)
        XCTAssertEqual(limiter.activeCount, 1)

        limiter.release()
        XCTAssertEqual(limiter.activeCount, 0)
    }

    func test解放した枠を次の待機要求へ渡す() async {
        let limiter = ThumbnailGenerationLimiter(limit: 1)
        let firstAcquired = await limiter.acquire()
        XCTAssertTrue(firstAcquired)

        let waitingTask = Task { @MainActor in
            await limiter.acquire()
        }
        await waitUntil { limiter.queuedCount == 1 }

        limiter.release()

        let resumedResult = await waitingTask.value
        XCTAssertTrue(resumedResult)
        XCTAssertEqual(limiter.activeCount, 1)
        XCTAssertEqual(limiter.queuedCount, 0)

        limiter.release()
        XCTAssertEqual(limiter.activeCount, 0)
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}

final class ThumbnailServiceAsyncCacheTests: XCTestCase {
    func test非同期保存は正規化してメモリキャッシュへ反映する() async throws {
        let service = ThumbnailService()
        let key = "test-async-cache-\(UUID().uuidString)"
        let source = try XCTUnwrap(makeImage(size: CGSize(width: 100, height: 300)))

        let stored = await service.storeAsync(source, for: key)

        let image = try XCTUnwrap(stored)
        XCTAssertTrue(ThumbnailImageNormalizer.isCanonical(image))
        XCTAssertTrue(service.thumbnail(for: key) === image)
    }

    func test非同期保存は黒いリモート動画サムネイルを拒否する() async throws {
        let service = ThumbnailService()
        let key = "remote-video-v3|test|\(UUID().uuidString)"
        let source = try XCTUnwrap(
            makeImage(size: ThumbnailImageNormalizer.pixelSize, color: .black)
        )

        let stored = await service.storeAsync(source, for: key)

        XCTAssertNil(stored)
        XCTAssertNil(service.thumbnail(for: key))
    }

    private func makeImage(size: CGSize, color: UIColor = .systemBlue) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(size, true, 1)
        defer { UIGraphicsEndImageContext() }
        color.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        return UIGraphicsGetImageFromCurrentImageContext()
    }
}
