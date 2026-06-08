import SwiftUI
import SwiftData

struct BrowsePathState: Equatable {
    let sourceID: String
    let rootPath: String
    var currentPath: String
    var deepestPath: String
    var pathStack: [String]
    var deepestPathStack: [String]

    init(sourceID: String, rootPath: String, currentPath: String, deepestPath: String) {
        self.sourceID = sourceID
        self.rootPath = BrowsePathStore.normalize(path: rootPath)
        self.currentPath = BrowsePathStore.normalize(path: currentPath)
        self.deepestPath = BrowsePathStore.normalize(path: deepestPath)
        self.pathStack = BrowsePathStore.buildPathStack(rootPath: self.rootPath, targetPath: self.currentPath)
        self.deepestPathStack = BrowsePathStore.buildPathStack(rootPath: self.rootPath, targetPath: self.deepestPath)
    }
}

@Observable
@MainActor
final class BrowsePathStore {
    private var states: [String: BrowsePathState] = [:]

    func state(for source: ContentSource, rootPath: String) -> BrowsePathState {
        let normalizedRoot = Self.normalize(path: rootPath)
        if let existing = states[source.id], existing.rootPath == normalizedRoot {
            return existing
        }

        let initialState = BrowsePathState(
            sourceID: source.id,
            rootPath: normalizedRoot,
            currentPath: normalizedRoot,
            deepestPath: normalizedRoot
        )
        states[source.id] = initialState
        return initialState
    }

    func syncCurrentPath(_ path: String, for source: ContentSource, rootPath: String) {
        let existing = state(for: source, rootPath: rootPath)
        let updated = BrowsePathState(
            sourceID: source.id,
            rootPath: existing.rootPath,
            currentPath: path,
            deepestPath: existing.deepestPath
        )
        states[source.id] = updated
    }

    func enterDirectory(_ path: String, for source: ContentSource, rootPath: String) {
        let existing = state(for: source, rootPath: rootPath)
        let normalizedPath = Self.normalize(path: path)
        let updated = BrowsePathState(
            sourceID: source.id,
            rootPath: existing.rootPath,
            currentPath: normalizedPath,
            deepestPath: normalizedPath
        )
        states[source.id] = updated
    }

    func jumpToPath(_ path: String, for source: ContentSource, rootPath: String) {
        let existing = state(for: source, rootPath: rootPath)
        let updated = BrowsePathState(
            sourceID: source.id,
            rootPath: existing.rootPath,
            currentPath: path,
            deepestPath: existing.deepestPath
        )
        states[source.id] = updated
    }

    func jumpToBreadcrumb(index: Int, for source: ContentSource, rootPath: String) -> String {
        let existing = state(for: source, rootPath: rootPath)
        if index < 0 {
            jumpToPath(existing.rootPath, for: source, rootPath: rootPath)
            return existing.rootPath
        }

        guard existing.deepestPathStack.indices.contains(index) else {
            return existing.currentPath
        }

        let targetPath = existing.deepestPathStack[index]
        jumpToPath(targetPath, for: source, rootPath: rootPath)
        return targetPath
    }

    func restoreDeepestPath(for source: ContentSource, rootPath: String) -> String? {
        state(for: source, rootPath: rootPath).deepestPath
    }

    nonisolated static func navigationPath(from rootPath: String, to targetPath: String) -> [String] {
        buildPathStack(rootPath: normalize(path: rootPath), targetPath: normalize(path: targetPath))
    }

    nonisolated static func displaySegments(rootPath: String, stack: [String]) -> [String] {
        let normalizedRoot = normalize(path: rootPath)
        return stack.map { fullPath in
            let normalizedPath = normalize(path: fullPath)
            let relative = relativePath(from: normalizedRoot, to: normalizedPath)
            return relative.split(separator: "/").last.map(String.init) ?? normalizedPath
        }
    }

    nonisolated static func normalize(path: String) -> String {
        guard path.count > 1 else { return path }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    nonisolated static func buildPathStack(rootPath: String, targetPath: String) -> [String] {
        let normalizedRoot = normalize(path: rootPath)
        let normalizedTarget = normalize(path: targetPath)
        let relative = relativePath(from: normalizedRoot, to: normalizedTarget)
        guard !relative.isEmpty else { return [] }

        var current = normalizedRoot
        var results: [String] = []

        for component in relative.split(separator: "/") {
            if current == "/" {
                current += String(component)
            } else {
                current += "/\(component)"
            }
            results.append(current)
        }

        return results
    }

    private nonisolated static func relativePath(from rootPath: String, to targetPath: String) -> String {
        let normalizedRoot = normalize(path: rootPath)
        let normalizedTarget = normalize(path: targetPath)

        guard normalizedTarget.hasPrefix(normalizedRoot) else {
            return normalizedTarget.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        let relative = String(normalizedTarget.dropFirst(normalizedRoot.count))
        return relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

@Observable
final class AppEnvironment {

    /// アプリ起動時にセットされるシングルトン参照。
    /// @Environment(\.appEnvironment) のデフォルト値として使われる。
    nonisolated(unsafe) private(set) static var main: AppEnvironment?

    let modelContainer: ModelContainer

    let remoteConnectionRepository: any RemoteConnectionRepository
    let localFolderSourceRepository: any LocalFolderSourceRepository
    let mediaListRepository: any MediaListRepository
    let watchHistoryRepository: any WatchHistoryRepository
    let playbackHistoryService: PlaybackHistoryService
    let purchaseService: PurchaseService

    let smbClientManager: SMBClientManager
    let appDataBackupService: AppDataBackupService
    let thumbnailService: ThumbnailService
    let mediaThumbnailProvider: MediaThumbnailProvider
    let prefetchManager: PrefetchManager
    let viewPreferences: ViewPreferences
    let browsePathStore: BrowsePathStore

    @MainActor
    init() {
        let schema = Schema([
            RemoteConnection.self,
            LocalFolderSource.self,
            MediaList.self,
            MediaFile.self,
            WatchHistory.self,
        ])
        let config = ModelConfiguration(schema: schema)
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("SwiftDataストアの初期化に失敗しました。既存データ保護のためストアは削除していません: \(error)")
        }
        self.modelContainer = container

        let context = container.mainContext
        self.remoteConnectionRepository = RemoteConnectionRepositoryImpl(context: context)
        self.localFolderSourceRepository = LocalFolderSourceRepositoryImpl(context: context)
        self.mediaListRepository = MediaListRepositoryImpl(context: context)
        self.watchHistoryRepository = WatchHistoryRepositoryImpl(context: context)

        self.smbClientManager = SMBClientManager()
        self.appDataBackupService = AppDataBackupService(
            modelContainer: container,
            smbClientManager: self.smbClientManager
        )
        self.thumbnailService = ThumbnailService()
        self.mediaThumbnailProvider = MediaThumbnailProvider(
            thumbnailService: self.thumbnailService,
            smbClientManager: self.smbClientManager
        )
        self.playbackHistoryService = PlaybackHistoryService(
            repository: self.watchHistoryRepository,
            mediaThumbnailProvider: self.mediaThumbnailProvider
        )
        self.prefetchManager = PrefetchManager()
        self.viewPreferences = ViewPreferences()
        self.browsePathStore = BrowsePathStore()
        self.purchaseService = PurchaseService()

        // EnvironmentKey のデフォルト値として使えるよう自身を登録
        AppEnvironment.main = self
    }
}
