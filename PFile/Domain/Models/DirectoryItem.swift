import Foundation

struct DirectoryItem: Identifiable {

    let id = UUID()
    let name: String
    let path: String
    let itemType: ItemType
    let size: Int64?
    let modifiedAt: Date?
    let createdAt: Date?
    /// SMBサーバーの inode 番号（smb2_ino）。ファイル移動後も同一FS内なら変わらない。0 またはnil は未取得
    var fileId: UInt64? = nil

    enum ItemType {
        case directory
        case video
        case image
        case pdf
        case other
    }
}

// MARK: - ItemType helpers

extension DirectoryItem.ItemType {

    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "wmv", "flv",
        "webm", "ts", "m2ts", "mpg", "mpeg", "rmvb", "3gp",
    ]

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif",
        "webp", "bmp", "tiff", "tif",
    ]

    private static let pdfExtensions: Set<String> = [
        "pdf",
    ]

    static func from(fileName: String) -> DirectoryItem.ItemType {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if videoExtensions.contains(ext) { return .video }
        if imageExtensions.contains(ext) { return .image }
        if pdfExtensions.contains(ext) { return .pdf }
        return .other
    }
}

extension DirectoryItem {
    var isDirectory: Bool { itemType == .directory }
    var isVideo: Bool { itemType == .video }
    var isImage: Bool { itemType == .image }
    var isPDF: Bool { itemType == .pdf }
    var isMedia: Bool { isVideo || isImage }
}
