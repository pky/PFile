import Foundation
import SwiftData

@Model
final class LocalFolderSource {

    @Attribute(.unique) var id: UUID
    var displayName: String
    var bookmarkData: Data
    var createdAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        bookmarkData: Data,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.bookmarkData = bookmarkData
        self.createdAt = createdAt
    }
}
