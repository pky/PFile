import SwiftUI

private enum AppEnvironmentKey: EnvironmentKey {
    /// fullScreenCover / sheet などで .environment() を渡し忘れた場合に
    /// AppEnvironment.main にフォールバックするためのデフォルト値。
    /// アプリ起動時に AppEnvironment.init() 内で main が設定されるため
    /// 実際には nil になることはない。
    nonisolated(unsafe) static let defaultValue: AppEnvironment = {
        guard let env = AppEnvironment.main else {
            fatalError("AppEnvironment が初期化される前にアクセスされました")
        }
        return env
    }()
}

extension EnvironmentValues {
    var appEnvironment: AppEnvironment {
        get { self[AppEnvironmentKey.self] }
        set { self[AppEnvironmentKey.self] = newValue }
    }
}
