import Foundation
import SwiftData

@Model
final class MediaList {

    @Attribute(.unique) var id: UUID
    var name: String
    var scopeID: String = ""
    var sortOrder: Int
    var createdAt: Date
    @Relationship(deleteRule: .nullify, inverse: \MediaFile.lists)
    var items: [MediaFile] = []

    init(
        id: UUID = UUID(),
        name: String,
        scopeID: String = "",
        sortOrder: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.scopeID = scopeID
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}
