import Foundation

struct RegisteredMediaReference: Hashable, Sendable {
    let path: String
    let fileId: UInt64?
}

@MainActor
protocol MediaListRepository {

    // リスト操作
    func fetchAllLists() async throws -> [MediaList]
    func fetchLists(in scopeID: String) async throws -> [MediaList]
    func createList(name: String, scopeID: String) async throws -> MediaList
    func renameList(_ list: MediaList, to name: String) async throws
    func deleteList(_ list: MediaList) async throws

    // ファイル操作
    func addItems(_ items: [DirectoryItem], connection: RemoteConnection, to list: MediaList) async throws
    func addItems(_ items: [DirectoryItem], sourceID: String, to list: MediaList) async throws
    func removeItems(_ items: [DirectoryItem], sourceID: String, from list: MediaList) async throws
    func removeFile(_ file: MediaFile, from list: MediaList) async throws
    func fetchFiles(in list: MediaList) async throws -> [MediaFile]

    // クエリ
    func registeredPaths(for sourceID: String) async throws -> Set<String>
    func registeredPaths(for connectionId: UUID) async throws -> Set<String>
    func registeredReferences(for sourceID: String) async throws -> [RegisteredMediaReference]
    func registeredReferences(for connectionId: UUID) async throws -> [RegisteredMediaReference]
    func lists(containing path: String, sourceID: String) async throws -> [MediaList]
    func lists(containing path: String, connectionId: UUID) async throws -> [MediaList]
}
