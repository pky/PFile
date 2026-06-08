import Foundation
import SwiftData

@Model
final class RemoteConnection {

    @Attribute(.unique) var id: UUID
    var displayName: String
    var serviceType: ServiceType
    var host: String?
    var port: Int?
    var username: String?
    /// Keychain から認証情報を引くためのキー
    var keychainIdentifier: String
    /// 接続時のトップフォルダパス（デフォルト: "/"）
    var startPath: String
    var createdAt: Date
    var lastConnectedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \WatchHistory.connection)
    var watchHistories: [WatchHistory] = []

    init(
        id: UUID = UUID(),
        displayName: String,
        serviceType: ServiceType,
        host: String? = nil,
        port: Int? = nil,
        username: String? = nil,
        keychainIdentifier: String = UUID().uuidString,
        startPath: String = "/"
    ) {
        self.id = id
        self.displayName = displayName
        self.serviceType = serviceType
        self.host = host
        self.port = port
        self.username = username
        self.keychainIdentifier = keychainIdentifier
        self.startPath = startPath
        self.createdAt = Date()
    }
}

// MARK: - ServiceType

enum ServiceType: String, Codable, CaseIterable {
    case smb
    case ftp
    case ftps
    case sftp
    case webdav
    case dropbox
    case googleDrive
    case oneDrive

    var displayName: String {
        switch self {
        case .smb:         return "SMB / NAS"
        case .ftp:         return "FTP"
        case .ftps:        return "FTPS"
        case .sftp:        return "SFTP"
        case .webdav:      return "WebDAV"
        case .dropbox:     return "Dropbox"
        case .googleDrive: return "Google Drive"
        case .oneDrive:    return "OneDrive"
        }
    }

    var defaultPort: Int? {
        switch self {
        case .smb:                          return 445
        case .ftp:                          return 21
        case .ftps:                         return 990
        case .sftp:                         return 22
        case .webdav:                       return nil
        case .dropbox, .googleDrive, .oneDrive: return nil
        }
    }

    /// 現在のアプリで選択可能な接続種別かどうか
    var isAvailable: Bool {
        self == .smb
    }
}
