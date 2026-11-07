import AVFoundation
import AudioToolbox
import Foundation

public enum AudioCodecID: UInt32 {
    case opus = 0x6F70_7573
    case aac = 0x0061_6163
    case flac = 0x666C_6163
    case raw = 0x0072_6177
}

/// Plays the device's audio stream (Opus/AAC/raw PCM, 48 kHz stereo).
/// Keeps a small jitter buffer; when the queue grows past `maxQueuedMs` (network burst
/// after a stall) it drops the oldest audio to stay in sync with video.
public final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
    private var converter: AVAudioConverter?
    private var compressedFormat: AVAudioFormat?
    private let codec: AudioCodecID
    private var queuedFrames: Int64 = 0
    private let queueLock = NSLock()
    private let maxQueuedMs: Double = 120
    private var started = false
    public var volume: Float = 1 { didSet { node.volume = volume } }
    public private(set) var decodedFrames = 0

    public init?(codec: AudioCodecID) {
        self.codec = codec
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: pcmFormat)
        switch codec {
        case .opus:
            var asbd = AudioStreamBasicDescription(
                mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                mFramesPerPacket: 960, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
            compressedFormat = AVAudioFormat(streamDescription: &asbd)
        case .aac:
            var asbd = AudioStreamBasicDescription(
                mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
                mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
            compressedFormat = AVAudioFormat(streamDescription: &asbd)
        case .raw:
            break
        case .flac:
            return nil
        }
        if let compressedFormat {
            converter = AVAudioConverter(from: compressedFormat, to: pcmFormat)
            if converter == nil { Log.error("no audio converter for \(codec)"); return nil }
        }
    }

    public func start() {
        guard !started else { return }
        do {
            try engine.start()
            node.play()
            started = true
        } catch {
            Log.error("audio engine start failed: \(error)")
        }
    }

    public func stop() {
        node.stop()
        engine.stop()
        started = false
    }

    /// Codec config packet (OpusHead / AudioSpecificConfig).
    public func configure(_ data: Data) {
        guard let converter else { return }
        if codec == .aac || codec == .opus {
            converter.magicCookie = data
        }
    }

    public func enqueue(_ data: Data) {
        if !started { start() }
        let buffer: AVAudioPCMBuffer?
        switch codec {
        case .raw: buffer = pcmFromRaw(data)
        default: buffer = decode(data)
        }
        guard let buffer, buffer.frameLength > 0 else { return }
        decodedFrames += Int(buffer.frameLength)

        queueLock.lock()
        let queuedMs = Double(queuedFrames) / 48.0
        if queuedMs > maxQueuedMs {
            queueLock.unlock()
            // Too far behind: flush and restart so audio stays in sync with the picture.
            node.stop()
            queueLock.lock(); queuedFrames = 0; queueLock.unlock()
            node.play()
            queueLock.lock()
        }
        queuedFrames += Int64(buffer.frameLength)
        queueLock.unlock()
        let frames = Int64(buffer.frameLength)
        node.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
            guard let self else { return }
            self.queueLock.lock(); self.queuedFrames = max(0, self.queuedFrames - frames); self.queueLock.unlock()
        }
    }

    private func pcmFromRaw(_ data: Data) -> AVAudioPCMBuffer? {
        // s16le interleaved stereo
        let frames = data.count / 4
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buf.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            let l = buf.floatChannelData![0], r = buf.floatChannelData![1]
            for i in 0..<frames {
                l[i] = Float(Int16(littleEndian: s[2 * i])) / 32768
                r[i] = Float(Int16(littleEndian: s[2 * i + 1])) / 32768
            }
        }
        return buf
    }

    private func decode(_ data: Data) -> AVAudioPCMBuffer? {
        guard let converter, let compressedFormat else { return nil }
        let input = AVAudioCompressedBuffer(format: compressedFormat, packetCapacity: 1, maximumPacketSize: max(data.count, 1))
        data.withUnsafeBytes { raw in
            memcpy(input.data, raw.baseAddress!, data.count)
        }
        input.byteLength = UInt32(data.count)
        input.packetCount = 1
        input.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(data.count))
        guard let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 2048) else { return nil }
        var supplied = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error {
            Log.warn("audio decode error: \(err?.localizedDescription ?? "?")")
            return nil
        }
        return out
    }
}
