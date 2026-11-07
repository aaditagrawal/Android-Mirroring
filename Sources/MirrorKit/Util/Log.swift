import Foundation
import os

/// Lightweight logging that goes to unified logging and, optionally, a rolling file
/// at ~/Library/Logs/AndroidMirroring/mirroring.log (useful when an agent is debugging).
public enum Log {
    private static let logger = Logger(subsystem: "com.aaditagrawal.AndroidMirroring", category: "core")
    private static let queue = DispatchQueue(label: "log.file")
    private static var handle: FileHandle? = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AndroidMirroring", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mirroring.log")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > 8 * 1024 * 1024 {
            try? FileManager.default.removeItem(at: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: url)
        h?.seekToEndOfFile()
        return h
    }()
    public static var echoToStderr = ProcessInfo.processInfo.environment["MIRROR_LOG_STDERR"] != nil

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    public static func info(_ msg: @autoclosure () -> String) { write("I", msg()) }
    public static func warn(_ msg: @autoclosure () -> String) { write("W", msg()) }
    public static func error(_ msg: @autoclosure () -> String) { write("E", msg()) }
    public static func debug(_ msg: @autoclosure () -> String) {
        #if DEBUG
        write("D", msg())
        #endif
    }

    private static func write(_ level: String, _ msg: String) {
        switch level {
        case "E": logger.error("\(msg, privacy: .public)")
        case "W": logger.warning("\(msg, privacy: .public)")
        default: logger.info("\(msg, privacy: .public)")
        }
        let line = "\(fmt.string(from: Date())) \(level) \(msg)\n"
        if echoToStderr { FileHandle.standardError.write(line.data(using: .utf8)!) }
        queue.async { handle?.write(line.data(using: .utf8)!) }
    }
}

/// Sleep with sub-millisecond accuracy. `usleep` on threads without an explicit QoS can be
/// coalesced by 100+ ms, which ruins gesture timing (a 300 ms swipe becoming 6 s).
@inline(__always) public func preciseSleep(microseconds us: Int) {
    guard us > 0 else { return }
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    let ticks = UInt64(us) * 1000 * UInt64(info.denom) / UInt64(info.numer)
    mach_wait_until(mach_absolute_time() + ticks)
}
