import Foundation

struct SMBHTTPResponsePlan: Equatable {
    let status: String
    let contentLength: UInt64
    let contentRange: String?
    let bodyRange: ClosedRange<UInt64>?
}

enum SMBHTTPResponsePlanner {

    enum RangeError: Error, Equatable {
        case unsatisfiable
    }

    static func parseRangeHeader(_ header: String, fileSize: UInt64) -> ClosedRange<UInt64>? {
        // "Range: bytes=X-Y" または "Range: bytes=X-"
        guard let eqIdx = header.firstIndex(of: "=") else { return nil }
        let unit = header[..<eqIdx].lowercased().trimmingCharacters(in: .whitespaces)
        guard unit.hasSuffix("bytes") else { return nil }
        let value = String(header[header.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
        let parts = value.components(separatedBy: "-")
        guard parts.count == 2,
              let start = UInt64(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        if let end = UInt64(parts[1].trimmingCharacters(in: .whitespaces)) {
            return start...end
        } else {
            let end = fileSize > 0 ? fileSize - 1 : 0
            return start...max(start, end)
        }
    }

    static func makePlan(fileSize: UInt64, requestedRange: ClosedRange<UInt64>?) throws -> SMBHTTPResponsePlan {
        if let requestedRange {
            guard fileSize > 0, requestedRange.lowerBound < fileSize else {
                throw RangeError.unsatisfiable
            }
            let upperBound = min(requestedRange.upperBound, fileSize - 1)
            let bodyRange = requestedRange.lowerBound...upperBound
            let contentLength = bodyRange.upperBound - bodyRange.lowerBound + 1
            let contentRange = "bytes \(bodyRange.lowerBound)-\(bodyRange.upperBound)/\(fileSize)"
            return SMBHTTPResponsePlan(
                status: "206 Partial Content",
                contentLength: contentLength,
                contentRange: contentRange,
                bodyRange: bodyRange
            )
        }

        guard fileSize > 0 else {
            return SMBHTTPResponsePlan(status: "200 OK", contentLength: 0, contentRange: nil, bodyRange: nil)
        }
        return SMBHTTPResponsePlan(status: "200 OK", contentLength: fileSize, contentRange: nil, bodyRange: 0...(fileSize - 1))
    }
}
