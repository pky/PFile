import Foundation
import AVFoundation

/// ByteRangeDataSource を AVPlayer へ供給する AVAssetResourceLoaderDelegate。
/// カスタムスキーム URL の AVURLAsset に設定し、AVPlayer が要求する byte range を SMB read に変換する。
/// AVPlayer 側が seek 時に未使用の loadingRequest を自動キャンセルするため、最新要求の優先は AVPlayer に任せる。
final class SMBResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {

    /// AVURLAsset を本デリゲート経由にするためのカスタムスキーム。
    static let scheme = "pfile-smb"

    private let dataSource: ByteRangeDataSource
    private let contentType: String
    private let ownerID: String
    private let mediaID: String
    private let failureHandler: @Sendable (Error) -> Void
    private let queue = DispatchQueue(label: "jp.pky.pfile.av-resource-loader")
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var requestCount = 0
    private var completedCount = 0
    private var cancellationCount = 0
    private var failedCount = 0
    private var activeCount = 0
    private var maximumActiveCount = 0
    private var totalBytes: UInt64 = 0
    private var longestRequestMilliseconds = 0

    /// AVPlayer へ一度に渡す読み出し単位。小さめにして初期バイトと seek 後の応答を速くする。
    private let chunkSize: UInt64 = 256 * 1024

    init(
        dataSource: ByteRangeDataSource,
        contentType: String,
        ownerID: String,
        mediaID: String,
        failureHandler: @escaping @Sendable (Error) -> Void
    ) {
        self.dataSource = dataSource
        self.contentType = contentType
        self.ownerID = ownerID
        self.mediaID = mediaID
        self.failureHandler = failureHandler
    }

    func cancelAllLoadingRequests() {
        queue.async {
            let tasks = Array(self.tasks.values)
            self.tasks.removeAll()
            self.cancellationCount += tasks.count
            for task in tasks {
                task.cancel()
            }
            self.logSummary(reason: "cancel_all")
        }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        let key = ObjectIdentifier(loadingRequest)
        let startedAt = CFAbsoluteTimeGetCurrent()
        queue.sync {
            let task = Task { [weak self] in
                guard let self else { return }
                let result = await self.fulfill(loadingRequest)
                let elapsedMilliseconds = max(0, Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000))
                self.queue.async {
                    self.tasks[key] = nil
                    self.completedCount += 1
                    self.activeCount = max(0, self.activeCount - 1)
                    self.totalBytes += result.byteCount
                    self.longestRequestMilliseconds = max(
                        self.longestRequestMilliseconds,
                        elapsedMilliseconds
                    )
                    if result.failed {
                        self.failedCount += 1
                    }
                    if self.activeCount == 0 || result.failed {
                        self.logSummary(reason: result.failed ? "failed" : "idle")
                    }
                }
            }
            self.tasks[key] = task
            self.requestCount += 1
            self.activeCount += 1
            self.maximumActiveCount = max(self.maximumActiveCount, self.activeCount)
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let key = ObjectIdentifier(loadingRequest)
        queue.async {
            self.tasks[key]?.cancel()
            self.cancellationCount += 1
        }
    }

    private func fulfill(_ loadingRequest: AVAssetResourceLoadingRequest) async -> RequestResult {
        do {
            let totalLength = try await dataSource.contentLength()

            if let infoRequest = loadingRequest.contentInformationRequest {
                infoRequest.contentType = contentType
                infoRequest.isByteRangeAccessSupported = true
                if totalLength > 0 {
                    infoRequest.contentLength = Int64(totalLength)
                }
            }

            var byteCount: UInt64 = 0
            if let dataRequest = loadingRequest.dataRequest {
                byteCount = try await respond(to: dataRequest, totalLength: totalLength)
            }

            if !loadingRequest.isCancelled, !loadingRequest.isFinished {
                loadingRequest.finishLoading()
            }
            return RequestResult(byteCount: byteCount, failed: false)
        } catch is CancellationError {
            // seek 等で破棄された要求。AVPlayer が新しい要求を出すので何もしない。
            return RequestResult(byteCount: 0, failed: false)
        } catch {
            guard !loadingRequest.isCancelled else {
                return RequestResult(byteCount: 0, failed: false)
            }
            MediaDiagnostics.resource(
                "event=load_failed mediaID=\(mediaID) playerID=\(ownerID) \(MediaDiagnostics.errorCode(error))"
            )
            loadingRequest.finishLoading(with: error)
            failureHandler(error)
            return RequestResult(byteCount: 0, failed: true)
        }
    }

    private func respond(
        to dataRequest: AVAssetResourceLoadingDataRequest,
        totalLength: UInt64
    ) async throws -> UInt64 {
        guard let range = ByteRangeResolver.resolve(
            requestedOffset: dataRequest.requestedOffset,
            requestedLength: dataRequest.requestedLength,
            requestsAllDataToEnd: dataRequest.requestsAllDataToEndOfResource,
            currentOffset: dataRequest.currentOffset,
            totalLength: totalLength
        ) else { return 0 }

        var offset = range.lowerBound
        var byteCount: UInt64 = 0
        while offset <= range.upperBound {
            try Task.checkCancellation()
            let upper = min(range.upperBound, offset + chunkSize - 1)
            let data: Data
            do {
                data = try await dataSource.readRange(offset...upper)
            } catch {
                MediaDiagnostics.resource(
                    "event=range_read_failed mediaID=\(mediaID) playerID=\(ownerID) offset=\(offset) length=\(upper - offset + 1) \(MediaDiagnostics.errorCode(error))"
                )
                throw error
            }
            guard !data.isEmpty else { break }
            dataRequest.respond(with: data)
            byteCount += UInt64(data.count)
            offset += UInt64(data.count)
        }
        return byteCount
    }

    private func logSummary(reason: String) {
        MediaDiagnostics.resource(
            "event=request_summary mediaID=\(mediaID) playerID=\(ownerID) reason=\(reason) requests=\(requestCount) completed=\(completedCount) cancelled=\(cancellationCount) failed=\(failedCount) active=\(activeCount) maxActive=\(maximumActiveCount) bytes=\(totalBytes) longestMs=\(longestRequestMilliseconds)"
        )
    }

    private struct RequestResult {
        let byteCount: UInt64
        let failed: Bool
    }
}
