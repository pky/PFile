import Foundation
import Network

// AMSMB2 は実機専用
#if !targetEnvironment(simulator)
import AMSMB2

/// AMSMB2 でファイルを読み込み、VLCKit に渡すためのローカル HTTP サーバー。
/// VLCKit の SMB クライアントは SMBv1 ベースのため Samba 新バージョンと互換性がない場合がある。
/// このサーバーを経由することで SMB アクセスを AMSMB2（SMBv2/v3）に任せ、VLCKit には HTTP を渡す。
final class SMBStreamingServer {

    private(set) var localURL: URL?

    private let ownerID: String
    private var listener: NWListener?
    private var smbClient: SMB2Manager?
    private var smbFilePath: String = ""
    private var fileSize: UInt64 = 0
    private var nextRequestID: Int = 0
    private var activeRequestCount: Int = 0
    private var activeReadCount: Int = 0
    private var activeConnections: [Int: NWConnection] = [:]
    private var activeTasks: [Int: Task<Void, Never>] = [:]

    private let queue = DispatchQueue(label: "jp.pky.pfile.smb-streaming", qos: .userInitiated)
    // 通常再生は大きめ、seek 直後は小さめのチャンクにして古い読み込みを捨てやすくする。
    private let maxChunkSize: UInt64 = 2 * 1024 * 1024 // 2MB
    private let seekHeadChunkSize: UInt64 = 256 * 1024 // 256KB
    private let seekFollowupChunkSize: UInt64 = 512 * 1024 // 512KB

    init(ownerID: String = "unknown") {
        self.ownerID = ownerID
    }

    // MARK: - ライフサイクル

    func start(client: SMB2Manager, filePath: String, fileSize: Int64?) async throws {
        self.smbClient = client

        let originalRelPath = relativePath(filePath)
        let nfcPath = originalRelPath.precomposedStringWithCanonicalMapping
        let bytesConverted = Array(nfcPath.utf8) != Array(originalRelPath.utf8)

        // NFC/NFDどちらでサーバーが保存しているかをattributesOfItemで確認してパスを決定
        self.smbFilePath = await resolveFilePath(client: client, nfcPath: nfcPath, originalPath: originalRelPath, bytesConverted: bytesConverted)
        print("[SMBStreamingServer] playerID: \(ownerID) | smbFilePath: \(smbFilePath)")

        self.fileSize = fileSize.map { UInt64(max(0, $0)) } ?? 0
        if self.fileSize == 0 {
            // DirectoryItem にサイズがない場合は attributesOfItem で取得
            let attrs = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[URLResourceKey: any Sendable], Error>) in
                client.attributesOfItem(atPath: smbFilePath) { result in cont.resume(with: result) }
            }
            self.fileSize = (attrs[.fileSizeKey] as? Int64).map { UInt64(max(0, $0)) } ?? 0
        }

        let listener = try NWListener(using: .tcp)
        self.listener = listener

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resolved = false
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard !resolved else { return }
                    resolved = true
                    if let port = listener.port {
                        self?.localURL = URL(string: "http://127.0.0.1:\(port)/stream")
                    }
                    cont.resume()
                case .failed(let error):
                    guard !resolved else { return }
                    resolved = true
                    cont.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        }

        print("[SMBStreamingServer] playerID: \(ownerID) | Started: \(localURL?.absoluteString ?? "nil") | size: \(self.fileSize) bytes")
    }

    func stop() {
        let activeRequestsAtStop = activeRequestCount
        let activeReadsAtStop = activeReadCount
        let activeConnectionsAtStop = activeConnections.count
        let activeTasksAtStop = activeTasks.count
        if activeRequestsAtStop > 0 || activeReadsAtStop > 0 {
            reportOverlapDetected(
                phase: "server_stop",
                activeRequests: activeRequestsAtStop,
                activeReads: activeReadsAtStop,
                activeConnections: activeConnectionsAtStop,
                activeTasks: activeTasksAtStop
            )
        }
        listener?.cancel()
        listener = nil
        localURL = nil
        let client = smbClient
        smbClient = nil
        let connections = Array(activeConnections.values)
        activeConnections.removeAll()
        let tasks = Array(activeTasks.values)
        activeTasks.removeAll()
        for task in tasks { task.cancel() }
        for connection in connections { connection.cancel() }
        print("[SMBStreamingServer] playerID: \(ownerID) | Stopped | activeRequests: \(activeRequestCount) | activeReads: \(activeReadCount)")
        // 専用接続を切断（FileBrowserのキャッシュ接続とは別インスタンス）
        Task { try? await client?.disconnectShare() }
    }

    // MARK: - 接続処理

    private func handle(_ connection: NWConnection) {
        let requestID = makeRequestID()
        activeRequestCount += 1
        activeConnections[requestID] = connection
        print("[SMBStreamingServer] playerID: \(ownerID) | request[\(requestID)] accepted | activeRequests: \(activeRequestCount)")
        connection.start(queue: queue)
        receiveRequest(on: connection, requestID: requestID)
    }

    private func receiveRequest(on connection: NWConnection, requestID: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self else { connection.cancel(); return }
            if let error {
                print("[SMBStreamingServer] playerID: \(ownerID) | request[\(requestID)] receive error: \(error)")
                self.finishRequest(connection, requestID: requestID, reason: "receive_error")
                return
            }
            guard let data, !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else {
                print("[SMBStreamingServer] playerID: \(ownerID) | request[\(requestID)] empty request")
                self.finishRequest(connection, requestID: requestID, reason: "empty_request")
                return
            }
            self.handleHTTP(text, on: connection, requestID: requestID)
        }
    }

    // MARK: - HTTP 処理

    private func handleHTTP(_ request: String, on connection: NWConnection, requestID: Int) {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            finishRequest(connection, requestID: requestID, reason: "missing_request_line")
            return
        }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            finishRequest(connection, requestID: requestID, reason: "invalid_request_line")
            return
        }

        let method = parts[0]
        let rangeValue = lines.first(where: { $0.lowercased().hasPrefix("range:") })
        let byteRange = rangeValue.flatMap { SMBHTTPResponsePlanner.parseRangeHeader($0, fileSize: fileSize) }

        print("[SMBStreamingServer] playerID: \(ownerID) | request[\(requestID)] \(method) \(byteRange.map { "Range: \($0)" } ?? "no-range")")

        switch method {
        case "HEAD":
            sendHead(on: connection, requestID: requestID)
        case "GET":
            if let byteRange {
                cancelOlderRangeRequests(newRequestID: requestID, newRange: byteRange)
            }
            let task: Task<Void, Never> = Task { [weak self] in
                guard let self else { return }
                await self.sendGet(range: byteRange, on: connection, requestID: requestID)
            }
            activeTasks[requestID] = task
        default:
            sendError(400, on: connection, requestID: requestID, reason: "unsupported_method")
        }
    }

    // MARK: - レスポンス

    private func sendHead(on connection: NWConnection, requestID: Int) {
        let header = buildHeader(status: "200 OK", contentLength: fileSize, contentRange: nil)
        print("[SMBStreamingServer] playerID: \(ownerID) | request[\(requestID)] response 200 | Content-Length: \(fileSize)")
        send(header, body: nil, on: connection, requestID: requestID, reason: "head_sent", shouldCloseConnection: false)
    }

    private func sendGet(range: ClosedRange<UInt64>?, on connection: NWConnection, requestID: Int) async {
        guard let client = smbClient else {
            finishRequest(connection, requestID: requestID, reason: "missing_smb_client")
            return
        }

        do {
            let response = try SMBHTTPResponsePlanner.makePlan(fileSize: fileSize, requestedRange: range)
            let header = buildHeader(
                status: response.status,
                contentLength: response.contentLength,
                contentRange: response.contentRange
            )

            print("[SMBStreamingServer] playerID: \(ownerID) | request[\(requestID)] response \(response.status) | Content-Length: \(response.contentLength)\(response.contentRange.map { " | Content-Range: \($0)" } ?? "")")
            try await sendBytes(header, on: connection)

            guard let bodyRange = response.bodyRange else {
                finishRequest(connection, requestID: requestID, reason: "header_only")
                return
            }

            var lowerBound = bodyRange.lowerBound
            var isFirstChunk = true
            while lowerBound <= bodyRange.upperBound {
                try Task.checkCancellation()
                let chunkSize = readChunkSize(for: bodyRange, isFirstChunk: isFirstChunk)
                let upperBound = min(bodyRange.upperBound, lowerBound + chunkSize - 1)
                let chunkRange = lowerBound...upperBound

                activeReadCount += 1
                let data = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                    client.contents(atPath: smbFilePath, range: chunkRange, progress: nil) { cont.resume(with: $0) }
                }
                activeReadCount = max(0, activeReadCount - 1)

                try Task.checkCancellation()
                try await sendBytes(data, on: connection)
                lowerBound = upperBound + 1
                isFirstChunk = false
            }

            completeRequest(on: connection, requestID: requestID, reason: "body_sent")
        } catch SMBHTTPResponsePlanner.RangeError.unsatisfiable {
            let contentRange = "bytes */\(fileSize)"
            let msg = """
HTTP/1.1 416 Range Not Satisfiable\r
Content-Length: 0\r
Content-Range: \(contentRange)\r
Connection: close\r
\r
"""
            connection.send(content: msg.data(using: .utf8)!, completion: .contentProcessed { _ in
                print("[SMBStreamingServer] playerID: \(self.ownerID) | request[\(requestID)] response 416 | Content-Range: \(contentRange)")
                self.finishRequest(connection, requestID: requestID, reason: "range_unsatisfiable")
            })
        } catch is CancellationError {
            finishRequest(connection, requestID: requestID, reason: "cancelled")
        } catch {
            print("[SMBStreamingServer] playerID: \(ownerID) | request[\(requestID)] read error: \(error) | activeReads: \(activeReadCount)")
            sendError(500, on: connection, requestID: requestID, reason: "read_error")
        }
    }

    private func buildHeader(status: String, contentLength: UInt64, contentRange: String?) -> Data {
        var lines = [
            "HTTP/1.1 \(status)",
            "Content-Length: \(contentLength)",
            "Content-Type: application/octet-stream",
            "Accept-Ranges: bytes",
            "Connection: keep-alive",
        ]
        if let contentRange {
            lines.append("Content-Range: \(contentRange)")
        }
        lines.append("")
        lines.append("")
        return lines.joined(separator: "\r\n").data(using: .utf8)!
    }

    private func sendBytes(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    private func send(
        _ header: Data,
        body: Data?,
        on connection: NWConnection,
        requestID: Int,
        reason: String,
        shouldCloseConnection: Bool
    ) {
        var payload = header
        if let body { payload.append(body) }
        connection.send(content: payload, completion: .contentProcessed { _ in
            if shouldCloseConnection {
                self.finishRequest(connection, requestID: requestID, reason: reason)
            } else {
                self.completeRequest(on: connection, requestID: requestID, reason: reason)
            }
        })
    }

    private func sendError(_ code: Int, on connection: NWConnection, requestID: Int, reason: String) {
        let msg = "HTTP/1.1 \(code) Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: msg.data(using: .utf8)!, completion: .contentProcessed { _ in
            print("[SMBStreamingServer] playerID: \(self.ownerID) | request[\(requestID)] response \(code)")
            self.finishRequest(connection, requestID: requestID, reason: reason)
        })
    }

    private func makeRequestID() -> Int {
        nextRequestID += 1
        return nextRequestID
    }

    private func cancelOlderRangeRequests(newRequestID: Int, newRange: ClosedRange<UInt64>) {
        let olderRequestIDs = activeTasks.keys.filter { $0 != newRequestID }
        guard !olderRequestIDs.isEmpty else { return }

        print("[SMBStreamingServer] playerID: \(ownerID) | request[\(newRequestID)] prioritizing latest Range: \(newRange) | cancelling: \(olderRequestIDs)")
        for requestID in olderRequestIDs {
            activeTasks[requestID]?.cancel()
            if let connection = activeConnections[requestID] {
                finishRequest(connection, requestID: requestID, reason: "superseded_by_latest_range")
            } else {
                activeTasks.removeValue(forKey: requestID)
            }
        }
    }

    private func readChunkSize(for bodyRange: ClosedRange<UInt64>, isFirstChunk: Bool) -> UInt64 {
        let bodyLength = bodyRange.upperBound - bodyRange.lowerBound + 1
        if isFirstChunk {
            return min(seekHeadChunkSize, bodyLength)
        }
        if bodyLength <= 8 * 1024 * 1024 {
            return seekFollowupChunkSize
        }
        return maxChunkSize
    }

    private func reportOverlapDetected(
        phase: String,
        activeRequests: Int,
        activeReads: Int,
        activeConnections: Int,
        activeTasks: Int
    ) {
        let fileName = URL(fileURLWithPath: smbFilePath).lastPathComponent
        let detail = "[VideoPlayer] overlap detected | phase: \(phase) | playerID: \(ownerID) | file: \(fileName) | activeRequests: \(activeRequests) | activeReads: \(activeReads) | activeConnections: \(activeConnections) | activeTasks: \(activeTasks)"
        print(detail)

        let telemetryDetail = "[VideoPlayer] overlap detected | phase: \(phase) | playerID: \(ownerID) | activeRequests: \(activeRequests) | activeReads: \(activeReads) | activeConnections: \(activeConnections) | activeTasks: \(activeTasks)"
        FirebaseSupport.logCrashlytics(telemetryDetail)
        FirebaseSupport.setCrashlyticsValue(ownerID, forKey: "vp_overlap_player_id")
        FirebaseSupport.setCrashlyticsValue(phase, forKey: "vp_overlap_phase")
        FirebaseSupport.setCrashlyticsValue(activeRequests, forKey: "vp_overlap_active_requests")
        FirebaseSupport.setCrashlyticsValue(activeReads, forKey: "vp_overlap_active_reads")
        FirebaseSupport.setCrashlyticsValue(activeConnections, forKey: "vp_overlap_active_connections")
        FirebaseSupport.setCrashlyticsValue(activeTasks, forKey: "vp_overlap_active_tasks")

        FirebaseSupport.logEvent("vp_overlap_detected", parameters: [
            "phase": phase,
            "active_requests": activeRequests,
            "active_reads": activeReads,
            "active_connections": activeConnections,
            "active_tasks": activeTasks,
        ])
    }

    private func finishRequest(_ connection: NWConnection, requestID: Int, reason: String) {
        guard activeConnections[requestID] != nil else { return }
        connection.cancel()
        activeConnections.removeValue(forKey: requestID)
        activeTasks.removeValue(forKey: requestID)
        activeRequestCount = max(0, activeRequestCount - 1)
        print("[SMBStreamingServer] playerID: \(ownerID) | request[\(requestID)] closed | reason: \(reason) | activeRequests: \(activeRequestCount) | activeReads: \(activeReadCount)")
    }

    private func completeRequest(on connection: NWConnection, requestID: Int, reason: String) {
        guard activeConnections[requestID] != nil else { return }
        activeTasks.removeValue(forKey: requestID)
        print("[SMBStreamingServer] playerID: \(ownerID) | request[\(requestID)] completed | reason: \(reason) | activeRequests: \(activeRequestCount) | activeReads: \(activeReadCount)")
        receiveRequest(on: connection, requestID: requestID)
    }

    // MARK: - ユーティリティ

    /// NFCパスとNFDパス（元のバイト列）を両方試して、サーバーで実際に見つかるパスを返す。
    /// サーバーによってNFC/NFD保存が異なるため、attributesOfItemで事前確認してから決定する。
    private func resolveFilePath(client: SMB2Manager, nfcPath: String, originalPath: String, bytesConverted: Bool) async -> String {
        // バイト列に変換がなければ確認不要
        guard bytesConverted else { return nfcPath }
        // NFCで存在確認
        if await checkPathExists(client: client, path: nfcPath) {
            print("[SMBStreamingServer] playerID: \(ownerID) | Resolved: NFC path")
            return nfcPath
        }
        // NFCで見つからない場合は元のNFDパスを試す
        if await checkPathExists(client: client, path: originalPath) {
            print("[SMBStreamingServer] playerID: \(ownerID) | Resolved: original NFD path (server stores in NFD)")
            return originalPath
        }
        // どちらも確認できない場合はNFCをデフォルト（エラーはsendGetで処理）
        print("[SMBStreamingServer] playerID: \(ownerID) | Warning: both NFC and NFD path not found via attributesOfItem")
        return nfcPath
    }

    private func checkPathExists(client: SMB2Manager, path: String) async -> Bool {
        await withCheckedContinuation { cont in
            client.attributesOfItem(atPath: path) { result in
                switch result {
                case .success: cont.resume(returning: true)
                case .failure: cont.resume(returning: false)
                }
            }
        }
    }

    private func relativePath(_ path: String) -> String {
        path.hasPrefix("/") ? String(path.dropFirst()) : path
    }
}

#endif
