import Foundation

/// 任意のバイト範囲を非同期で読み出せるデータ源。
/// AVAssetResourceLoader 経由の動画再生で、実機の SMB 源とテスト用メモリ源を同じ口で扱う。
protocol ByteRangeDataSource: AnyObject, Sendable {
    /// ファイル全体のバイト数。0 は不明を表す。
    func contentLength() async throws -> UInt64
    /// 指定範囲（両端含む）を読み出す。末尾を超える範囲は読める分だけ返す。
    func readRange(_ range: ClosedRange<UInt64>) async throws -> Data
}

/// AVAssetResourceLoadingDataRequest から実際に読むべきバイト範囲を決める純粋ロジック。
/// AVFoundation のオブジェクトを直接モックできないため、計算部分だけ切り出してテスト対象にする。
enum ByteRangeResolver {

    /// 要求オフセット・長さ・末尾までフラグ・全体長から、読み出す閉区間を返す。
    /// 読む必要がなければ nil を返す。
    static func resolve(
        requestedOffset: Int64,
        requestedLength: Int,
        requestsAllDataToEnd: Bool,
        currentOffset: Int64,
        totalLength: UInt64
    ) -> ClosedRange<UInt64>? {
        let requestStart = UInt64(max(0, requestedOffset))
        // currentOffset は応答済みの続きを示すので、開始位置だけ前進させる。
        let start = max(requestStart, UInt64(max(0, currentOffset)))

        // 全体長が判明していて、開始が末尾以降なら読むものがない。
        if totalLength > 0, start >= totalLength {
            return nil
        }

        let lastIndex: UInt64 = totalLength > 0 ? totalLength - 1 : UInt64.max

        let end: UInt64
        if requestsAllDataToEnd {
            end = lastIndex
        } else {
            let requested = UInt64(max(0, requestedLength))
            guard requested > 0 else { return nil }
            // 絶対終端 = requestStart + (requested - 1) を末尾でクランプする。
            // ここに来る時点で requestStart <= lastIndex なので lastIndex - requestStart は安全。
            let span = requested - 1
            end = span > lastIndex - requestStart ? lastIndex : requestStart + span
        }

        guard start <= end else { return nil }
        return start...end
    }
}
