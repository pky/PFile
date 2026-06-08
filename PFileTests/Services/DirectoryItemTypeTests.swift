@testable import PFile
import Testing

struct DirectoryItemTypeTests {

    // MARK: - 動画拡張子

    @Test("動画拡張子は .video と判定される", arguments: [
        "movie.mp4", "clip.mov", "film.m4v", "video.avi", "stream.mkv",
        "windows.wmv", "flash.flv", "web.webm", "tv.ts", "broadcast.m2ts",
        "old.mpg", "old2.mpeg", "realvideo.rmvb", "mobile.3gp",
    ])
    func videoExtensions(fileName: String) {
        #expect(DirectoryItem.ItemType.from(fileName: fileName) == .video)
    }

    // MARK: - 画像拡張子

    @Test("画像拡張子は .image と判定される", arguments: [
        "photo.jpg", "photo.jpeg", "image.png", "animation.gif",
        "apple.heic", "apple.heif", "modern.webp", "old.bmp",
        "print.tiff", "print.tif",
    ])
    func imageExtensions(fileName: String) {
        #expect(DirectoryItem.ItemType.from(fileName: fileName) == .image)
    }

    // MARK: - その他拡張子

    @Test("非メディアファイルは .other と判定される", arguments: [
        "doc.pdf", "text.txt", "data.csv", "archive.zip", "code.swift",
    ])
    func otherExtensions(fileName: String) {
        #expect(DirectoryItem.ItemType.from(fileName: fileName) == .other)
    }

    // MARK: - 大文字拡張子

    @Test("大文字の拡張子も正しく判定される")
    func uppercaseExtension() {
        #expect(DirectoryItem.ItemType.from(fileName: "MOVIE.MP4") == .video)
        #expect(DirectoryItem.ItemType.from(fileName: "PHOTO.JPG") == .image)
    }
}
