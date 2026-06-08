import Foundation

enum SortKey: String, CaseIterable {
    case name
    case size
    case modifiedAt
    case createdAt

    var displayName: String {
        switch self {
        case .name:       return "名前"
        case .size:       return "サイズ"
        case .modifiedAt: return "更新日時"
        case .createdAt:  return "追加日時"
        }
    }
}

enum SortOrder: String, CaseIterable {
    case ascending
    case descending

    var displayName: String {
        switch self {
        case .ascending:  return "昇順"
        case .descending: return "降順"
        }
    }
}

final class SortService {

    func sort(_ items: [DirectoryItem], by key: SortKey, order: SortOrder, foldersFirst: Bool = false) -> [DirectoryItem] {
        let sorted: [DirectoryItem]
        switch key {
        case .name:
            sorted = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size:
            sorted = items.sorted { ($0.size ?? 0) < ($1.size ?? 0) }
        case .modifiedAt:
            sorted = items.sorted { ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast) }
        case .createdAt:
            sorted = items.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        }
        let ordered = order == .ascending ? sorted : sorted.reversed()
        guard foldersFirst else { return ordered }
        return ordered.filter { $0.isDirectory } + ordered.filter { !$0.isDirectory }
    }
}
