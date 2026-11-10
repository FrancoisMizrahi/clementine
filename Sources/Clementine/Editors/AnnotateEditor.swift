import AppKit
import CoreText
import SwiftUI
import UniformTypeIdentifiers

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select, arrow, line, rectangle, ellipse, pen, highlighter, text, number, magnifier
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .number: return "1.circle"
        case .magnifier: return "plus.magnifyingglass"
        }
    }
    var help: String { rawValue.capitalized }
}

struct Annotation: Identifiable, Equatable {
    enum Kind: Equatable { case arrow, line, rectangle, ellipse, pen, highlighter, text, number, magnifier }
    let id: UUID
    var kind: Kind
    var points: [CGPoint]      // arrow/line: 2 points; pen/highlighter: path; others: unused
    var rect: CGRect           // rectangle/ellipse/text/number/magnifier
    var color: CGColor
    var strokeWidth: CGFloat
    var text: String = ""
    var fontSize: CGFloat = 24
    var number: Int = 0

    static func == (a: Annotation, b: Annotation) -> Bool {
        a.id == b.id && a.kind == b.kind && a.points == b.points && a.rect == b.rect && a.strokeWidth == b.strokeWidth
            && a.text == b.text && a.fontSize == b.fontSize && a.number == b.number && a.color == b.color
    }

    var isRectBased: Bool { [.rectangle, .ellipse, .text, .number, .magnifier].contains(kind) }
    var bounds: CGRect {
        switch kind {
        case .arrow, .line, .pen, .highlighter:
            guard let first = points.first else { return rect }
            return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        default: return rect
        }
    }

    mutating func translate(by d: CGSize) {
        points = points.map { CGPoint(x: $0.x + d.width, y: $0.y + d.height) }
        rect = rect.offsetBy(dx: d.width, dy: d.height)
    }

    func hitTest(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        switch kind {
        case .arrow, .line:
            guard points.count == 2 else { return false }
            return Annotation.distance(from: p, toSegment: points[0], points[1]) <= tolerance + strokeWidth
        case .pen, .highlighter:
            guard points.count > 1 else { return false }
            for i in 1..<points.count where Annotation.distance(from: p, toSegment: points[i - 1], points[i]) <= tolerance + strokeWidth { return true }
            return false
        case .ellipse, .magnifier, .number:
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let rx = rect.width / 2 + tolerance, ry = rect.height / 2 + tolerance
            guard rx > 0, ry > 0 else { return false }
            let dx = (p.x - c.x) / rx, dy = (p.y - c.y) / ry
            return dx * dx + dy * dy <= 1
        default:
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

/// Draws annotations into any CGContext whose CTM maps image pixel coordinates (y down) to the device.
/// The same routine feeds the SwiftUI canvas and the full-resolution export.
enum AnnotationRenderer {
    static func draw(_ items: [Annotation], in ctx: CGContext, source: CGImage?, sourceScale: CGFloat) {
        for a in items { draw(a, in: ctx, source: source, sourceScale: sourceScale) }
    }

    static func draw(_ a: Annotation, in ctx: CGContext, source: CGImage?, sourceScale: CGFloat) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(a.color)
        ctx.setFillColor(a.color)
        ctx.setLineWidth(a.strokeWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch a.kind {
        case .line:
            guard a.points.count == 2 else { return }
            ctx.move(to: a.points[0]); ctx.addLine(to: a.points[1]); ctx.strokePath()
        case .arrow:
            guard a.points.count == 2 else { return }
            let (s, e) = (a.points[0], a.points[1])
            let angle = atan2(e.y - s.y, e.x - s.x)
            let head = max(a.strokeWidth * 4, 10)
            let back = CGPoint(x: e.x - cos(angle) * head * 0.8, y: e.y - sin(angle) * head * 0.8)
            ctx.move(to: s); ctx.addLine(to: back); ctx.strokePath()
            let left = CGPoint(x: e.x - cos(angle - .pi / 6) * head, y: e.y - sin(angle - .pi / 6) * head)
            let right = CGPoint(x: e.x - cos(angle + .pi / 6) * head, y: e.y - sin(angle + .pi / 6) * head)
            ctx.move(to: e); ctx.addLine(to: left); ctx.addLine(to: right); ctx.closePath(); ctx.fillPath()
        case .rectangle:
            ctx.stroke(a.rect.insetBy(dx: a.strokeWidth / 2, dy: a.strokeWidth / 2))
        case .ellipse:
            ctx.strokeEllipse(in: a.rect.insetBy(dx: a.strokeWidth / 2, dy: a.strokeWidth / 2))
        case .pen, .highlighter:
            guard a.points.count > 1 else { return }
            if a.kind == .highlighter {
                ctx.setBlendMode(.multiply)
                ctx.setStrokeColor(a.color.copy(alpha: 0.45) ?? a.color)
                ctx.setLineWidth(a.strokeWidth * 4)
                ctx.setLineCap(.square)
            }
            ctx.move(to: a.points[0])
            for p in a.points.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
        case .number:
            let r = a.rect
            ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: r.width * 0.08, color: CGColor(gray: 0, alpha: 0.35))
            ctx.fillEllipse(in: r)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            drawText("\(a.number)", in: r, fontSize: r.height * 0.58, color: CGColor(gray: 1, alpha: 1), bold: true, centered: true, ctx: ctx)
        case .text:
            ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: a.fontSize * 0.08, color: CGColor(gray: 0, alpha: 0.6))
            drawText(a.text.isEmpty ? "Text" : a.text, in: a.rect, fontSize: a.fontSize, color: a.color, bold: true, centered: false, ctx: ctx)
        case .magnifier:
            guard let source else { return }
            let r = a.rect
            let zoom: CGFloat = 2
            let srcRect = CGRect(x: r.midX - r.width / zoom / 2, y: r.midY - r.height / zoom / 2, width: r.width / zoom, height: r.height / zoom)
            let pixelRect = CGRect(x: srcRect.minX * sourceScale, y: srcRect.minY * sourceScale, width: srcRect.width * sourceScale, height: srcRect.height * sourceScale).integral
            if let crop = source.cropping(to: pixelRect) {
                ctx.saveGState()
                ctx.addEllipse(in: r); ctx.clip()
                ctx.translateBy(x: 0, y: r.maxY + r.minY); ctx.scaleBy(x: 1, y: -1)
                ctx.interpolationQuality = .high
                ctx.draw(crop, in: r)
                ctx.restoreGState()
            }
            ctx.setLineWidth(a.strokeWidth)
            ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: a.strokeWidth * 2, color: CGColor(gray: 0, alpha: 0.4))
            ctx.strokeEllipse(in: r.insetBy(dx: a.strokeWidth / 2, dy: a.strokeWidth / 2))
        }
    }

    private static func drawText(_ string: String, in rect: CGRect, fontSize: CGFloat, color: CGColor, bold: Bool, centered: Bool, ctx: CGContext) {
        let font = bold ? NSFont.boldSystemFont(ofSize: fontSize) : NSFont.systemFont(ofSize: fontSize)
        let para = NSMutableParagraphStyle()
        para.alignment = centered ? .center : .left
        let attr = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color) ?? .white, .paragraphStyle: para])
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        var box = rect
        if centered {
            let needed = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil, CGSize(width: rect.width, height: .greatestFiniteMagnitude), nil)
            box = CGRect(x: rect.minX, y: rect.midY - needed.height / 2, width: rect.width, height: needed.height)
        }
        ctx.saveGState()
        ctx.translateBy(x: box.minX, y: box.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: box.width, height: box.height), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }
}

struct AnnotateSpec: @unchecked Sendable {
    let url: URL
    let items: [Annotation]
    let type: UTType
    let keepMetadata: Bool
}

@MainActor
final class AnnotateModel: ObservableObject {
    let file: FileItem
    @Published private(set) var picture: EditablePicture?
    @Published private(set) var previewImage: CGImage?
    @Published var items: [Annotation] = []
    @Published var selected: UUID?
    @Published var tool: AnnotationTool = .arrow
    @Published var colorIndex = 0
    @Published var widthIndex = 1
    @Published var fontIndex = 1
    @Published var draft: Annotation?
    @Published var outputFormat: EditOutputFormat = .same
    @Published var keepMetadata = true
    @Published var error: String?
    private var undoStack: [[Annotation]] = []

    static let palette: [(String, CGColor)] = [
        ("Red", CGColor(red: 0.95, green: 0.2, blue: 0.2, alpha: 1)),
        ("Orange", CGColor(red: 1.0, green: 0.55, blue: 0.15, alpha: 1)),
        ("Yellow", CGColor(red: 1.0, green: 0.85, blue: 0.1, alpha: 1)),
        ("Green", CGColor(red: 0.2, green: 0.75, blue: 0.3, alpha: 1)),
        ("Blue", CGColor(red: 0.15, green: 0.5, blue: 0.95, alpha: 1)),
        ("Purple", CGColor(red: 0.6, green: 0.3, blue: 0.9, alpha: 1)),
        ("Black", CGColor(gray: 0.08, alpha: 1)),
        ("White", CGColor(gray: 1, alpha: 1)),
    ]

    var imageSize: CGSize { picture?.fullSize ?? .zero }
    private var unit: CGFloat { max(imageSize.width, imageSize.height) / 400 } // 1 unit ≈ 2.5 px on a 1000 px image
    var strokeWidth: CGFloat { unit * [0.9, 1.6, 2.6, 4.5][widthIndex] }
    var fontSize: CGFloat { unit * [6, 9, 13, 20][fontIndex] }
    var color: CGColor { AnnotateModel.palette[colorIndex].1 }
    var selectedItem: Annotation? { items.first { $0.id == selected } }

    init(file: FileItem) {
        self.file = file
        let url = file.url
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () -> (EditablePicture, CGImage?) in
                let p = try EditablePicture.load(url)
                return (p, CIPipeline.render(p.preview, colorSpace: nil))
            }
            Task { @MainActor in
                switch result {
                case .success(let (p, img)): self.picture = p; self.previewImage = img
                case .failure(let e): self.error = e.localizedDescription
                }
            }
        }
    }

    private func pushUndo() {
        undoStack.append(items)
        if undoStack.count > 60 { undoStack.removeFirst() }
    }
    func undo() {
        guard let last = undoStack.popLast() else { return }
        items = last
        if let s = selected, !items.contains(where: { $0.id == s }) { selected = nil }
    }
    func deleteSelected() {
        guard let s = selected else { return }
        pushUndo()
        items.removeAll { $0.id == s }
        selected = nil
    }
    func clearAll() {
        guard !items.isEmpty else { return }
        pushUndo()
        items.removeAll()
        selected = nil
    }

    // MARK: Gestures (image coordinates)

    private var dragOrigin: CGPoint?
    private var dragSnapshot: Annotation?

    func dragChanged(start: CGPoint, current: CGPoint) {
        let bounds = CGRect(origin: .zero, size: imageSize)
        let s = clamp(start, bounds), c = clamp(current, bounds)
        switch tool {
        case .select:
            if dragOrigin == nil {
                dragOrigin = s
                if let hit = hit(at: s) { selected = hit.id; dragSnapshot = hit } else { selected = nil; dragSnapshot = nil }
            }
            if var snap = dragSnapshot, let i = items.firstIndex(where: { $0.id == snap.id }) {
                snap.translate(by: CGSize(width: c.x - s.x, height: c.y - s.y))
                if items[i] != snap, dragSnapshot?.id == snap.id, undoStack.last != items { if !(undoStack.last.map { $0 == items } ?? false) { pushUndo() } }
                items[i] = snap
            }
        case .arrow, .line:
            draft = Annotation(id: draft?.id ?? UUID(), kind: tool == .arrow ? .arrow : .line, points: [s, c], rect: .zero, color: color, strokeWidth: strokeWidth)
        case .rectangle, .ellipse, .magnifier:
            var r = CGRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(c.x - s.x), height: abs(c.y - s.y))
            if tool == .magnifier { let d = max(r.width, r.height); r = CGRect(x: s.x - d / 2, y: s.y - d / 2, width: d, height: d) }
            let kind: Annotation.Kind = tool == .rectangle ? .rectangle : (tool == .ellipse ? .ellipse : .magnifier)
            draft = Annotation(id: draft?.id ?? UUID(), kind: kind, points: [], rect: r, color: color, strokeWidth: strokeWidth)
        case .pen, .highlighter:
            if draft == nil {
                draft = Annotation(id: UUID(), kind: tool == .pen ? .pen : .highlighter, points: [s], rect: .zero, color: color, strokeWidth: strokeWidth)
            }
            if let last = draft?.points.last, hypot(last.x - c.x, last.y - c.y) > unit * 0.6 { draft?.points.append(c) }
        case .text, .number:
            break // placed on release
        }
    }

    func dragEnded(start: CGPoint, end: CGPoint) {
        let bounds = CGRect(origin: .zero, size: imageSize)
        let s = clamp(start, bounds), e = clamp(end, bounds)
        defer { dragOrigin = nil; dragSnapshot = nil; draft = nil }
        switch tool {
        case .select:
            return
        case .text:
            pushUndo()
            let w = max(abs(e.x - s.x), fontSize * 8), h = max(abs(e.y - s.y), fontSize * 1.6)
            let item = Annotation(id: UUID(), kind: .text, points: [], rect: CGRect(x: min(s.x, e.x), y: min(s.y, e.y), width: w, height: h),
                                  color: color, strokeWidth: strokeWidth, text: "", fontSize: fontSize)
            items.append(item); selected = item.id
        case .number:
            pushUndo()
            let d = fontSize * 2.2
            let n = (items.filter { $0.kind == .number }.map(\.number).max() ?? 0) + 1
            let item = Annotation(id: UUID(), kind: .number, points: [], rect: CGRect(x: e.x - d / 2, y: e.y - d / 2, width: d, height: d),
                                  color: color, strokeWidth: strokeWidth, number: n)
            items.append(item); selected = item.id
        default:
            guard let d = draft else { return }
            let big = d.bounds.width > unit * 2 || d.bounds.height > unit * 2 || d.points.count > 3
            guard big else { return }
            pushUndo()
            items.append(d); selected = d.id
        }
    }

    func hit(at p: CGPoint) -> Annotation? {
        items.reversed().first { $0.hitTest(p, tolerance: unit * 3) }
    }

    private func clamp(_ p: CGPoint, _ b: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, b.minX), b.maxX), y: min(max(p.y, b.minY), b.maxY))
    }

    func rectBinding(for id: UUID) -> Binding<CGRect> {
        Binding(get: { self.items.first { $0.id == id }?.rect ?? .zero },
                set: { r in if let i = self.items.firstIndex(where: { $0.id == id }) { self.items[i].rect = r } })
    }
    func pointBinding(for id: UUID, index: Int) -> Binding<CGPoint> {
        Binding(get: { self.items.first { $0.id == id }.map { $0.points.indices.contains(index) ? $0.points[index] : .zero } ?? .zero },
                set: { p in if let i = self.items.firstIndex(where: { $0.id == id }), self.items[i].points.indices.contains(index) { self.items[i].points[index] = p } })
    }
    var selectedText: Binding<String> {
        Binding(get: { self.selectedItem?.text ?? "" },
                set: { t in if let i = self.items.firstIndex(where: { $0.id == self.selected }) { self.items[i].text = t } })
    }
    func applyStyleToSelection() {
        guard let i = items.firstIndex(where: { $0.id == selected }) else { return }
        items[i].color = color
        items[i].strokeWidth = strokeWidth
        if items[i].kind == .text { items[i].fontSize = fontSize }
    }

    // MARK: Export

    var outputType: UTType {
        if let t = outputFormat.utType { return t }
        return ImageConverter.writableType(for: file) == .gif ? .png : (ImageConverter.writableType(for: file) ?? .jpeg)
    }
    func spec() -> AnnotateSpec { AnnotateSpec(url: file.url, items: items, type: outputType, keepMetadata: keepMetadata) }

    nonisolated static func export(_ s: AnnotateSpec) throws -> URL {
        let loaded = try ImageConverter.load(s.url)
        let img = loaded.image
        guard let c = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ClementineError.cannotRead(s.url) }
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        c.translateBy(x: 0, y: CGFloat(img.height))
        c.scaleBy(x: 1, y: -1)
        AnnotationRenderer.draw(s.items, in: c, source: img, sourceScale: 1)
        guard let out = c.makeImage() else { throw ClementineError.noOutput }
        let dest = Output.sibling(of: s.url, ext: ImageConverter.ext(for: s.type), suffix: "Annotated")
        return try Output.write(to: dest) { tmp in
            try ImageConverter.write(out, to: tmp, type: s.type, quality: max(Settings.shared.imageQuality, 0.9),
                                     properties: s.keepMetadata ? ImageConverter.metadataOnly(loaded.properties) : nil)
        }
    }
}

struct AnnotateEditorView: View {
    @ObservedObject var model: AnnotateModel
    unowned let controller: EditorWindowController
    @FocusState private var textFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                canvas
                Divider()
                sidebar.frame(width: 250)
            }
            Divider()
            footer
        }
        .frame(minWidth: 860, minHeight: 540)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            ForEach(AnnotationTool.allCases) { t in
                Button { model.tool = t } label: {
                    Image(systemName: t.symbol).font(.system(size: 14)).frame(width: 30, height: 24)
                }
                .buttonStyle(.bordered)
                .tint(model.tool == t ? Color.clementine : nil)
                .help(t.help)
                .keyboardShortcut(KeyEquivalent(Character(String(AnnotationTool.allCases.firstIndex(of: t)! + 1 > 9 ? "0" : String(AnnotationTool.allCases.firstIndex(of: t)! + 1)))), modifiers: .command)
            }
            Divider().frame(height: 20)
            ForEach(Array(AnnotateModel.palette.enumerated()), id: \.offset) { i, entry in
                Circle().fill(Color(cgColor: entry.1))
                    .overlay(Circle().stroke(model.colorIndex == i ? Color.primary : Color.primary.opacity(0.2), lineWidth: model.colorIndex == i ? 2 : 1))
                    .frame(width: 18, height: 18)
                    .onTapGesture { model.colorIndex = i; model.applyStyleToSelection() }
                    .help(entry.0)
            }
            Divider().frame(height: 20)
            Picker("", selection: $model.widthIndex) {
                ForEach(0..<4, id: \.self) { i in Image(systemName: ["minus", "equal", "line.3.horizontal", "line.3.horizontal.decrease"][i]).tag(i) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            .onChange(of: model.widthIndex) { _, _ in model.applyStyleToSelection() }
            Spacer()
            Button("Undo") { model.undo() }.keyboardShortcut("z", modifiers: .command)
            Button("Delete") { model.deleteSelected() }.keyboardShortcut(.delete, modifiers: []).disabled(model.selected == nil)
        }
        .padding(8)
    }

    private var canvas: some View {
        GeometryReader { geo in
            let size = model.imageSize
            let g = CanvasGeometry(imageSize: size, in: geo.size, inset: 20)
            ZStack(alignment: .topLeading) {
                Color(nsColor: .underPageBackgroundColor)
                if let cg = model.previewImage, size.width > 0, let pic = model.picture {
                    Image(decorative: cg, scale: 1).resizable().interpolation(.high)
                        .frame(width: g.fitted.width, height: g.fitted.height)
                        .position(x: g.fitted.midX, y: g.fitted.midY)
                    Canvas { context, _ in
                        context.withCGContext { cg in
                            cg.translateBy(x: g.fitted.minX, y: g.fitted.minY)
                            cg.scaleBy(x: g.scale, y: g.scale)
                            AnnotationRenderer.draw(model.items, in: cg, source: model.previewImage, sourceScale: pic.previewScale)
                            if let d = model.draft { AnnotationRenderer.draw(d, in: cg, source: model.previewImage, sourceScale: pic.previewScale) }
                        }
                    }
                    .allowsHitTesting(false)
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .frame(width: g.fitted.width, height: g.fitted.height)
                        .position(x: g.fitted.midX, y: g.fitted.midY)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("annotateCanvas"))
                            .onChanged { v in model.dragChanged(start: g.toImage(v.startLocation), current: g.toImage(v.location)) }
                            .onEnded { v in model.dragEnded(start: g.toImage(v.startLocation), end: g.toImage(v.location)); if model.tool == .text { textFocused = true } })
                    if let sel = model.selectedItem, model.tool == .select {
                        if sel.isRectBased {
                            RectHandlesOverlay(geometry: g, rect: model.rectBinding(for: sel.id), aspect: sel.kind == .number || sel.kind == .magnifier ? 1 : nil, color: Color.clementine)
                        } else if sel.kind == .arrow || sel.kind == .line {
                            ForEach(0..<2, id: \.self) { i in
                                let p = model.pointBinding(for: sel.id, index: i)
                                let v = g.toView(CGRect(origin: p.wrappedValue, size: .zero)).origin
                                Circle().fill(Color.clementine).overlay(Circle().stroke(.white, lineWidth: 1)).frame(width: 12, height: 12)
                                    .position(x: v.x, y: v.y)
                                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("annotateCanvas")).onChanged { d in
                                        p.wrappedValue = g.clampToImage(g.toImage(d.location))
                                    })
                            }
                        } else {
                            let b = g.toView(sel.bounds.insetBy(dx: -4, dy: -4))
                            Rectangle().stroke(Color.clementine, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                .frame(width: max(b.width, 1), height: max(b.height, 1)).position(x: b.midX, y: b.midY).allowsHitTesting(false)
                        }
                    }
                } else if let e = model.error {
                    Text(e).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .coordinateSpace(name: "annotateCanvas")
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(hint).font(.caption).foregroundStyle(.secondary)
                if let sel = model.selectedItem, sel.kind == .text {
                    Text("Text").font(.headline)
                    TextField("Type here", text: model.selectedText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...6)
                        .focused($textFocused)
                    Picker("Size", selection: $model.fontIndex) {
                        ForEach(0..<4, id: \.self) { i in Text(["S", "M", "L", "XL"][i]).tag(i) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: model.fontIndex) { _, _ in model.applyStyleToSelection() }
                } else if model.tool == .text {
                    Text("Text size").font(.headline)
                    Picker("Size", selection: $model.fontIndex) {
                        ForEach(0..<4, id: \.self) { i in Text(["S", "M", "L", "XL"][i]).tag(i) }
                    }
                    .pickerStyle(.segmented)
                }
                Text("Shapes: \(model.items.count)").font(.headline)
                Button("Clear all") { model.clearAll() }.controlSize(.small).disabled(model.items.isEmpty)
                Text("⌘1–⌘9 switch tools, ⌫ deletes, ⌘Z undoes. Shapes render at full resolution on save.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
        }
    }

    private var hint: String {
        switch model.tool {
        case .select: return "Click a shape to select it, drag to move it. Handles resize boxes, circles and lines."
        case .arrow, .line: return "Drag from the tail to the head."
        case .rectangle, .ellipse: return "Drag to draw."
        case .pen: return "Draw freehand."
        case .highlighter: return "Paint a translucent highlight."
        case .text: return "Click or drag a box, then type in the field below."
        case .number: return "Click to drop numbered steps."
        case .magnifier: return "Drag to place a 2× magnifier bubble."
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Picker("Format", selection: $model.outputFormat) {
                ForEach(EditOutputFormat.offered) { f in Text(f.label).tag(f) }
            }
            .frame(maxWidth: 220)
            Toggle("Keep metadata", isOn: $model.keepMetadata)
            Spacer()
            Text("Saves as “\(model.file.baseName) Annotated.\(ImageConverter.ext(for: model.outputType))”")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Button("Cancel") { controller.dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save") {
                let spec = model.spec()
                EditorManager.shared.save(title: "Annotate", source: model.file.url) { try AnnotateModel.export(spec) }
                controller.dismiss()
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .tint(Color.clementine)
            .disabled(model.items.isEmpty)
        }
        .padding(12)
    }
}
