import Foundation
import SwiftData

@Model
final class WatchHistory {

    @Attribute(.unique) var id: UUID
    var sourceID: String = ""
    var filePath: String
    var fileName: String
    /// 最終視聴位置（秒）
    var lastPositionSeconds: Double
    /// 動画の総時間（取得できた場合のみ）
    var durationSeconds: Double?
    /// SMBサーバーの inode 番号。ファイル移動後も同一ファイルとして再解決するために使う
    var fileId: UInt64?
    var watchedAt: Date
    var thumbnailData: Data?

    var connection: RemoteConnection?

    init(
        id: UUID = UUID(),
        sourceID: String = "",
        connection: RemoteConnection? = nil,
        filePath: String,
        fileName: String,
        lastPositionSeconds: Double = 0.0,
        durationSeconds: Double? = nil,
        fileId: UInt64? = nil,
        thumbnailData: Data? = nil
    ) {
        self.id = id
        self.sourceID = sourceID.isEmpty ? connection.map { ContentSource.remote($0.id).id } ?? "" : sourceID
        self.filePath = filePath
        self.fileName = fileName
        self.lastPositionSeconds = lastPositionSeconds
        self.durationSeconds = durationSeconds
        self.fileId = fileId
        self.watchedAt = Date()
        self.thumbnailData = thumbnailData
        self.connection = connection
    }
}

extension WatchHistory {
    func toDirectoryItem() -> DirectoryItem {
        SourceDirectoryItemAdapter.watchHistory(self)
    }
}
