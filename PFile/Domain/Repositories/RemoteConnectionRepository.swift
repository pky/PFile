import Foundation

@MainActor
protocol RemoteConnectionRepository {
    func fetchAll() async throws -> [RemoteConnection]
    func save(_ connection: RemoteConnection) async throws
    func update(_ connection: RemoteConnection) async throws
    func delete(_ connection: RemoteConnection) async throws
}
