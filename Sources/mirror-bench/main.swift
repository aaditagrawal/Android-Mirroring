import Foundation
import MirrorKit

// Developer benchmark: connects a scrcpy session (no input is injected), measures
// connect time, fps and bitrate, ADB round-trip latency, and writes a frame to disk.
//
//   swift run mirror-bench <serial> [seconds] [h265|h264] [out.png]

Log.echoToStderr = true
let args = CommandLine.arguments
let adb = ADBClient.shared
let devices = (try? adb.devices()) ?? []
guard let serial = args.count > 1 ? args[1] : devices.first(where: \.isOnline)?.serial else {
    print("no device"); exit(1)
}
let seconds = args.count > 2 ? Double(args[2]) ?? 5 : 5
var opts = StreamOptions()
if args.count > 3 { opts.videoCodec = args[3] }
opts.audio = ProcessInfo.processInfo.environment["BENCH_AUDIO"] != nil
let out = args.count > 4 ? args[4] : "bench-frame.png"

print("server \(adb.host):\(adb.port), serial \(serial)")
var pings: [Double] = []
for _ in 0..<5 { if let p = adb.ping(serial: serial) { pings.append(p * 1000) } }
print("adb shell RTT ms:", pings.map { String(format: "%.1f", $0) }.joined(separator: " "))

let store = FrameStore()
let session = ScrcpySession(adb: adb, serial: serial, options: opts)
var firstFrameAt: Date?
let t0 = Date()
session.onFrame = { pb in
    if firstFrameAt == nil { firstFrameAt = Date() }
    store.update(pb)
}
session.onStats = { s in
    print(String(format: "fps %.1f  %.2f Mbps  %@ %dx%d  frames %llu  errors %llu", s.fps, s.bitrateMbps, s.codec, s.width, s.height, s.decodedFrames, s.droppedOrErrors))
}
session.onClosed = { r in print("closed:", r ?? "") }
do {
    try session.start()
} catch {
    print("start failed: \(error)"); exit(2)
}
print(String(format: "connected in %.0f ms, device '%@'", Date().timeIntervalSince(t0) * 1000, session.deviceName))
_ = store.waitForFrame(after: 0, timeout: 10)
if let f = firstFrameAt { print(String(format: "first frame after %.0f ms", f.timeIntervalSince(t0) * 1000)) }
Thread.sleep(forTimeInterval: seconds)
let shotStart = Date()
if let enc = store.encoded(format: .png, maxDimension: 1200) {
    try? enc.data.write(to: URL(fileURLWithPath: out))
    print(String(format: "screenshot %dx%d %d KB in %.1f ms -> %@", enc.width, enc.height, enc.data.count / 1024, Date().timeIntervalSince(shotStart) * 1000, out))
}
session.stop()
Thread.sleep(forTimeInterval: 0.3)
