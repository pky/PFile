@testable import PFile
import Testing
import Foundation

struct SortServiceTests {

    private let service = SortService()

    private func makeItem(name: String, size: Int64, modified: Date) -> DirectoryItem {
        DirectoryItem(name: name, path: "/\(name)", itemType: .video, size: size, modifiedAt: modified, createdAt: nil)
    }

    // MARK: - 名前ソート

    @Test("名前の昇順でソートされる")
    func sort_byName_ascending() {
        let items = [makeItem(name: "c", size: 0, modified: .now),
                     makeItem(name: "a", size: 0, modified: .now),
                     makeItem(name: "b", size: 0, modified: .now)]

        let result = service.sort(items, by: .name, order: .ascending)

        #expect(result.map(\.name) == ["a", "b", "c"])
    }

    @Test("名前の降順でソートされる")
    func sort_byName_descending() {
        let items = [makeItem(name: "a", size: 0, modified: .now),
                     makeItem(name: "c", size: 0, modified: .now),
                     makeItem(name: "b", size: 0, modified: .now)]

        let result = service.sort(items, by: .name, order: .descending)

        #expect(result.map(\.name) == ["c", "b", "a"])
    }

    // MARK: - サイズソート

    @Test("サイズの昇順でソートされる")
    func sort_bySize_ascending() {
        let items = [makeItem(name: "a", size: 300, modified: .now),
                     makeItem(name: "b", size: 100, modified: .now),
                     makeItem(name: "c", size: 200, modified: .now)]

        let result = service.sort(items, by: .size, order: .ascending)

        #expect(result.map(\.size) == [100, 200, 300])
    }

    @Test("サイズの降順でソートされる")
    func sort_bySize_descending() {
        let items = [makeItem(name: "a", size: 100, modified: .now),
                     makeItem(name: "b", size: 300, modified: .now),
                     makeItem(name: "c", size: 200, modified: .now)]

        let result = service.sort(items, by: .size, order: .descending)

        #expect(result.map(\.size) == [300, 200, 100])
    }

    // MARK: - 更新日時ソート

    @Test("更新日時の昇順でソートされる")
    func sort_byModifiedAt_ascending() {
        let base = Date(timeIntervalSince1970: 0)
        let items = [makeItem(name: "newest", size: 0, modified: base.addingTimeInterval(200)),
                     makeItem(name: "oldest", size: 0, modified: base.addingTimeInterval(100)),
                     makeItem(name: "middle", size: 0, modified: base.addingTimeInterval(150))]

        let result = service.sort(items, by: .modifiedAt, order: .ascending)

        #expect(result.map(\.name) == ["oldest", "middle", "newest"])
    }

    // MARK: - 空配列

    @Test("空配列をソートしても空のまま")
    func sort_emptyArray() {
        let result = service.sort([], by: .name, order: .ascending)
        #expect(result.isEmpty)
    }

    // MARK: - 日本語ファイル名

    @Test("日本語ファイル名も正しくソートされる")
    func sort_japaneseNames() {
        let items = [makeItem(name: "動画03", size: 0, modified: .now),
                     makeItem(name: "動画01", size: 0, modified: .now),
                     makeItem(name: "動画02", size: 0, modified: .now)]

        let result = service.sort(items, by: .name, order: .ascending)

        #expect(result.map(\.name) == ["動画01", "動画02", "動画03"])
    }
}
