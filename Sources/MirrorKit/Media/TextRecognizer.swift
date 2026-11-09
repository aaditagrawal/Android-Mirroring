import CoreGraphics
import Foundation
import Vision

/// A line of text found on screen. `box` is in image pixels (top-left origin).
public struct ScreenText {
    public let text: String
    public let confidence: Float
    public let box: CGRect
    fileprivate let candidate: VNRecognizedText
    fileprivate let imageSize: CGSize

    /// Pixel box of a substring (falls back to the whole line).
    public func box(of range: Range<String.Index>) -> CGRect {
        guard let obs = try? candidate.boundingBox(for: range) else { return box }
        return TextRecognizer.pixelRect(obs.boundingBox, imageSize)
    }
}

public struct TextMatch {
    public let line: ScreenText
    /// Box of the matched text itself (not the whole line).
    public let box: CGRect
    /// 0 = whole line equals the query, 1 = line starts with it, 2 = contains it.
    public let score: Int
}

/// On-device OCR with Apple's Vision framework. Works on anything drawn on screen (web views,
/// Flutter, games, images), needs nothing on the phone, and never competes with other
/// automation tools for Android's single UiAutomation connection.
public enum TextRecognizer {
    /// Vision loads its text models on first use (can take many seconds on a cold start).
    /// Call once at launch so the first agent request is fast.
    public static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            let t0 = Date()
            let ctx = CGContext(data: nil, width: 320, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            ctx?.setFillColor(gray: 1, alpha: 1); ctx?.fill(CGRect(x: 0, y: 0, width: 320, height: 64))
            guard let img = ctx?.makeImage() else { return }
            _ = try? recognize(img)
            Log.info("text recognizer ready in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        }
    }

    public static func recognize(_ image: CGImage, fast: Bool = false) throws -> [ScreenText] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.usesLanguageCorrection = !fast
        request.minimumTextHeight = 0.006
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let size = CGSize(width: image.width, height: image.height)
        return (request.results ?? []).compactMap { obs in
            guard let c = obs.topCandidates(1).first else { return nil }
            let text = c.string.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return ScreenText(text: text, confidence: c.confidence, box: pixelRect(obs.boundingBox, size), candidate: c, imageSize: size)
        }
        .sorted { abs($0.box.midY - $1.box.midY) < 8 ? $0.box.minX < $1.box.minX : $0.box.midY < $1.box.midY }
    }

    /// Lines containing `query` (case/diacritic-insensitive), best first, then top to bottom.
    public static func find(_ query: String, in lines: [ScreenText]) -> [TextMatch] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var out: [TextMatch] = []
        for line in lines {
            guard let r = line.text.range(of: q, options: opts) else { continue }
            let score: Int
            if line.text.compare(q, options: opts) == .orderedSame { score = 0 }
            else if r.lowerBound == line.text.startIndex { score = 1 }
            else { score = 2 }
            out.append(TextMatch(line: line, box: score == 0 ? line.box : line.box(of: r), score: score))
        }
        return out.sorted { $0.score != $1.score ? $0.score < $1.score : $0.box.minY < $1.box.minY }
    }

    static func pixelRect(_ n: CGRect, _ size: CGSize) -> CGRect {
        CGRect(x: n.minX * size.width, y: (1 - n.maxY) * size.height, width: n.width * size.width, height: n.height * size.height)
    }
}
