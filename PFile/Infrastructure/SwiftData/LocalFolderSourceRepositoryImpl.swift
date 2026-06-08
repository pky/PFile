import Foundation
import SwiftData

@MainActor
final class LocalFolderSourceRepositoryImpl: LocalFolderSourceRepository {

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func fetchAll() async throws -> [LocalFolderSource] {
        let descriptor = FetchDescriptor<LocalFolderSource>(
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return try context.fetch(descriptor)
    }

    func save(_ source: LocalFolderSource) async throws {
        if source.modelContext == nil {
            context.insert(source)
        }
        try context.save()
    }

    func delete(_ source: LocalFolderSource) async throws {
        context.delete(source)
        try context.save()
    }
}
