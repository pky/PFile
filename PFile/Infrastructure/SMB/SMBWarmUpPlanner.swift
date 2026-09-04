import Foundation

/// NAS の HDD を確実に起こすための暖気読み取り計画。
/// ディレクトリ一覧やファイル先頭は NAS 側の RAM キャッシュで返されやすく、
/// 読んでもディスクが休止したままになる。大きな動画の途中をランダムに読んで
/// 確実にディスク I/O を発生させる。
enum SMBWarmUpPlanner {

    static let blockSize: UInt64 = 1024 * 1024

    /// サムネイル生成などで既読になりがちな先頭領域を避ける幅
    static let headerSkipBytes: UInt64 = 16 * 1024 * 1024

    static func readRange(fileSize: Int64?, fraction: Double = .random(in: 0..<1)) -> Range<UInt64> {
        guard let fileSize, fileSize > 0 else { return 0..<blockSize }
        let size = UInt64(fileSize)
        guard size > blockSize else { return 0..<size }

        let maxOffset = size - blockSize
        let minOffset = min(headerSkipBytes, maxOffset)
        let clamped = min(max(fraction, 0), 1)
        let offset = minOffset + UInt64((Double(maxOffset - minOffset) * clamped).rounded(.down))
        return offset..<(offset + blockSize)
    }

    /// 動画があれば最大の動画、なければ最大のファイルを暖気対象にする。
    static func preferredItem(in items: [DirectoryItem]) -> DirectoryItem? {
        let files = items.filter { !$0.isDirectory }
        let candidates = files.contains(where: \.isVideo) ? files.filter(\.isVideo) : files
        return candidates.max { ($0.size ?? 0) < ($1.size ?? 0) }
    }
}
