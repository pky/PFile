import SwiftUI
import SwiftData
import GoogleMobileAds

@main
struct PFileApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        MobileAds.shared.start(completionHandler: nil)
    }

    @State private var appEnvironment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(\.appEnvironment, appEnvironment)
                .task {
                    do {
                        _ = try appEnvironment.appDataBackupService.performAutoBackupIfNeeded()
                    } catch {
                        print("[AppDataBackup] 自動バックアップ失敗: \(error)")
                    }
                }
        }
        .modelContainer(appEnvironment.modelContainer)
    }
}
