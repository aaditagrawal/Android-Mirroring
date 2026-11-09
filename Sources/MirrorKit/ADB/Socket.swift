import Darwin
import Foundation

public struct SocketError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// A minimal blocking TCP socket. Streams in this app run on dedicated threads, so blocking
/// I/O is both the simplest and the lowest-latency option (no executor hops per packet).
public final class TCPSocket {
    public private(set) var fd: Int32
    private let closeLock = NSLock()

    public init(fd: Int32) { self.fd = fd }

    /// Connect to host:port with a timeout. Enables TCP_NODELAY and SO_NOSIGPIPE.
    public static func connect(host: String, port: UInt16, timeout: TimeInterval = 5) throws -> TCPSocket {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let first = res else {
            throw SocketError("getaddrinfo(\(host)): \(String(cString: gai_strerror(rc)))")
        }
        defer { freeaddrinfo(res) }
        var lastError = "no address"
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if fd >= 0 {
                let s = TCPSocket(fd: fd)
                s.configure()
                if s.connectWithTimeout(a.pointee.ai_addr, a.pointee.ai_addrlen, timeout: timeout) {
                    return s
                }
                lastError = String(cString: strerror(errno))
                s.close()
            }
            ai = a.pointee.ai_next
        }
        throw SocketError("connect \(host):\(port): \(lastError)")
    }

    /// Connect to whichever host answers first ("happy eyeballs"): non-blocking connects to all
    /// hosts at once, the first established connection wins and the rest are closed. Returns the
    /// socket and the winning host. If every host actively refused, the error says "refused".
    public static func connectFirst(hosts: [String], port: UInt16, timeout: TimeInterval) throws -> (TCPSocket, String) {
        var pending: [(TCPSocket, String)] = []
        var errors: [String] = []
        for host in hosts {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            hints.ai_flags = AI_NUMERICSERV
            var res: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, String(port), &hints, &res) == 0, let a = res else { errors.append("\(host): bad address"); continue }
            defer { freeaddrinfo(res) }
            let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            let s = TCPSocket(fd: fd)
            s.configure()
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
            if Darwin.connect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0 || errno == EINPROGRESS {
                pending.append((s, host))
            } else {
                errors.append("\(host): \(String(cString: strerror(errno)))")
                s.close()
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !pending.isEmpty {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { break }
            var pfds = pending.map { pollfd(fd: $0.0.fd, events: Int16(POLLOUT), revents: 0) }
            let r = poll(&pfds, nfds_t(pfds.count), Int32(left * 1000))
            if r <= 0 { break }
            var stillPending: [(TCPSocket, String)] = []
            var winner: (TCPSocket, String)?
            for (i, p) in pending.enumerated() {
                guard pfds[i].revents != 0 else { stillPending.append(p); continue }
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(p.0.fd, SOL_SOCKET, SO_ERROR, &err, &len)
                if err == 0 && winner == nil {
                    winner = p
                } else {
                    if err != 0 { errors.append("\(p.1): \(String(cString: strerror(err)))") }
                    p.0.close()
                }
            }
            if let w = winner {
                stillPending.forEach { $0.0.close() }
                _ = fcntl(w.0.fd, F_SETFL, fcntl(w.0.fd, F_GETFL, 0) & ~O_NONBLOCK)
                return w
            }
            pending = stillPending
        }
        pending.forEach { errors.append("\($0.1): timed out"); $0.0.close() }
        throw SocketError("connect :\(port): " + errors.joined(separator: ", "))
    }

    private func configure() {
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        // Large receive buffer: video bursts on key frames should never stall the device side.
        var rcv: Int32 = 4 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))
    }

    private func connectWithTimeout(_ addr: UnsafeMutablePointer<sockaddr>!, _ len: socklen_t, timeout: TimeInterval) -> Bool {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(fd, F_SETFL, flags) }
        if Darwin.connect(fd, addr, len) == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let r = poll(&pfd, 1, Int32(timeout * 1000))
        guard r > 0 else { errno = ETIMEDOUT; return false }
        var err: Int32 = 0
        var errLen = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &errLen)
        if err != 0 { errno = err; return false }
        return true
    }

    /// Set a receive timeout (0 = blocking forever).
    public func setReadTimeout(_ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    public func setWriteTimeout(_ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    public func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            try writeAll(base, raw.count)
        }
    }

    public func write(_ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            try writeAll(base, raw.count)
        }
    }

    public func write(_ string: String) throws { try write(Array(string.utf8)) }

    private func writeAll(_ ptr: UnsafeRawPointer, _ count: Int) throws {
        var off = 0
        while off < count {
            let n = Darwin.write(fd, ptr + off, count - off)
            if n < 0 {
                if errno == EINTR { continue }
                throw SocketError("write: \(String(cString: strerror(errno)))")
            }
            off += n
        }
    }

    /// Read exactly `count` bytes into `buffer`. Throws on EOF.
    public func readFully(into buffer: UnsafeMutableRawPointer, count: Int) throws {
        var off = 0
        while off < count {
            let n = Darwin.read(fd, buffer + off, count - off)
            if n == 0 { throw SocketError("connection closed") }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN { throw SocketError("read timeout") }
                throw SocketError("read: \(String(cString: strerror(errno)))")
            }
            off += n
        }
    }

    public func readFully(_ count: Int) throws -> Data {
        var data = Data(count: count)
        if count == 0 { return data }
        try data.withUnsafeMutableBytes { raw in
            try readFully(into: raw.baseAddress!, count: count)
        }
        return data
    }

    public func readBytes(_ count: Int) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: count)
        if count == 0 { return buf }
        try buf.withUnsafeMutableBytes { raw in
            try readFully(into: raw.baseAddress!, count: count)
        }
        return buf
    }

    /// Read until EOF.
    public func readToEnd(limit: Int = 256 * 1024 * 1024) throws -> Data {
        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while out.count < limit {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN { throw SocketError("read timeout") }
                throw SocketError("read: \(String(cString: strerror(errno)))")
            }
            out.append(chunk, count: n)
        }
        return out
    }

    /// Read some bytes (at least 1) or return nil on EOF.
    public func readSome(max: Int = 64 * 1024) throws -> Data? {
        var chunk = [UInt8](repeating: 0, count: max)
        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if n == 0 { return nil }
            if n < 0 {
                if errno == EINTR { continue }
                throw SocketError("read: \(String(cString: strerror(errno)))")
            }
            return Data(chunk[0..<n])
        }
    }

    public func shutdown() {
        closeLock.lock(); defer { closeLock.unlock() }
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
    }

    public func close() {
        closeLock.lock(); defer { closeLock.unlock() }
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            fd = -1
        }
    }

    deinit { close() }
}

// MARK: - Big-endian helpers

@inline(__always) func be32(_ p: UnsafeRawPointer, _ off: Int = 0) -> UInt32 {
    UInt32(bigEndian: p.loadUnaligned(fromByteOffset: off, as: UInt32.self))
}

@inline(__always) func be64(_ p: UnsafeRawPointer, _ off: Int = 0) -> UInt64 {
    UInt64(bigEndian: p.loadUnaligned(fromByteOffset: off, as: UInt64.self))
}

extension Array where Element == UInt8 {
    @inline(__always) mutating func appendBE<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) }
    }
    @inline(__always) mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
}
