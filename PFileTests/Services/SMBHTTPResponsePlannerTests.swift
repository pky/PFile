@testable import PFile
import Testing
import UIKit

struct ThumbnailGenerationPolicyTests {

    @Test("通常生成は時間帯を変えて3地点を試す")
    func automaticGenerationUsesThreePositions() {
        #expect(ThumbnailGenerationPolicy.automaticPositions == [0.10, 0.20, 0.50])
    }

    @Test("通常地点で取れない動画は手動候補の追加地点を自動でも試す")
    func automaticGenerationUsesFallbackPositions() {
        #expect(ThumbnailGenerationPolicy.automaticFallbackPositions == [0.04, 0.38, 0.56, 0.74, 0.92])
    }

    @Test("手動候補は通常生成より広い時間帯を使う")
    func manualChoicesCoverVideoTimeline() {
        #expect(ThumbnailGenerationPolicy.choicePositions.count == 6)
        #expect(ThumbnailGenerationPolicy.supplementalChoicePositions.count == 6)
        #expect(ThumbnailGenerationPolicy.choicePositions.first == 0.04)
        #expect(ThumbnailGenerationPolicy.choicePositions.last == 0.92)
        #expect(ThumbnailGenerationPolicy.maximumChoiceCount == 8)
        #expect(ThumbnailGenerationPolicy.maximumConsecutiveChoiceFailures == 2)
    }

    @Test("通常生成は黒画像を保存対象にしない")
    func automaticGenerationRejectsBlackImage() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            context.cgContext.setFillColor(UIColor.black.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }

        #expect(ThumbnailImageAnalyzer.isBlack(image))
    }

    @Test("通常生成は明るい画像を保存対象にする")
    func automaticGenerationAcceptsVisibleImage() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            context.cgContext.setFillColor(UIColor.systemBlue.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }

        #expect(!ThumbnailImageAnalyzer.isBlack(image))
    }

    @Test("暗い部分が多くても被写体が見える画像は採用する")
    func automaticGenerationAcceptsDarkVisibleImage() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
            context.cgContext.setFillColor(UIColor.black.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 70, height: 100))
            context.cgContext.setFillColor(UIColor.white.cgColor)
            context.cgContext.fill(CGRect(x: 70, y: 0, width: 30, height: 100))
        }

        #expect(!ThumbnailImageAnalyzer.isBlack(image))
    }

    @Test("手動候補は黒でない単色画像も採用する")
    func manualChoicesAcceptSolidGrayImage() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            context.cgContext.setFillColor(UIColor.gray.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }

        #expect(ThumbnailImageAnalyzer.isLowInformation(image))
        #expect(ThumbnailGenerationPolicy.shouldIncludeChoice(
            isBlack: ThumbnailImageAnalyzer.isBlack(image)
        ))
    }

    @Test("手動候補は連続失敗を上限で打ち切る")
    func manualChoicesStopAfterConsecutiveFailures() {
        #expect(!ThumbnailGenerationPolicy.shouldStopChoiceSearch(consecutiveFailures: 1))
        #expect(ThumbnailGenerationPolicy.shouldStopChoiceSearch(consecutiveFailures: 2))
    }

    @Test("手動候補の類似判定は色の違いを区別する")
    func manualChoicesDistinguishDifferentColors() {
        let redImage = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            context.cgContext.setFillColor(UIColor.red.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        let greenImage = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            context.cgContext.setFillColor(UIColor.green.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }

        #expect(!ThumbnailImageAnalyzer.areVisuallySimilar(redImage, greenImage))
    }

    @Test("手動候補は明暗差のある画像を採用する")
    func manualChoicesAcceptDetailedImage() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            context.cgContext.setFillColor(UIColor.white.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 16, height: 32))
            context.cgContext.setFillColor(UIColor.systemBlue.cgColor)
            context.cgContext.fill(CGRect(x: 16, y: 0, width: 16, height: 32))
        }

        #expect(!ThumbnailImageAnalyzer.isLowInformation(image))
    }
}

struct VideoResolutionFormatterTests {

    @Test("動画解像度をSD・HD・FHD・WQHD・4Kへ分類する", arguments: [
        (640.0, 480.0, "SD 640×480"),
        (1_280.0, 720.0, "HD 1280×720"),
        (1_920.0, 1_080.0, "FHD 1920×1080"),
        (2_560.0, 1_440.0, "WQHD 2560×1440"),
        (3_840.0, 2_160.0, "4K 3840×2160"),
    ])
    func formatsResolution(width: Double, height: Double, expected: String) {
        #expect(VideoResolutionFormatter.text(width: width, height: height) == expected)
    }
}

struct SMBHTTPResponsePlannerTests {

    @Test("動画拡張子をHTTPパスとContent-Typeへ反映する")
    func mediaDescriptorUsesVideoExtension() {
        #expect(
            SMBHTTPMediaDescriptor.make(filePath: "/folder/movie.mp4")
                == SMBHTTPMediaDescriptor(requestPath: "/stream.mp4", contentType: "video/mp4")
        )
        #expect(
            SMBHTTPMediaDescriptor.make(filePath: "/folder/movie.mkv")
                == SMBHTTPMediaDescriptor(requestPath: "/stream.mkv", contentType: "video/x-matroska")
        )
    }

    @Test("不正な拡張子はHTTPパスへ埋め込まない")
    func mediaDescriptorRejectsUnsafeExtension() {
        #expect(
            SMBHTTPMediaDescriptor.make(filePath: "/folder/movie.bad-ext")
                == SMBHTTPMediaDescriptor(requestPath: "/stream", contentType: "application/octet-stream")
        )
    }

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

    @Test("suffix Range をファイル末尾へ展開する")
    func parsesSuffixRangeHeader() {
        let range = SMBHTTPResponsePlanner.parseRangeHeader("Range: bytes=-500", fileSize: 1_000)
        #expect(range == 500...999)
    }

    @Test("ファイルサイズを超える suffix Range は全体へ丸める")
    func clampsSuffixRangeHeader() {
        let range = SMBHTTPResponsePlanner.parseRangeHeader("Range: bytes=-1500", fileSize: 1_000)
        #expect(range == 0...999)
    }

    @Test("不正な Range ヘッダは nil を返す")
    func returnsNilForInvalidRangeHeader() {
        #expect(SMBHTTPResponsePlanner.parseRangeHeader("Range: items=0-10", fileSize: 1_000) == nil)
        #expect(SMBHTTPResponsePlanner.parseRangeHeader("Range: bytes=-0", fileSize: 1_000) == nil)
        #expect(SMBHTTPResponsePlanner.parseRangeHeader("Range: bytes=a-b", fileSize: 1_000) == nil)
    }
}
