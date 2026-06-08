import Foundation

enum ContentSource: Hashable, Identifiable {
    case remote(UUID)
    case localFolder(UUID)
    case photoLibrary

    var id: String {
        switch self {
        case .remote(let id):
            return "remote:\(id.uuidString)"
        case .localFolder(let id):
            return "localFolder:\(id.uuidString)"
        case .photoLibrary:
            return "photoLibrary"
        }
    }

    var displayName: String {
        switch self {
        case .remote:
            return "ネットワーク"
        case .localFolder(_):
            return "ローカルフォルダ"
        case .photoLibrary:
            return "フォトライブラリ"
        }
    }

    var storageUUID: UUID {
        switch self {
        case .remote(let id), .localFolder(let id):
            return id
        case .photoLibrary:
            return UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        }
    }

    static func from(id: String) -> ContentSource? {
        if id == "photoLibrary" {
            return .photoLibrary
        }
        if id.hasPrefix("remote:"),
           let uuid = UUID(uuidString: String(id.dropFirst("remote:".count))) {
            return .remote(uuid)
        }
        if id.hasPrefix("localFolder:"),
           let uuid = UUID(uuidString: String(id.dropFirst("localFolder:".count))) {
            return .localFolder(uuid)
        }
        return nil
    }
}
