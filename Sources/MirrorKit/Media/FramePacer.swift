import CoreVideo
import Foundation

/// A decoded video frame and its timing, as it leaves the decoder.
public struct DecodedFrame: @unchecked Sendable {
    public let buffer: CVPixelBuffer
    /// Capture time on the phone, µs (stream clock; only differences within one `stream` mean anything).
    public let pts: Int64
    /// Decode-complete time, host ns (mach uptime: the same clock as `DispatchTime` and `CACurrentMediaTime`).
    public let arrival: UInt64
    /// Identifies the stream (and so the pts clock) the frame belongs to; changes on every reconnect.
    public let stream: UInt32

    public init(buffer: CVPixelBuffer, pts: Int64, arrival: UInt64, stream: UInt32) {
        self.buffer = buffer; self.pts = pts; self.arrival = arrival; self.stream = stream
    }
}

/// How the display trades latency for even motion.
public enum Pacing: String, CaseIterable, Sendable {
    /// Absorb ~98% of the jitter measured on the link.
    case smooth
    /// Absorb ~95%: a few ms less latency, slightly more judder.
    case balanced
    /// Show the newest frame at every refresh, no buffering.
    case immediate

    /// Fraction of recent frames the jitter buffer absorbs (nil: no buffer).
    public var coverage: Double? {
        switch self {
        case .smooth: return 0.98
        case .balanced: return 0.95
        case .immediate: return nil
        }
    }
}

/// Decides which decoded frame to show at each display refresh.
///
/// Frames carry the phone's capture timestamp. Network and decode jitter make them *arrive*
/// unevenly; showing each one at the first refresh after arrival turns that jitter into judder.
/// The pacer schedules frames at `target = pts + base`, so they keep their original spacing:
///
/// - `base` tracks `min transit + p(coverage)(recent lateness) + 1 ms`: the smallest buffer that
///   absorbs almost all of the jitter actually observed on this link (min over a 3 s window
///   follows clock drift). It moves toward that value by at most 1 ms per frame when growing and
///   0.25 ms when shrinking, so changes never show as a step.
/// - The first frame after the screen has been still is shown at the next refresh: the response
///   to a touch gets no added latency; the buffer then ramps in over the next frames.
/// - A frame that still arrives after its target is shown at once (one late frame, no timeline shift).
/// - At each refresh the newest frame whose target falls before the middle of that refresh
///   interval is shown; older ones are dropped.
///
/// Thread-safe: `push` runs on the decoder thread, `next` on the display thread, `pacing` may be
/// set from anywhere.
public final class FramePacer: @unchecked Sendable {
    /// A frame with the host time it is scheduled for.
    public struct Scheduled {
        public let frame: DecodedFrame
        public let target: UInt64    // host ns
    }

    public struct Diagnostics: Sendable {
        public let pacing: Pacing
        /// Current buffer on top of the fastest recent transit, ms.
        public let bufferMs: Double
        public let pending: Int
    }

    /// Gap in capture time that starts a new run (screen was still).
    private let runGapUs: Int64 = 60_000
    /// Upper bound on the jitter buffer.
    private let maxBufferNs: Int64 = 35_000_000
    private let historyNs: Int64 = 3_000_000_000
    private let maxQueue = 8

    private let lock = NSLock()
    private var _pacing: Pacing
    private var queue: [Scheduled] = []
    private var base: Int64 = 0                    // target(ns) = pts*1000 + base
    private var lastPts: Int64?
    private var stream: UInt32?
    private var history: [(at: Int64, transit: Int64)] = []
    private var desiredBuffer: Int64 = 0
    private var pushes = 0
    private var bufferNs: Int64 = 0

    public init(pacing: Pacing = .smooth) { _pacing = pacing }

    public var pacing: Pacing {
        get { lock.lock(); defer { lock.unlock() }; return _pacing }
        set { lock.lock(); _pacing = newValue; lock.unlock() }
    }

    public var diagnostics: Diagnostics {
        lock.lock(); defer { lock.unlock() }
        return Diagnostics(pacing: _pacing, bufferMs: Double(bufferNs / 100_000) / 10, pending: queue.count)
    }

    public func reset() {
        lock.lock(); resetLocked(); lock.unlock()
    }

    private func resetLocked() {
        queue.removeAll(); lastPts = nil; stream = nil; history.removeAll(); bufferNs = 0
    }

    /// Decoder thread.
    public func push(_ f: DecodedFrame) {
        lock.lock(); defer { lock.unlock() }
        if f.stream != stream { resetLocked(); stream = f.stream }
        if let lp = lastPts, f.pts <= lp { return }   // stale (or duplicate) frame
        let ptsNs = f.pts &* 1000
        let arr = Int64(bitPattern: f.arrival)
        let transit = arr - ptsNs
        history.append((arr, transit))
        while let h = history.first, arr - h.at > historyNs { history.removeFirst() }
        let minTransit = history.reduce(Int64.max) { min($0, $1.transit) }
        pushes += 1
        if pushes % 8 == 0 || history.count < 16 {
            let excess = history.map { $0.transit - minTransit }.sorted()
            let c = _pacing.coverage ?? 0.95
            desiredBuffer = min(maxBufferNs, excess[min(excess.count - 1, Int(Double(excess.count) * c))] + 1_000_000)
        }

        let target: Int64
        if let lp = lastPts, f.pts - lp < runGapUs {
            let desired = minTransit + desiredBuffer
            if base < desired { base += min(desired - base, 1_000_000) }
            else if base > desired + 1_000_000 { base -= min(base - desired, 250_000) }
            target = max(arr, ptsNs + base)
        } else {
            // New run: show at the next refresh.
            base = transit
            target = arr
        }
        bufferNs = base - minTransit
        lastPts = f.pts
        queue.append(Scheduled(frame: f, target: UInt64(max(0, target))))
        if queue.count > maxQueue { queue.removeFirst(queue.count - maxQueue) }
    }

    /// The frame to render at this refresh, or nil to keep the current image.
    ///
    /// `now` is the display-link callback time and `interval` the refresh interval (host ns).
    /// Rendering happens a fixed time before presentation, so comparing targets with the callback
    /// time keeps the schedule consistent while leaving all of the buffer for network jitter.
    public func next(at now: UInt64, interval: UInt64) -> Scheduled? {
        lock.lock(); defer { lock.unlock() }
        guard !queue.isEmpty else { return nil }
        if _pacing == .immediate {
            let f = queue.removeLast(); queue.removeAll(); return f
        }
        let deadline = now &+ interval / 2
        guard let i = queue.lastIndex(where: { $0.target <= deadline }) else { return nil }
        let f = queue[i]
        queue.removeFirst(i + 1)
        return f
    }
}

/// What was actually put on screen over a window of refreshes.
public struct PresentReport: Sendable {
    public struct Percentiles: Sendable {
        public let p50, p90, p99: Double    // ms, -1 when there are no samples
    }
    public let refreshes: Int
    public let newFrames: Int
    /// Present time - decode time (Mac-side buffering + refresh wait).
    public let displayLatency: Percentiles
    /// Per-frame deviation of (present - capture) from its 9-frame median: what reads as judder.
    public let judder: Percentiles
    public let judderSamples: Int

    public var dictionary: [String: Any] {
        func d(_ p: Percentiles) -> [String: Any] { ["p50": p.p50, "p90": p.p90, "p99": p.p99] }
        var j = d(judder); j["n"] = judderSamples
        return ["refreshes": refreshes, "new_frames": newFrames, "display_latency_ms": d(displayLatency), "judder_ms": j]
    }
}

/// Rolling statistics about what was actually put on screen.
///
/// Perfect pacing leaves only refresh quantization (< 1 refresh) in the judder figure; arrival
/// jitter that leaks through shows up as a longer tail.
public final class PresentStats: @unchecked Sendable {
    private let lock = NSLock()
    private var latency: [Double] = []
    private var lagVar: [Double] = []
    private var newFrames = 0
    private var refreshes = 0
    private var runLags: [Int64] = []
    private var last: (stream: UInt32, pts: Int64)?
    public init() {}

    /// One refresh: `present` is its presentation time (host ns), `shown` the new frame, if any.
    public func record(present: UInt64, shown: FramePacer.Scheduled?) {
        lock.lock(); defer { lock.unlock() }
        refreshes += 1
        guard let f = shown?.frame else { return }
        newFrames += 1
        latency.append(Double(Int64(bitPattern: present) - Int64(bitPattern: f.arrival)) / 1e6)
        let lag = Int64(bitPattern: present) - f.pts * 1000
        if let l = last, l.stream == f.stream, f.pts > l.pts, f.pts - l.pts < 60_000 {
            runLags.append(lag)
            if runLags.count > 9 { runLags.removeFirst() }
            if runLags.count == 9 {
                let med = runLags.sorted()[4]
                lagVar.append(Double(abs(runLags[4] - med)) / 1e6)
            }
        } else {
            runLags = [lag]
        }
        last = (f.stream, f.pts)
        if latency.count > 4000 { latency.removeFirst(2000) }
        if lagVar.count > 4000 { lagVar.removeFirst(2000) }
    }

    public func report(reset: Bool) -> PresentReport {
        lock.lock(); defer { lock.unlock() }
        func pct(_ v: [Double]) -> PresentReport.Percentiles {
            guard !v.isEmpty else { return .init(p50: -1, p90: -1, p99: -1) }
            let s = v.sorted()
            func at(_ p: Double) -> Double { (s[min(s.count - 1, Int(Double(s.count - 1) * p))] * 10).rounded() / 10 }
            return .init(p50: at(0.5), p90: at(0.9), p99: at(0.99))
        }
        let r = PresentReport(refreshes: refreshes, newFrames: newFrames, displayLatency: pct(latency),
                              judder: pct(lagVar), judderSamples: lagVar.count)
        if reset { latency.removeAll(); lagVar.removeAll(); newFrames = 0; refreshes = 0; runLags.removeAll(); last = nil }
        return r
    }
}
