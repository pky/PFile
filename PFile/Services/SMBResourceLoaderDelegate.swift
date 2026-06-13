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
    private let queue = DispatchQueue(label: "jp.pky.pfile.av-resource-loader")
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// AVPlayer へ一度に渡す読み出し単位。小さめにして初期バイトと seek 後の応答を速くする。
    private let chunkSize: UInt64 = 256 * 1024

    init(dataSource: ByteRangeDataSource, contentType: String, ownerID: String) {
        self.dataSource = dataSource
        self.contentType = contentType
        self.ownerID = ownerID
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        let key = ObjectIdentifier(loadingRequest)
        let task = Task { [weak self] in
            await self?.fulfill(loadingRequest)
            self?.queue.async { self?.tasks[key] = nil }
        }
        queue.async { self.tasks[key] = task }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let key = ObjectIdentifier(loadingRequest)
        queue.async {
            self.tasks[key]?.cancel()
            self.tasks[key] = nil
        }
    }

    private func fulfill(_ loadingRequest: AVAssetResourceLoadingRequest) async {
        do {
            let totalLength = try await dataSource.contentLength()

            if let infoRequest = loadingRequest.contentInformationRequest {
                infoRequest.contentType = contentType
                infoRequest.isByteRangeAccessSupported = true
                if totalLength > 0 {
                    infoRequest.contentLength = Int64(totalLength)
                }
            }

            if let dataRequest = loadingRequest.dataRequest {
                try await respond(to: dataRequest, totalLength: totalLength)
            }

            if !loadingRequest.isCancelled, !loadingRequest.isFinished {
                loadingRequest.finishLoading()
            }
        } catch is CancellationError {
            // seek 等で破棄された要求。AVPlayer が新しい要求を出すので何もしない。
        } catch {
            guard !loadingRequest.isCancelled else { return }
            print("[SMBResourceLoader] playerID: \(ownerID) | load error: \(error)")
            loadingRequest.finishLoading(with: error)
        }
    }

    private func respond(
        to dataRequest: AVAssetResourceLoadingDataRequest,
        totalLength: UInt64
    ) async throws {
        guard let range = ByteRangeResolver.resolve(
            requestedOffset: dataRequest.requestedOffset,
            requestedLength: dataRequest.requestedLength,
            requestsAllDataToEnd: dataRequest.requestsAllDataToEndOfResource,
            currentOffset: dataRequest.currentOffset,
            totalLength: totalLength
        ) else { return }

        var offset = range.lowerBound
        while offset <= range.upperBound {
            try Task.checkCancellation()
            let upper = min(range.upperBound, offset + chunkSize - 1)
            let data = try await dataSource.readRange(offset...upper)
            guard !data.isEmpty else { break }
            dataRequest.respond(with: data)
            offset += UInt64(data.count)
        }
    }
}
