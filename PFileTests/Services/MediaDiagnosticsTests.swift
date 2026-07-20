@testable import PFile
import XCTest

final class MediaDiagnosticsTests: XCTestCase {
    func testMediaID同じ入力は同じセッション内で一致する() {
        let first = MediaDiagnostics.mediaID(sourceID: "source", path: "/private/video.mp4")
        let second = MediaDiagnostics.mediaID(sourceID: "source", path: "/private/video.mp4")

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 12)
        XCTAssertFalse(first.contains("video"))
        XCTAssertFalse(first.contains("private"))
    }

    func testMediaID異なるパスは異なる() {
        let first = MediaDiagnostics.mediaID(sourceID: "source", path: "/a.mp4")
        let second = MediaDiagnostics.mediaID(sourceID: "source", path: "/b.mp4")

        XCTAssertNotEqual(first, second)
    }

    func testErrorCode説明文を含めない() {
        let error = NSError(
            domain: "TestDomain",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "/secret/path/video.mp4"]
        )

        let summary = MediaDiagnostics.errorCode(error)

        XCTAssertEqual(summary, "domain=TestDomain code=42")
        XCTAssertFalse(summary.contains("secret"))
    }
}
