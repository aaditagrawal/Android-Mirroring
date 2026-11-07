import CoreVideo
import Foundation

public struct StreamOptions: Equatable, Sendable {
    public var videoCodec: String = "h265"     // h265 | h264
    public var maxSize: Int = 1920             // 0 = native
    public var videoBitRate: Int = 12_000_000
    public var maxFps: Int = 60
    public var audio: Bool = true
    public var audioCodec: String = "opus"     // opus | aac | raw
    public var audioBitRate: Int = 128_000
    public var clipboardAutosync: Bool = true
    public var stayAwake: Bool = false
    public var showTouches: Bool = false
    public var powerOffOnClose: Bool = false
    public var displayId: Int = 0
    public var turnScreenOff: Bool = false

    public init() {}

    /// Tuned for a remote / higher-latency path: fewer bits, smaller frames, same fps.
    public static func remote() -> StreamOptions {
        var o = StreamOptions()
        o.maxSize = 1600
        o.videoBitRate = 6_000_000
        o.audioBitRate = 96_000
        return o
    }
}

public struct StreamStats: Sendable {
    public var fps: Double = 0
    public var bitrateMbps: Double = 0
    public var decodedFrames: UInt64 = 0
    public var droppedOrErrors: UInt64 = 0
    public var codec: String = ""
    public var width: Int = 0
    public var height: Int = 0
}

/// One scrcpy server instance on one adb transport.
public final class ScrcpySession: @unchecked Sendable {
    public static let serverVersion = "5.0.1"
    /// Cached copy of the server on the device. Never executed directly: scrcpy's cleanup
    /// process unlinks the jar it was started from, so each run gets its own copy.
    static let cachedJar = "/data/local/tmp/android-mirroring-server-\(serverVersion).cache"
    static func runJar(_ tag: String) -> String { "/data/local/tmp/android-mirroring-\(tag).jar" }
    /// Shell prefix that materializes a runnable copy and sets CLASSPATH.
    static func launchPrefix(_ tag: String) -> String {
        "cp \(cachedJar) \(runJar(tag)) && CLASSPATH=\(runJar(tag)) app_process / com.genymobile.scrcpy.Server \(serverVersion)"
    }

    public let serial: String
    public let options: StreamOptions
    let adb: ADBClient
    let scid: UInt32 = UInt32.random(in: 1..<0x7FFF_FFFF)

    private var serverStream: TCPSocket?
    private var videoSocket: TCPSocket?
    private var audioSocket: TCPSocket?
    private var controlSocket: TCPSocket?
    private let controlLock = NSLock()
    private var stopped = false
    private let stateLock = NSLock()

    private var decoder: VideoDecoder?
    private var audioPlayer: AudioPlayer?

    public private(set) var deviceName: String = ""
    /// Current video frame size (what touch coordinates must be expressed in).
    public private(set) var frameSize: (UInt16, UInt16) = (0, 0)

    // Callbacks (invoked on the stream threads).
    public var onFrame: ((CVPixelBuffer) -> Void)?
    public var onFrameSize: ((Int, Int) -> Void)?
    public var onClipboard: ((String) -> Void)?
    public var onClosed: ((String?) -> Void)?
    public var onStats: ((StreamStats) -> Void)?
    public var audioVolume: Float = 1 { didSet { audioPlayer?.volume = audioVolume } }

    private var statFrames = 0
    private var statBytes = 0
    private var statStart = DispatchTime.now()
    private var stats = StreamStats()

    public init(adb: ADBClient, serial: String, options: StreamOptions) {
        self.adb = adb
        self.serial = serial
        self.options = options
    }

    // MARK: Lifecycle

    /// Blocking: pushes the server, launches it and connects all sockets. Then spawns reader threads.
    public func start() throws {
        let t0 = DispatchTime.now()
        try pushServerIfNeeded()
        try launchServer()
        try connectSockets()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        Log.info("scrcpy session \(String(format: "%08x", scid)) up on \(serial) in \(Int(ms)) ms")
        startReaders()
    }

    public func stop() {
        stateLock.lock()
        if stopped { stateLock.unlock(); return }
        stopped = true
        stateLock.unlock()
        videoSocket?.shutdown()
        audioSocket?.shutdown()
        controlSocket?.shutdown()
        serverStream?.shutdown()
        audioPlayer?.stop()
    }

    var isStopped: Bool { stateLock.lock(); defer { stateLock.unlock() }; return stopped }

    private func pushServerIfNeeded() throws {
        guard let url = ScrcpySession.serverJarURL() else { throw ADBError("scrcpy-server resource missing from app bundle") }
        let data = try Data(contentsOf: url)
        try ScrcpySession.ensureServer(adb: adb, serial: serial, data: data)
    }

    static func ensureServer(adb: ADBClient, serial: String, data: Data? = nil) throws {
        // Let transport errors propagate (don't try to push over a dead link).
        let remoteSize = try adb.shell(serial: serial, "stat -c %s \(cachedJar) 2>/dev/null", timeout: 5)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = data ?? serverJarURL().flatMap({ try? Data(contentsOf: $0) }) else {
            throw ADBError("scrcpy-server resource missing from app bundle")
        }
        if remoteSize == String(data.count) { return }
        Log.info("pushing scrcpy-server (\(data.count) bytes) to \(serial)")
        try adb.push(serial: serial, data: data, remotePath: cachedJar)
    }

    public static func serverJarURL() -> URL? {
        if let u = Bundle.main.url(forResource: "scrcpy-server", withExtension: nil) { return u }
        // Development: walk up from the executable to find Resources/scrcpy-server.
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            let c = dir.appendingPathComponent("Resources/scrcpy-server")
            if FileManager.default.fileExists(atPath: c.path) { return c }
            dir.deleteLastPathComponent()
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/scrcpy-server")
        return FileManager.default.fileExists(atPath: cwd.path) ? cwd : nil
    }

    private func serverArgs() -> [String] {
        let o = options
        var a = [
            "scid=\(String(format: "%08x", scid))",
            "log_level=info",
            "tunnel_forward=true",
            "video_codec=\(o.videoCodec)",
            "video_bit_rate=\(o.videoBitRate)",
            "max_fps=\(o.maxFps)",
            "audio=\(o.audio)",
            "control=true",
            "clipboard_autosync=\(o.clipboardAutosync)",
            "stay_awake=\(o.stayAwake)",
            "show_touches=\(o.showTouches)",
            "power_off_on_close=\(o.powerOffOnClose)",
            "downsize_on_error=true",
            "cleanup=true",
            // Ask MediaCodec for realtime priority (0) so the encoder is scheduled ahead of background work.
            "video_codec_options=priority:int=0",
        ]
        if o.maxSize > 0 { a.append("max_size=\(o.maxSize)") }
        if o.audio {
            a.append("audio_codec=\(o.audioCodec)")
            a.append("audio_bit_rate=\(o.audioBitRate)")
        }
        if o.displayId != 0 { a.append("display_id=\(o.displayId)") }
        return a
    }

    private func launchServer() throws {
        let cmd = ScrcpySession.launchPrefix(String(format: "%08x", scid)) + " " + serverArgs().joined(separator: " ")
        let s = try adb.openStream(serial: serial, service: "exec:\(cmd)", timeout: 8)
        serverStream = s
        let name = String(format: "%08x", scid)
        Thread.detachNewThread { [weak self] in
            Thread.current.name = "scrcpy-server-log"
            var pending = ""
            while let chunk = try? s.readSome() {
                pending += String(decoding: chunk, as: UTF8.self)
                while let nl = pending.firstIndex(of: "\n") {
                    let line = String(pending[..<nl]).trimmingCharacters(in: .whitespaces)
                    pending = String(pending[pending.index(after: nl)...])
                    if !line.isEmpty { Log.info("[server \(name)] \(line)") }
                }
            }
            if let self, !self.isStopped { Log.warn("[server \(name)] process output closed") }
        }
    }

    private func openLocalAbstract() throws -> TCPSocket {
        try adb.openStream(serial: serial, service: "localabstract:scrcpy_\(String(format: "%08x", scid))", timeout: 5)
    }

    private func connectSockets() throws {
        // The server needs a moment to start its JVM and bind; retry until it answers with the dummy byte.
        let deadline = Date().addingTimeInterval(12)
        var video: TCPSocket?
        var lastErr: Error?
        while Date() < deadline, !isStopped {
            do {
                let s = try openLocalAbstract()
                s.setReadTimeout(2)
                let b = try s.readBytes(1)
                if b.count == 1 { video = s; break }
            } catch {
                lastErr = error
                usleep(60_000)
            }
        }
        guard let video else { throw ADBError("scrcpy server did not start: \(lastErr.map { "\($0)" } ?? "timeout")") }
        videoSocket = video
        if options.audio { audioSocket = try openLocalAbstract() }
        controlSocket = try openLocalAbstract()

        video.setReadTimeout(8)
        let meta = try video.readBytes(64)
        let nameBytes = meta.prefix { $0 != 0 }
        deviceName = String(decoding: nameBytes, as: UTF8.self)
        video.setReadTimeout(0)
    }

    private func startReaders() {
        let v = Thread { [weak self] in self?.videoLoop() }
        v.name = "video-reader"
        v.qualityOfService = .userInteractive
        v.start()
        if audioSocket != nil {
            let a = Thread { [weak self] in self?.audioLoop() }
            a.name = "audio-reader"
            a.qualityOfService = .userInteractive
            a.start()
        }
        let c = Thread { [weak self] in self?.controlLoop() }
        c.name = "control-reader"
        c.qualityOfService = .userInitiated
        c.start()
    }

    private func closeWith(_ reason: String?) {
        let wasStopped = isStopped
        stop()
        if !wasStopped {
            Log.warn("session closed: \(reason ?? "unknown")")
            onClosed?(reason)
        }
    }

    // MARK: Video

    private func videoLoop() {
        guard let sock = videoSocket else { return }
        do {
            let codecRaw = be32Read(try sock.readBytes(4))
            if codecRaw == 0 || codecRaw == 1 {
                throw ADBError(codecRaw == 0 ? "video disabled by device" : "video capture error on device")
            }
            guard let codec = VideoCodecID(rawValue: codecRaw) else { throw ADBError("unsupported video codec 0x\(String(codecRaw, radix: 16))") }
            let dec = VideoDecoder(codec: codec)
            dec.onFrame = { [weak self] pb, _ in self?.handleFrame(pb) }
            dec.onError = { [weak self] status in self?.handleDecodeError(status) }
            decoder = dec
            stats.codec = codec.name

            var capacity = 1 << 20
            var buf = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { buf.deallocate() }
            var header = [UInt8](repeating: 0, count: 12)
            while !isStopped {
                try header.withUnsafeMutableBytes { try sock.readFully(into: $0.baseAddress!, count: 12) }
                let first = header.withUnsafeBytes { be64($0.baseAddress!) }
                if header[0] & 0x80 != 0 {
                    let w = header.withUnsafeBytes { be32($0.baseAddress!, 4) }
                    let h = header.withUnsafeBytes { be32($0.baseAddress!, 8) }
                    frameSize = (UInt16(w), UInt16(h))
                    stats.width = Int(w); stats.height = Int(h)
                    Log.info("video session \(w)x\(h)")
                    onFrameSize?(Int(w), Int(h))
                    continue
                }
                let size = Int(header.withUnsafeBytes { be32($0.baseAddress!, 8) })
                if size > capacity {
                    buf.deallocate()
                    capacity = max(size, capacity * 2)
                    buf = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
                }
                try sock.readFully(into: buf, count: size)
                statBytes += size + 12
                let isConfig = first & (1 << 62) != 0
                let pts = Int64(bitPattern: first & ((1 << 61) - 1))
                if isConfig {
                    dec.configure(annexB: Data(bytes: buf, count: size))
                } else {
                    dec.decode(annexB: buf, count: size, pts: pts)
                }
            }
        } catch {
            closeWith("video: \(error)")
        }
        decoder?.invalidate()
    }

    private var lastResetRequest = DispatchTime(uptimeNanoseconds: 0)
    private func handleDecodeError(_ status: OSStatus) {
        stats.droppedOrErrors &+= 1
        // Ask for a fresh key frame, at most twice per second.
        let now = DispatchTime.now()
        if now.uptimeNanoseconds - lastResetRequest.uptimeNanoseconds > 500_000_000 {
            lastResetRequest = now
            send(ControlMessage.resetVideo())
        }
    }

    private func handleFrame(_ pb: CVPixelBuffer) {
        statFrames += 1
        onFrame?(pb)
        let now = DispatchTime.now()
        let dt = Double(now.uptimeNanoseconds - statStart.uptimeNanoseconds) / 1e9
        if dt >= 1 {
            stats.fps = Double(statFrames) / dt
            stats.bitrateMbps = Double(statBytes) * 8 / dt / 1e6
            stats.decodedFrames = decoder?.decodedFrames ?? 0
            statFrames = 0; statBytes = 0; statStart = now
            onStats?(stats)
        }
    }

    public var currentStats: StreamStats { stats }

    // MARK: Audio

    private func audioLoop() {
        guard let sock = audioSocket else { return }
        do {
            let codecRaw = be32Read(try sock.readBytes(4))
            if codecRaw == 0 || codecRaw == 1 {
                Log.warn(codecRaw == 0 ? "audio disabled by device" : "audio capture failed on device (unlock the phone and reconnect, Android 11+ needed)")
                return
            }
            guard let codec = AudioCodecID(rawValue: codecRaw), let player = AudioPlayer(codec: codec) else {
                Log.warn("unsupported audio codec 0x\(String(codecRaw, radix: 16))")
                return
            }
            player.volume = audioVolume
            audioPlayer = player
            Log.info("audio stream: \(codec)")
            var packets = 0
            var header = [UInt8](repeating: 0, count: 12)
            while !isStopped {
                try header.withUnsafeMutableBytes { try sock.readFully(into: $0.baseAddress!, count: 12) }
                let first = header.withUnsafeBytes { be64($0.baseAddress!) }
                let size = Int(header.withUnsafeBytes { be32($0.baseAddress!, 8) })
                let data = try sock.readFully(size)
                if first & (1 << 62) != 0 {
                    player.configure(data)
                } else {
                    player.enqueue(data)
                    packets += 1
                    if packets == 50 { Log.info("audio: 50 packets decoded (\(player.decodedFrames) frames)") }
                }
            }
        } catch {
            if !isStopped { Log.warn("audio stream ended: \(error)") }
        }
        audioPlayer?.stop()
    }

    // MARK: Control

    private func controlLoop() {
        guard let sock = controlSocket else { return }
        do {
            while !isStopped {
                let type = try sock.readBytes(1)[0]
                switch type {
                case 0:
                    let len = Int(be32Read(try sock.readBytes(4)))
                    let text = String(decoding: try sock.readFully(len), as: UTF8.self)
                    onClipboard?(text)
                case 1:
                    _ = try sock.readBytes(8)
                case 2:
                    _ = try sock.readBytes(2)
                    let len = Int(UInt16(try sock.readBytes(2)).bigEndianValue)
                    _ = try sock.readBytes(len)
                default:
                    throw ADBError("unknown device message \(type)")
                }
            }
        } catch {
            if !isStopped { closeWith("control: \(error)") }
        }
    }

    /// Thread-safe write of a serialized control message.
    public func send(_ bytes: [UInt8]) {
        guard let s = controlSocket, !isStopped else { return }
        controlLock.lock()
        defer { controlLock.unlock() }
        do { try s.write(bytes) } catch { Log.warn("control write failed: \(error)") }
    }

    private func be32Read(_ b: [UInt8]) -> UInt32 {
        UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }
}

private extension UInt16 {
    init(_ bytes: [UInt8]) { self = UInt16(bytes[0]) << 8 | UInt16(bytes[1]) }
    var bigEndianValue: UInt16 { self }
}
