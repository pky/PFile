import CryptoKit
import Foundation
import OSLog

/// 動画・サムネイル処理を、ファイル情報を公開せずに追跡する診断基盤。
enum MediaDiagnostics {
    struct Interval {
        fileprivate let name: StaticString
        fileprivate let id: OSSignpostID
    }

    private static let subsystem = Bundle.main.bundleIdentifier ?? "jp.pky.pfile"
    private static let sessionSalt = UUID().uuidString
    private static let playbackLogger = Logger(subsystem: subsystem, category: "media.playback")
    private static let thumbnailLogger = Logger(subsystem: subsystem, category: "media.thumbnail")
    private static let resourceLogger = Logger(subsystem: subsystem, category: "media.resource")
    private static let performanceLogger = Logger(subsystem: subsystem, category: "media.performance")
    private static let signpostLog = OSLog(subsystem: subsystem, category: .pointsOfInterest)

    static func mediaID(sourceID: String, path: String) -> String {
        let input = Data("\(sessionSalt)|\(sourceID)|\(path)".utf8)
        return SHA256.hash(data: input)
            .prefix(6)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func playback(_ message: String) {
        playbackLogger.info("\(message, privacy: .public)")
    }

    static func thumbnail(_ message: String) {
        thumbnailLogger.info("\(message, privacy: .public)")
    }

    static func resource(_ message: String) {
        resourceLogger.info("\(message, privacy: .public)")
    }

    static func performance(_ message: String) {
        performanceLogger.info("\(message, privacy: .public)")
    }

    static func errorCode(_ error: Error) -> String {
        let nsError = error as NSError
        return "domain=\(nsError.domain) code=\(nsError.code)"
    }

    static func begin(_ name: StaticString, mediaID: String, detail: String = "") -> Interval {
        let id = OSSignpostID(log: signpostLog)
        os_signpost(
            .begin,
            log: signpostLog,
            name: name,
            signpostID: id,
            "mediaID=%{public}s detail=%{public}s",
            mediaID,
            detail
        )
        return Interval(name: name, id: id)
    }

    static func end(_ interval: Interval, mediaID: String, result: String) {
        os_signpost(
            .end,
            log: signpostLog,
            name: interval.name,
            signpostID: interval.id,
            "mediaID=%{public}s result=%{public}s",
            mediaID,
            result
        )
    }
}
