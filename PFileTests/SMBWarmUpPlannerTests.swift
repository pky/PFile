@testable import PFile
import Foundation
import Testing

struct SMBWarmUpPlannerTests {

    private let mebibyte: UInt64 = 1024 * 1024

    private func file(_ name: String, size: Int64?, type: DirectoryItem.ItemType) -> DirectoryItem {
        DirectoryItem(
            name: name,
            path: "/videos/\(name)",
            itemType: type,
            size: size,
            modifiedAt: nil,
            createdAt: nil
        )
    }

    // MARK: - readRange

    @Test("サイズ不明のファイルは先頭 1MiB を読む")
    func unknownSizeReadsHeader() {
        #expect(SMBWarmUpPlanner.readRange(fileSize: nil, fraction: 0.5) == 0..<mebibyte)
        #expect(SMBWarmUpPlanner.readRange(fileSize: 0, fraction: 0.5) == 0..<mebibyte)
    }

    @Test("ブロックより小さいファイルは全体を読む")
    func smallFileReadsWhole() {
        let size = Int64(512 * 1024)
        #expect(SMBWarmUpPlanner.readRange(fileSize: size, fraction: 0.9) == 0..<UInt64(size))
    }

    @Test("大きいファイルは先頭ヘッダを避けたランダム位置から 1MiB を読む")
    func largeFileReadsRandomBlockBeyondHeader() {
        let size = Int64(4) * 1024 * 1024 * 1024

        let middle = SMBWarmUpPlanner.readRange(fileSize: size, fraction: 0.5)
        #expect(middle.count == Int(mebibyte))
        #expect(middle.lowerBound >= SMBWarmUpPlanner.headerSkipBytes)
        #expect(middle.upperBound <= UInt64(size))

        let first = SMBWarmUpPlanner.readRange(fileSize: size, fraction: 0)
        #expect(first.lowerBound == SMBWarmUpPlanner.headerSkipBytes)

        let last = SMBWarmUpPlanner.readRange(fileSize: size, fraction: 1)
        #expect(last.upperBound == UInt64(size))
        #expect(last.count == Int(mebibyte))
    }

    @Test("ヘッダ回避幅より小さいファイルでも先頭ブロックを避ける")
    func mediumFileAvoidsLeadingBlock() {
        let size = Int64(2 * mebibyte)
        let range = SMBWarmUpPlanner.readRange(fileSize: size, fraction: 0)
        #expect(range == mebibyte..<(2 * mebibyte))
    }

    @Test("割合が範囲外でもファイル境界を超えない")
    func fractionIsClamped() {
        let size = Int64(64 * mebibyte)
        let below = SMBWarmUpPlanner.readRange(fileSize: size, fraction: -3)
        let above = SMBWarmUpPlanner.readRange(fileSize: size, fraction: 7)
        #expect(below.lowerBound == SMBWarmUpPlanner.headerSkipBytes)
        #expect(above.upperBound == UInt64(size))
    }

    // MARK: - preferredItem

    @Test("動画があれば最大サイズの動画を選ぶ")
    func prefersLargestVideo() {
        let items = [
            file("a.mkv", size: 3_000, type: .video),
            file("big.iso", size: 900_000, type: .other),
            file("b.mp4", size: 5_000, type: .video),
            file("dir", size: nil, type: .directory),
        ]
        #expect(SMBWarmUpPlanner.preferredItem(in: items)?.name == "b.mp4")
    }

    @Test("動画がなければ最大サイズのファイルを選ぶ")
    func fallsBackToLargestFile() {
        let items = [
            file("dir", size: nil, type: .directory),
            file("small.jpg", size: 100, type: .image),
            file("doc.pdf", size: 8_000, type: .pdf),
        ]
        #expect(SMBWarmUpPlanner.preferredItem(in: items)?.name == "doc.pdf")
    }

    @Test("サイズ不明のファイルは 0 として扱い、ディレクトリだけなら nil")
    func handlesUnknownSizesAndDirectories() {
        let mixed = [
            file("unknown.mp4", size: nil, type: .video),
            file("known.mp4", size: 1, type: .video),
        ]
        #expect(SMBWarmUpPlanner.preferredItem(in: mixed)?.name == "known.mp4")
        #expect(SMBWarmUpPlanner.preferredItem(in: [file("dir", size: nil, type: .directory)])?.name == nil)
        #expect(SMBWarmUpPlanner.preferredItem(in: [])?.name == nil)
    }
}
