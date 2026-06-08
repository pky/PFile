import Foundation
import UIKit

enum MediaListSortKey: String, CaseIterable {
    case name
    case size
    case addedAt

    var displayName: String {
        switch self {
        case .name: return "名前"
        case .size: return "サイズ"
        case .addedAt: return "追加順"
        }
    }
}

@Observable
@MainActor
final class MediaListDetailViewModel {

    let list: MediaList
    /// list.items から直接計算することで、AddToListSheet 等でアイテムが追加された後も自動反映される
    var files: [MediaFile] { sortFiles(list.items) }
    var isLoading = false
    var errorMessage: String?
    private(set) var thumbnails: [String: UIImage] = [:]
    private(set) var connections: [UUID: RemoteConnection] = [:]
    var sortKey: MediaListSortKey = .addedAt
    var sortOrder: SortOrder = .descending

    private let repository: any MediaListRepository
    private let remoteConnectionRepository: (any RemoteConnectionRepository)?
    private let mediaThumbnailProvider: MediaThumbnailProvider?
    private static let sortKeyDefaultsKey = "MediaListDetail.sortKey"
    private static let sortOrderDefaultsKey = "MediaListDetail.sortOrder"

    init(
        list: MediaList,
        repository: any MediaListRepository,
        remoteConnectionRepository: (any RemoteConnectionRepository)? = nil,
        mediaThumbnailProvider: MediaThumbnailProvider? = nil
    ) {
        self.list = list
        self.repository = repository
        self.remoteConnectionRepository = remoteConnectionRepository
        self.mediaThumbnailProvider = mediaThumbnailProvider
        if let raw = UserDefaults.standard.string(forKey: Self.sortKeyDefaultsKey),
           let saved = MediaListSortKey(rawValue: raw) {
            sortKey = saved
        }
        if let raw = UserDefaults.standard.string(forKey: Self.sortOrderDefaultsKey),
           let saved = SortOrder(rawValue: raw) {
            sortOrder = saved
        }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        if let repo = remoteConnectionRepository,
           let all = try? await repo.fetchAll() {
            connections = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        }
    }

    func removeFile(_ file: MediaFile) async {
        do {
            try await repository.removeFile(file, from: list)
            // files は list.items の computed property のため自動更新
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeFiles(_ files: [MediaFile]) async {
        do {
            for file in files {
                try await repository.removeFile(file, from: list)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Thumbnail

    func thumbnail(for file: MediaFile) -> UIImage? {
        let key = cacheKey(for: file)
        if let img = thumbnails[key] { return img }
        if let mediaThumbnailProvider,
           let img = mediaThumbnailProvider.thumbnail(for: source(for: file), item: file.toDirectoryItem()) {
            thumbnails[key] = img
            return img
        }
        return nil
    }

    func loadThumbnail(for file: MediaFile) async {
        let key = cacheKey(for: file)
        guard thumbnails[key] == nil, let mediaThumbnailProvider else { return }
        let item = file.toDirectoryItem()
        let connection = sourceConnection(for: file)
        guard let img = await mediaThumbnailProvider.loadThumbnail(
            for: source(for: file),
            item: item,
            connection: connection
        ) else { return }
        thumbnails[key] = img
    }

    func applySortChange() {
        UserDefaults.standard.set(sortKey.rawValue, forKey: Self.sortKeyDefaultsKey)
        UserDefaults.standard.set(sortOrder.rawValue, forKey: Self.sortOrderDefaultsKey)
    }

    func resolvePlayableFile(_ file: MediaFile, smbClientManager: SMBClientManager) async -> MediaFile {
        guard let connection = sourceConnection(for: file),
              connection.serviceType == .smb else {
            return file
        }

        do {
            let repo = try SMBFileRepository(connection: connection, clientManager: smbClientManager)
            if try await repo.fileExists(at: file.path) {
                return file
            }

            guard let fileId = file.fileId, fileId > 0,
                  let resolvedItem = try await repo.findMediaItemRecursively(
                    at: connection.startPath,
                    matchingFileId: fileId
                  ) else {
                return file
            }

            try await repository.addItems([resolvedItem], sourceID: file.sourceID, to: list)
            errorMessage = nil
            return list.items.first(where: { $0.id == file.id }) ?? file
        } catch {
            errorMessage = error.localizedDescription
            return file
        }
    }

    private func cacheKey(for file: MediaFile) -> String {
        let item = file.toDirectoryItem()
        return mediaThumbnailProvider?.cacheKey(source: source(for: file), item: item)
            ?? "\(file.sourceID)/\(file.path)"
    }

    private func source(for file: MediaFile) -> ContentSource {
        ContentSource.from(id: file.sourceID) ?? .remote(file.connectionId)
    }

    func sourceConnection(for file: MediaFile) -> RemoteConnection? {
        if let connection = connections[file.connectionId] {
            return connection
        }
        guard file.sourceID.hasPrefix("remote:") else { return nil }
        let rawID = String(file.sourceID.dropFirst("remote:".count))
        guard let uuid = UUID(uuidString: rawID) else { return nil }
        return connections[uuid]
    }

    private func sortFiles(_ files: [MediaFile]) -> [MediaFile] {
        let sorted: [MediaFile]
        switch sortKey {
        case .name:
            sorted = files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size:
            sorted = files.sorted { ($0.fileSize ?? 0) < ($1.fileSize ?? 0) }
        case .addedAt:
            sorted = files.sorted { $0.addedAt < $1.addedAt }
        }
        return sortOrder == .ascending ? sorted : Array(sorted.reversed())
    }

}
