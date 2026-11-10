import AppKit
import SwiftUI

/// Opens editor windows for petals that need a UI, and routes their Save through the job pipeline.
@MainActor
final class EditorManager {
    static let shared = EditorManager()
    private var controllers: [EditorWindowController] = []

    func open(_ kind: EditorKind, urls: [URL]) {
        let files = urls.map(FileItem.init)
        switch kind {
        case .image:
            for f in files.filter({ $0.kind == .image }).prefix(6) {
                let c = EditorWindowController(title: "\(kind.title) · \(f.name)", size: NSSize(width: 1040, height: 720))
                let model = ImageEditModel(file: f)
                c.setContent(ImageEditorView(model: model, controller: c))
                present(c)
            }
        case .redact:
            for f in files.filter({ $0.kind == .image }).prefix(6) {
                let c = EditorWindowController(title: "\(kind.title) · \(f.name)", size: NSSize(width: 1040, height: 720))
                let model = RedactModel(file: f)
                c.setContent(RedactEditorView(model: model, controller: c))
                present(c)
            }
        case .annotate:
            for f in files.filter({ $0.kind == .image }).prefix(6) {
                let c = EditorWindowController(title: "\(kind.title) · \(f.name)", size: NSSize(width: 1100, height: 740))
                let model = AnnotateModel(file: f)
                c.setContent(AnnotateEditorView(model: model, controller: c))
                present(c)
            }
        case .videoTrim:
            for f in files.filter({ $0.kind == .video }).prefix(3) {
                let c = EditorWindowController(title: "\(kind.title) · \(f.name)", size: NSSize(width: 1000, height: 720))
                let model = VideoEditModel(file: f)
                c.setContent(VideoEditorView(model: model, controller: c))
                present(c)
            }
        case .audioTrim:
            for f in files.filter({ $0.kind == .audio }).prefix(3) {
                let c = EditorWindowController(title: "\(kind.title) · \(f.name)", size: NSSize(width: 980, height: 400), minSize: NSSize(width: 820, height: 360))
                let model = AudioEditModel(file: f)
                c.setContent(AudioEditorView(model: model, controller: c))
                present(c)
            }
        case .collage:
            let images = files.filter { $0.kind == .image }
            guard images.count >= 2 else { return }
            let c = EditorWindowController(title: "Collage · \(images.count) images", size: NSSize(width: 920, height: 600))
            c.setContent(CollageView(model: CollageModel(files: images), controller: c))
            present(c)
        case .visualizer:
            let audio = files.filter { $0.kind == .audio }
            guard !audio.isEmpty else { return }
            let c = EditorWindowController(title: "Visualizer", size: NSSize(width: 520, height: 430), minSize: NSSize(width: 520, height: 380))
            c.window?.styleMask.remove(.resizable)
            c.setContent(VisualizerView(model: VisualizerModel(files: audio), controller: c))
            present(c)
        case .metadata:
            for f in files.filter({ $0.kind == .image }).prefix(4) {
                let c = EditorWindowController(title: "Metadata · \(f.name)", size: NSSize(width: 700, height: 680), minSize: NSSize(width: 620, height: 520))
                c.setContent(MetadataEditorView(model: MetadataModel(file: f), controller: c))
                present(c)
            }
        case .targetSize:
            let media = files.filter { $0.kind == .image || $0.kind == .video }
            guard !media.isEmpty else { return }
            let c = EditorWindowController(title: "Target Size", size: NSSize(width: 460, height: 320), minSize: NSSize(width: 460, height: 240))
            c.window?.styleMask.remove(.resizable)
            let model = TargetSizeModel(files: media)
            c.setContent(TargetSizeView(model: model, controller: c))
            present(c)
        case .pdfOrganizer:
            let pdfs = files.filter { $0.kind == .pdf }
            guard !pdfs.isEmpty else { return }
            let title = pdfs.count == 1 ? "\(kind.title) · \(pdfs[0].name)" : "\(kind.title) · \(pdfs.count) files"
            let c = EditorWindowController(title: title, size: NSSize(width: 960, height: 680))
            let model = PDFOrganizerModel(files: pdfs)
            c.setContent(PDFOrganizerView(model: model, controller: c))
            present(c)
        }
    }

    /// Runs an export as a normal job so the HUD, sound, reveal and naming rules all apply.
    func save(title: String, source: URL, _ export: @escaping () throws -> URL) {
        let op = Operation("editor.save", title, "square.and.arrow.down", .tools) { _ in
            OperationResult(outputs: [try export()])
        }
        JobCenter.shared.run(op, urls: [source])
    }

    private func present(_ c: EditorWindowController) {
        controllers.append(c)
        let offset = CGFloat((controllers.count - 1) % 6) * 26
        if let w = c.window, let screen = NSScreen.main?.visibleFrame {
            w.setFrameOrigin(NSPoint(x: screen.midX - w.frame.width / 2 + offset, y: screen.midY - w.frame.height / 2 - offset))
        }
        NSApp.activate(ignoringOtherApps: true)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
    }

    func remove(_ c: EditorWindowController) {
        controllers.removeAll { $0 === c }
    }
}

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    init(title: String, size: NSSize, minSize: NSSize = NSSize(width: 720, height: 480)) {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = title
        w.minSize = minSize
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    func setContent<V: View>(_ view: V) {
        window?.contentView = NSHostingView(rootView: view)
    }

    func windowWillClose(_ notification: Notification) {
        EditorManager.shared.remove(self)
    }

    func dismiss() {
        window?.close()
    }
}

// MARK: Shared canvas helpers

/// Maps between a bitmap's pixel space (top-left origin) and the view rect it is fitted into.
struct CanvasGeometry {
    let fitted: CGRect
    let imageSize: CGSize
    var scale: CGFloat { imageSize.width > 0 ? fitted.width / imageSize.width : 1 }

    init(imageSize: CGSize, in viewSize: CGSize, inset: CGFloat = 12) {
        self.imageSize = imageSize
        let avail = CGSize(width: max(viewSize.width - 2 * inset, 1), height: max(viewSize.height - 2 * inset, 1))
        guard imageSize.width > 0, imageSize.height > 0 else { fitted = CGRect(x: inset, y: inset, width: avail.width, height: avail.height); return }
        let s = min(avail.width / imageSize.width, avail.height / imageSize.height)
        let size = CGSize(width: imageSize.width * s, height: imageSize.height * s)
        fitted = CGRect(x: inset + (avail.width - size.width) / 2, y: inset + (avail.height - size.height) / 2, width: size.width, height: size.height)
    }

    func toView(_ r: CGRect) -> CGRect {
        CGRect(x: fitted.minX + r.minX * scale, y: fitted.minY + r.minY * scale, width: r.width * scale, height: r.height * scale)
    }
    func toImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - fitted.minX) / scale, y: (p.y - fitted.minY) / scale)
    }
    func clampToImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), imageSize.width), y: min(max(p.y, 0), imageSize.height))
    }
}

enum RectHandle: CaseIterable, Identifiable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    var id: Self { self }
    var movesLeft: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
    var movesRight: Bool { [.topRight, .right, .bottomRight].contains(self) }
    var movesTop: Bool { [.topLeft, .top, .topRight].contains(self) }
    var movesBottom: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }
    var isCorner: Bool { (movesLeft || movesRight) && (movesTop || movesBottom) }

    func position(in r: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .top: return CGPoint(x: r.midX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .right: return CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: return CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .left: return CGPoint(x: r.minX, y: r.midY)
        }
    }
}

enum RectMath {
    static func moved(_ start: CGRect, by d: CGSize, in bounds: CGRect) -> CGRect {
        var r = start
        r.origin.x = min(max(start.minX + d.width, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(start.minY + d.height, bounds.minY), bounds.maxY - r.height)
        return r
    }

    /// Resizes `start` by dragging `handle` by `delta`, keeping the rect inside `bounds` and, when given, an aspect ratio.
    static func resized(_ start: CGRect, handle h: RectHandle, by delta: CGSize, in bounds: CGRect, aspect: CGFloat?, minSize: CGFloat = 12) -> CGRect {
        var minX = start.minX, minY = start.minY, maxX = start.maxX, maxY = start.maxY
        if h.movesLeft { minX = min(max(bounds.minX, start.minX + delta.width), maxX - minSize) }
        if h.movesRight { maxX = max(min(bounds.maxX, start.maxX + delta.width), minX + minSize) }
        if h.movesTop { minY = min(max(bounds.minY, start.minY + delta.height), maxY - minSize) }
        if h.movesBottom { maxY = max(min(bounds.maxY, start.maxY + delta.height), minY + minSize) }
        let free = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard let aspect, aspect > 0 else { return free }

        if h.isCorner {
            let ax = h.movesLeft ? free.maxX : free.minX
            let ay = h.movesTop ? free.maxY : free.minY
            let maxW = h.movesLeft ? ax - bounds.minX : bounds.maxX - ax
            let maxH = h.movesTop ? ay - bounds.minY : bounds.maxY - ay
            var w = max(free.width, minSize)
            w = min(w, maxW, maxH * aspect)
            let hgt = w / aspect
            return CGRect(x: h.movesLeft ? ax - w : ax, y: h.movesTop ? ay - hgt : ay, width: w, height: hgt)
        } else if h.movesLeft || h.movesRight {
            let ax = h.movesLeft ? free.maxX : free.minX
            let maxW = h.movesLeft ? ax - bounds.minX : bounds.maxX - ax
            var w = min(max(free.width, minSize), maxW, bounds.height * aspect)
            var hgt = w / aspect
            var y = min(max(start.midY - hgt / 2, bounds.minY), bounds.maxY - hgt)
            if y + hgt > bounds.maxY { hgt = bounds.maxY - y; w = hgt * aspect }
            return CGRect(x: h.movesLeft ? ax - w : ax, y: y, width: w, height: hgt)
        } else {
            let ay = h.movesTop ? free.maxY : free.minY
            let maxH = h.movesTop ? ay - bounds.minY : bounds.maxY - ay
            var hgt = min(max(free.height, minSize), maxH, bounds.width / aspect)
            var w = hgt * aspect
            let x = min(max(start.midX - w / 2, bounds.minX), bounds.maxX - w)
            if x + w > bounds.maxX { w = bounds.maxX - x; hgt = w / aspect }
            return CGRect(x: x, y: h.movesTop ? ay - hgt : ay, width: w, height: hgt)
        }
    }

    /// Largest centred rect with the given aspect inside `size` (nil aspect = the whole image).
    static func centered(aspect: CGFloat?, in size: CGSize) -> CGRect {
        guard let aspect, aspect > 0 else { return CGRect(origin: .zero, size: size) }
        var w = size.width, h = w / aspect
        if h > size.height { h = size.height; w = h * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// Rect transforms that follow a visual quarter turn clockwise or a flip of an image of `size`.
    static func rotatedClockwise(_ r: CGRect, size: CGSize) -> CGRect {
        CGRect(x: size.height - r.maxY, y: r.minX, width: r.height, height: r.width)
    }
    static func rotatedCounterclockwise(_ r: CGRect, size: CGSize) -> CGRect {
        CGRect(x: r.minY, y: size.width - r.maxX, width: r.height, height: r.width)
    }
    static func flippedHorizontally(_ r: CGRect, size: CGSize) -> CGRect {
        CGRect(x: size.width - r.maxX, y: r.minY, width: r.width, height: r.height)
    }
    static func flippedVertically(_ r: CGRect, size: CGSize) -> CGRect {
        CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height)
    }
}

/// Eight drag handles plus a move area for one rectangle, in canvas coordinates.
struct RectHandlesOverlay: View {
    let geometry: CanvasGeometry
    @Binding var rect: CGRect
    var aspect: CGFloat? = nil
    var color: Color = .white
    @State private var dragStart: CGRect? = nil

    var body: some View {
        let r = geometry.toView(rect)
        let bounds = CGRect(origin: .zero, size: geometry.imageSize)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .frame(width: max(r.width, 1), height: max(r.height, 1))
                .position(x: r.midX, y: r.midY)
                .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                    if dragStart == nil { dragStart = rect }
                    rect = RectMath.moved(dragStart!, by: CGSize(width: v.translation.width / geometry.scale, height: v.translation.height / geometry.scale), in: bounds)
                }.onEnded { _ in dragStart = nil })
            Rectangle().stroke(color, lineWidth: 1.5).frame(width: max(r.width, 1), height: max(r.height, 1)).position(x: r.midX, y: r.midY).allowsHitTesting(false)
            ForEach(RectHandle.allCases) { h in
                let p = h.position(in: r)
                Circle()
                    .fill(color)
                    .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 0.5))
                    .frame(width: 11, height: 11)
                    .contentShape(Circle().scale(2))
                    .position(x: p.x, y: p.y)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        if dragStart == nil { dragStart = rect }
                        rect = RectMath.resized(dragStart!, handle: h, by: CGSize(width: v.translation.width / geometry.scale, height: v.translation.height / geometry.scale), in: bounds, aspect: aspect)
                    }.onEnded { _ in dragStart = nil })
            }
        }
    }
}
