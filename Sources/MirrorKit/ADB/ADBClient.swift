import Foundation

public struct ADBError: Error, CustomStringConvertible, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// One line of `host:devices-l`.
public struct ADBDeviceEntry: Hashable, Sendable {
    public var serial: String
    public var state: String          // device, unauthorized, offline, authorizing, connecting, ...
    public var product: String?
    public var model: String?
    public var device: String?
    public var transportId: String?
    public var usb: String?

    public var isOnline: Bool { state == "device" }
    /// Transport kind inferred from the serial.
    public var kind: TransportKind { TransportKind.infer(serial: serial, usb: usb) }
}

public enum TransportKind: String, Codable, Sendable, Comparable {
    case usb, lan, wirelessDebugging, tailscale, remote

    public static func infer(serial: String, usb: String?) -> TransportKind {
        if serial.contains("._adb-tls-connect.") { return .wirelessDebugging }
        if let host = serial.split(separator: ":").first.map(String.init), isIPv4(host) {
            if host.hasPrefix("100.") , let second = host.split(separator: ".").dropFirst().first.flatMap({ Int($0) }),
               (64...127).contains(second) { return .tailscale }
            return .lan
        }
        if serial.hasPrefix("[") { return .lan }
        return .usb
    }

    private static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    /// Lower is better.
    public var preference: Int {
        switch self {
        case .usb: return 0
        case .lan: return 1
        case .wirelessDebugging: return 2
        case .tailscale: return 3
        case .remote: return 4
        }
    }

    public static func < (a: TransportKind, b: TransportKind) -> Bool { a.preference < b.preference }

    public var label: String {
        switch self {
        case .usb: return "USB"
        case .lan: return "Wi-Fi"
        case .wirelessDebugging: return "Wireless Debugging"
        case .tailscale: return "Tailscale"
        case .remote: return "Remote"
        }
    }

    public var symbol: String {
        switch self {
        case .usb: return "cable.connector"
        case .lan: return "wifi"
        case .wirelessDebugging: return "antenna.radiowaves.left.and.right"
        case .tailscale: return "network"
        case .remote: return "globe"
        }
    }
}

/// Client for the ADB *server* protocol (the smart socket on tcp:5037).
/// We speak it directly rather than spawning `adb` for every call: a host request costs
/// ~0.3 ms instead of ~15-40 ms of process launch.
public final class ADBClient: @unchecked Sendable {
    public var host: String
    public var port: UInt16

    public static let shared = ADBClient()

    public init(host: String? = nil, port: UInt16? = nil) {
        let (h, p) = ADBClient.defaultServerAddress()
        self.host = host ?? h
        self.port = port ?? p
    }

    /// Honors ADB_SERVER_SOCKET=tcp:host:port (the same variable the adb CLI uses), and the
    /// app's "ADB server" setting.
    public static func defaultServerAddress() -> (String, UInt16) {
        if let override = UserDefaults.standard.string(forKey: "adbServerSocket"), !override.isEmpty,
           let parsed = parseServerSocket(override) {
            return parsed
        }
        if let env = ProcessInfo.processInfo.environment["ADB_SERVER_SOCKET"], let parsed = parseServerSocket(env) {
            return parsed
        }
        return ("127.0.0.1", 5037)
    }

    public static func parseServerSocket(_ s: String) -> (String, UInt16)? {
        var str = s
        if str.hasPrefix("tcp:") { str.removeFirst(4) }
        let comps = str.split(separator: ":")
        if comps.count == 1, let p = UInt16(comps[0]) { return ("127.0.0.1", p) }
        if comps.count == 2, let p = UInt16(comps[1]) { return (String(comps[0]), p) }
        return nil
    }

    public var serverSocketString: String { "tcp:\(host):\(port)" }
    public var isLocalServer: Bool { host == "127.0.0.1" || host == "localhost" }

    // MARK: Low-level

    func openServerSocket(timeout: TimeInterval = 3) throws -> TCPSocket {
        do {
            return try TCPSocket.connect(host: host, port: port, timeout: timeout)
        } catch {
            if isLocalServer, ADBTool.startServerIfNeeded() {
                return try TCPSocket.connect(host: host, port: port, timeout: timeout)
            }
            throw ADBError("ADB server unreachable at \(host):\(port) (\(error))")
        }
    }

    static func sendRequest(_ sock: TCPSocket, _ payload: String) throws {
        let bytes = Array(payload.utf8)
        let header = String(format: "%04x", bytes.count)
        try sock.write(Array(header.utf8) + bytes)
    }

    static func readStatus(_ sock: TCPSocket) throws {
        let status = try sock.readBytes(4)
        let s = String(decoding: status, as: UTF8.self)
        if s == "OKAY" { return }
        if s == "FAIL" {
            let msg = (try? readLengthPrefixedString(sock)) ?? "unknown failure"
            throw ADBError(msg)
        }
        throw ADBError("unexpected adb status '\(s)'")
    }

    static func readLengthPrefixedString(_ sock: TCPSocket) throws -> String {
        let lenHex = String(decoding: try sock.readBytes(4), as: UTF8.self)
        guard let len = Int(lenHex, radix: 16) else { throw ADBError("bad length '\(lenHex)'") }
        return String(decoding: try sock.readBytes(len), as: UTF8.self)
    }

    /// A host-level query (`host:version`, `host:devices-l`, ...) returning its payload.
    public func hostQuery(_ request: String, timeout: TimeInterval = 5) throws -> String {
        let sock = try openServerSocket()
        defer { sock.close() }
        sock.setReadTimeout(timeout)
        try ADBClient.sendRequest(sock, request)
        try ADBClient.readStatus(sock)
        return try ADBClient.readLengthPrefixedString(sock)
    }

    /// Like `hostQuery` but for commands that answer OKAY then a raw string until EOF (or nothing).
    public func hostCommand(_ request: String, timeout: TimeInterval = 15) throws -> String {
        let sock = try openServerSocket()
        defer { sock.close() }
        sock.setReadTimeout(timeout)
        try ADBClient.sendRequest(sock, request)
        try ADBClient.readStatus(sock)
        // host:connect etc. reply with OKAY + length-prefixed message.
        return (try? ADBClient.readLengthPrefixedString(sock)) ?? ""
    }

    /// Open a stream to a device service (e.g. `exec:ls`, `localabstract:scrcpy_1234`, `sync:`).
    public func openStream(serial: String, service: String, timeout: TimeInterval = 5) throws -> TCPSocket {
        let sock = try openServerSocket(timeout: timeout)
        do {
            sock.setReadTimeout(timeout)
            try ADBClient.sendRequest(sock, "host:transport:\(serial)")
            try ADBClient.readStatus(sock)
            try ADBClient.sendRequest(sock, service)
            try ADBClient.readStatus(sock)
            sock.setReadTimeout(0)
            return sock
        } catch {
            sock.close()
            throw error
        }
    }

    // MARK: High-level

    public func version() throws -> Int {
        let v = try hostQuery("host:version")
        return Int(v, radix: 16) ?? 0
    }

    public func devices() throws -> [ADBDeviceEntry] {
        let text = try hostQuery("host:devices-l")
        return ADBClient.parseDevices(text)
    }

    public static func parseDevices(_ text: String) -> [ADBDeviceEntry] {
        var out: [ADBDeviceEntry] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2 else { continue }
            var e = ADBDeviceEntry(serial: parts[0], state: parts[1])
            for p in parts.dropFirst(2) {
                let kv = p.split(separator: ":", maxSplits: 1).map(String.init)
                guard kv.count == 2 else { continue }
                switch kv[0] {
                case "product": e.product = kv[1]
                case "model": e.model = kv[1]
                case "device": e.device = kv[1]
                case "transport_id": e.transportId = kv[1]
                case "usb": e.usb = kv[1]
                default: break
                }
            }
            out.append(e)
        }
        return out
    }

    /// `adb connect host:port`. Returns the server's message ("connected to ...", "already connected ...").
    @discardableResult
    public func connect(_ address: String) throws -> String {
        let msg = try hostCommand("host:connect:\(address)", timeout: 12)
        if msg.contains("failed") || msg.contains("unable") || msg.contains("cannot") {
            throw ADBError(msg)
        }
        return msg
    }

    @discardableResult
    public func disconnect(_ address: String) throws -> String {
        try hostCommand("host:disconnect:\(address)")
    }

    /// Run a command with `exec:` (no pty, binary-safe stdout) and return its output.
    public func exec(serial: String, _ command: String, timeout: TimeInterval = 20) throws -> Data {
        let sock = try openStream(serial: serial, service: "exec:\(command)", timeout: timeout)
        defer { sock.close() }
        sock.setReadTimeout(timeout)
        return try sock.readToEnd()
    }

    public func shell(serial: String, _ command: String, timeout: TimeInterval = 20) throws -> String {
        String(decoding: try exec(serial: serial, command, timeout: timeout), as: UTF8.self)
    }

    /// Fast round-trip probe through the full path (server → transport → adbd → shell).
    public func ping(serial: String, timeout: TimeInterval = 3) -> TimeInterval? {
        let start = DispatchTime.now()
        guard let out = try? shell(serial: serial, "echo 1", timeout: timeout), out.hasPrefix("1") else { return nil }
        return Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
    }

    public func getprop(serial: String, _ name: String) -> String? {
        let v = (try? shell(serial: serial, "getprop \(name)", timeout: 5))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (v?.isEmpty ?? true) ? nil : v
    }

    // MARK: Sync (push)

    /// Push a local file to the device using the sync protocol.
    public func push(serial: String, data: Data, remotePath: String, mode: Int = 0o644) throws {
        let sock = try openStream(serial: serial, service: "sync:", timeout: 10)
        defer { sock.close() }
        sock.setReadTimeout(30)
        let spec = Array("\(remotePath),\(mode)".utf8)
        var hdr: [UInt8] = Array("SEND".utf8)
        hdr.appendLE(UInt32(spec.count))
        hdr += spec
        try sock.write(hdr)
        let chunk = 64 * 1024
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunk, data.count)
            var dh: [UInt8] = Array("DATA".utf8)
            dh.appendLE(UInt32(end - offset))
            try sock.write(dh)
            try sock.write(data.subdata(in: offset..<end))
            offset = end
        }
        var done: [UInt8] = Array("DONE".utf8)
        done.appendLE(UInt32(Date().timeIntervalSince1970))
        try sock.write(done)
        let status = try sock.readBytes(8)
        let id = String(decoding: status[0..<4], as: UTF8.self)
        if id != "OKAY" {
            let len = Int(UInt32(status[4]) | UInt32(status[5]) << 8 | UInt32(status[6]) << 16 | UInt32(status[7]) << 24)
            let msg = String(decoding: (try? sock.readBytes(len)) ?? [], as: UTF8.self)
            throw ADBError("push failed: \(msg)")
        }
        var quit: [UInt8] = Array("QUIT".utf8)
        quit.appendLE(UInt32(0))
        try? sock.write(quit)
    }

    /// Pull a remote file using the sync protocol.
    public func pull(serial: String, remotePath: String) throws -> Data {
        let sock = try openStream(serial: serial, service: "sync:", timeout: 10)
        defer { sock.close() }
        sock.setReadTimeout(30)
        let path = Array(remotePath.utf8)
        var hdr: [UInt8] = Array("RECV".utf8)
        hdr.appendLE(UInt32(path.count))
        hdr += path
        try sock.write(hdr)
        var out = Data()
        while true {
            let h = try sock.readBytes(8)
            let id = String(decoding: h[0..<4], as: UTF8.self)
            let len = Int(UInt32(h[4]) | UInt32(h[5]) << 8 | UInt32(h[6]) << 16 | UInt32(h[7]) << 24)
            if id == "DATA" {
                out.append(try sock.readFully(len))
            } else if id == "DONE" {
                break
            } else if id == "FAIL" {
                throw ADBError(String(decoding: try sock.readBytes(len), as: UTF8.self))
            } else {
                throw ADBError("unexpected sync id \(id)")
            }
        }
        return out
    }
}

/// Wrapper around the `adb` executable for the few operations that need it
/// (pairing, starting the server, installs with streaming progress).
public enum ADBTool {
    public static var executablePath: String? = {
        if let custom = UserDefaults.standard.string(forKey: "adbPath"), FileManager.default.isExecutableFile(atPath: custom) {
            return custom
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "\(home)/Android/Sdk/platform-tools/adb",
            "/Applications/Android Studio.app/Contents/platform-tools/adb",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return found }
        // PATH lookup
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let p = "\(dir)/adb"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }()

    @discardableResult
    public static func run(_ args: [String], timeout: TimeInterval = 60, input: String? = nil) throws -> (status: Int32, output: String) {
        guard let exe = executablePath else { throw ADBError("adb not found. Install with: brew install android-platform-tools") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["ADB_SERVER_SOCKET"] = ADBClient.shared.serverSocketString
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let inPipe = Pipe()
        p.standardInput = inPipe
        try p.run()
        if let input { inPipe.fileHandleForWriting.write(input.data(using: .utf8)!) }
        try? inPipe.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        let reader = DispatchQueue.global()
        let group = DispatchGroup()
        group.enter()
        reader.async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate() }
        _ = group.wait(timeout: .now() + 2)
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static let startLock = NSLock()
    /// Starts the local adb server if it isn't running. Returns true if it is up afterwards.
    public static func startServerIfNeeded() -> Bool {
        startLock.lock(); defer { startLock.unlock() }
        if (try? TCPSocket.connect(host: "127.0.0.1", port: 5037, timeout: 0.3)) != nil { return true }
        guard let exe = executablePath else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["start-server"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// `adb pair host:port code`
    public static func pair(address: String, code: String) throws -> String {
        let (status, out) = try run(["pair", address, code], timeout: 30)
        if status != 0 || out.lowercased().contains("failed") {
            throw ADBError(out.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
