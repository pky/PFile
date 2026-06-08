@testable import PFile
import Foundation
import Testing

struct ViewPreferencesTests {

    // MARK: - viewMode

    @Test("viewMode のデフォルトは list")
    func viewMode_default() {
        let prefs = ViewPreferences()
        #expect(prefs.viewMode == .list)
    }

    @Test("viewMode を変更すると UserDefaults に保存される")
    func viewMode_persistsToUserDefaults() {
        let prefs = ViewPreferences()
        prefs.viewMode = .gridTitled

        let raw = UserDefaults.standard.string(forKey: ViewPreferences.viewModeKey)
        #expect(raw == ViewMode.gridTitled.rawValue)

        UserDefaults.standard.removeObject(forKey: ViewPreferences.viewModeKey)
    }

    @Test("UserDefaults に保存済みの viewMode が init で復元される")
    func viewMode_restoredFromUserDefaults() {
        UserDefaults.standard.set(ViewMode.gridNoTitle.rawValue, forKey: ViewPreferences.viewModeKey)
        let prefs = ViewPreferences()
        #expect(prefs.viewMode == .gridNoTitle)

        UserDefaults.standard.removeObject(forKey: ViewPreferences.viewModeKey)
    }

    // MARK: - gridCellWidth

    @Test("gridCellWidth のデフォルトは 150")
    func gridCellWidth_default() {
        let prefs = ViewPreferences()
        #expect(prefs.gridCellWidth == 150)
    }

    @Test("gridCellWidth を変更すると UserDefaults に保存される")
    func gridCellWidth_persistsToUserDefaults() {
        let prefs = ViewPreferences()
        prefs.gridCellWidth = 200

        let saved = UserDefaults.standard.double(forKey: ViewPreferences.gridCellWidthKey)
        #expect(saved == 200)

        UserDefaults.standard.removeObject(forKey: ViewPreferences.gridCellWidthKey)
    }

    @Test("UserDefaults に保存済みの gridCellWidth が init で復元される")
    func gridCellWidth_restoredFromUserDefaults() {
        UserDefaults.standard.set(Double(180), forKey: ViewPreferences.gridCellWidthKey)
        let prefs = ViewPreferences()
        #expect(prefs.gridCellWidth == 180)

        UserDefaults.standard.removeObject(forKey: ViewPreferences.gridCellWidthKey)
    }

    @Test("gridCellWidth が最小値未満の場合は 80 にクランプされる")
    func gridCellWidth_clampedToMin() {
        let prefs = ViewPreferences()
        prefs.gridCellWidth = 50
        #expect(prefs.gridCellWidth == 80)

        UserDefaults.standard.removeObject(forKey: ViewPreferences.gridCellWidthKey)
    }

    @Test("gridCellWidth が最大値超過の場合は 280 にクランプされる")
    func gridCellWidth_clampedToMax() {
        let prefs = ViewPreferences()
        prefs.gridCellWidth = 400
        #expect(prefs.gridCellWidth == 280)

        UserDefaults.standard.removeObject(forKey: ViewPreferences.gridCellWidthKey)
    }
}
