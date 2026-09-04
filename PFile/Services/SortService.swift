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

/// ブラウズとリストで同じ並び替え規則を共有するための最小の属性。
protocol FileSortable {
    var sortableName: String { get }
    var sortableSize: Int64? { get }
    var sortableModifiedAt: Date? { get }
    var sortableCreatedAt: Date? { get }
}

extension DirectoryItem: FileSortable {
    var sortableName: String { name }
    var sortableSize: Int64? { size }
    var sortableModifiedAt: Date? { modifiedAt }
    var sortableCreatedAt: Date? { createdAt }
}

extension MediaFile: FileSortable {
    var sortableName: String { name }
    var sortableSize: Int64? { fileSize }
    var sortableModifiedAt: Date? { sourceModifiedAt }
    var sortableCreatedAt: Date? { sourceCreatedAt }
}

final class SortService {

    func sort(_ items: [DirectoryItem], by key: SortKey, order: SortOrder, foldersFirst: Bool = false) -> [DirectoryItem] {
        let ordered = sortFiles(items, by: key, order: order)
        guard foldersFirst else { return ordered }
        return ordered.filter { $0.isDirectory } + ordered.filter { !$0.isDirectory }
    }

    /// ブラウズとリストで共通の並び替え。
    func sortFiles<T: FileSortable>(_ items: [T], by key: SortKey, order: SortOrder) -> [T] {
        let sorted: [T]
        switch key {
        case .name:
            sorted = items.sorted { $0.sortableName.localizedStandardCompare($1.sortableName) == .orderedAscending }
        case .size:
            sorted = items.sorted { ($0.sortableSize ?? 0) < ($1.sortableSize ?? 0) }
        case .modifiedAt:
            sorted = items.sorted { ($0.sortableModifiedAt ?? .distantPast) < ($1.sortableModifiedAt ?? .distantPast) }
        case .createdAt:
            sorted = items.sorted { ($0.sortableCreatedAt ?? .distantPast) < ($1.sortableCreatedAt ?? .distantPast) }
        }
        return order == .ascending ? sorted : sorted.reversed()
    }
}
