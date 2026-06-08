@testable import PFile
import Foundation
import SwiftData

/// テスト用のモデルインスタンスを生成するファクトリ
/// SwiftData の @Model は ModelContext なしでも生成・参照可能
enum ModelFactory {

    static func makeConnection(
        displayName: String = "テスト接続",
        serviceType: ServiceType = .smb,
        host: String = "nas.example.local",
        port: Int = 445
    ) -> RemoteConnection {
        RemoteConnection(
            displayName: displayName,
            serviceType: serviceType,
            host: host,
            port: port,
            username: "testuser",
            startPath: "/"
        )
    }

    static func makeDirectoryItems() -> [DirectoryItem] {
        [
            DirectoryItem(name: "Movies",    path: "/Movies",           itemType: .directory, size: nil,        modifiedAt: Date(), createdAt: Date()),
            DirectoryItem(name: "movie.mp4", path: "/movie.mp4",        itemType: .video,     size: 1_000_000,  modifiedAt: Date(), createdAt: Date()),
            DirectoryItem(name: "photo.jpg", path: "/photo.jpg",        itemType: .image,     size: 500_000,    modifiedAt: Date(), createdAt: Date()),
            DirectoryItem(name: "data.txt",  path: "/data.txt",         itemType: .other,     size: 1_024,      modifiedAt: Date(), createdAt: Date()),
            DirectoryItem(name: "video.mkv", path: "/video.mkv",        itemType: .video,     size: 2_000_000,  modifiedAt: Date(), createdAt: Date()),
        ]
    }
}
