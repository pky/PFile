import UIKit

// MARK: - OrientationMode

enum OrientationMode: String, CaseIterable {
    case portrait = "portrait"
    case landscape = "landscape"
    case system = "system"

    var displayName: String {
        switch self {
        case .portrait:  return "縦固定"
        case .landscape: return "横固定"
        case .system:    return "OSに合わせる"
        }
    }

    var interfaceOrientationMask: UIInterfaceOrientationMask {
        switch self {
        case .portrait:  return [.portrait, .portraitUpsideDown]
        case .landscape: return [.landscapeLeft, .landscapeRight]
        case .system:    return .all
        }
    }
}

// MARK: - OrientationService

final class OrientationService {

    static let shared = OrientationService()

    private static let key = "Settings.orientationMode"

    private(set) var mode: OrientationMode = .system {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.key)
        }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.key),
           let saved = OrientationMode(rawValue: raw) {
            mode = saved
        }
    }

    func setMode(_ newMode: OrientationMode) {
        mode = newMode
        // SwiftUI の更新サイクルが完了してから UIKit に適用する
        DispatchQueue.main.async { self.applyOrientation() }
    }

    func applyOrientation() {
        guard let windowScene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        else { return }

        let preferences = UIWindowScene.GeometryPreferences.iOS(
            interfaceOrientations: mode.interfaceOrientationMask
        )
        windowScene.requestGeometryUpdate(preferences) { error in
            print("[OrientationService] requestGeometryUpdate error: \(error)")
        }
        // rootViewController に向きの再評価を要求する（iOS 16+）
        windowScene.windows.first?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
