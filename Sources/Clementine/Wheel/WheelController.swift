import AppKit
import SwiftUI

/// Transparent, non-activating panel that hosts the wheel and receives the drop.
final class WheelPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Dragging destination that maps the cursor to a petal.
final class WheelDropView: NSView {
    let model: WheelModel
    var onDrop: (() -> Void)?

    init(model: WheelModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: WheelGeometry.size, height: WheelGeometry.size))
        registerForDraggedTypes([.fileURL])
        let host = NSHostingView(rootView: WheelView(model: model))
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { model.reset() }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = convert(sender.draggingLocation, from: nil)
        model.updateHighlight(point: p, in: bounds)
        if let kind = Settings.shared.kind(for: NSEvent.modifierFlags) { model.setKind(kind) }
        return model.highlighted == nil ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { model.highlighted != nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        let ok = model.perform(urls: urls)
        onDrop?()
        return ok
    }
}

@MainActor
final class WheelController {
    let model = WheelModel()
    private var panel: WheelPanel?
    private(set) var isVisible = false
    private var hideWork: DispatchWorkItem?

    func show(kind: WheelKind, urls: [URL], at screenPoint: NSPoint) {
        hideWork?.cancel()
        if isVisible {
            model.setKind(kind)
            return
        }
        model.load(urls: urls, kind: kind)
        guard !model.items.isEmpty else { return }
        let p = panel ?? makePanel()
        panel = p
        let size = WheelGeometry.size
        var origin = NSPoint(x: screenPoint.x - size / 2, y: screenPoint.y - size / 2)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(screenPoint, $0.frame, false) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            origin.x = min(max(origin.x, f.minX), f.maxX - size)
            origin.y = min(max(origin.y, f.minY), f.maxY - size)
        }
        p.setFrameOrigin(origin)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 1
        }
        isVisible = true
    }

    /// Builds the panel ahead of time and renders each wheel once off-screen, so the first real
    /// open costs the same couple of milliseconds as every later one.
    func prewarm() {
        guard panel == nil else { return }
        let p = makePanel()
        panel = p
        p.alphaValue = 0
        p.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        p.orderFrontRegardless()
        let sample = URL(fileURLWithPath: "/tmp/Clementine Warmup.png") // only the extension matters for classification
        let kinds = WheelKind.allCases
        func step(_ i: Int) {
            guard !isVisible else { finish(); return } // a real drag started; leave the panel to it
            if i < kinds.count {
                model.load(urls: [sample], kind: kinds[i])
                p.displayIfNeeded()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { step(i + 1) }
            } else {
                finish()
            }
        }
        func finish() {
            guard !isVisible else { return }
            p.orderOut(nil)
            p.alphaValue = 1
            model.load(urls: [], kind: .convert)
        }
        step(0)
    }

    /// Called when the modifier is released mid-drag: keep the wheel only if the cursor is on it.
    func modifierReleased(at screenPoint: NSPoint) {
        guard isVisible, let panel else { return }
        if !NSMouseInRect(screenPoint, panel.frame, false) { hide() }
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        panel?.orderOut(nil)
        model.reset()
    }

    /// Mouse went up somewhere. Delay a little so a drop on the wheel is delivered first.
    func dragEnded() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func makePanel() -> WheelPanel {
        let size = WheelGeometry.size
        let p = WheelPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = false
        p.ignoresMouseEvents = false
        p.isReleasedWhenClosed = false
        let drop = WheelDropView(model: model)
        drop.onDrop = { [weak self] in self?.hide() }
        p.contentView = drop
        return p
    }
}

/// `--render-wheel out.png [convert|tools|actions] [sample.ext ...]` renders the wheel to a PNG for inspection.
enum WheelRenderer {
    @MainActor
    static func render(to path: String, kind: WheelKind, sampleURLs: [URL]) -> Bool {
        let model = WheelModel()
        model.load(urls: sampleURLs, kind: kind)
        model.highlighted = model.items.isEmpty ? nil : 1
        let renderer = ImageRenderer(content: WheelView(model: model).padding(20).background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return false }
        return (try? ImageConverter.write(cg, to: URL(fileURLWithPath: path), type: .png, quality: 1, properties: nil)) != nil
    }
}
