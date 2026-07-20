import Foundation

struct SMBHTTPResponsePlan: Equatable {
    let status: String
    let contentLength: UInt64
    let contentRange: String?
    let bodyRange: ClosedRange<UInt64>?
}

struct SMBHTTPMediaDescriptor: Equatable {
    let requestPath: String
    let contentType: String

    static func make(filePath: String) -> SMBHTTPMediaDescriptor {
        let ext = (filePath as NSString).pathExtension.lowercased()
        let safeExtension = ext.allSatisfy { $0.isLetter || $0.isNumber } ? ext : ""
        let requestPath = safeExtension.isEmpty ? "/stream" : "/stream.\(safeExtension)"

        let contentType: String
        switch safeExtension {
        case "mp4", "m4v": contentType = "video/mp4"
        case "mov": contentType = "video/quicktime"
        case "mkv": contentType = "video/x-matroska"
        case "webm": contentType = "video/webm"
        case "avi": contentType = "video/x-msvideo"
        case "ts", "m2ts", "mts": contentType = "video/mp2t"
        default: contentType = "application/octet-stream"
        }
        return SMBHTTPMediaDescriptor(requestPath: requestPath, contentType: contentType)
    }
}

enum SMBHTTPResponsePlanner {

    enum RangeError: Error, Equatable {
        case unsatisfiable
    }

    static func parseRangeHeader(_ header: String, fileSize: UInt64) -> ClosedRange<UInt64>? {
        // "Range: bytes=X-Y"、"Range: bytes=X-"、"Range: bytes=-N"
        guard let eqIdx = header.firstIndex(of: "=") else { return nil }
        let unit = header[..<eqIdx].lowercased().trimmingCharacters(in: .whitespaces)
        guard unit.hasSuffix("bytes") else { return nil }
        let value = String(header[header.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
        let parts = value.components(separatedBy: "-")
        guard parts.count == 2 else { return nil }

        let startValue = parts[0].trimmingCharacters(in: .whitespaces)
        let endValue = parts[1].trimmingCharacters(in: .whitespaces)
        if startValue.isEmpty {
            guard fileSize > 0,
                  let suffixLength = UInt64(endValue),
                  suffixLength > 0 else { return nil }
            let start = suffixLength >= fileSize ? 0 : fileSize - suffixLength
            return start...(fileSize - 1)
        }

        guard let start = UInt64(startValue) else { return nil }
        if let end = UInt64(endValue) {
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
