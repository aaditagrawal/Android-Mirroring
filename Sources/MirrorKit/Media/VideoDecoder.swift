import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public enum VideoCodecID: UInt32 {
    case h264 = 0x6832_3634
    case h265 = 0x6832_3635
    case av1 = 0x0061_7631

    public var name: String {
        switch self { case .h264: return "H.264"; case .h265: return "HEVC"; case .av1: return "AV1" }
    }
}

/// Hardware decoder for the scrcpy Annex-B elementary stream.
/// Decodes synchronously on the caller's (network reader) thread: this avoids a queue hop
/// and keeps glass-to-glass latency to network + encode + ~2-4 ms decode.
public final class VideoDecoder {
    public let codec: VideoCodecID
    private var formatDesc: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var parameterSets: [Data] = []
    public var onFrame: ((CVPixelBuffer, Int64) -> Void)?
    public var onError: ((OSStatus) -> Void)?
    public private(set) var decodedFrames: UInt64 = 0
    private var lastErrorStatus: OSStatus = 0

    public init(codec: VideoCodecID) { self.codec = codec }

    deinit { invalidate() }

    public func invalidate() {
        if let s = session {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
        }
        session = nil
    }

    // MARK: Annex-B helpers

    /// Split an Annex-B buffer into NAL units (without start codes).
    public static func splitNALs(_ p: UnsafePointer<UInt8>, _ count: Int) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var i = 0
        var start = -1
        while i + 2 < count {
            if p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    if end > start && p[end - 1] == 0 { end -= 1 } // 4-byte start code
                    ranges.append(start..<end)
                }
                i += 3
                start = i
                continue
            }
            i += 1
        }
        if start >= 0 && start < count { ranges.append(start..<count) }
        if start < 0 && count > 0 { ranges.append(0..<count) } // no start code: treat as single NAL
        return ranges
    }

    private func nalType(_ first: UInt8) -> UInt8 {
        codec == .h265 ? (first >> 1) & 0x3F : first & 0x1F
    }

    private func isParameterSet(_ t: UInt8) -> Bool {
        codec == .h265 ? (t == 32 || t == 33 || t == 34) : (t == 7 || t == 8)
    }

    // MARK: Config

    /// Handle a codec config packet (SPS/PPS, or VPS/SPS/PPS).
    public func configure(annexB: Data) {
        var sets: [Data] = []
        annexB.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self).baseAddress!
            for r in VideoDecoder.splitNALs(p, raw.count) where !r.isEmpty {
                if isParameterSet(nalType(p[r.lowerBound])) {
                    sets.append(Data(bytes: p + r.lowerBound, count: r.count))
                }
            }
        }
        applyParameterSets(sets)
    }

    private func applyParameterSets(_ sets: [Data]) {
        guard !sets.isEmpty, sets != parameterSets else { return }
        var desc: CMVideoFormatDescription?
        let status: OSStatus = withPointers(sets) { ptrs, sizes in
            if codec == .h265 {
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: ptrs,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &desc)
            } else {
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: ptrs,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
            }
        }
        guard status == noErr, let desc else {
            Log.error("format description failed: \(status)")
            return
        }
        parameterSets = sets
        if let s = session, VTDecompressionSessionCanAcceptFormatDescription(s, formatDescription: desc) {
            formatDesc = desc
            return
        }
        invalidate()
        formatDesc = desc
        createSession()
    }

    private func withPointers<R>(_ sets: [Data], _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R) -> R {
        let copies = sets.map { d -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count)
            d.copyBytes(to: p, count: d.count)
            return p
        }
        defer { copies.forEach { $0.deallocate() } }
        let ptrs = copies.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        return ptrs.withUnsafeBufferPointer { pp in
            sizes.withUnsafeBufferPointer { sp in body(pp.baseAddress!, sp.baseAddress!) }
        }
    }

    private func createSession() {
        guard let formatDesc else { return }
        let spec: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
        ]
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var cb = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refcon, _, status, _, imageBuffer, pts, _ in
                guard let refcon else { return }
                let me = Unmanaged<VideoDecoder>.fromOpaque(refcon).takeUnretainedValue()
                if status != noErr {
                    me.reportError(status)
                    return
                }
                guard let imageBuffer else { return }
                me.decodedFrames &+= 1
                me.onFrame?(imageBuffer, pts.isValid ? pts.value : 0)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        var s: VTDecompressionSession?
        let st = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: formatDesc,
            decoderSpecification: spec as CFDictionary, imageBufferAttributes: attrs as CFDictionary,
            outputCallback: &cb, decompressionSessionOut: &s)
        guard st == noErr, let s else {
            Log.error("VTDecompressionSessionCreate failed: \(st)")
            return
        }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = s
        Log.info("decoder ready: \(codec.name)")
    }

    private func reportError(_ status: OSStatus) {
        if status != lastErrorStatus { Log.warn("decode error \(status)") }
        lastErrorStatus = status
        onError?(status)
    }

    // MARK: Decode

    /// Decode one access unit (Annex-B). Converts start codes to 4-byte lengths in place.
    public func decode(annexB p: UnsafeMutablePointer<UInt8>, count: Int, pts: Int64) {
        // Collect NALs; strip in-band parameter sets (some encoders repeat them on IDR).
        let nals = VideoDecoder.splitNALs(UnsafePointer(p), count)
        var inband: [Data] = []
        var total = 0
        for r in nals where !r.isEmpty {
            if isParameterSet(nalType(p[r.lowerBound])) {
                inband.append(Data(bytes: p + r.lowerBound, count: r.count))
            } else {
                total += 4 + r.count
            }
        }
        if !inband.isEmpty { applyParameterSets(inband) }
        guard let session, let formatDesc, total > 0 else { return }

        var block: CMBlockBuffer?
        var st = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: total,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: total, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard st == noErr, let block else { return }
        var dataPtr: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &dataPtr)
        guard let dst = dataPtr.map({ UnsafeMutableRawPointer($0) }) else { return }
        var off = 0
        for r in nals where !r.isEmpty && !isParameterSet(nalType(p[r.lowerBound])) {
            var len = UInt32(r.count).bigEndian
            memcpy(dst + off, &len, 4)
            memcpy(dst + off + 4, p + r.lowerBound, r.count)
            off += 4 + r.count
        }

        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: pts, timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var size = total
        st = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDesc,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard st == noErr, let sample else { return }
        var infoFlags = VTDecodeInfoFlags()
        let ds = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: &infoFlags)
        if ds != noErr {
            reportError(ds)
            if ds == kVTInvalidSessionErr {
                invalidate()
                createSession()
            }
        }
    }
}
