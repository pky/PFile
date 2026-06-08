import Foundation

@MainActor
protocol LocalFolderSourceRepository {
    func fetchAll() async throws -> [LocalFolderSource]
    func save(_ source: LocalFolderSource) async throws
    func delete(_ source: LocalFolderSource) async throws
}
