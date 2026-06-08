@testable import PFile
import Foundation
import Testing

struct MediaViewerRouteTests {

    @Test("リモートブラウザ起点の画像は自然順でページ送りされる")
    func remotePageSource_sortsImagesNaturally() {
        let connection = ModelFactory.makeConnection()
        let image10 = DirectoryItem(name: "10.jpg", path: "/10.jpg", itemType: .image, size: nil, modifiedAt: nil, createdAt: nil)
        let image2 = DirectoryItem(name: "2.jpg", path: "/2.jpg", itemType: .image, size: nil, modifiedAt: nil, createdAt: nil)
        let image1 = DirectoryItem(name: "1.jpg", path: "/1.jpg", itemType: .image, size: nil, modifiedAt: nil, createdAt: nil)
        let note = DirectoryItem(name: "note.txt", path: "/note.txt", itemType: .other, size: nil, modifiedAt: nil, createdAt: nil)

        let route = MediaViewerPageSource
            .remote(connection: connection, items: [image10, note, image2, image1])
            .route(for: image2)

        #expect(route?.items.map(\.name) == ["1.jpg", "2.jpg", "10.jpg"])
    }

    @Test("ローカルブラウザ起点の画像は自然順でページ送りされる")
    func localFolderPageSource_sortsImagesNaturally() {
        let imageB = DirectoryItem(name: "page_12.png", path: "/page_12.png", itemType: .image, size: nil, modifiedAt: nil, createdAt: nil)
        let imageA = DirectoryItem(name: "page_2.png", path: "/page_2.png", itemType: .image, size: nil, modifiedAt: nil, createdAt: nil)

        let route = MediaViewerPageSource
            .localFolder(sourceID: UUID(), items: [imageB, imageA])
            .route(for: imageB)

        #expect(route?.items.map(\.name) == ["page_2.png", "page_12.png"])
    }

    @Test("リスト起点の画像は入力順を維持する")
    func filesPageSource_preservesInputOrderForImages() {
        let connection = ModelFactory.makeConnection()
        let fileA = MediaFile(
            connectionId: connection.id,
            path: "/10.jpg",
            name: "10.jpg",
            itemTypeRaw: "image"
        )
        let fileB = MediaFile(
            connectionId: connection.id,
            path: "/2.jpg",
            name: "2.jpg",
            itemTypeRaw: "image"
        )

        let route = MediaViewerPageSource
            .files(
                sourceID: ContentSource.remote(connection.id).id,
                allFiles: [fileA, fileB],
                connectionResolver: { _ in connection }
            )?
            .route(for: fileA)

        #expect(route?.items.map(\.name) == ["10.jpg", "2.jpg"])
    }
}
