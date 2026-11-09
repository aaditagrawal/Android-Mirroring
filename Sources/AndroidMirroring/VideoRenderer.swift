import AppKit
import CoreVideo
import Metal
import MirrorKit
import QuartzCore
import simd

/// Puts decoded frames on screen with Metal, paced by the display.
///
/// - `CAMetalDisplayLink` (on its own high-priority thread) asks for a frame once per refresh,
///   one refresh ahead (`preferredFrameLatency = 1`). The `FramePacer` picks the frame that keeps
///   the phone's original timing; on refreshes with nothing new, nothing is drawn or presented.
/// - Zero-copy: the decoder's IOSurface-backed NV12 buffers become Metal textures through a
///   texture cache; one draw converts YCbCr to RGB (BT.709 / BT.601 from the stream's tags) and
///   downsamples with 4 taps per pixel so text stays crisp when the window is smaller than the phone.
final class VideoRenderer: NSObject, CAMetalDisplayLinkDelegate {
    let layer = CAMetalLayer()
    private let pacer = FramePacer()
    private let stats = PresentStats()

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var textureCache: CVMetalTextureCache?
    private var link: CAMetalDisplayLink?
    private var thread: Thread?

    private let stateLock = NSLock()
    private var current: CVPixelBuffer?
    private var redraw = false
    private var blank = false
    private var lastTarget: CFTimeInterval = 0
    private var interval: UInt64 = 16_666_667
    private var leadSamples: [Double] = []      // targetPresentationTimestamp - callback time, ms
    private var deadlineSamples: [Double] = []  // targetTimestamp - callback time, ms

    init?(frameLatency: Int = 1) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        do {
            let lib = try device.makeLibrary(source: VideoRenderer.shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "vtx")
            desc.fragmentFunction = lib.makeFunction(name: "frag")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            Log.error("Metal renderer unavailable: \(error)")
            return nil
        }
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: sd) else { return nil }
        self.sampler = sampler
        super.init()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)

        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.backgroundColor = NSColor.black.cgColor
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.maximumDrawableCount = 3
        layer.presentsWithTransaction = false

        let link = CAMetalDisplayLink(metalLayer: layer)
        link.delegate = self
        let fl = UserDefaults.standard.object(forKey: "debugFrameLatency") as? Double ?? Double(frameLatency)
        link.preferredFrameLatency = Float(fl)
        self.link = link
        setMaxFrameRate(NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 120)
        let t = Thread { [weak self] in
            guard let self, let link = self.link else { return }
            link.add(to: .current, forMode: .default)
            while !Thread.current.isCancelled { RunLoop.current.run(mode: .default, before: .distantFuture) }
        }
        t.name = "video-present"
        t.qualityOfService = .userInteractive
        t.start()
        thread = t
    }

    deinit { link?.invalidate() }

    /// Decoder thread.
    func push(_ frame: DecodedFrame) {
        guard !syntheticActive else { return }
        pacer.push(frame)
    }

    var pacing: Pacing {
        get { pacer.pacing }
        set { pacer.pacing = newValue }
    }

    /// Run at the display's full rate (100/120/144 Hz...); the phone streams up to 120 fps.
    /// Call when the window moves to another screen.
    func setMaxFrameRate(_ hz: Int) {
        let maxHz = Float(max(60, hz))
        guard link?.preferredFrameRateRange.maximum != maxHz else { return }
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: maxHz, preferred: maxHz)
    }

    /// What was presented since the last reset, plus the pacer's and display link's state.
    func report(reset: Bool) -> [String: Any] {
        var r = stats.report(reset: reset).dictionary
        let d = pacer.diagnostics
        r["renderer"] = "metal"
        r["pacing"] = d.pacing.rawValue
        r["buffer_ms"] = d.bufferMs
        stateLock.lock()
        let lead = leadSamples.sorted(), dl = deadlineSamples.sorted(), iv = interval
        if reset { leadSamples.removeAll(); deadlineSamples.removeAll() }
        stateLock.unlock()
        if !lead.isEmpty { r["present_lead_ms_p50"] = (lead[lead.count / 2] * 10).rounded() / 10 }
        if !dl.isEmpty { r["render_deadline_ms_p50"] = (dl[dl.count / 2] * 10).rounded() / 10 }
        r["refresh_hz"] = (1e9 / Double(iv)).rounded()
        return r
    }

    // MARK: Synthetic source (presentation tests without a phone)

    private(set) var syntheticActive = false

    /// Feeds a 120 Hz moving-bar stream with network-like arrival jitter (0-12 ms, 5% spikes of
    /// +18 ms, delivered in order like TCP) for `seconds`, then returns what was presented.
    func runSynthetic(seconds: Double, jitter: Bool) -> [String: Any] {
        syntheticActive = true
        defer { syntheticActive = false }
        pacer.reset()
        _ = report(reset: true)
        let w = 1080, h = 2340
        var pool: CVPixelBufferPool?
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                      kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
                                      kCVPixelBufferMetalCompatibilityKey: true]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        guard let pool else { return ["error": "pool"] }
        var rng: UInt64 = 0x9E3779B97F4A7C15
        func rand() -> Double { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Double(rng >> 11) / Double(1 << 53) }
        let start = DispatchTime.now().uptimeNanoseconds + 50_000_000
        var lastArrival: UInt64 = 0
        let frames = Int(seconds * 120)
        for i in 0..<frames {
            let pts = Int64(i) * 8333
            var j = 0.0
            if jitter { j = rand() * 12; if rand() < 0.05 { j += 18 } }
            lastArrival = max(lastArrival, start + UInt64(pts) * 1000 + UInt64(j * 1e6))
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
            let ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            memset(y, 30, ys * h)
            let bar = (i * 12) % (h - 120)       // moves 12 px per frame (1440 px/s)
            for r in bar..<(bar + 120) { memset(y + r * ys, 220, w) }
            let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!
            memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * h / 2)
            CVPixelBufferUnlockBaseAddress(pb, [])
            let now = DispatchTime.now().uptimeNanoseconds
            if lastArrival > now { preciseSleep(microseconds: Int((lastArrival - now) / 1000)) }
            pacer.push(DecodedFrame(buffer: pb, pts: pts, arrival: DispatchTime.now().uptimeNanoseconds, stream: .max))
        }
        Thread.sleep(forTimeInterval: 0.1)
        var r = report(reset: true)
        r["frames_sent"] = frames
        pacer.reset()   // the next real frame starts a fresh timeline
        return r
    }

    /// Re-render the current frame (after a resize).
    func setNeedsRedraw() { stateLock.lock(); redraw = true; stateLock.unlock() }

    func clear() {
        pacer.reset()
        stateLock.lock(); current = nil; blank = true; stateLock.unlock()
    }

    var paused: Bool {
        get { link?.isPaused ?? true }
        set { link?.isPaused = newValue }
    }

    // MARK: CAMetalDisplayLinkDelegate

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        let now = DispatchTime.now().uptimeNanoseconds
        let target = update.targetPresentationTimestamp
        let nowS = Double(now) / 1e9
        stateLock.lock()
        if lastTarget > 0 {
            let d = target - lastTarget
            if d > 0.004 && d < 0.05 { interval = UInt64(d * 1e9) }
        }
        lastTarget = target
        let iv = interval
        if leadSamples.count < 2000 { leadSamples.append((target - nowS) * 1000); deadlineSamples.append((update.targetTimestamp - nowS) * 1000) }
        stateLock.unlock()
        let shown = pacer.next(at: now, interval: iv)
        // CACurrentMediaTime and DispatchTime both count mach absolute time.
        stats.record(present: UInt64(target * 1e9), shown: shown)

        stateLock.lock()
        if let f = shown { current = f.frame.buffer; blank = false }
        let draw = shown != nil || redraw || blank
        redraw = false
        let pb = current
        let clearOnly = blank
        if clearOnly { blank = false }
        stateLock.unlock()
        guard draw else { return }
        render(pb, to: update.drawable, clearOnly: clearOnly && pb == nil)
    }

    // MARK: Rendering

    private struct Uniforms {
        var matrix: simd_float3x3
        var offset: simd_float3
        var texel: simd_float2      // source texel size * downscale spread (for 4-tap sampling)
    }

    private func render(_ pb: CVPixelBuffer?, to drawable: CAMetalDrawable, clearOnly: Bool) {
        guard let cmd = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

        if !clearOnly, let pb, let cache = textureCache,
           let y = texture(pb, plane: 0, format: .r8Unorm, cache), let uv = texture(pb, plane: 1, format: .rg8Unorm, cache) {
            let vw = Double(CVPixelBufferGetWidth(pb)), vh = Double(CVPixelBufferGetHeight(pb))
            let dw = Double(drawable.texture.width), dh = Double(drawable.texture.height)
            // Aspect fit.
            let s = min(dw / vw, dh / vh)
            let w = vw * s, h = vh * s
            enc.setViewport(MTLViewport(originX: (dw - w) / 2, originY: (dh - h) / 2, width: w, height: h, znear: 0, zfar: 1))
            var u = VideoRenderer.uniforms(for: pb)
            // Spread the 4 taps over the source area one output pixel covers (when downscaling).
            let spread = 1 / s
            u.texel = s < 1 ? simd_float2(Float(spread / vw), Float(spread / vh)) * 0.25 : .zero
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(CVMetalTextureGetTexture(y), index: 0)
            enc.setFragmentTexture(CVMetalTextureGetTexture(uv), index: 1)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            // Keep the CVMetalTextures (and so the IOSurface) alive until the GPU is done.
            cmd.addCompletedHandler { _ in _ = y; _ = uv }
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    private func texture(_ pb: CVPixelBuffer, plane: Int, format: MTLPixelFormat, _ cache: CVMetalTextureCache) -> CVMetalTexture? {
        var tex: CVMetalTexture?
        let w = CVPixelBufferGetWidthOfPlane(pb, plane), h = CVPixelBufferGetHeightOfPlane(pb, plane)
        let st = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, format, w, h, plane, &tex)
        return st == kCVReturnSuccess ? tex : nil
    }

    private static func uniforms(for pb: CVPixelBuffer) -> Uniforms {
        let matrixKey = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) as? String
        let fullRange = CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        // Columns map (Y, Cb, Cr) to R, G, B.
        let bt601 = matrixKey == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
        let m: simd_float3x3 = bt601
            ? simd_float3x3(simd_float3(1, 1, 1), simd_float3(0, -0.344136, 1.772), simd_float3(1.402, -0.714136, 0))
            : simd_float3x3(simd_float3(1, 1, 1), simd_float3(0, -0.187324, 1.8556), simd_float3(1.5748, -0.468124, 0))
        let ys: Float = fullRange ? 1 : 255.0 / 219.0, cs: Float = fullRange ? 1 : 255.0 / 224.0
        let scale = simd_float3x3(simd_float3(ys, 0, 0), simd_float3(0, cs, 0), simd_float3(0, 0, cs))
        let offset = simd_float3(fullRange ? 0 : 16.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0)
        return Uniforms(matrix: m * scale, offset: offset, texel: .zero)
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float4 pos [[position]]; float2 uv; };
    struct U { float3x3 m; float3 off; float2 texel; };
    vertex V vtx(uint vid [[vertex_id]]) {
        float2 p[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        V o; o.pos = float4(p[vid], 0, 1); o.uv = float2((p[vid].x + 1) * 0.5, (1 - p[vid].y) * 0.5); return o;
    }
    static float3 rgb(texture2d<float> y, texture2d<float> c, sampler s, float2 uv, constant U& u) {
        float3 ycc = float3(y.sample(s, uv).r, c.sample(s, uv).rg) - u.off;
        return u.m * ycc;
    }
    fragment float4 frag(V in [[stage_in]], texture2d<float> y [[texture(0)]], texture2d<float> c [[texture(1)]],
                         sampler s [[sampler(0)]], constant U& u [[buffer(0)]]) {
        float2 d = u.texel;
        float3 col = rgb(y, c, s, in.uv + float2(-d.x, -d.y), u) + rgb(y, c, s, in.uv + float2(d.x, -d.y), u)
                   + rgb(y, c, s, in.uv + float2(-d.x, d.y), u) + rgb(y, c, s, in.uv + float2(d.x, d.y), u);
        return float4(saturate(col * 0.25), 1);
    }
    """
}
