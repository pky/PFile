import Foundation

/// ディレクトリリスト表示時にサムネイルや動画の先読みを行う
final class PrefetchManager {

    private var activeTasks: [String: Task<Void, Never>] = [:]

    func prefetch(items: [DirectoryItem], fileRepository: any FileRepository, thumbnailService: ThumbnailService) {
        for item in items where item.isMedia {
            guard activeTasks[item.path] == nil else { continue }
            let task = Task(priority: .utility) {
                // サムネイル生成処理は VideoPlayer / ImageViewer の実装時に追加
                _ = item.path
            }
            activeTasks[item.path] = task
        }
    }

    func cancel(for path: String) {
        activeTasks[path]?.cancel()
        activeTasks.removeValue(forKey: path)
    }

    func cancelAll() {
        activeTasks.values.forEach { $0.cancel() }
        activeTasks.removeAll()
    }
}
