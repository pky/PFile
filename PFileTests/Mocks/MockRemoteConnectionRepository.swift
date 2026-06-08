@testable import PFile
import Foundation

final class MockRemoteConnectionRepository: RemoteConnectionRepository {

    var connections: [RemoteConnection] = []
    var savedConnections: [RemoteConnection] = []
    var updatedConnections: [RemoteConnection] = []
    var deletedConnections: [RemoteConnection] = []
    var shouldThrow = false

    func fetchAll() async throws -> [RemoteConnection] {
        if shouldThrow { throw TestError.mock }
        return connections
    }

    func save(_ connection: RemoteConnection) async throws {
        if shouldThrow { throw TestError.mock }
        savedConnections.append(connection)
        connections.append(connection)
    }

    func update(_ connection: RemoteConnection) async throws {
        if shouldThrow { throw TestError.mock }
        updatedConnections.append(connection)
    }

    func delete(_ connection: RemoteConnection) async throws {
        if shouldThrow { throw TestError.mock }
        deletedConnections.append(connection)
        connections.removeAll { $0.id == connection.id }
    }
}
