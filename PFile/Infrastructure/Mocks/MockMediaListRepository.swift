import Foundation

final class MockMediaListRepository: MediaListRepository {

    var lists: [MediaList] = []
    var files: [MediaFile] = []

    func fetchAllLists() async throws -> [MediaList] {
        lists.sorted { $0.sortOrder < $1.sortOrder }
    }

    func fetchLists(in scopeID: String) async throws -> [MediaList] {
        lists
            .filter { $0.scopeID == scopeID }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    func createList(name: String, scopeID: String) async throws -> MediaList {
        let order = (lists.filter { $0.scopeID == scopeID }.map(\.sortOrder).max() ?? -1) + 1
        let list = MediaList(name: name, scopeID: scopeID, sortOrder: order)
        lists.append(list)
        return list
    }

    func renameList(_ list: MediaList, to name: String) async throws {
        list.name = name
    }

    func deleteList(_ list: MediaList) async throws {
        lists.removeAll { $0.id == list.id }
    }

    func addItems(_ items: [DirectoryItem], connection: RemoteConnection, to list: MediaList) async throws {
        try await addItems(items, sourceID: list.scopeID.isEmpty ? ContentSource.remote(connection.id).id : list.scopeID, to: list)
    }

    func addItems(_ items: [DirectoryItem], sourceID: String, to list: MediaList) async throws {
        let contentSource = ContentSource.from(id: sourceID)
        let storageID = contentSource?.storageUUID ?? UUID()
        for item in items where item.isMedia {
            let existing: MediaFile?
            if let fid = item.fileId, fid > 0 {
                existing = files.first { $0.sourceID == sourceID && $0.fileId == fid }
            } else {
                existing = files.first { $0.sourceID == sourceID && $0.path == item.path }
            }
            let file: MediaFile
            if let existing {
                if existing.path != item.path { existing.path = item.path }
                if existing.name != item.name { existing.name = item.name }
                if existing.fileId == nil, let fid = item.fileId { existing.fileId = fid }
                file = existing
            } else {
                file = MediaFile(
                    connectionId: storageID,
                    sourceID: sourceID,
                    path: item.path,
                    name: item.name,
                    itemTypeRaw: item.isVideo ? "video" : "image",
                    fileId: item.fileId
                )
                files.append(file)
            }
            if !list.items.contains(where: { $0.id == file.id }) {
                list.items.append(file)
            }
        }
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
    }

    func removeFile(_ file: MediaFile, from list: MediaList) async throws {
        list.items.removeAll { $0.id == file.id }
    }

    func fetchFiles(in list: MediaList) async throws -> [MediaFile] {
        list.items.sorted { $0.addedAt < $1.addedAt }
    }

    func registeredPaths(for sourceID: String) async throws -> Set<String> {
        let refs = try await registeredReferences(for: sourceID)
        return Set(refs.map(\.path))
    }

    func registeredPaths(for connectionId: UUID) async throws -> Set<String> {
        try await registeredPaths(for: ContentSource.remote(connectionId).id)
    }

    func registeredReferences(for sourceID: String) async throws -> [RegisteredMediaReference] {
        files
            .filter { $0.sourceID == sourceID }
            .map { RegisteredMediaReference(path: $0.path, fileId: $0.fileId) }
    }

    func registeredReferences(for connectionId: UUID) async throws -> [RegisteredMediaReference] {
        try await registeredReferences(for: ContentSource.remote(connectionId).id)
    }

    func lists(containing path: String, sourceID: String) async throws -> [MediaList] {
        guard let file = files.first(where: { $0.sourceID == sourceID && $0.path == path }) else {
            return []
        }
        return file.lists
    }

    func lists(containing path: String, connectionId: UUID) async throws -> [MediaList] {
        try await lists(containing: path, sourceID: ContentSource.remote(connectionId).id)
    }
}
