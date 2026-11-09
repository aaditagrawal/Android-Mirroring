import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import ImageIO
import MirrorKit

// Like the app: don't inherit a background priority from the launching shell (timer precision).
setpriority(PRIO_DARWIN_PROCESS, 0, 0)
setvbuf(stdout, nil, _IOLBF, 0)

var failures = 0
func expect(_ ok: Bool, _ line: Int = #line) { if !ok { failures += 1; print("FAIL line \(line)") } }

enum Tests {
    static func touchLayout() {
        let b = ControlMessage.touch(.down, pointer: PointerID.genericFinger, at: DevicePoint(x: 100, y: 200), screen: (1080, 2340))
        expect(b.count == 32)
        expect(b[0] == 2)
        expect(b[1] == 0)
        expect(Array(b[2..<10]) == [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE])
        expect(Array(b[10..<14]) == [0, 0, 0, 100])
        expect(Array(b[18..<20]) == [0x04, 0x38])
        expect(Array(b[22..<24]) == [0xFF, 0xFF])
    }

    static func scrollLayout() {
        let b = ControlMessage.scroll(at: DevicePoint(x: 1, y: 2), screen: (10, 20), h: 16, v: -16)
        expect(b.count == 21)
        expect(Array(b[13..<15]) == [0x7F, 0xFF])
        expect(Array(b[15..<17]) == [0x80, 0x00])
    }

    static func keycodeLayout() {
        expect(ControlMessage.keycode(.up, AKey.home) == [0, 1, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    static func utf8Truncation() {
        let b = ControlMessage.text(String(repeating: "é", count: 200)) // 400 bytes
        let len = Int(b[1]) << 24 | Int(b[2]) << 16 | Int(b[3]) << 8 | Int(b[4])
        expect(len == 300)
        expect(String(bytes: b[5...], encoding: .utf8) != nil)
    }

    static func nalSplit() {
        let data: [UInt8] = [0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 9, 9]
        let r = data.withUnsafeBufferPointer { VideoDecoder.splitNALs($0.baseAddress!, $0.count) }
        expect(r == [4..<7, 10..<12, 16..<19])
    }

    static func transportKind() {
        expect(TransportKind.infer(serial: "100.64.0.10:5555", usb: nil) == .tailscale)
        expect(TransportKind.infer(serial: "192.168.1.4:5555", usb: nil) == .lan)
        expect(TransportKind.infer(serial: "adb-R5CX-abc._adb-tls-connect._tcp", usb: nil) == .wirelessDebugging)
        expect(TransportKind.infer(serial: "R5CX123", usb: "1-1") == .usb)
    }

    static func devicesParsing() {
        let text = "100.64.0.10:5555      device product:example model:ExamplePhone device:example transport_id:14\nemulator-5554 offline\n"
        let d = ADBClient.parseDevices(text)
        expect(d.count == 2)
        expect(d[0].model == "ExamplePhone")
        expect(d[0].isOnline)
        expect(!d[1].isOnline)
    }
}

// MARK: - Agent observation tests

/// NV12 frame with uniform luma, plus optional bright rectangles (x, y, w, h).
func nv12(_ w: Int, _ h: Int, luma: UInt8, rects: [(Int, Int, Int, Int)] = []) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb)
    let b = pb!
    CVPixelBufferLockBaseAddress(b, [])
    let y = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
    for row in 0..<h { memset(y + row * stride, Int32(luma), w) }
    for (rx, ry, rw, rh) in rects { for row in ry..<(ry + rh) { memset(y + row * stride + rx, 235, rw) } }
    let uv = CVPixelBufferGetBaseAddressOfPlane(b, 1)!
    memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(b, 1) * CVPixelBufferGetHeightOfPlane(b, 1))
    CVPixelBufferUnlockBaseAddress(b, [])
    return b
}

extension Tests {
    static func settleSignature() {
        let base = FrameStore.signature(of: nv12(738, 1600, luma: 20))!
        // A blinking caret (3x40 px) is not activity.
        let caret = FrameStore.signature(of: nv12(738, 1600, luma: 20, rects: [(300, 800, 3, 40)]))!
        expect(!FrameStore.significantlyDifferent(base, caret))
        // Status bar clock change is ignored entirely.
        let clock = FrameStore.signature(of: nv12(738, 1600, luma: 20, rects: [(20, 10, 120, 40)]))!
        expect(FrameStore.maxDelta(base, clock) == 0)
        // A button highlight / new content is.
        let button = FrameStore.signature(of: nv12(738, 1600, luma: 20, rects: [(100, 700, 300, 90)]))!
        expect(FrameStore.significantlyDifferent(base, button))
        // A one-step change in a fade (8 levels everywhere) is moderate-but-wide, so it counts... only once it accumulates.
        let fade1 = FrameStore.signature(of: nv12(738, 1600, luma: 28))!
        let fade3 = FrameStore.signature(of: nv12(738, 1600, luma: 44))!
        expect(!FrameStore.significantlyDifferent(base, fade1) && FrameStore.significantlyDifferent(base, fade3))
        // Speed: well under a millisecond or two per frame.
        let pb = nv12(1080, 2340, luma: 50)
        let t0 = Date()
        for _ in 0..<50 { _ = FrameStore.signature(of: pb) }
        let ms = Date().timeIntervalSince(t0) * 1000 / 50
        print(String(format: "  signature of 1080x2340: %.2f ms", ms))
        expect(ms < 5)
    }

    static func settleTiming() {
        let store = FrameStore()
        store.update(nv12(738, 1600, luma: 20))
        // No frames after an action: return unchanged after the reaction window.
        var st = store.waitForSettle(after: store.frameCounter, reactTimeout: 0.15)
        expect(st.settled && !st.changed)
        print("  unchanged screen: \(st.ms) ms")
        // An already quiet screen returns settled; a new frame waits for quiet.
        st = store.waitForSettle(quiet: 0.15)
        expect(st.settled)
        store.update(nv12(738, 1600, luma: 20))
        st = store.waitForSettle(quiet: 0.15)
        expect(st.settled && st.ms >= 100)
        print("  new frame quiet window: \(st.ms) ms")

        // Exercise an actual concurrent frame arrival without depending on sub-refresh
        // OS scheduling or reading an unsynchronized variable from the producer thread.
        let before = store.frameCounter
        let finished = DispatchSemaphore(value: 0)
        let producer = Thread {
            store.update(nv12(738, 1600, luma: 180))
            finished.signal()
        }
        producer.qualityOfService = .userInteractive
        producer.start()
        st = store.waitForSettle(after: before, reactTimeout: 3, quiet: 0.15, timeout: 5)
        expect(finished.wait(timeout: .now() + 5) == .success)
        expect(st.settled && st.changed)
        print("  concurrent change settled: \(st.ms) ms")
        // Caret/status-bar filtering and cumulative fades are covered deterministically
        // by settleSignature. Real animation cadence belongs in mirror-bench.
    }

    static func ocr() {
        // Render a phone-like screen with some labels and find them.
        let w = 738, h = 1600
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.05, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        func draw(_ s: String, _ x: CGFloat, _ yTop: CGFloat, _ size: CGFloat) {
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let attr = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                                  NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.95, alpha: 1)])
            ctx.textPosition = CGPoint(x: x, y: CGFloat(h) - yTop - size)
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        }
        draw("Inbox", 40, 200, 56)
        draw("Personal", 40, 330, 30)
        draw("Transactions 67", 260, 330, 30)
        draw("Send money to Aditi", 40, 900, 34)
        let img = ctx.makeImage()!
        var t0 = Date()
        let cold = try! TextRecognizer.recognize(img)
        let coldMs = Int(Date().timeIntervalSince(t0) * 1000)
        t0 = Date()
        let lines = try! TextRecognizer.recognize(img)
        let warmMs = Int(Date().timeIntervalSince(t0) * 1000)
        print("  OCR 738x1600: cold \(coldMs) ms, warm \(warmMs) ms, \(lines.count) lines: \(lines.map(\.text))")
        expect(cold.count == lines.count)
        let t = TextRecognizer.find("transactions", in: lines)
        expect(t.first?.score == 1)
        // The substring box is the word, not the whole line; its center is near the word.
        if let m = t.first { expect(m.box.width < m.line.box.width && abs(m.box.midY - 345) < 25 && m.box.minX < 300) }
        // Exact match wins over a longer line containing the query.
        let p = TextRecognizer.find("personal", in: lines)
        expect(p.first?.score == 0 && abs((p.first?.box.midX ?? 0) - 100) < 60)
        // Mid-line word gets its own box.
        let a = TextRecognizer.find("aditi", in: lines)
        expect(a.first?.score == 2 && (a.first?.box.minX ?? 0) > 250 && abs((a.first?.box.midY ?? 0) - 917) < 25)
        expect(TextRecognizer.find("nonexistent", in: lines).isEmpty)
    }
}

extension Tests {
    /// 120 Hz capture, arrival jitter like Wi-Fi (0-12 ms, 5% spikes to 30 ms), 100 Hz display.
    static func simulatePacing(_ pacing: Pacing, seed: UInt64) -> PresentReport {
        var rng = seed
        func rand() -> Double { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Double(rng >> 11) / Double(1 << 53) }
        let pb = nv12(64, 64, luma: 0)
        let pacer = FramePacer(pacing: pacing)
        let stats = PresentStats()
        let base: UInt64 = 10_000_000_000
        var events: [(UInt64, Int, Int64)] = []   // (time, kind 0=arrival 1=vsync, pts)
        var lastArrival: UInt64 = 0
        for i in 0..<600 {   // 5 s of continuous motion
            let pts = Int64(i) * 8333
            var j = rand() * 12
            if rand() < 0.05 { j += 18 }
            // TCP delivers in order: a delayed frame holds back the ones behind it.
            lastArrival = max(lastArrival, base + UInt64(pts) * 1000 + 20_000_000 + UInt64(j * 1e6))
            events.append((lastArrival, 0, pts))
        }
        var t = base
        while t < base + 5_200_000_000 { events.append((t, 1, 0)); t += 10_000_000 }
        events.sort { $0.0 < $1.0 }
        for e in events {
            if e.1 == 0 { pacer.push(DecodedFrame(buffer: pb, pts: e.2, arrival: e.0, stream: 1)) }
            else { stats.record(present: e.0 + 10_000_000, shown: pacer.next(at: e.0, interval: 10_000_000)) }
        }
        return stats.report(reset: false)
    }

    static func pacing() {
        let imm = simulatePacing(.immediate, seed: 7), smooth = simulatePacing(.smooth, seed: 7)
        func line(_ name: String, _ r: PresentReport) {
            print(String(format: "  %@ judder p90 %.1f p99 %.1f ms, display latency p50 %.1f ms, %d frames shown",
                         name, r.judder.p90, r.judder.p99, r.displayLatency.p50, r.newFrames))
        }
        line("immediate:", imm); line("smooth:   ", smooth)
        // Paced output keeps the phone's timing within about one refresh (10 ms) almost always.
        expect(smooth.newFrames > imm.newFrames)
        expect(smooth.judder.p90 <= 5.5)
        // ...without a large latency cost.
        expect(smooth.displayLatency.p50 - imm.displayLatency.p50 < 15)

        // First frame after stillness shows at the next refresh.
        let p = FramePacer()
        let pb = nv12(64, 64, luma: 0)
        p.push(DecodedFrame(buffer: pb, pts: 1_000_000, arrival: 5_000_000_000, stream: 1))
        expect(p.next(at: 5_001_000_000, interval: 10_000_000)?.frame.pts == 1_000_000)
        // A stale frame of the same stream is dropped...
        p.push(DecodedFrame(buffer: pb, pts: 900_000, arrival: 5_002_000_000, stream: 1))
        expect(p.next(at: 5_003_000_000, interval: 10_000_000) == nil)
        // ...but a reconnect (new stream, pts clock restarted near 0) is shown at once.
        p.push(DecodedFrame(buffer: pb, pts: 8_333, arrival: 5_004_000_000, stream: 2))
        expect(p.next(at: 5_005_000_000, interval: 10_000_000)?.frame.stream == 2)
    }
}

if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--pacing" {
    for mode in Pacing.allCases {
        var shown = 0, j90 = 0.0, j99 = 0.0, lat = 0.0
        for seed in [UInt64(3), 7, 11, 19] {
            let r = Tests.simulatePacing(mode, seed: seed)
            shown += r.newFrames
            j90 += r.judder.p90 / 4; j99 += r.judder.p99 / 4; lat += r.displayLatency.p50 / 4
        }
        print(String(format: "%-9@ frames shown %d/2000, judder p90 %.1f p99 %.1f, display latency p50 %.1f", mode.rawValue, shown, j90, j99, lat))
    }
    exit(0)
}

if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--ocr" {
    guard CommandLine.arguments.count >= 3 else { print("Usage: mirror-selftest --ocr IMAGE [QUERY]"); exit(2) }
    // mirror-selftest --ocr IMAGE [QUERY]: OCR a screenshot and time it.
    let url = URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL
    guard let src = CGImageSourceCreateWithURL(url, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("cannot read image"); exit(2) }
    _ = try? TextRecognizer.recognize(img)
    let t0 = Date()
    let lines = try TextRecognizer.recognize(img)
    print("\(img.width)x\(img.height): \(lines.count) lines in \(Int(Date().timeIntervalSince(t0) * 1000)) ms (warm)")
    if CommandLine.arguments.count > 3 {
        for m in TextRecognizer.find(CommandLine.arguments[3], in: lines) { print("  match [\(m.score)] '\(m.line.text)' at \(Int(m.box.midX)),\(Int(m.box.midY))") }
    } else {
        for l in lines.prefix(12) { print("  \(Int(l.box.midX)),\(Int(l.box.midY))  \(l.text)") }
    }
    exit(0)
}

let all: [(String, () -> Void)] = [("pacing", Tests.pacing), ("settle-signature", Tests.settleSignature), ("settle-timing", Tests.settleTiming), ("ocr", Tests.ocr),
    ("touch", Tests.touchLayout), ("scroll", Tests.scrollLayout), ("keycode", Tests.keycodeLayout),
    ("utf8", Tests.utf8Truncation), ("nal", Tests.nalSplit), ("transport", Tests.transportKind), ("devices", Tests.devicesParsing)]
let arguments = Array(CommandLine.arguments.dropFirst())
var selected = Set(all.map(\.0))
if !arguments.isEmpty {
    guard arguments.count == 2, arguments[0] == "--only" else {
        print("Usage: mirror-selftest [--only name,name | --pacing | --ocr IMAGE [QUERY]]")
        exit(2)
    }
    selected = Set(arguments[1].split(separator: ",").map(String.init))
    guard !selected.isEmpty, selected.isSubset(of: Set(all.map(\.0))) else {
        print("Known tests: " + all.map(\.0).joined(separator: ",")); exit(2)
    }
}
// Framework/model startup must not leave CI or a local check running indefinitely.
let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
watchdog.schedule(deadline: .now() + 90)
watchdog.setEventHandler {
    FileHandle.standardError.write(Data("FAIL: self-test exceeded 90 seconds (check the last running test)\n".utf8))
    exit(1)
}
watchdog.resume()
for (name, f) in all where selected.contains(name) { print("running \(name)"); f(); print("ran \(name)") }
watchdog.cancel()
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
