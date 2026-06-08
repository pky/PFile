import Foundation
import UIKit

@Observable
@MainActor
final class WatchHistoryListViewModel {

    var histories: [WatchHistory] = []
    var isLoading = false
    var errorMessage: String?
    private(set) var thumbnails: [String: UIImage] = [:]
    private(set) var currentSourceID: String?
    private(set) var connections: [UUID: RemoteConnection] = [:]

    private let watchHistoryRepository: any WatchHistoryRepository
    private let remoteConnectionRepository: (any RemoteConnectionRepository)?
    private let mediaThumbnailProvider: MediaThumbnailProvider?

    init(
        watchHistoryRepository: any WatchHistoryRepository,
        remoteConnectionRepository: (any RemoteConnectionRepository)? = nil,
        mediaThumbnailProvider: MediaThumbnailProvider? = nil
    ) {
        self.watchHistoryRepository = watchHistoryRepository
        self.remoteConnectionRepository = remoteConnectionRepository
        self.mediaThumbnailProvider = mediaThumbnailProvider
    }

    func load(sourceID: String? = nil) async {
        isLoading = true
        currentSourceID = sourceID
        defer { isLoading = false }
        do {
            if let repo = remoteConnectionRepository,
               let all = try? await repo.fetchAll() {
                connections = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
            }
            if let sourceID, !sourceID.isEmpty {
                histories = try await watchHistoryRepository.fetch(for: sourceID)
            } else {
                histories = try await watchHistoryRepository.fetchAll()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ history: WatchHistory) async {
        do {
            try await watchHistoryRepository.delete(history)
            await load(sourceID: currentSourceID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resolvePlayableHistory(_ history: WatchHistory, smbClientManager: SMBClientManager) async -> WatchHistory {
        guard let connection = sourceConnection(for: history),
              connection.serviceType == .smb else {
            return history
        }

        do {
            let repo = try SMBFileRepository(connection: connection, clientManager: smbClientManager)
            if try await repo.fileExists(at: history.filePath) {
                errorMessage = nil
                return history
            }

            guard let fileId = history.fileId, fileId > 0,
                  let resolvedItem = try await repo.findMediaItemRecursively(
                    at: connection.startPath,
                    matchingFileId: fileId
                  ) else {
                return history
            }

            try await watchHistoryRepository.upsert(
                sourceID: source(for: history).id,
                connection: connection,
                filePath: resolvedItem.path,
                fileName: resolvedItem.name,
                lastPositionSeconds: history.lastPositionSeconds,
                durationSeconds: history.durationSeconds,
                fileId: resolvedItem.fileId,
                thumbnailData: history.thumbnailData
            )
            errorMessage = nil
            return history
        } catch {
            errorMessage = error.localizedDescription
            return history
        }
    }

    // MARK: - Thumbnail

    func thumbnail(for history: WatchHistory) -> UIImage? {
        let key = thumbnailKey(for: history)
        if let img = thumbnails[key] { return img }
        if let mediaThumbnailProvider,
           let img = mediaThumbnailProvider.thumbnail(for: source(for: history), item: history.toDirectoryItem()) {
            thumbnails[key] = img
            return img
        }
        if let data = history.thumbnailData, let image = UIImage(data: data) {
            thumbnails[key] = image
            return image
        }
        return nil
    }

    func loadThumbnail(for history: WatchHistory) async {
        let key = thumbnailKey(for: history)
        guard thumbnails[key] == nil else { return }
        if let mediaThumbnailProvider,
           let img = await mediaThumbnailProvider.loadThumbnail(
            for: source(for: history),
            item: history.toDirectoryItem(),
            connection: sourceConnection(for: history)
           ) {
            thumbnails[key] = img
            return
        }
        if let data = history.thumbnailData, let image = UIImage(data: data) {
            thumbnails[key] = image
        }
    }

    private func thumbnailKey(for history: WatchHistory) -> String {
        let item = history.toDirectoryItem()
        return mediaThumbnailProvider?.cacheKey(source: source(for: history), item: item) ?? history.filePath
    }

    private func source(for history: WatchHistory) -> ContentSource {
        if let source = ContentSource.from(id: history.sourceID) {
            return source
        }
        if let connection = history.connection {
            return .remote(connection.id)
        }
        return .photoLibrary
    }

    private func sourceConnection(for history: WatchHistory) -> RemoteConnection? {
        if let connection = history.connection {
            return connection
        }
        guard case .remote(let id) = source(for: history) else { return nil }
        return connections[id]
    }
}
