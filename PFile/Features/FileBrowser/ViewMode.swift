import Foundation

enum ViewMode: String, CaseIterable {
    case list
    case listDetail

    // 注: grid は Swift の予約語に近いため gridTitled を使う
    case gridTitled
    case gridNoTitle
    case gridDetail

    var displayName: String {
        switch self {
        case .list:        return "リスト"
        case .listDetail:  return "詳細リスト"
        case .gridTitled:  return "グリッド"
        case .gridNoTitle: return "グリッド（タイトルなし）"
        case .gridDetail:  return "詳細グリッド"
        }
    }

    var systemImage: String {
        switch self {
        case .list:        return "list.bullet"
        case .listDetail:  return "list.bullet.indent"
        case .gridTitled:  return "square.grid.3x3"
        case .gridNoTitle: return "square.grid.4x3.fill"
        case .gridDetail:  return "square.grid.2x2"
        }
    }

    var isListMode: Bool {
        self == .list || self == .listDetail
    }
}
