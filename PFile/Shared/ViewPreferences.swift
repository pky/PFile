import SwiftUI

/// 表示設定（viewMode・gridCellWidth）をアプリ全体で共有する
@Observable
final class ViewPreferences {

    var viewMode: ViewMode = .list {
        didSet {
            UserDefaults.standard.set(viewMode.rawValue, forKey: Self.viewModeKey)
        }
    }

    var gridCellWidth: CGFloat = 150 {
        didSet {
            let clamped = max(Self.minCellWidth, min(Self.maxCellWidth, gridCellWidth))
            UserDefaults.standard.set(Double(clamped), forKey: Self.gridCellWidthKey)
            if clamped != gridCellWidth { gridCellWidth = clamped }
        }
    }

    static let viewModeKey      = "FileBrowser.viewMode"
    static let gridCellWidthKey = "FileBrowser.gridCellWidth"
    static let minCellWidth: CGFloat = 80
    static let maxCellWidth: CGFloat = 280

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.viewModeKey),
           let mode = ViewMode(rawValue: raw) { self.viewMode = mode }
        let savedWidth = UserDefaults.standard.double(forKey: Self.gridCellWidthKey)
        if savedWidth > 0 {
            self.gridCellWidth = max(Self.minCellWidth, min(Self.maxCellWidth, CGFloat(savedWidth)))
        }
    }
}
