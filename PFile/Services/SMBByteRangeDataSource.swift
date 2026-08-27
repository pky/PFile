import Foundation

#if !targetEnvironment(simulator)
import AMSMB2

private actor SMBByteRangeReadGate {
    private var isReading = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isReading {
            isReading = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isReading = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// AMSMB2 で SMB 上のファイルを byte range 読みする ByteRangeDataSource 実装。
/// AVPlayer の AVAssetResourceLoader 経由で MP4 / MOV を再生するときの読み出し元になる。
final class SMBByteRangeDataSource: ByteRangeDataSource, @unchecked Sendable {

    private let client: SMB2Manager
    private let path: String
    private let ownerID: String
    private let lock = NSLock()
    private let readGate = SMBByteRangeReadGate()
    private var cachedLength: UInt64?

    init(client: SMB2Manager, path: String, fileSize: UInt64, ownerID: String) {
        self.client = client
        self.path = path
        self.ownerID = ownerID
        self.cachedLength = fileSize > 0 ? fileSize : nil
    }

    func contentLength() async throws -> UInt64 {
        lock.lock()
        let cached = cachedLength
        lock.unlock()
        if let cached { return cached }

        let attrs = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[URLResourceKey: any Sendable], Error>) in
            client.attributesOfItem(atPath: path) { cont.resume(with: $0) }
        }
        let size = (attrs[.fileSizeKey] as? Int64).map { UInt64(max(0, $0)) } ?? 0
        lock.lock()
        cachedLength = size
        lock.unlock()
        return size
    }

    func readRange(_ range: ClosedRange<UInt64>) async throws -> Data {
        await readGate.acquire()
        do {
            try Task.checkCancellation()
            let data = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                client.contents(atPath: path, range: range, progress: nil) { cont.resume(with: $0) }
            }
            // AMSMB2 のread自体は中断できないため、完了後にキャンセルを再確認して古い応答を捨てる。
            try Task.checkCancellation()
            await readGate.release()
            return data
        } catch {
            await readGate.release()
            throw error
        }
    }
}

#endif
