import Foundation

enum AppTab: String, CaseIterable, Codable {
    case browser
    case lists
    case history

    var title: String {
        switch self {
        case .browser: return "ブラウザ"
        case .lists:   return "リスト"
        case .history: return "履歴"
        }
    }

    var systemImage: String {
        switch self {
        case .browser: return "folder"
        case .lists:   return "list.bullet"
        case .history: return "clock"
        }
    }
}

@Observable
final class TabOrderService {

    static let shared = TabOrderService()

    private static let defaultsKey = "App.tabOrder"

    var tabs: [AppTab] {
        didSet { save(tabs) }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([AppTab].self, from: data) {
            // 保存済み配列に存在しないタブを末尾に追加
            let missing = AppTab.allCases.filter { !decoded.contains($0) }
            tabs = decoded + missing
        } else {
            tabs = AppTab.allCases
        }
    }

    func save(_ tabs: [AppTab]) {
        if let data = try? JSONEncoder().encode(tabs) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
