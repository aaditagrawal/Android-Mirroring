import AppKit
import Combine
import MirrorKit
import SwiftUI

/// Observable UI state shared by the window chrome overlays.
final class WindowUIState: ObservableObject {
    @Published var toolbarVisible = false
    @Published var toast: String?
    @Published var progress: String?
    private var toastWork: DispatchWorkItem?

    func show(toast: String, for seconds: Double = 2.5) {
        toastWork?.cancel()
        withAnimation(.spring(duration: 0.3)) { self.toast = toast }
        let w = DispatchWorkItem { [weak self] in withAnimation(.easeOut(duration: 0.3)) { self?.toast = nil } }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }
}

/// Container that lets clicks on transparent overlay areas fall through to the mirror view.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === self ? nil : v
    }
}

/// A view that drags the window (used under the hover toolbar).
final class WindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

final class MirrorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class MirrorWindowController: NSWindowController, NSWindowDelegate {
    let model: AppModel
    let mirrorView: MirrorView
    let ui = WindowUIState()
    private var cancellables = Set<AnyCancellable>()
    private var hideToolbarWork: DispatchWorkItem?
    private let container = NSView()
    /// The rounded phone screen. The toolbar lives in a strip above it, never on top of it.
    private let screenView = NSView()
    private var videoAspect: CGSize?
    static let cornerRadiusFraction: CGFloat = 0.075
    /// Toolbar strip above the screen: 36 pt bar + 8 pt gap.
    static let toolbarBarHeight: CGFloat = 36
    static let toolbarGap: CGFloat = 8
    static var stripHeight: CGFloat { toolbarBarHeight + toolbarGap }

    init(model: AppModel) {
        self.model = model
        self.mirrorView = MirrorView(controller: model.controller)
        let window = MirrorWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 820),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        super.init(window: window)
        configureWindow(window)
        buildContent(window)
        bind()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configureWindow(_ w: NSWindow) {
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isMovableByWindowBackground = false
        w.collectionBehavior = [.fullScreenNone, .managed]
        w.delegate = self
        w.title = "Android Mirroring"
        w.setFrameAutosaveName("MirrorWindow")
        w.minSize = NSSize(width: 200, height: 300 + MirrorWindowController.stripHeight)
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            w.standardWindowButton(b)?.isHidden = true
        }
        if w.frame.width < 200 || w.frame.height < 300 {
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let h = min(880, screen.height * 0.82)
            let strip = MirrorWindowController.stripHeight
            w.setFrame(NSRect(x: screen.midX - h * 0.23, y: screen.midY - h / 2, width: (h * 0.4615).rounded(), height: (h + strip).rounded()), display: false)
        }
    }

    private func buildContent(_ w: NSWindow) {
        // Root view is fully transparent: clicks and the pointer pass through the empty strip
        // above the screen to whatever is behind the window.
        w.contentView = container

        screenView.wantsLayer = true
        screenView.layer?.cornerCurve = .continuous
        screenView.layer?.masksToBounds = true
        screenView.layer?.backgroundColor = NSColor.black.cgColor
        screenView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(screenView)

        mirrorView.translatesAutoresizingMaskIntoConstraints = false
        screenView.addSubview(mirrorView)

        let overlay = PassthroughHostingView(rootView: MirrorOverlay(controller: model.controller, model: model, ui: ui))
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.sizingOptions = []   // never let SwiftUI content drive the window size
        screenView.addSubview(overlay)

        let toolbar = PassthroughHostingView(rootView: HoverToolbar(model: model, ui: ui, window: { [weak self] in self?.window }))
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.sizingOptions = []
        // Below the screen in z-order, so the bar slides out from behind the screen's top edge.
        container.addSubview(toolbar, positioned: .below, relativeTo: screenView)

        NSLayoutConstraint.activate([
            screenView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            screenView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            screenView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            screenView.topAnchor.constraint(equalTo: container.topAnchor, constant: MirrorWindowController.stripHeight),
            mirrorView.leadingAnchor.constraint(equalTo: screenView.leadingAnchor),
            mirrorView.trailingAnchor.constraint(equalTo: screenView.trailingAnchor),
            mirrorView.topAnchor.constraint(equalTo: screenView.topAnchor),
            mirrorView.bottomAnchor.constraint(equalTo: screenView.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: screenView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: screenView.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: screenView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: screenView.bottomAnchor),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: MirrorWindowController.stripHeight),
        ])

        mirrorView.onHover = { [weak self] p in self?.hover(p) }
        mirrorView.onFileDrop = { [weak self] urls in self?.model.handleDrop(urls, ui: self!.ui) }
        ui.$toolbarVisible
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // The window shadow follows its opaque pixels; refresh it once the bar has animated.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.window?.invalidateShadow() }
            }
            .store(in: &cancellables)
        updateCornerRadius()
    }

    private func bind() {
        model.controller.$frameSize
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] size in self?.applyAspect(size) }
            .store(in: &cancellables)
        model.controller.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in
                if case .idle = s { self?.mirrorView.clearDisplay() }
            }
            .store(in: &cancellables)
        model.controller.$lastSwitchReason
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.announcePathSoon() }
            .store(in: &cancellables)
    }

    private func announcePathSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, let t = self.model.controller.activeTransport else { return }
            self.ui.show(toast: "Now using \(t.label)")
        }
    }

    // MARK: Sizing

    private var strip: CGFloat { MirrorWindowController.stripHeight }

    /// Window size for a screen area of the given size (the strip sits on top).
    private func windowSize(screen: NSSize) -> NSSize {
        NSSize(width: screen.width.rounded(), height: (screen.height + strip).rounded())
    }

    private func applyAspect(_ size: CGSize) {
        guard let w = window, size.width > 0, size.height > 0 else { return }
        videoAspect = size
        let frame = w.frame
        let screenArea = NSSize(width: frame.width, height: frame.height - strip)
        let display = w.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        // Keep the current height (or width when rotating to landscape), within the display.
        let portrait = size.height >= size.width
        var newScreen: NSSize
        if portrait {
            var h = screenArea.height
            if screenArea.width > screenArea.height { h = min(display.height * 0.85 - strip, screenArea.width) } // was landscape
            h = min(h, display.height * 0.95 - strip)
            newScreen = NSSize(width: h * size.width / size.height, height: h)
        } else {
            var wd = screenArea.width
            if screenArea.height > screenArea.width { wd = min(display.width * 0.7, screenArea.height) }
            wd = min(wd, display.width * 0.95)
            newScreen = NSSize(width: wd, height: wd * size.height / size.width)
        }
        let newSize = windowSize(screen: newScreen)
        let origin = NSPoint(x: frame.midX - newSize.width / 2, y: frame.maxY - newSize.height)
        w.setFrame(NSRect(origin: origin, size: newSize), display: true, animate: false)
        updateCornerRadius()
    }

    /// Keep the screen area (not the whole window) at the video's aspect ratio while resizing.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard let a = videoAspect, a.width > 0, a.height > 0 else { return frameSize }
        let cur = sender.frame.size
        let widthLed = abs(frameSize.width - cur.width) >= abs(frameSize.height - cur.height)
        if widthLed {
            return windowSize(screen: NSSize(width: frameSize.width, height: frameSize.width * a.height / a.width))
        }
        let h = max(1, frameSize.height - strip)
        return windowSize(screen: NSSize(width: h * a.width / a.height, height: h))
    }

    func windowDidResize(_ notification: Notification) { updateCornerRadius() }

    private func updateCornerRadius() {
        guard let w = window else { return }
        let r = min(w.frame.width, w.frame.height - strip) * MirrorWindowController.cornerRadiusFraction
        screenView.layer?.cornerRadius = max(10, r)
        w.invalidateShadow()
    }

    /// Scale to an exact device-pixel ratio (1.0 = one device pixel per screen pixel).
    func setScale(_ s: CGFloat) {
        guard let w = window else { return }
        let fs = model.controller.frameSize
        guard fs.width > 0 else { return }
        let backing = w.backingScaleFactor
        let size = windowSize(screen: NSSize(width: fs.width * s / backing, height: fs.height * s / backing))
        let f = w.frame
        w.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height), display: true, animate: true)
    }

    func zoom(by factor: CGFloat) {
        guard let w = window else { return }
        let f = w.frame
        let display = w.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        var screen = NSSize(width: f.width * factor, height: (f.height - strip) * factor)
        let maxH = display.height - strip
        if screen.height > maxH { screen = NSSize(width: screen.width * maxH / screen.height, height: maxH) }
        if screen.height < 300 { return }
        let size = windowSize(screen: screen)
        w.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height), display: true, animate: true)
    }

    // MARK: Hover toolbar

    private func hover(_ p: CGPoint?) {
        // The bar sits outside the screen, so it can show whenever the pointer is over the
        // phone without covering anything (as in iPhone Mirroring).
        guard p != nil else { scheduleHideToolbar(0.8); return }
        hideToolbarWork?.cancel()
        if !ui.toolbarVisible { withAnimation(.spring(duration: 0.28, bounce: 0.15)) { ui.toolbarVisible = true } }
    }

    private func scheduleHideToolbar(_ delay: Double) {
        hideToolbarWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            withAnimation(.easeIn(duration: 0.2)) { self?.ui.toolbarVisible = false }
        }
        hideToolbarWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    func toolbarHovering(_ inside: Bool) {
        if inside { hideToolbarWork?.cancel() } else { scheduleHideToolbar(0.6) }
    }

    // MARK: Window lifecycle

    func showMirror() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(mirrorView)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        model.windowClosed()
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        window?.makeFirstResponder(mirrorView)
        model.controller.requestKeyFrame()
    }
}
