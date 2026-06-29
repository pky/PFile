import Foundation
import Darwin

enum VideoPlayerDiagnostics {
    private static let lock = NSLock()
    private static var activePlayerCount = 0
    private static var peakResidentMemoryBytes: UInt64 = 0

    static func playerDidInit(playerID: String) {
        lock.lock()
        activePlayerCount += 1
        let active = activePlayerCount
        lock.unlock()

        logMemory(event: "init", playerID: playerID, activePlayerCount: active)
    }

    static func playerDidDeinit(playerID: String) {
        lock.lock()
        activePlayerCount = max(0, activePlayerCount - 1)
        let active = activePlayerCount
        lock.unlock()

        logMemory(event: "deinit", playerID: playerID, activePlayerCount: active)
    }

    static func logMemory(event: String, playerID: String) {
        logMemory(event: event, playerID: playerID, activePlayerCount: currentActivePlayerCount())
    }

    private static func logMemory(event: String, playerID: String, activePlayerCount: Int) {
        let residentBytes = currentResidentMemoryBytes()
        let peakBytes = updatePeakResidentMemoryBytes(residentBytes)
        let residentMB = megabytesString(residentBytes)
        let peakMB = megabytesString(peakBytes)
        print("[VideoPlayerDiagnostics] vp_memory | event: \(event) | playerID: \(playerID) | activePlayers: \(activePlayerCount) | rssMB: \(residentMB) | peakRSSMB: \(peakMB)")
    }

    private static func currentActivePlayerCount() -> Int {
        lock.lock()
        let active = activePlayerCount
        lock.unlock()
        return active
    }

    private static func updatePeakResidentMemoryBytes(_ bytes: UInt64) -> UInt64 {
        lock.lock()
        peakResidentMemoryBytes = max(peakResidentMemoryBytes, bytes)
        let peak = peakResidentMemoryBytes
        lock.unlock()
        return peak
    }

    private static func currentResidentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    reboundPointer,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }

    private static func megabytesString(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1024.0 / 1024.0)
    }
}
