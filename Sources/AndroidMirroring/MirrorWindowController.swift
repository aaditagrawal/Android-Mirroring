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
    private let chrome = PassthroughHostingView(rootView: MirrorChrome(screenRadius: 28))
    /// The rounded phone screen. At maximum height the toolbar overlays it to save space.
    private let screenView = NSView()
    private var screenTop: NSLayoutConstraint!
    private var videoAspect: CGSize?
    static let cornerRadiusFraction: CGFloat = 0.075
    /// Keep the material frame outside the video so no phone pixels are covered by the outline.
    static let frameInset: CGFloat = 6
    /// Attached title bar, like iPhone Mirroring; no gap between the bar and phone.
    static let toolbarBarHeight: CGFloat = 36
    static var stripHeight: CGFloat { toolbarBarHeight }

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
        w.minSize = NSSize(width: 240, height: 300 + MirrorWindowController.stripHeight + Self.frameInset)
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

        chrome.sizingOptions = []
        chrome.isHidden = true
        chrome.translatesAutoresizingMaskIntoConstraints = false

        screenView.wantsLayer = true
        screenView.layer?.cornerCurve = .continuous
        screenView.layer?.masksToBounds = true
        screenView.layer?.backgroundColor = NSColor.black.cgColor
        screenView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(screenView)
        container.addSubview(chrome, positioned: .above, relativeTo: screenView)

        mirrorView.translatesAutoresizingMaskIntoConstraints = false
        screenView.addSubview(mirrorView)

        let overlay = PassthroughHostingView(rootView: MirrorOverlay(controller: model.controller, model: model, ui: ui))
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.sizingOptions = []   // never let SwiftUI content drive the window size
        screenView.addSubview(overlay)

        let toolbar = PassthroughHostingView(rootView: HoverToolbar(model: model, ui: ui, window: { [weak self] in self?.window }))
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.sizingOptions = []
        // Controls sit above one continuous glass surface in both windowed and expanded layouts.
        container.addSubview(toolbar, positioned: .above, relativeTo: chrome)

        screenTop = screenView.topAnchor.constraint(equalTo: container.topAnchor, constant: strip)
        NSLayoutConstraint.activate([
            chrome.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            chrome.topAnchor.constraint(equalTo: container.topAnchor),
            chrome.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            screenView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.frameInset),
            screenView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.frameInset),
            screenView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.frameInset),
            screenTop,
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
            .sink { [weak self] visible in
                self?.chrome.isHidden = !visible
                // The window shadow follows its opaque pixels; refresh it once the bar has animated.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.window?.invalidateShadow() }
            }
            .store(in: &cancellables)
        windowDidResize(Notification(name: NSWindow.didResizeNotification))
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

    private var fillsScreenHeight: Bool {
        guard let w = window, let display = w.screen?.visibleFrame else { return false }
        return w.frame.height >= display.height - 1
    }

    private var strip: CGFloat { fillsScreenHeight ? 0 : MirrorWindowController.stripHeight }
    private var screenTopInset: CGFloat { fillsScreenHeight ? Self.frameInset : strip }
    private var verticalChrome: CGFloat { screenTopInset + Self.frameInset }

    /// Reserve space for controls unless the phone can fill the display's available height.
    private func windowSize(screen: NSSize) -> NSSize {
        let bar = MirrorWindowController.stripHeight
        let inset = Self.frameInset
        if let display = window?.screen?.visibleFrame,
           screen.height + bar + inset >= display.height,
           screen.width * (display.height - 2 * inset) / screen.height + 2 * inset <= display.width {
            return NSSize(width: (screen.width * (display.height - 2 * inset) / screen.height + 2 * inset).rounded(), height: display.height)
        }
        return NSSize(width: (screen.width + 2 * inset).rounded(), height: (screen.height + bar + inset).rounded())
    }

    private func applyAspect(_ size: CGSize) {
        guard let w = window, size.width > 0, size.height > 0 else { return }
        videoAspect = size
        if fillsScreenHeight, let display = w.screen?.visibleFrame,
           (display.height - 2 * Self.frameInset) * size.width / size.height + 2 * Self.frameInset <= display.width {
            let width = (display.height - 2 * Self.frameInset) * size.width / size.height + 2 * Self.frameInset
            w.setFrame(NSRect(x: display.midX - width / 2, y: display.minY,
                              width: width, height: display.height), display: true)
            return
        }
        let frame = w.frame
        let screenArea = NSSize(width: frame.width - 2 * Self.frameInset, height: frame.height - verticalChrome)
        let display = w.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        // Keep the current height (or width when rotating to landscape), within the display.
        let portrait = size.height >= size.width
        var newScreen: NSSize
        if portrait {
            var h = screenArea.height
            if screenArea.width > screenArea.height { h = min(display.height * 0.85 - strip - Self.frameInset, screenArea.width) } // was landscape
            h = min(h, display.height * 0.95 - strip - Self.frameInset)
            newScreen = NSSize(width: h * size.width / size.height, height: h)
        } else {
            var wd = screenArea.width
            if screenArea.height > screenArea.width { wd = min(display.width * 0.7, screenArea.height) }
            wd = min(wd, display.width * 0.95 - 2 * Self.frameInset)
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
            let width = max(1, frameSize.width - 2 * Self.frameInset)
            return windowSize(screen: NSSize(width: width, height: width * a.height / a.width))
        }
        let h = max(1, frameSize.height - MirrorWindowController.stripHeight - Self.frameInset)
        return windowSize(screen: NSSize(width: h * a.width / a.height, height: h))
    }

    func windowDidResize(_ notification: Notification) {
        guard let screenTop else { return }
        screenTop.constant = screenTopInset
        updateCornerRadius()
    }

    private func updateCornerRadius() {
        guard let w = window else { return }
        let r = min(w.frame.width - 2 * Self.frameInset, w.frame.height - verticalChrome) * MirrorWindowController.cornerRadiusFraction
        screenView.layer?.cornerRadius = max(10, r)
        chrome.rootView = MirrorChrome(screenRadius: max(10, r), toolbarOverlaysPhone: fillsScreenHeight)
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
        var screen = NSSize(width: (f.width - 2 * Self.frameInset) * factor, height: (f.height - verticalChrome) * factor)
        let maxH = display.height - MirrorWindowController.stripHeight - Self.frameInset
        if screen.height > maxH { screen = NSSize(width: screen.width * maxH / screen.height, height: maxH) }
        if screen.height < 300 { return }
        let size = windowSize(screen: screen)
        w.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height), display: true, animate: true)
    }

    // MARK: Hover toolbar

    private func hover(_ p: CGPoint?) {
        // Match iPhone Mirroring: reveal controls at the top, not while reading or scrolling.
        if let p, p.y < mirrorView.bounds.height - MirrorWindowController.toolbarBarHeight {
            scheduleHideToolbar(0.8)
            return
        }
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
