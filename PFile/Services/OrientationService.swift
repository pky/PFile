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

enum OrientationScope: Hashable {
    case remote
    case localFolder
    case photoLibrary

    init(source: ContentSource) {
        switch source {
        case .remote:
            self = .remote
        case .localFolder:
            self = .localFolder
        case .photoLibrary:
            self = .photoLibrary
        }
    }
}

// MARK: - OrientationService

final class OrientationService {

    static let shared = OrientationService()

    private static let legacyKey = "Settings.orientationMode"
    private static let remoteKey = "Settings.remoteOrientationMode"
    private static let localFolderKey = "Settings.localFolderOrientationMode"
    private static let photoLibraryKey = "Settings.photoLibraryOrientationMode"
    private static let documentLegacyKey = "Settings.documentOrientationMode"
    private static let videoLegacyKey = "Settings.videoOrientationMode"

    private(set) var remoteMode: OrientationMode = .system {
        didSet {
            UserDefaults.standard.set(remoteMode.rawValue, forKey: Self.remoteKey)
        }
    }

    private(set) var localFolderMode: OrientationMode = .system {
        didSet {
            UserDefaults.standard.set(localFolderMode.rawValue, forKey: Self.localFolderKey)
        }
    }

    private(set) var photoLibraryMode: OrientationMode = .system {
        didSet {
            UserDefaults.standard.set(photoLibraryMode.rawValue, forKey: Self.photoLibraryKey)
        }
    }

    private var activeScopes: [UUID: OrientationScope] = [:]
    private var scopeOrder: [UUID] = []

    var mode: OrientationMode {
        scopeOrder.last.flatMap { activeScopes[$0] }.map(mode(for:)) ?? .system
    }

    private init() {
        let defaults = UserDefaults.standard
        let legacyMode = defaults.string(forKey: Self.legacyKey)
            .flatMap(OrientationMode.init(rawValue:)) ?? .system
        let documentLegacyMode = defaults.string(forKey: Self.documentLegacyKey)
            .flatMap(OrientationMode.init(rawValue:)) ?? legacyMode
        let videoLegacyMode = defaults.string(forKey: Self.videoLegacyKey)
            .flatMap(OrientationMode.init(rawValue:)) ?? legacyMode
        remoteMode = defaults.string(forKey: Self.remoteKey)
            .flatMap(OrientationMode.init(rawValue:)) ?? videoLegacyMode
        localFolderMode = defaults.string(forKey: Self.localFolderKey)
            .flatMap(OrientationMode.init(rawValue:)) ?? documentLegacyMode
        photoLibraryMode = defaults.string(forKey: Self.photoLibraryKey)
            .flatMap(OrientationMode.init(rawValue:)) ?? .system
    }

    func setMode(_ newMode: OrientationMode, for scope: OrientationScope) {
        switch scope {
        case .remote:
            remoteMode = newMode
        case .localFolder:
            localFolderMode = newMode
        case .photoLibrary:
            photoLibraryMode = newMode
        }
        applyOrientationAfterViewUpdate()
    }

    func activate(_ scope: OrientationScope, contextID: UUID) {
        activeScopes[contextID] = scope
        scopeOrder.removeAll { $0 == contextID }
        scopeOrder.append(contextID)
        applyOrientationAfterViewUpdate()
    }

    func deactivate(contextID: UUID) {
        activeScopes[contextID] = nil
        scopeOrder.removeAll { $0 == contextID }
        applyOrientationAfterViewUpdate()
    }

    func mode(for scope: OrientationScope) -> OrientationMode {
        switch scope {
        case .remote:
            return remoteMode
        case .localFolder:
            return localFolderMode
        case .photoLibrary:
            return photoLibraryMode
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
