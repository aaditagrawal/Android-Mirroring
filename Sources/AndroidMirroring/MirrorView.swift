import AVFoundation
import AppKit
import Carbon.HIToolbox
import CoreMedia
import MirrorKit

/// Renders the decoded stream and turns Mac input into Android touches and keys.
final class MirrorView: NSView, NSTextInputClient {
    let controller: MirrorController
    private let displayLayer = AVSampleBufferDisplayLayer()
    /// Metal presenter with display-linked frame pacing (falls back to the sample-buffer layer).
    let renderer = VideoRenderer()
    private var formatDesc: CMVideoFormatDescription?
    private var formatDims: (Int32, Int32) = (0, 0)
    private var trackingArea: NSTrackingArea?
    private var defaultsObserver: NSObjectProtocol?
    private var windowObservers: [NSObjectProtocol] = []

    // Touch state
    private var mouseDown = false
    private var scrollFingerActive = false   // a finger is down on the phone
    private var scrollGestureLive = false    // trackpad gesture in progress (finger may not be down yet)
    private var scrollFingerPos = CGPoint.zero
    private var scrollEndWork: DispatchWorkItem?
    private var pinchActive = false
    private var pinchCenter = CGPoint.zero
    private var pinchRadius: CGFloat = 0
    private static let scrollPointer: UInt64 = 20
    private static let pinchPointerA: UInt64 = 21
    private static let pinchPointerB: UInt64 = 22

    var onHover: ((CGPoint?) -> Void)?
    var onFileDrop: (([URL]) -> Void)?

    init(controller: MirrorController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        if let renderer {
            renderer.layer.frame = bounds
            renderer.layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer?.addSublayer(renderer.layer)
            renderer.pacing = MirrorSettings.pacing
            // Follow the setting wherever it is changed from (Settings, the agent API, `defaults write`).
            defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { [weak renderer] _ in
                let p = MirrorSettings.pacing
                if renderer?.pacing != p { renderer?.pacing = p }
            }
            controller.displaySink = { [weak renderer] f in renderer?.push(f) }
        } else {
            displayLayer.videoGravity = .resizeAspect
            displayLayer.backgroundColor = NSColor.black.cgColor
            displayLayer.frame = bounds
            displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            // Never wait for a timebase: show each frame the moment it is decoded.
            displayLayer.preventsDisplaySleepDuringVideoPlayback = true
            layer?.addSublayer(displayLayer)
            controller.displaySink = { [weak self] f in self?.enqueue(f.buffer) }
        }
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        if let r = renderer {
            r.layer.frame = bounds
            let scale = window?.backingScaleFactor ?? 2
            r.layer.contentsScale = scale
            r.layer.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
            r.setNeedsRedraw()
        }
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    deinit {
        if let o = defaultsObserver { NotificationCenter.default.removeObserver(o) }
        windowObservers.forEach(NotificationCenter.default.removeObserver)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        guard let w = window else { renderer?.paused = true; return }
        let nc = NotificationCenter.default
        windowObservers = [
            nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self] _ in self?.updatePaused() },
            nc.addObserver(forName: NSWindow.didChangeScreenNotification, object: w, queue: .main) { [weak self] _ in self?.updateFrameRate() },
        ]
        updatePaused()
        updateFrameRate()
    }

    /// Match the refresh rate of the screen the window is on (e.g. 120 Hz on a ProMotion panel).
    private func updateFrameRate() {
        guard let hz = window?.screen?.maximumFramesPerSecond else { return }
        renderer?.setMaxFrameRate(hz)
    }

    /// Stop the display link while the window can't be seen (saves power; the agent API reads the
    /// frame store, not the screen).
    private func updatePaused() {
        guard let r = renderer else { return }
        let visible = window?.occlusionState.contains(.visible) ?? false
        r.paused = !visible
        if visible { r.setNeedsRedraw() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        trackingArea = t
    }

    // MARK: Display

    /// Called on the decoder thread.
    private func enqueue(_ pb: CVPixelBuffer) {
        let w = Int32(CVPixelBufferGetWidth(pb)), h = Int32(CVPixelBufferGetHeight(pb))
        if formatDesc == nil || formatDims != (w, h) {
            var fd: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &fd)
            formatDesc = fd
            formatDims = (w, h)
        }
        guard let formatDesc else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescription: formatDesc,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary],
           let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }

    func clearDisplay() {
        renderer?.clear()
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true)
    }

    // MARK: Coordinate mapping

    /// The rect (in view points) where the video is drawn (aspect fit).
    private var videoRect: CGRect {
        let fs = controller.frameSize
        guard fs.width > 0, fs.height > 0 else { return bounds }
        let scale = min(bounds.width / fs.width, bounds.height / fs.height)
        let w = fs.width * scale, h = fs.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    /// View point → device pixel.
    private func devicePoint(_ p: CGPoint) -> CGPoint {
        let r = videoRect
        let fs = controller.frameSize
        let nx = (p.x - r.minX) / max(r.width, 1)
        let ny = 1 - (p.y - r.minY) / max(r.height, 1)
        return CGPoint(x: nx * fs.width, y: ny * fs.height)
    }

    private var pointsToPixels: CGFloat {
        let r = videoRect
        return controller.frameSize.width / max(r.width, 1)
    }

    private func location(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    // MARK: Mouse → touch

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        if e.modifierFlags.contains(.command) {
            window?.performDrag(with: e)
            return
        }
        if e.clickCount == 1 || !mouseDown {
            mouseDown = true
            let p = devicePoint(location(e))
            controller.touch(.down, x: p.x, y: p.y)
        }
    }

    override func mouseDragged(with e: NSEvent) {
        guard mouseDown else { return }
        let p = devicePoint(location(e))
        controller.touch(.move, x: p.x, y: p.y)
    }

    override func mouseUp(with e: NSEvent) {
        guard mouseDown else { return }
        mouseDown = false
        let p = devicePoint(location(e))
        controller.touch(.up, x: p.x, y: p.y)
    }

    override func rightMouseDown(with e: NSEvent) {
        // Right click = Back (wakes the screen if it is off).
        controller.backOrScreenOn()
    }

    override func otherMouseDown(with e: NSEvent) {
        if e.buttonNumber == 2 { controller.key(AKey.home) }
        else if e.buttonNumber == 3 { controller.key(AKey.back) }
        else if e.buttonNumber == 4 { controller.key(AKey.appSwitch) }
    }

    override func mouseMoved(with e: NSEvent) { onHover?(location(e)) }
    override func mouseEntered(with e: NSEvent) { onHover?(location(e)) }
    override func mouseExited(with e: NSEvent) { onHover?(nil) }

    // MARK: Scroll

    override func scrollWheel(with e: NSEvent) {
        if e.hasPreciseScrollingDeltas && UserDefaults.standard.object(forKey: "trackpadAsTouch") as? Bool ?? true {
            trackpadScroll(e)
        } else {
            let p = devicePoint(location(e))
            // Wheel notches: macOS gives ±1..±N lines; Android expects ±1 per notch.
            let dx = Float(e.scrollingDeltaX) / (e.hasPreciseScrollingDeltas ? 30 : 1)
            let dy = Float(e.scrollingDeltaY) / (e.hasPreciseScrollingDeltas ? 30 : 1)
            controller.scroll(x: p.x, y: p.y, dx: -dx, dy: dy)
        }
    }

    /// Two-finger trackpad scrolling becomes a real finger drag, so lists fling and
    /// rubber-band exactly as they would under a finger.
    private func trackpadScroll(_ e: NSEvent) {
        // Momentum events: Android performs its own fling after the finger lifts.
        if !e.momentumPhase.isEmpty { return }
        let k = pointsToPixels
        switch e.phase {
        case .began, .mayBegin:
            // Only remember where the gesture starts. Putting the finger down here would turn a
            // resting two-finger touch (mayBegin → cancelled) into a tap on the phone.
            if scrollFingerActive { endScrollFinger() }
            scrollFingerPos = devicePoint(location(e))
            scrollGestureLive = true
        case .changed:
            if e.scrollingDeltaX == 0 && e.scrollingDeltaY == 0 { break }
            if !scrollFingerActive {
                if !scrollGestureLive { scrollFingerPos = devicePoint(location(e)) }
                scrollGestureLive = true
                scrollFingerActive = true
                controller.touch(.down, x: scrollFingerPos.x, y: scrollFingerPos.y, pointer: MirrorView.scrollPointer)
            }
            let fs = controller.frameSize
            scrollFingerPos.x = max(1, min(fs.width - 2, scrollFingerPos.x + e.scrollingDeltaX * k))
            scrollFingerPos.y = max(1, min(fs.height - 2, scrollFingerPos.y + e.scrollingDeltaY * k))
            controller.touch(.move, x: scrollFingerPos.x, y: scrollFingerPos.y, pointer: MirrorView.scrollPointer)
        case .ended, .cancelled:
            scrollGestureLive = false
            endScrollFinger()
        default:
            break
        }
        // Safety net: lift the finger if the trackpad never reports an end.
        scrollEndWork?.cancel()
        if scrollFingerActive {
            let w = DispatchWorkItem { [weak self] in self?.endScrollFinger() }
            scrollEndWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
        }
    }

    private func endScrollFinger() {
        guard scrollFingerActive else { return }
        scrollFingerActive = false
        controller.touch(.up, x: scrollFingerPos.x, y: scrollFingerPos.y, pointer: MirrorView.scrollPointer)
    }

    // MARK: Pinch

    override func magnify(with e: NSEvent) {
        let fs = controller.frameSize
        switch e.phase {
        case .began:
            pinchActive = true
            pinchCenter = devicePoint(location(e))
            pinchRadius = min(fs.width, fs.height) * 0.1
            sendPinch(.down, .down)
        case .changed:
            guard pinchActive else { return }
            pinchRadius = max(10, min(min(fs.width, fs.height) * 0.48, pinchRadius * (1 + e.magnification)))
            sendPinch(.move, .move)
        case .ended, .cancelled:
            guard pinchActive else { return }
            pinchActive = false
            // The server derives ACTION_POINTER_DOWN/UP itself; send plain DOWN/UP per finger.
            sendPinch(.up, .up, reversed: true)
        default: break
        }
    }

    private func sendPinch(_ a: MotionAction, _ b: MotionAction, reversed: Bool = false) {
        let p1 = CGPoint(x: pinchCenter.x - pinchRadius, y: pinchCenter.y)
        let p2 = CGPoint(x: pinchCenter.x + pinchRadius, y: pinchCenter.y)
        if reversed {
            controller.touch(a, x: p2.x, y: p2.y, pointer: MirrorView.pinchPointerB)
            controller.touch(b, x: p1.x, y: p1.y, pointer: MirrorView.pinchPointerA)
        } else {
            controller.touch(a, x: p1.x, y: p1.y, pointer: MirrorView.pinchPointerA)
            controller.touch(b, x: p2.x, y: p2.y, pointer: MirrorView.pinchPointerB)
        }
    }

    // MARK: Keyboard

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: e) }
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return super.performKeyEquivalent(with: e) }
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (chars, flags.contains(.shift)) {
        case ("v", false):
            // Paste: push the Mac clipboard to the phone and paste it.
            if let text = NSPasteboard.general.string(forType: .string) { controller.setDeviceClipboard(text, paste: true) }
            return true
        case ("c", false):
            controller.fetchDeviceClipboard(copyKey: 1) { text in
                guard let text else { return }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            }
            return true
        case ("x", false):
            controller.fetchDeviceClipboard(copyKey: 2) { text in
                guard let text else { return }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            }
            return true
        case ("a", false): sendCtrl(AKey.a); return true
        case ("z", false): sendCtrl(AKey.z); return true
        case ("z", true): sendCtrl(AKey.z, shift: true); return true
        default:
            break
        }
        switch Int(e.keyCode) {
        case kVK_LeftArrow where !flags.contains(.shift): controller.key(AKey.moveHome); return true
        case kVK_RightArrow where !flags.contains(.shift): controller.key(AKey.moveEnd); return true
        case kVK_Delete: // Cmd-Delete: delete to line start
            controller.key(AKey.moveHome, meta: AKey.metaShiftOn); controller.key(AKey.del); return true
        default:
            return super.performKeyEquivalent(with: e)
        }
    }

    private func sendCtrl(_ code: Int32, shift: Bool = false) {
        var meta = AKey.metaCtrlOn | AKey.metaCtrlLeftOn
        if shift { meta |= AKey.metaShiftOn }
        controller.key(code, meta: meta)
    }

    private func meta(from flags: NSEvent.ModifierFlags) -> Int32 {
        var m: Int32 = 0
        if flags.contains(.shift) { m |= AKey.metaShiftOn }
        if flags.contains(.control) { m |= AKey.metaCtrlOn | AKey.metaCtrlLeftOn }
        return m
    }

    /// Keys sent as raw key events (with repeat), bypassing the text system.
    private func directKey(_ e: NSEvent) -> Int32? {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch Int(e.keyCode) {
        case kVK_Escape: return AKey.back
        case kVK_Return, kVK_ANSI_KeypadEnter: return AKey.enter
        case kVK_Delete: return flags.contains(.option) ? nil : AKey.del
        case kVK_ForwardDelete: return AKey.forwardDel
        case kVK_Tab: return AKey.tab
        case kVK_LeftArrow: return flags.contains(.option) ? nil : AKey.dpadLeft
        case kVK_RightArrow: return flags.contains(.option) ? nil : AKey.dpadRight
        case kVK_UpArrow: return AKey.dpadUp
        case kVK_DownArrow: return AKey.dpadDown
        case kVK_Home: return AKey.moveHome
        case kVK_End: return AKey.moveEnd
        case kVK_PageUp: return AKey.pageUp
        case kVK_PageDown: return AKey.pageDown
        case kVK_F1: return AKey.brightnessDown
        case kVK_F2: return AKey.brightnessUp
        case kVK_F7: return AKey.mediaPrevious
        case kVK_F8: return AKey.mediaPlayPause
        case kVK_F9: return AKey.mediaNext
        case kVK_F10: return AKey.volumeMute
        case kVK_F11: return AKey.volumeDown
        case kVK_F12: return AKey.volumeUp
        default: return nil
        }
    }

    override func keyDown(with e: NSEvent) {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let code = directKey(e) {
            controller.keyEvent(.down, code, meta: meta(from: flags), repeatCount: e.isARepeat ? 1 : 0)
            return
        }
        // Option-Delete / Option-arrows: word-wise editing (Ctrl on Android).
        if flags.contains(.option) {
            switch Int(e.keyCode) {
            case kVK_Delete: controller.key(AKey.del, meta: AKey.metaCtrlOn | AKey.metaCtrlLeftOn); return
            case kVK_LeftArrow: controller.key(AKey.dpadLeft, meta: AKey.metaCtrlOn | AKey.metaCtrlLeftOn | meta(from: flags)); return
            case kVK_RightArrow: controller.key(AKey.dpadRight, meta: AKey.metaCtrlOn | AKey.metaCtrlLeftOn | meta(from: flags)); return
            default: break
            }
        }
        if flags.contains(.control), let c = e.charactersIgnoringModifiers?.lowercased().unicodeScalars.first,
           c.value >= 97, c.value <= 122 {
            // Ctrl+letter → Android Ctrl+letter key event (KEYCODE_A = 29).
            controller.key(Int32(29 + Int(c.value) - 97), meta: AKey.metaCtrlOn | AKey.metaCtrlLeftOn)
            return
        }
        interpretKeyEvents([e])
    }

    override func keyUp(with e: NSEvent) {
        if let code = directKey(e) {
            controller.keyEvent(.up, code, meta: meta(from: e.modifierFlags))
        }
    }

    // MARK: NSTextInputClient (IME, dead keys, emoji picker)

    private var marked = NSMutableAttributedString()

    func insertText(_ string: Any, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        marked = NSMutableAttributedString()
        guard !s.isEmpty else { return }
        controller.type(s)
    }

    override func doCommand(by selector: Selector) {
        // Commands not covered by directKey (e.g. from IME) – map the common ones.
        switch selector {
        case #selector(insertNewline(_:)): controller.key(AKey.enter)
        case #selector(deleteBackward(_:)): controller.key(AKey.del)
        case #selector(insertTab(_:)): controller.key(AKey.tab)
        default: break
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = NSMutableAttributedString(string: (string as? NSAttributedString)?.string ?? (string as? String) ?? "")
    }
    func unmarkText() { marked = NSMutableAttributedString() }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { marked.length > 0 ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let w = window else { return .zero }
        let r = convert(CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 20), to: nil)
        return w.convertToScreen(r)
    }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    // MARK: Drag & drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        onFileDrop?(urls)
        return true
    }
}
