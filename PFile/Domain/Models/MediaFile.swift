import Foundation
import SwiftData

// MARK: - MediaFile → DirectoryItem 変換

extension MediaFile {
    func toDirectoryItem() -> DirectoryItem {
        SourceDirectoryItemAdapter.mediaFile(self)
    }

    var displaySubtitle: String {
        if sourceID == ContentSource.photoLibrary.id {
            return itemTypeRaw == "video" ? "フォトライブラリの動画" : "フォトライブラリの写真"
        }
        if sourceID.hasPrefix("localFolder:") {
            let directory = (path as NSString).deletingLastPathComponent
            let abbreviated = (directory as NSString).abbreviatingWithTildeInPath
            return abbreviated.isEmpty ? "ローカルフォルダ" : abbreviated
        }
        return path
    }
}

@Model
final class MediaFile {

    @Attribute(.unique) var id: UUID
    var connectionId: UUID
    var sourceID: String = ""
    var path: String
    var name: String
    var itemTypeRaw: String
    var addedAt: Date
    var fileSize: Int64?
    /// SMBサーバーの inode 番号。同一FS内でのファイル移動後も変わらない（サーバー依存）
    var fileId: UInt64?
    @Relationship(deleteRule: .nullify)
    var lists: [MediaList] = []

    init(
        id: UUID = UUID(),
        connectionId: UUID,
        sourceID: String = "",
        path: String,
        name: String,
        itemTypeRaw: String,
        fileId: UInt64? = nil,
        fileSize: Int64? = nil,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.connectionId = connectionId
        self.sourceID = sourceID.isEmpty ? ContentSource.remote(connectionId).id : sourceID
        self.path = path
        self.name = name
        self.itemTypeRaw = itemTypeRaw
        self.fileId = fileId
        self.fileSize = fileSize
        self.addedAt = addedAt
    }
}
