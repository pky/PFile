import Foundation
import XCTest
@testable import PFile

final class DebugMetricsLogTests: XCTestCase {

    func test_encodeLineProducesSingleLineJSONWithEnvelopeAndSortedKeys() throws {
        let date = Date(timeIntervalSince1970: 0)
        let line = try XCTUnwrap(DebugMetricsLog.encodeLine(
            event: "scrub_frame",
            payload: ["value": "first\nsecond\rthird"],
            at: date
        ))

        XCTAssertFalse(line.contains("\n"))
        XCTAssertFalse(line.contains("\r"))
        let data = Data(line.utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["at", "event", "data"])
        XCTAssertEqual(object["event"] as? String, "scrub_frame")
        let timestamp = try XCTUnwrap(object["at"] as? String)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let decodedDate = formatter.date(from: timestamp)
            ?? ISO8601DateFormatter().date(from: timestamp)
        XCTAssertEqual(decodedDate, date)
        let payload = try XCTUnwrap(object["data"] as? [String: String])
        XCTAssertEqual(payload, ["value": "first\nsecond\rthird"])
        let sortedData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertEqual(line, String(decoding: sortedData, as: UTF8.self))
    }

    func test_encodeLineContainsOnlyScrubFrameReportFieldsAndSummary() throws {
        var stats = ScrubFrameStats(startedAt: 0)
        stats.recordPictureCounts(displayed: 10, lost: 1, at: 0)
        stats.recordSeekIssued(targetSeconds: 0, at: 0)
        stats.recordTime(observedSeconds: 0.5, at: 0.0205)
        stats.recordPictureCounts(displayed: 12, lost: 2, at: 0.0405)
        let report = ScrubFrameReport(
            route: "direct_smb",
            mediaDurationSeconds: 120,
            resolution: "1920x1080",
            networkCachingMs: 300,
            inputs: 3,
            stats: stats.summary(endedAt: 2)
        )
        let line = try XCTUnwrap(DebugMetricsLog.encodeLine(
            event: "scrub_frame", payload: report, at: Date(timeIntervalSince1970: 0)
        ))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        let payload = try XCTUnwrap(object["data"] as? [String: Any])

        XCTAssertEqual(Set(payload.keys), [
            "route", "mediaDurationSeconds", "resolution", "networkCachingMs", "inputs", "stats"
        ])
        XCTAssertEqual(payload["route"] as? String, "direct_smb")
        XCTAssertEqual(payload["mediaDurationSeconds"] as? Int, 120)
        XCTAssertEqual(payload["resolution"] as? String, "1920x1080")
        XCTAssertEqual(payload["networkCachingMs"] as? Int, 300)
        XCTAssertEqual(payload["inputs"] as? Int, 3)

        let summary = try XCTUnwrap(payload["stats"] as? [String: Any])
        XCTAssertEqual(Set(summary.keys), [
            "durationMs", "seekCount", "advancedSeekCount", "effectiveSeekCount",
            "effectiveSeeksPerSecond", "advanceLatencyP50Ms", "advanceLatencyP90Ms",
            "effectiveLatencyP50Ms", "effectiveLatencyP90Ms", "displayedPictures", "lostPictures"
        ])
        XCTAssertEqual(summary["durationMs"] as? Int, 2000)
        XCTAssertEqual(summary["seekCount"] as? Int, 1)
        XCTAssertEqual(summary["advancedSeekCount"] as? Int, 1)
        XCTAssertEqual(summary["effectiveSeekCount"] as? Int, 1)
        XCTAssertEqual(summary["effectiveSeeksPerSecond"] as? Double, 0.5)
        XCTAssertEqual(summary["advanceLatencyP50Ms"] as? Int, 20)
        XCTAssertEqual(summary["advanceLatencyP90Ms"] as? Int, 20)
        XCTAssertEqual(summary["effectiveLatencyP50Ms"] as? Int, 40)
        XCTAssertEqual(summary["effectiveLatencyP90Ms"] as? Int, 40)
        XCTAssertEqual(summary["displayedPictures"] as? Int, 2)
        XCTAssertEqual(summary["lostPictures"] as? Int, 1)
    }

    func test_encodeLineReturnsNilWhenPayloadEncodingFails() {
        XCTAssertNil(DebugMetricsLog.encodeLine(
            event: "scrub_frame",
            payload: UnencodablePayload(),
            at: Date(timeIntervalSince1970: 0)
        ))
    }

    func test_appendCreatesParentDirectoriesAndPreservesTwoLines() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("diagnostics").appendingPathComponent("metrics.jsonl")
        XCTAssertFalse(fileManager.fileExists(atPath: fileURL.deletingLastPathComponent().path))
        let first = try XCTUnwrap(DebugMetricsLog.encodeLine(
            event: "scrub_frame", payload: ["count": 1], at: Date(timeIntervalSince1970: 0)
        ))
        let second = try XCTUnwrap(DebugMetricsLog.encodeLine(
            event: "playback_frame", payload: ["count": 2], at: Date(timeIntervalSince1970: 1)
        ))

        try DebugMetricsLog.append(line: first, to: fileURL)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), first + "\n")
        try DebugMetricsLog.append(line: second, to: fileURL)

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(contents, first + "\n" + second + "\n")
        XCTAssertEqual(contents.split(separator: "\n").count, 2)
    }

    private struct UnencodablePayload: Encodable {
        func encode(to encoder: Encoder) throws {
            throw EncodingError.invalidValue(
                0,
                EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "テスト用の失敗")
            )
        }
    }
}
