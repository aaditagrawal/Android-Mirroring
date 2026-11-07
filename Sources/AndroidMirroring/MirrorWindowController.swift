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
    static let cornerRadiusFraction: CGFloat = 0.075

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
        w.minSize = NSSize(width: 200, height: 300)
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            w.standardWindowButton(b)?.isHidden = true
        }
        if w.frame.width < 200 || w.frame.height < 300 {
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let h = min(880, screen.height * 0.82)
            w.setFrame(NSRect(x: screen.midX - h * 0.23, y: screen.midY - h / 2, width: (h * 0.4615).rounded(), height: h.rounded()), display: false)
        }
    }

    private func buildContent(_ w: NSWindow) {
        container.wantsLayer = true
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        w.contentView = container

        mirrorView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(mirrorView)

        let overlay = PassthroughHostingView(rootView: MirrorOverlay(controller: model.controller, model: model, ui: ui))
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.sizingOptions = []   // never let SwiftUI content drive the window size
        container.addSubview(overlay)

        let toolbar = PassthroughHostingView(rootView: HoverToolbar(model: model, ui: ui, window: { [weak self] in self?.window }))
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.sizingOptions = []
        container.addSubview(toolbar)

        NSLayoutConstraint.activate([
            mirrorView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            mirrorView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            mirrorView.topAnchor.constraint(equalTo: container.topAnchor),
            mirrorView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 64),
        ])

        mirrorView.onHover = { [weak self] p in self?.hover(p) }
        mirrorView.onFileDrop = { [weak self] urls in self?.model.handleDrop(urls, ui: self!.ui) }
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

    private func applyAspect(_ size: CGSize) {
        guard let w = window, size.width > 0, size.height > 0 else { return }
        w.contentAspectRatio = size
        let frame = w.frame
        let screen = w.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        // Keep the current height (or width when rotating to landscape), within the screen.
        let portrait = size.height >= size.width
        var newSize: NSSize
        if portrait {
            var h = frame.height
            if frame.width > frame.height { h = min(screen.height * 0.85, frame.width) } // was landscape
            h = min(h, screen.height * 0.95)
            newSize = NSSize(width: (h * size.width / size.height).rounded(), height: h.rounded())
        } else {
            var wd = frame.width
            if frame.height > frame.width { wd = min(screen.width * 0.7, frame.height) }
            wd = min(wd, screen.width * 0.95)
            newSize = NSSize(width: wd.rounded(), height: (wd * size.height / size.width).rounded())
        }
        let origin = NSPoint(x: frame.midX - newSize.width / 2, y: frame.maxY - newSize.height)
        w.setFrame(NSRect(origin: origin, size: newSize), display: true, animate: false)
        updateCornerRadius()
    }

    func windowDidResize(_ notification: Notification) { updateCornerRadius() }

    private func updateCornerRadius() {
        guard let w = window else { return }
        let r = min(w.frame.width, w.frame.height) * MirrorWindowController.cornerRadiusFraction
        container.layer?.cornerRadius = max(10, r)
        w.invalidateShadow()
    }

    /// Scale to an exact device-pixel ratio (1.0 = one device pixel per screen pixel).
    func setScale(_ s: CGFloat) {
        guard let w = window else { return }
        let fs = model.controller.frameSize
        guard fs.width > 0 else { return }
        let backing = w.backingScaleFactor
        let size = NSSize(width: fs.width * s / backing, height: fs.height * s / backing)
        let f = w.frame
        w.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height), display: true, animate: true)
    }

    func zoom(by factor: CGFloat) {
        guard let w = window else { return }
        let f = w.frame
        let screen = w.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        var size = NSSize(width: f.width * factor, height: f.height * factor)
        if size.height > screen.height { size = NSSize(width: size.width * screen.height / size.height, height: screen.height) }
        if size.height < 300 { return }
        w.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height), display: true, animate: true)
    }

    // MARK: Hover toolbar

    private func hover(_ p: CGPoint?) {
        guard let p else { scheduleHideToolbar(0.6); return }
        let nearTop = p.y > mirrorView.bounds.height - 70
        if nearTop {
            hideToolbarWork?.cancel()
            if !ui.toolbarVisible { withAnimation(.easeOut(duration: 0.18)) { ui.toolbarVisible = true } }
        } else if ui.toolbarVisible {
            scheduleHideToolbar(0.8)
        }
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
