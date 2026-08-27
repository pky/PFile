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

enum OrientationContent {
    case document
    case video
}

// MARK: - OrientationService

final class OrientationService {

    static let shared = OrientationService()

    private static let legacyKey = "Settings.orientationMode"
    private static let documentKey = "Settings.documentOrientationMode"
    private static let videoKey = "Settings.videoOrientationMode"

    private(set) var documentMode: OrientationMode = .system {
        didSet {
            UserDefaults.standard.set(documentMode.rawValue, forKey: Self.documentKey)
        }
    }

    private(set) var videoMode: OrientationMode = .system {
        didSet {
            UserDefaults.standard.set(videoMode.rawValue, forKey: Self.videoKey)
        }
    }

    private var activeContent: OrientationContent?

    var mode: OrientationMode {
        mode(for: activeContent)
    }

    private init() {
        let legacyMode = UserDefaults.standard.string(forKey: Self.legacyKey)
            .flatMap(OrientationMode.init(rawValue:)) ?? .system
        documentMode = UserDefaults.standard.string(forKey: Self.documentKey)
            .flatMap(OrientationMode.init(rawValue:)) ?? legacyMode
        videoMode = UserDefaults.standard.string(forKey: Self.videoKey)
            .flatMap(OrientationMode.init(rawValue:)) ?? legacyMode
    }

    func setDocumentMode(_ newMode: OrientationMode) {
        documentMode = newMode
        applyOrientationAfterViewUpdate()
    }

    func setVideoMode(_ newMode: OrientationMode) {
        videoMode = newMode
        applyOrientationAfterViewUpdate()
    }

    func activate(_ content: OrientationContent) {
        activeContent = content
        applyOrientationAfterViewUpdate()
    }

    func deactivate(_ content: OrientationContent) {
        guard activeContent == content else { return }
        activeContent = nil
        applyOrientationAfterViewUpdate()
    }

    private func mode(for content: OrientationContent?) -> OrientationMode {
        switch content {
        case .document:
            return documentMode
        case .video:
            return videoMode
        case nil:
            return .system
        }
    }

    private func applyOrientationAfterViewUpdate() {
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
