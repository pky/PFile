import Foundation
import FirebaseAnalytics
import FirebaseCore
import FirebaseCrashlytics

enum FirebaseSupport {
    static var isConfigured: Bool {
        FirebaseApp.app() != nil
    }

    static func configureIfAvailable() {
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else {
            return
        }
        FirebaseApp.configure()
    }

    static func logEvent(_ name: String, parameters: [String: Any]? = nil) {
        guard isConfigured else { return }
        Analytics.logEvent(name, parameters: parameters)
    }

    static func logCrashlytics(_ message: String) {
        guard isConfigured else { return }
        Crashlytics.crashlytics().log(message)
    }

    static func setCrashlyticsValue(_ value: Any, forKey key: String) {
        guard isConfigured else { return }
        Crashlytics.crashlytics().setCustomValue(value, forKey: key)
    }

    static func recordCrashlytics(error: Error) {
        guard isConfigured else { return }
        Crashlytics.crashlytics().record(error: error)
    }
}
