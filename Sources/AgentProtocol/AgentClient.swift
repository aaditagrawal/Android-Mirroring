import Foundation

// MARK: - Minimal client used by droidctl

public final class AgentClient {
    private var fd: Int32 = -1
    private var buffer = Data()
    private var nextId = 1

    public init() {}

    public func connect(path: String = AgentAPI.socketPath) throws {
        if fd >= 0 { close(fd); fd = -1 }
        buffer.removeAll(keepingCapacity: true)
        var addr = sockaddr_un()
        let bytes = Array(path.utf8)
        guard !bytes.contains(0), bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw AgentError.message("socket path is invalid or too long")
        }
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentError.message("socket() failed") }
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        if rc != 0 {
            close(fd); fd = -1
            throw AgentError.notRunning
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { if fd >= 0 { close(fd) } }

    /// Send a request and wait for its response.
    public func call(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        let id = nextId; nextId += 1
        let req: [String: Any] = ["id": id, "method": method, "params": params]
        var data = try JSONSerialization.data(withJSONObject: req)
        data.append(0x0A)
        try data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { throw AgentError.message("write failed") }
                off += n
            }
        }
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if (obj["id"] as? Int) != id { continue }
                if let err = obj["error"] as? String { throw AgentError.message(err) }
                return obj["result"] as? [String: Any] ?? [:]
            }
            var chunk = [UInt8](repeating: 0, count: 256 * 1024)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { throw AgentError.message("connection closed by Android Mirroring") }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}

public enum AgentError: Error, CustomStringConvertible {
    case notRunning
    case message(String)
    public var description: String {
        switch self {
        case .notRunning: return "Android Mirroring is not running"
        case .message(let m): return m
        }
    }
}
