import Foundation

enum SourceDirectoryItemAdapter {
    static func localFile(url: URL, values: URLResourceValues) -> DirectoryItem {
        let isDirectory = values.isDirectory ?? false
        let name = values.name ?? url.lastPathComponent
        return DirectoryItem(
            name: name,
            path: url.path,
            itemType: isDirectory ? .directory : .from(fileName: name),
            size: isDirectory ? nil : values.fileSize.map(Int64.init),
            modifiedAt: values.contentModificationDate,
            createdAt: values.creationDate
        )
    }

    static func photoAsset(
        id: String,
        title: String,
        mediaType: DirectoryItem.ItemType,
        createdAt: Date?
    ) -> DirectoryItem {
        DirectoryItem(
            name: title,
            path: "phasset://\(id)",
            itemType: mediaType,
            size: nil,
            modifiedAt: createdAt,
            createdAt: createdAt,
            fileId: nil
        )
    }

    static func mediaFile(_ file: MediaFile) -> DirectoryItem {
        let itemType: DirectoryItem.ItemType
        switch file.itemTypeRaw {
        case "video":
            itemType = .video
        case "pdf":
            itemType = .pdf
        default:
            itemType = .image
        }
        return DirectoryItem(
            name: file.name,
            path: file.path,
            itemType: itemType,
            size: nil,
            modifiedAt: nil,
            createdAt: nil,
            fileId: file.fileId
        )
    }

    static func watchHistory(_ history: WatchHistory) -> DirectoryItem {
        DirectoryItem(
            name: history.fileName,
            path: history.filePath,
            itemType: .video,
            size: nil,
            modifiedAt: nil,
            createdAt: nil,
            fileId: history.fileId
        )
    }
}
