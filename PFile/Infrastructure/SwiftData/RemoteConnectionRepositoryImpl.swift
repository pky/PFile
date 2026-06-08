import Foundation
import SwiftData

@MainActor
final class RemoteConnectionRepositoryImpl: RemoteConnectionRepository {

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func fetchAll() async throws -> [RemoteConnection] {
        let descriptor = FetchDescriptor<RemoteConnection>(
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return try context.fetch(descriptor)
    }

    func save(_ connection: RemoteConnection) async throws {
        context.insert(connection)
        try context.save()
    }

    func update(_ connection: RemoteConnection) async throws {
        try context.save()
    }

    func delete(_ connection: RemoteConnection) async throws {
        context.delete(connection)
        try context.save()
    }
}
