@testable import PFile
import XCTest

final class ByteRangeResolverTests: XCTestCase {

    // MARK: - resolve

    func test_resolve_boundedRequestWithinFile() {
        let range = ByteRangeResolver.resolve(
            requestedOffset: 0,
            requestedLength: 1000,
            requestsAllDataToEnd: false,
            currentOffset: 0,
            totalLength: 10_000
        )
        XCTAssertEqual(range, 0...999)
    }

    func test_resolve_clampsToFileEnd() {
        let range = ByteRangeResolver.resolve(
            requestedOffset: 9_000,
            requestedLength: 5_000,
            requestsAllDataToEnd: false,
            currentOffset: 9_000,
            totalLength: 10_000
        )
        XCTAssertEqual(range, 9_000...9_999)
    }

    func test_resolve_allDataToEndReadsToLastByte() {
        let range = ByteRangeResolver.resolve(
            requestedOffset: 5_000,
            requestedLength: 0,
            requestsAllDataToEnd: true,
            currentOffset: 5_000,
            totalLength: 10_000
        )
        XCTAssertEqual(range, 5_000...9_999)
    }

    func test_resolve_currentOffsetAdvancesStartButKeepsAbsoluteEnd() {
        let range = ByteRangeResolver.resolve(
            requestedOffset: 0,
            requestedLength: 1_000,
            requestsAllDataToEnd: false,
            currentOffset: 400,
            totalLength: 10_000
        )
        // 終端は requestedOffset + length - 1 = 999 のまま、開始だけ 400 へ進む。
        XCTAssertEqual(range, 400...999)
    }

    func test_resolve_startAtOrBeyondEndReturnsNil() {
        XCTAssertNil(ByteRangeResolver.resolve(
            requestedOffset: 10_000,
            requestedLength: 100,
            requestsAllDataToEnd: false,
            currentOffset: 10_000,
            totalLength: 10_000
        ))
    }

    func test_resolve_unknownTotalLengthUsesRequestedSpan() {
        let range = ByteRangeResolver.resolve(
            requestedOffset: 2_000,
            requestedLength: 500,
            requestsAllDataToEnd: false,
            currentOffset: 2_000,
            totalLength: 0
        )
        XCTAssertEqual(range, 2_000...2_499)
    }

    func test_resolve_zeroLengthBoundedRequestReturnsNil() {
        XCTAssertNil(ByteRangeResolver.resolve(
            requestedOffset: 0,
            requestedLength: 0,
            requestsAllDataToEnd: false,
            currentOffset: 0,
            totalLength: 10_000
        ))
    }

    // MARK: - InMemoryByteRangeDataSource

    func test_inMemorySource_readsRequestedRange() async throws {
        let bytes = Data((0..<256).map { UInt8($0) })
        let source = InMemoryByteRangeDataSource(data: bytes)

        let length = try await source.contentLength()
        XCTAssertEqual(length, 256)

        let chunk = try await source.readRange(10...19)
        XCTAssertEqual(Array(chunk), Array(10...19).map { UInt8($0) })
    }

    func test_inMemorySource_clampsRangeToEnd() async throws {
        let bytes = Data((0..<100).map { UInt8($0) })
        let source = InMemoryByteRangeDataSource(data: bytes)

        let chunk = try await source.readRange(90...200)
        XCTAssertEqual(chunk.count, 10)
        XCTAssertEqual(Array(chunk), Array(90...99).map { UInt8($0) })
    }
}

/// テスト用のメモリ上 ByteRangeDataSource。
private final class InMemoryByteRangeDataSource: ByteRangeDataSource, @unchecked Sendable {

    private let data: Data

    init(data: Data) {
        self.data = data
    }

    func contentLength() async throws -> UInt64 {
        UInt64(data.count)
    }

    func readRange(_ range: ClosedRange<UInt64>) async throws -> Data {
        let lower = Int(range.lowerBound)
        guard lower < data.count else { return Data() }
        let upper = min(Int(range.upperBound), data.count - 1)
        return data.subdata(in: lower..<(upper + 1))
    }
}
