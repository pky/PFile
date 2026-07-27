@testable import PFile
import Foundation
import SwiftData
import XCTest

@MainActor
final class AppDataBackupServiceTests: XCTestCase {

    func test_exportBackup_doesNotContainSMBCredential() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let secret = "この文字列はバックアップへ出力しない"
        let connection = try insertConnection(
            into: fixture.container,
            keychainIdentifier: fixture.keychainIdentifier,
            password: secret
        )

        let url = try fixture.service.exportBackup()
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let connections = try XCTUnwrap(root["connections"] as? [[String: Any]])
        let backupConnection = try XCTUnwrap(connections.first)

        XCTAssertNil(backupConnection["credential"])
        XCTAssertEqual(backupConnection["shareName"] as? String, "videos")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(secret))
        XCTAssertEqual(connection.startPath, "/movies")
    }

    func test_autoBackup_sanitizesLegacyStoredBackupBeforeDateCheck() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let legacyURL = fixture.backupDirectory.appendingPathComponent("PFileBackup-legacy.json")
        let legacyJSON: [String: Any] = [
            "connections": [[
                "displayName": "旧NAS",
                "credential": [
                    "shareName": "archive",
                    "username": "legacy-user",
                    "password": "legacy-plain-password",
                ],
            ]],
        ]
        let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON)
        try legacyData.write(to: legacyURL, options: .atomic)
        fixture.userDefaults.set(Date(), forKey: "AppDataBackup.lastAutoBackupAt")

        XCTAssertNil(try fixture.service.performAutoBackupIfNeeded())

        let sanitizedData = try Data(contentsOf: legacyURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: sanitizedData) as? [String: Any])
        let connections = try XCTUnwrap(root["connections"] as? [[String: Any]])
        let backupConnection = try XCTUnwrap(connections.first)
        XCTAssertNil(backupConnection["credential"])
        XCTAssertEqual(backupConnection["shareName"] as? String, "archive")
        XCTAssertFalse(String(decoding: sanitizedData, as: UTF8.self).contains("legacy-plain-password"))
    }

    func test_restoreBackup_requiresPasswordReentryAndPreservesSharePath() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        _ = try insertConnection(
            into: fixture.container,
            keychainIdentifier: fixture.keychainIdentifier,
            password: "restore-secret"
        )
        let backupURL = try fixture.service.exportBackup()

        let result = try fixture.service.restoreBackup(from: backupURL)
        let restoredConnections = try fixture.container.mainContext.fetch(FetchDescriptor<RemoteConnection>())
        let restoredConnection = try XCTUnwrap(restoredConnections.first)

        XCTAssertTrue(result.requiresCredentialReentry)
        XCTAssertEqual(restoredConnection.startPath, "/videos/movies")
        XCTAssertThrowsError(try SMBClientManager().loadCredential(for: restoredConnection))
    }

    private func makeFixture() throws -> Fixture {
        let schema = Schema([
            RemoteConnection.self,
            LocalFolderSource.self,
            MediaList.self,
            MediaFile.self,
            WatchHistory.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let backupDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PFileBackupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: true
        )
        let suiteName = "PFile.AppDataBackupServiceTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let keychainIdentifier = "PFileBackupTests-\(UUID().uuidString)"
        let service = AppDataBackupService(
            modelContainer: container,
            smbClientManager: SMBClientManager(),
            userDefaults: userDefaults,
            backupDirectoryURL: backupDirectory
        )
        return Fixture(
            container: container,
            service: service,
            backupDirectory: backupDirectory,
            userDefaults: userDefaults,
            userDefaultsSuiteName: suiteName,
            keychainIdentifier: keychainIdentifier
        )
    }

    @discardableResult
    private func insertConnection(
        into container: ModelContainer,
        keychainIdentifier: String,
        password: String
    ) throws -> RemoteConnection {
        let connection = RemoteConnection(
            displayName: "テストNAS",
            serviceType: .smb,
            host: "nas.example.local",
            port: 445,
            username: "test-user",
            keychainIdentifier: keychainIdentifier,
            startPath: "/movies"
        )
        container.mainContext.insert(connection)
        try container.mainContext.save()
        try KeychainService.shared.save(
            SMBClientManager.SMBCredential(
                shareName: "videos",
                username: "test-user",
                password: password
            ),
            key: keychainIdentifier
        )
        return connection
    }
}

@MainActor
private struct Fixture {
    let container: ModelContainer
    let service: AppDataBackupService
    let backupDirectory: URL
    let userDefaults: UserDefaults
    let userDefaultsSuiteName: String
    let keychainIdentifier: String

    func cleanup() {
        KeychainService.shared.delete(key: keychainIdentifier)
        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        try? FileManager.default.removeItem(at: backupDirectory)
    }
}
