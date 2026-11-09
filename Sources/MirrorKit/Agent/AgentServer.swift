import AgentProtocol
import CoreGraphics
import Darwin
import Foundation

/// Serves the agent API (see AgentProtocol) on a Unix domain socket.
/// Every connection is handled on its own thread; requests on one connection run in order.
public final class AgentServer: @unchecked Sendable {
    let controller: MirrorController
    private var listenFD: Int32 = -1
    private let path: String
    /// Hooks provided by the app.
    public var showWindow: ((Bool) -> Void)?
    public var windowVisible: (() -> Bool)?
    public var pinProvider: (() -> String?)?
    public var connectHandler: (() -> Void)?
    /// Debug: PNG of the app's own windows (hidden method `debug_window`).
    public var windowSnapshot: ((String) -> Data?)?
    /// Debug: presentation statistics from the renderer (hidden method `debug_present`).
    public var presentStats: ((Bool) -> [String: Any])?
    /// Debug: run the renderer on a synthetic stream (hidden method `debug_synthetic`).
    public var syntheticTest: (([String: Any]) -> [String: Any])?

    /// Size of the last screenshot handed to an agent; defines "screenshot space".
    var shotSize: CGSize?
    let shotLock = NSLock()
    var appCache: (Date, [PhoneApp])?

    // Shared request state. Helpers are internal to MirrorKit; the public API remains on this type.
    var physicalSizeCache: [String: (Date, (Double, Double))] = [:]
    let cacheLock = NSLock()
    var ocrCache: (counter: UInt64, texts: [ScreenText], scale: CGFloat)?
    let ocrLock = NSLock()
    var treeCache: (counter: UInt64, nodes: [UINode])?

    public init(controller: MirrorController, path: String = AgentAPI.socketPath) {
        self.controller = controller
        self.path = path
    }

    public func start() throws {
        guard listenFD < 0 else { throw ADBError("agent server is already running") }
        var addr = sockaddr_un()
        let bytes = Array(path.utf8)
        guard !bytes.contains(0), bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw ADBError("agent socket path is invalid or too long")
        }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw ADBError("socket() failed") }
        var started = false
        defer {
            if !started { close(listenFD); listenFD = -1; unlink(path) }
        }
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { throw ADBError("bind \(path): \(String(cString: strerror(errno)))") }
        guard chmod(path, 0o600) == 0, listen(listenFD, 16) == 0 else {
            throw ADBError("cannot protect or listen on agent socket: \(String(cString: strerror(errno)))")
        }
        started = true
        Log.info("agent API listening on \(path)")
        TextRecognizer.warmUp()
        let t = Thread { [weak self] in self?.acceptLoop() }
        t.qualityOfService = .userInteractive
        t.start()
    }

    public func stop() {
        if listenFD >= 0 { shutdown(listenFD, SHUT_RDWR); close(listenFD); listenFD = -1 }
        unlink(path)
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { if errno == EINTR { continue }; break }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let t = Thread { [weak self] in self?.serve(fd) }
            t.qualityOfService = .userInteractive
            t.name = "agent-conn"
            t.start()
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard !line.isEmpty else { continue }
                let response = handleLine(Data(line))
                var out = (try? JSONSerialization.data(withJSONObject: response)) ?? Data("{\"error\":\"encode\"}".utf8)
                out.append(0x0A)
                let ok = out.withUnsafeBytes { raw -> Bool in
                    var off = 0
                    while off < raw.count {
                        let w = write(fd, raw.baseAddress! + off, raw.count - off)
                        if w <= 0 { return false }
                        off += w
                    }
                    return true
                }
                if !ok { return }
            }
        }
    }

    private func handleLine(_ line: Data) -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let method = obj["method"] as? String else {
            return ["error": "invalid request"]
        }
        let id = obj["id"] ?? NSNull()
        let params = obj["params"] as? [String: Any] ?? [:]
        let t0 = Date()
        do {
            let result = try dispatch(method, params)
            Log.info("agent \(method) \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            return ["id": id, "result": result]
        } catch {
            Log.warn("agent \(method) failed: \(error)")
            return ["id": id, "error": "\(error)"]
        }
    }

}
