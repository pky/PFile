@testable import PFile
import Foundation

@MainActor
final class MockAppDataBackupService: AppDataBackupServiceProtocol {

    var lastAutoBackupAt: Date? = nil
    var shouldThrow = false
    var exportedURL: URL = URL(fileURLWithPath: "/tmp/backup.json")
    var restoredResult = AppDataBackupRestoreResult(
        restoredFromURL: URL(fileURLWithPath: "/tmp/backup.json"),
        preRestoreSnapshotURL: URL(fileURLWithPath: "/tmp/pre-restore.json")
    )
    var backupDirectoryURL: URL = URL(fileURLWithPath: "/tmp/backups")
    var restoreLatestBackupCalled = false
    var restoreBackupURL: URL?

    func exportBackup() throws -> URL {
        if shouldThrow { throw TestError.mock }
        return exportedURL
    }

    func restoreLatestBackup() throws -> AppDataBackupRestoreResult {
        restoreLatestBackupCalled = true
        if shouldThrow { throw TestError.mock }
        return restoredResult
    }

    func restoreBackup(from url: URL) throws -> AppDataBackupRestoreResult {
        restoreBackupURL = url
        if shouldThrow { throw TestError.mock }
        return restoredResult
    }

    func backupDirectoryURLForDisplay() throws -> URL {
        if shouldThrow { throw TestError.mock }
        return backupDirectoryURL
    }
}
