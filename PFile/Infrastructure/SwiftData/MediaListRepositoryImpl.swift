import Foundation
import SwiftData

@MainActor
final class MediaListRepositoryImpl: MediaListRepository {

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - リスト操作

    func fetchAllLists() async throws -> [MediaList] {
        let descriptor = FetchDescriptor<MediaList>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
        )
        return try context.fetch(descriptor)
    }

    func fetchLists(in scopeID: String) async throws -> [MediaList] {
        let descriptor = FetchDescriptor<MediaList>(
            predicate: #Predicate<MediaList> { $0.scopeID == scopeID },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
        )
        return try context.fetch(descriptor)
    }

    func createList(name: String, scopeID: String) async throws -> MediaList {
        let all = try await fetchLists(in: scopeID)
        let nextOrder = (all.map(\.sortOrder).max() ?? -1) + 1
        let list = MediaList(name: name, scopeID: scopeID, sortOrder: nextOrder)
        context.insert(list)
        try context.save()
        return list
    }

    func renameList(_ list: MediaList, to name: String) async throws {
        list.name = name
        try context.save()
    }

    func deleteList(_ list: MediaList) async throws {
        context.delete(list)
        try context.save()
    }

    // MARK: - ファイル操作

    func addItems(_ items: [DirectoryItem], connection: RemoteConnection, to list: MediaList) async throws {
        try await addItems(items, sourceID: list.scopeID.isEmpty ? ContentSource.remote(connection.id).id : list.scopeID, to: list)
    }

    func addItems(_ items: [DirectoryItem], sourceID: String, to list: MediaList) async throws {
        let allFiles = try context.fetch(FetchDescriptor<MediaFile>())
        let contentSource = ContentSource.from(id: sourceID)
        let storageID = contentSource?.storageUUID ?? UUID()
        for item in items where item.isMedia {
            // fileId（inode）があれば優先して検索。ファイル移動後も同一ファイルとして扱える
            let existing: MediaFile?
            if let fid = item.fileId, fid > 0 {
                existing = allFiles.first { $0.sourceID == sourceID && $0.fileId == fid }
            } else {
                existing = allFiles.first { $0.sourceID == sourceID && $0.path == item.path }
            }
            let file: MediaFile
            if let existing {
                // ファイルが移動またはリネームされていた場合はパスと名前を最新化
                if existing.path != item.path { existing.path = item.path }
                if existing.name != item.name { existing.name = item.name }
                if existing.fileId == nil, let fid = item.fileId { existing.fileId = fid }
                if let size = item.size { existing.fileSize = size }
                file = existing
            } else {
                file = MediaFile(
                    connectionId: storageID,
                    sourceID: sourceID,
                    path: item.path,
                    name: item.name,
                    itemTypeRaw: item.isVideo ? "video" : "image",
                    fileId: item.fileId,
                    fileSize: item.size
                )
                context.insert(file)
            }
            if !list.items.contains(where: { $0.id == file.id }) {
                list.items.append(file)
            }
        }
        try context.save()
    }

    func removeItems(_ items: [DirectoryItem], sourceID: String, from list: MediaList) async throws {
        let targets = items.filter(\.isMedia)
        guard !targets.isEmpty else { return }

        list.items.removeAll { file in
            guard file.sourceID == sourceID else { return false }
            return targets.contains { item in
                if let itemFileId = item.fileId, itemFileId > 0 {
                    return file.fileId == itemFileId
                }
                return file.path == item.path
            }
        }
        try context.save()
    }

    func removeFile(_ file: MediaFile, from list: MediaList) async throws {
        list.items.removeAll { $0.id == file.id }
        try context.save()
    }

    func fetchFiles(in list: MediaList) async throws -> [MediaFile] {
        list.items.sorted { $0.addedAt < $1.addedAt }
    }

    // MARK: - クエリ

    func registeredPaths(for sourceID: String) async throws -> Set<String> {
        let refs = try await registeredReferences(for: sourceID)
        return Set(refs.map(\.path))
    }

    func registeredPaths(for connectionId: UUID) async throws -> Set<String> {
        try await registeredPaths(for: ContentSource.remote(connectionId).id)
    }

    func registeredReferences(for sourceID: String) async throws -> [RegisteredMediaReference] {
        let all = try context.fetch(FetchDescriptor<MediaFile>())
        return all
            .filter { $0.sourceID == sourceID }
            .map { RegisteredMediaReference(path: $0.path, fileId: $0.fileId) }
    }

    func registeredReferences(for connectionId: UUID) async throws -> [RegisteredMediaReference] {
        try await registeredReferences(for: ContentSource.remote(connectionId).id)
    }

    func lists(containing path: String, sourceID: String) async throws -> [MediaList] {
        let all = try context.fetch(FetchDescriptor<MediaFile>())
        guard let file = all.first(where: { $0.sourceID == sourceID && $0.path == path }) else {
            return []
        }
        return file.lists
    }

    func lists(containing path: String, connectionId: UUID) async throws -> [MediaList] {
        try await lists(containing: path, sourceID: ContentSource.remote(connectionId).id)
    }
}
