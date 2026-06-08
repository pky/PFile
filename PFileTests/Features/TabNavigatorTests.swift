@testable import PFile
import Foundation
import Testing

struct TabNavigatorTests {

    // MARK: - allTabs

    @Test("リストなしのとき browse と history の2タブ")
    func allTabs_noLists() {
        let tabs = TabNavigator.allTabs(lists: [])
        #expect(tabs == [.browse, .history])
    }

    @Test("リストありのとき末尾に list タブが並ぶ")
    func allTabs_withLists() {
        let id1 = UUID()
        let id2 = UUID()
        let lists = [
            MediaList(id: id1, name: "A", sortOrder: 0),
            MediaList(id: id2, name: "B", sortOrder: 1),
        ]
        let tabs = TabNavigator.allTabs(lists: lists)
        #expect(tabs == [.browse, .history, .list(id1), .list(id2)])
    }

    // MARK: - adjacentTab

    @Test("browse から offset +1 で history を返す")
    func adjacentTab_nextFromBrowse() {
        let tabs = TabNavigator.allTabs(lists: [])
        let result = TabNavigator.adjacentTab(to: .browse, in: tabs, offset: 1)
        #expect(result == .history)
    }

    @Test("browse から offset -1 で nil を返す（境界外）")
    func adjacentTab_prevFromBrowse() {
        let tabs = TabNavigator.allTabs(lists: [])
        let result = TabNavigator.adjacentTab(to: .browse, in: tabs, offset: -1)
        #expect(result == nil)
    }

    @Test("最後のタブから offset +1 で nil を返す（境界外）")
    func adjacentTab_nextFromLast() {
        let id = UUID()
        let lists = [MediaList(id: id, name: "X", sortOrder: 0)]
        let tabs = TabNavigator.allTabs(lists: lists)
        let result = TabNavigator.adjacentTab(to: .list(id), in: tabs, offset: 1)
        #expect(result == nil)
    }

    @Test("history から offset +1 でリストタブを返す")
    func adjacentTab_nextFromHistory() {
        let id = UUID()
        let lists = [MediaList(id: id, name: "X", sortOrder: 0)]
        let tabs = TabNavigator.allTabs(lists: lists)
        let result = TabNavigator.adjacentTab(to: .history, in: tabs, offset: 1)
        #expect(result == .list(id))
    }
}

@MainActor
struct BrowsePathStoreTests {

    @Test("enterDirectory で currentPath と deepestPath が更新される")
    func enterDirectory_updatesCurrentAndDeepest() {
        let store = BrowsePathStore()
        let source = ContentSource.remote(UUID())

        store.enterDirectory("/share/movies", for: source, rootPath: "/share")
        let state = store.state(for: source, rootPath: "/share")

        #expect(state.currentPath == "/share/movies")
        #expect(state.deepestPath == "/share/movies")
        #expect(state.pathStack == ["/share/movies"])
        #expect(state.deepestPathStack == ["/share/movies"])
    }

    @Test("jumpToBreadcrumb で currentPath だけ戻り deepestPath は保持される")
    func jumpToBreadcrumb_preservesDeepestPath() {
        let store = BrowsePathStore()
        let source = ContentSource.remote(UUID())

        store.enterDirectory("/share/movies", for: source, rootPath: "/share")
        store.enterDirectory("/share/movies/action", for: source, rootPath: "/share")

        let target = store.jumpToBreadcrumb(index: 0, for: source, rootPath: "/share")
        let state = store.state(for: source, rootPath: "/share")

        #expect(target == "/share/movies")
        #expect(state.currentPath == "/share/movies")
        #expect(state.deepestPath == "/share/movies/action")
        #expect(state.pathStack == ["/share/movies"])
        #expect(state.deepestPathStack == ["/share/movies", "/share/movies/action"])
    }

    @Test("ソースごとに状態が分離される")
    func states_areIsolatedPerSource() {
        let store = BrowsePathStore()
        let remote = ContentSource.remote(UUID())
        let local = ContentSource.localFolder(UUID())

        store.enterDirectory("/share/movies", for: remote, rootPath: "/share")
        store.enterDirectory("/local/example/videos", for: local, rootPath: "/local/example")

        let remoteState = store.state(for: remote, rootPath: "/share")
        let localState = store.state(for: local, rootPath: "/local/example")

        #expect(remoteState.currentPath == "/share/movies")
        #expect(localState.currentPath == "/local/example/videos")
    }

    @Test("restoreDeepestPath で最後の最下層を復元できる")
    func restoreDeepestPath_returnsLastDeepestPath() {
        let store = BrowsePathStore()
        let source = ContentSource.localFolder(UUID())

        store.enterDirectory("/local/example/a", for: source, rootPath: "/local/example")
        store.jumpToPath("/local/example", for: source, rootPath: "/local/example")

        let restored = store.restoreDeepestPath(for: source, rootPath: "/local/example")

        #expect(restored == "/local/example/a")
    }
}
