import Foundation

#if !targetEnvironment(simulator)

/// libsmb2 のグローバル接続状態を同時アクセスで壊さないための直列化ゲート。
/// AMSMB2 の connect/disconnect はこのゲート経由で実行する。
enum SMB2OperationGate {
    private static let queue = DispatchQueue(label: "jp.pky.pfile.smb2-operation-gate", qos: .userInitiated)

    static func runAsync<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let semaphore = DispatchSemaphore(value: 0)
                Task {
                    let result: Result<T, Error>
                    do {
                        result = .success(try await operation())
                    } catch {
                        result = .failure(error)
                    }
                    continuation.resume(with: result)
                    semaphore.signal()
                }
                semaphore.wait()
            }
        }
    }
}

#endif
