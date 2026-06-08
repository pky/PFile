@testable import PFile
import Testing

struct SMBHTTPResponsePlannerTests {

    @Test("Range なしは 200 OK で全体を返す")
    func fullResponseWithoutRange() throws {
        let plan = try SMBHTTPResponsePlanner.makePlan(fileSize: 1_000, requestedRange: nil)

        #expect(plan.status == "200 OK")
        #expect(plan.contentLength == 1_000)
        #expect(plan.contentRange == nil)
        #expect(plan.bodyRange == 0...999)
    }

    @Test("Range 指定は 206 Partial Content を返す")
    func partialResponseWithRange() throws {
        let plan = try SMBHTTPResponsePlanner.makePlan(fileSize: 1_000, requestedRange: 100...199)

        #expect(plan.status == "206 Partial Content")
        #expect(plan.contentLength == 100)
        #expect(plan.contentRange == "bytes 100-199/1000")
        #expect(plan.bodyRange == 100...199)
    }

    @Test("終端超過の Range はファイルサイズに丸める")
    func clampsRangeUpperBound() throws {
        let plan = try SMBHTTPResponsePlanner.makePlan(fileSize: 1_000, requestedRange: 900...1_500)

        #expect(plan.status == "206 Partial Content")
        #expect(plan.contentLength == 100)
        #expect(plan.contentRange == "bytes 900-999/1000")
        #expect(plan.bodyRange == 900...999)
    }

    @Test("ファイルサイズ超過の Range は unsatisfiable")
    func rejectsUnsatisfiableRange() {
        #expect(throws: SMBHTTPResponsePlanner.RangeError.unsatisfiable) {
            try SMBHTTPResponsePlanner.makePlan(fileSize: 1_000, requestedRange: 1_000...1_100)
        }
    }

    @Test("open-ended Range を終端まで展開する")
    func parsesOpenEndedRangeHeader() {
        let range = SMBHTTPResponsePlanner.parseRangeHeader("Range: bytes=250-", fileSize: 1_000)
        #expect(range == 250...999)
    }

    @Test("通常の Range ヘッダを解釈する")
    func parsesClosedRangeHeader() {
        let range = SMBHTTPResponsePlanner.parseRangeHeader("Range: bytes=100-199", fileSize: 1_000)
        #expect(range == 100...199)
    }

    @Test("不正な Range ヘッダは nil を返す")
    func returnsNilForInvalidRangeHeader() {
        #expect(SMBHTTPResponsePlanner.parseRangeHeader("Range: items=0-10", fileSize: 1_000) == nil)
        #expect(SMBHTTPResponsePlanner.parseRangeHeader("Range: bytes=-500", fileSize: 1_000) == nil)
        #expect(SMBHTTPResponsePlanner.parseRangeHeader("Range: bytes=a-b", fileSize: 1_000) == nil)
    }
}
