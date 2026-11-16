import Foundation

enum DebugMetricsLog {
    private struct Entry<Payload: Encodable>: Encodable {
        let at: String
        let event: String
        let data: Payload
    }

    static func encodeLine<T: Encodable>(event: String, payload: T, at date: Date) -> String? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let entry = Entry(at: formatter.string(from: date), event: event, data: payload)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(entry) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func append(line: String, to fileURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: fileURL.path) {
            try Data().write(to: fileURL)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

#if DEBUG
    private static let queue = DispatchQueue(label: "jp.pky.pfile.debug-metrics", qos: .utility)
#endif

    static func record<T: Encodable>(event: String, payload: T) {
#if DEBUG
        let date = Date()
        queue.async {
            guard let line = encodeLine(event: event, payload: payload, at: date) else { return }
            guard let documents = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask
            ).first else { return }
            let fileURL = documents.appendingPathComponent("diagnostics")
                .appendingPathComponent("metrics.jsonl")
            try? append(line: line, to: fileURL)
        }
#endif
    }
}
