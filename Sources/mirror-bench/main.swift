import CoreVideo
import Darwin
import Foundation
import MirrorKit

// Performance lab. Mirrors a *virtual display* on the phone (nothing appears on the physical
// screen), opens Settings there, and drives scripted scrolls to measure:
//
//   latency   touch-to-photon: finger move sent -> first decoded frame where the list moved
//   smooth    frame cadence during continuous drags (interval percentiles, stutters)
//   passive   just stream for N seconds (physical display unless PERF_VD is set)
//
//   mirror-bench <serial> [latency|smooth|all|passive] [iterations]
//
// Environment: PERF_CODEC (h265|h264), PERF_SIZE (max size, 0 = native), PERF_BITRATE,
// PERF_FPS, PERF_CODEC_OPTS, PERF_VD (virtual display "WxH/dpi"; default 1080x2340/420),
// PERF_LABEL (name for the results file), PERF_OUT (results .jsonl path).

setpriority(PRIO_DARWIN_PROCESS, 0, 0)
setvbuf(stdout, nil, _IOLBF, 0)
let env = ProcessInfo.processInfo.environment
if env["PERF_LOG"] != nil { Log.echoToStderr = true }
let args = CommandLine.arguments
let adb = ADBClient.shared
guard let serial = args.count > 1 ? args[1] : (try? adb.devices())?.first(where: \.isOnline)?.serial else {
    print("no device"); exit(1)
}
let mode = args.count > 2 ? args[2] : "all"
let iterations = args.count > 3 ? Int(args[3]) ?? 12 : 12

var opts = StreamOptions()
opts.audio = false
opts.clipboardAutosync = false
opts.videoCodec = env["PERF_CODEC"] ?? "h265"
opts.maxSize = Int(env["PERF_SIZE"] ?? "0") ?? 0
opts.videoBitRate = Int(env["PERF_BITRATE"] ?? "12000000") ?? 12_000_000
opts.maxFps = Int(env["PERF_FPS"] ?? "60") ?? 60
if let o = env["PERF_CODEC_OPTS"] { opts.videoCodecOptions = o }
if let extra = env["PERF_EXTRA"] { opts.extraServerArgs = extra.split(separator: " ").map(String.init) }
if let t = env["PERF_TRANSPORT"], let m = MediaTransport(rawValue: t) { opts.transport = m }
if let h = env["PERF_HOSTS"] { opts.directHosts = h.split(separator: ",").map(String.init) }
if env["PERF_UNTIMED"] != nil { opts.timedControl = false }
if let b = env["PERF_SNDBUF"] { opts.relaySendBuffer = Int(b) ?? 0 }
let useVD = mode != "passive" || env["PERF_VD"] != nil
if useVD { opts.newDisplay = env["PERF_VD"] ?? "1080x2340/420" }

func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func ms(_ ns: UInt64) -> Double { Double(ns) / 1e6 }

// MARK: Recording

final class Recorder: @unchecked Sendable {
    let lock = NSLock()
    var traces: [PacketTrace] = []
    var recording = false
    // Change detection for latency probes.
    var reference: [UInt8]?
    var armedAt: UInt64 = 0
    var detectedAt: UInt64 = 0
    var detectedTrace: PacketTrace?
    var lastTrace: PacketTrace?
    let detected = DispatchSemaphore(value: 0)
    var latest: [UInt8]?

    func frame(_ pb: CVPixelBuffer) {
        guard let sig = FrameStore.signature(of: pb) else { return }
        lock.lock()
        latest = sig
        if armedAt != 0, let ref = reference, Recorder.changedFraction(ref, sig) >= 0.25 {
            detectedAt = now()
            detectedTrace = lastTrace
            armedAt = 0
            lock.unlock()
            detected.signal()
            return
        }
        lock.unlock()
    }

    func trace(_ t: PacketTrace) {
        lock.lock()
        lastTrace = t
        if recording { traces.append(t) }
        lock.unlock()
    }

    static func changedFraction(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var n = 0
        for i in 0..<a.count where abs(Int(a[i]) - Int(b[i])) > 12 { n += 1 }
        return Double(n) / Double(a.count)
    }
}

var results_transport = ""
let rec = Recorder()
let session = ScrcpySession(adb: adb, serial: serial, options: opts)
var displayId: Int?
session.onServerLog = { line in
    // "[server] INFO: New display: 1080x2340/420 (id=12)"
    if let r = line.range(of: "id=") {
        let digits = line[r.upperBound...].prefix { $0.isNumber }
        if let id = Int(digits), line.lowercased().contains("display") { displayId = id }
    }
}
session.onPacketTrace = { rec.trace($0) }
// The decoder callback runs synchronously inside decode(), i.e. before onPacketTrace for the same packet.
session.onFrame = { rec.frame($0.buffer) }
session.onClosed = { r in print("closed:", r ?? "") }

let t0 = now()
do { try session.start() } catch { print("start failed: \(error)"); exit(2) }
print("transport: \(session.activeTransport.rawValue)")
results_transport = session.activeTransport.rawValue
print(String(format: "connected in %.0f ms (%@ %@, size %d, %d Mbps, %d fps, opts '%@'%@)", ms(now() - t0), serial, opts.videoCodec,
             opts.maxSize, opts.videoBitRate / 1_000_000, opts.maxFps, opts.videoCodecOptions, useVD ? ", virtual display" : ""))

if useVD {
    // Open Settings on the new display right away: an empty virtual display may never produce a frame.
    var tries = 0
    while displayId == nil && tries < 60 { usleep(50_000); tries += 1 }
    guard let id = displayId else { print("virtual display id not found in server log"); session.stop(); exit(4) }
    // A new task instance on the virtual display (never moves the user's own Settings task).
    _ = try? adb.shell(serial: serial, "am start --display \(id) -f 0x18000000 -a android.settings.SETTINGS", timeout: 10)
    print("virtual display \(id): Settings launched")
}

// Wait for the first frame.
var waited = 0
while rec.latest == nil && waited < 100 { usleep(50_000); waited += 1 }
guard rec.latest != nil else { print("no frames"); session.stop(); exit(3) }
let (fw, fh) = session.frameSize
let W = Double(fw), H = Double(fh)
print("video \(fw)x\(fh)")

if useVD { sleep(2) }

func touch(_ a: MotionAction, _ x: Double, _ y: Double) {
    session.send(ControlMessage.touch(a, pointer: PointerID.genericFinger, at: DevicePoint(x, y), screen: session.frameSize))
}

// MARK: Stats helpers

func pct(_ v: [Double], _ p: Double) -> Double {
    guard !v.isEmpty else { return .nan }
    let s = v.sorted()
    return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
}
func fmt(_ v: [Double]) -> String {
    String(format: "p50 %.1f  p90 %.1f  p99 %.1f  max %.1f  (n=%d)", pct(v, 0.5), pct(v, 0.9), pct(v, 0.99), v.max() ?? .nan, v.count)
}

var results: [String: Any] = ["label": env["PERF_LABEL"] ?? "", "codec": opts.videoCodec, "size": opts.maxSize,
                              "bitrate": opts.videoBitRate, "fps": opts.maxFps, "codec_opts": opts.videoCodecOptions,
                              "video": "\(fw)x\(fh)", "serial": serial, "transport": results_transport]

// Physical display refresh at run time (the compositor's vsync also drives virtual displays).
let refreshOut = (try? adb.shell(serial: serial, "dumpsys display | grep -m1 mActiveRenderFrameRate", timeout: 5)) ?? ""
let refresh = Double(refreshOut.split(separator: "=").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
let screenOn = ((try? adb.shell(serial: serial, "dumpsys power | grep -m1 mWakefulness=", timeout: 5)) ?? "").contains("Awake")
print(String(format: "phone refresh %.0f Hz, screen %@", refresh, screenOn ? "on" : "off"))
results["refresh"] = refresh.rounded()
results["screen_on"] = screenOn

// MARK: Latency probe

if mode == "latency" || mode == "all" {
    var lat: [Double] = []
    var netPart: [Double] = []
    var dir = 1.0
    let x = W / 2, y0 = H * 0.55, jump = H * 0.11
    for i in 0..<iterations {
        touch(.down, x, y0)
        usleep(450_000)                       // pressed-state ripple settles
        rec.lock.lock(); rec.reference = rec.latest; rec.detectedAt = 0; rec.armedAt = now(); let armed = rec.armedAt; rec.lock.unlock()
        touch(.move, x, y0 - dir * jump)       // beyond touch slop: the list scrolls by ~jump
        let ok = rec.detected.wait(timeout: .now() + 1.5) == .success
        rec.lock.lock(); let det = rec.detectedAt; rec.armedAt = 0; rec.lock.unlock()
        if ok && det > armed { lat.append(ms(det - armed)) } else { print("  probe \(i): no change detected") }
        usleep(250_000)
        touch(.up, x, y0 - dir * jump)         // no motion for 250 ms: no fling
        usleep(500_000)
        dir = -dir
        _ = netPart
    }
    print("touch→photon ms   " + fmt(lat))
    results["latency_p50"] = pct(lat, 0.5); results["latency_p90"] = pct(lat, 0.9); results["latency_max"] = lat.max() ?? -1
}

// MARK: Smoothness

if mode == "smooth" || mode == "all" {
    var intervals: [Double] = []
    var devIntervals: [Double] = []
    var oneWay: [Double] = []
    var decode: [Double] = []
    var sizes: [Double] = []
    var strokesFrames = 0
    var dir = 1.0
    let strokes = max(4, iterations / 2)
    for _ in 0..<strokes {
        // A steady drag: 3 px every 4 ms (~750 px/s), 1.1 s, then hold still and lift (no fling).
        let x = W / 2
        var y = dir > 0 ? H * 0.8 : H * 0.25
        touch(.down, x, y)
        usleep(120_000)
        rec.lock.lock(); rec.traces.removeAll(); rec.recording = true; rec.lock.unlock()
        let start = now()
        var next = start
        while now() - start < 1_100_000_000 {
            y -= dir * 3 * (H / 2340)
            touch(.move, x, y)
            next += 4_000_000
            let n = now(); if next > n { preciseSleep(microseconds: Int((next - n) / 1000)) }
        }
        rec.lock.lock(); rec.recording = false; let tr = rec.traces; rec.lock.unlock()
        usleep(200_000)
        touch(.up, x, y)
        usleep(500_000)
        dir = -dir
        // Skip the first 150 ms (scroll start / touch slop).
        let steady = tr.filter { $0.tPayload > start + 150_000_000 }
        strokesFrames += steady.count
        for i in 1..<max(1, steady.count) {
            intervals.append(ms(steady[i].tDecoded - steady[i - 1].tDecoded))
            devIntervals.append(Double(steady[i].pts - steady[i - 1].pts) / 1000)
        }
        // One-way delay variation: arrival - capture, relative to the best frame of the stroke.
        let ow = steady.map { ms($0.tPayload) - Double($0.pts) / 1000 }
        if let m = ow.min() { oneWay += ow.map { $0 - m } }
        decode += steady.map { ms($0.tDecoded - $0.tPayload) }
        sizes += steady.map { Double($0.size) / 1024 }
    }
    let span = Double(strokes) * 0.95
    let fps = Double(strokesFrames) / span
    let stutters = intervals.filter { $0 > 25 }.count
    print(String(format: "fps during drag   %.1f   stutters (>25 ms) %d of %d intervals", fps, stutters, intervals.count))
    print("mac interval ms   " + fmt(intervals))
    print("device pts ms     " + fmt(devIntervals))
    var hist: [Int: Int] = [:]
    for v in devIntervals { hist[Int((v / 8.333).rounded()), default: 0] += 1 }
    print("device intervals  " + hist.keys.sorted().map { String(format: "%.0fms:%d", Double($0) * 8.333, hist[$0]!) }.joined(separator: "  "))
    print("queueing ms       " + fmt(oneWay) + "   (arrival - capture, minus best)")
    print("decode ms         " + fmt(decode))
    print("frame KB          " + fmt(sizes))
    results["fps"] = fps; results["stutters"] = stutters; results["intervals"] = intervals.count
    results["interval_p50"] = pct(intervals, 0.5); results["interval_p99"] = pct(intervals, 0.99)
    results["dev_interval_p99"] = pct(devIntervals, 0.99)
    results["jitter_p50"] = pct(oneWay, 0.5); results["jitter_p90"] = pct(oneWay, 0.9); results["jitter_p99"] = pct(oneWay, 0.99)
    results["decode_p50"] = pct(decode, 0.5); results["decode_p99"] = pct(decode, 0.99)
    results["kb_p50"] = pct(sizes, 0.5)
}

if mode == "fling" {
    // Fling: a quick swipe, then measure the phone-driven animation (no input in flight).
    var devIntervals: [Double] = []
    var macIntervals: [Double] = []
    var dir = 1.0
    for _ in 0..<max(4, iterations / 2) {
        let x = W / 2
        var y = dir > 0 ? H * 0.75 : H * 0.3
        touch(.down, x, y)
        for _ in 0..<8 { preciseSleep(microseconds: 8_000); y -= dir * 40 * (H / 2340); touch(.move, x, y) }
        touch(.up, x, y)
        let t = now()
        rec.lock.lock(); rec.traces.removeAll(); rec.recording = true; rec.lock.unlock()
        usleep(700_000)
        rec.lock.lock(); rec.recording = false; let tr = rec.traces.filter { $0.tPayload > t + 50_000_000 }; rec.lock.unlock()
        for i in 1..<max(1, tr.count) {
            devIntervals.append(Double(tr[i].pts - tr[i - 1].pts) / 1000)
            macIntervals.append(ms(tr[i].tDecoded - tr[i - 1].tDecoded))
        }
        usleep(900_000)
        dir = -dir
    }
    var hist: [Int: Int] = [:]
    for v in devIntervals { hist[Int((v / 8.333).rounded()), default: 0] += 1 }
    print("fling device intervals  " + hist.keys.sorted().map { String(format: "%.0fms:%d", Double($0) * 8.333, hist[$0]!) }.joined(separator: "  "))
    print("fling mac interval ms   " + fmt(macIntervals))
}

if mode == "passive" {
    rec.lock.lock(); rec.recording = true; rec.lock.unlock()
    sleep(UInt32(iterations))
    rec.lock.lock(); rec.recording = false; let tr = rec.traces; rec.lock.unlock()
    let iv = zip(tr.dropFirst(), tr).map { ms($0.tDecoded - $1.tDecoded) }
    print(String(format: "frames %d in %d s", tr.count, iterations))
    print("mac interval ms   " + fmt(iv))
}

session.stop()
usleep(300_000)
let out = env["PERF_OUT"] ?? "perf-results.jsonl"
if let d = try? JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]),
   let h = FileHandle(forWritingAtPath: out) ?? { FileManager.default.createFile(atPath: out, contents: nil); return FileHandle(forWritingAtPath: out) }() {
    h.seekToEndOfFile(); h.write(d); h.write(Data("\n".utf8)); h.closeFile()
}
print("DONE")
