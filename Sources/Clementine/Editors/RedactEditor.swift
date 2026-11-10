import AppKit
import SwiftUI
import Vision
import UniformTypeIdentifiers

struct RedactRegion: Identifiable, Equatable {
    let id: UUID
    var rect: CGRect
    var style: RedactStyle
}

struct RedactSpec: @unchecked Sendable {
    let url: URL
    let regions: [(CGRect, RedactStyle)]
    let type: UTType
}

@MainActor
final class RedactModel: ObservableObject {
    let file: FileItem
    @Published private(set) var picture: EditablePicture?
    @Published var regions: [RedactRegion] = [] { didSet { requestRender() } }
    @Published var selected: UUID?
    @Published var style: RedactStyle = .pixelate {
        didSet { if let i = regions.firstIndex(where: { $0.id == selected }) { regions[i].style = style } }
    }
    @Published private(set) var preview: CGImage?
    @Published var draft: CGRect?
    @Published var searchText = ""
    @Published var status: String?
    @Published var isBusy = false
    @Published var outputFormat: EditOutputFormat = .same
    @Published var error: String?
    private var undoStack: [[RedactRegion]] = []
    private let coalescer = RenderCoalescer()
    private let renderQueue = DispatchQueue(label: "clementine.redact.render", qos: .userInteractive)

    var imageSize: CGSize { picture?.fullSize ?? .zero }

    init(file: FileItem) {
        self.file = file
        let url = file.url
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try EditablePicture.load(url) }
            Task { @MainActor in
                switch result {
                case .success(let p): self.picture = p; self.requestRender()
                case .failure(let e): self.error = e.localizedDescription
                }
            }
        }
    }

    func requestRender() {
        guard let p = picture else { return }
        let g = coalescer.next()
        let rects = regions.map { ($0.rect, $0.style) }
        let coalescer = self.coalescer
        renderQueue.async {
            guard coalescer.isCurrent(g) else { return }
            let img = CIPipeline.redacted(p.preview, rects: rects, scale: p.previewScale)
            let cg = CIPipeline.render(img, colorSpace: nil)
            Task { @MainActor in
                if coalescer.isCurrent(g) { self.preview = cg }
            }
        }
    }

    private func pushUndo() {
        undoStack.append(regions)
        if undoStack.count > 50 { undoStack.removeFirst() }
    }

    func add(_ rect: CGRect) {
        let r = rect.intersection(CGRect(origin: .zero, size: imageSize))
        guard r.width >= 3, r.height >= 3 else { return }
        pushUndo()
        let region = RedactRegion(id: UUID(), rect: r, style: style)
        regions.append(region)
        selected = region.id
    }

    func add(rects: [CGRect], label: String) {
        guard !rects.isEmpty else { status = "No \(label) found"; return }
        pushUndo()
        for r in rects {
            let clipped = r.intersection(CGRect(origin: .zero, size: imageSize))
            if clipped.width >= 2, clipped.height >= 2 { regions.append(RedactRegion(id: UUID(), rect: clipped, style: style)) }
        }
        status = "\(rects.count) \(label) added"
    }

    func deleteSelected() {
        guard let s = selected else { return }
        pushUndo()
        regions.removeAll { $0.id == s }
        selected = nil
    }

    func clearAll() {
        guard !regions.isEmpty else { return }
        pushUndo()
        regions.removeAll()
        selected = nil
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        regions = last
        if let s = selected, !regions.contains(where: { $0.id == s }) { selected = nil }
    }

    func binding(for id: UUID) -> Binding<CGRect> {
        Binding(get: { self.regions.first { $0.id == id }?.rect ?? .zero },
                set: { r in if let i = self.regions.firstIndex(where: { $0.id == id }) { self.regions[i].rect = r } })
    }

    // MARK: Detection

    func detectFaces() {
        runDetection(label: "faces") { image, size in
            let request = VNDetectFaceRectanglesRequest()
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            return (request.results ?? []).map { obs in
                RedactModel.rect(from: obs.boundingBox, in: size).insetBy(dx: -obs.boundingBox.width * size.width * 0.2,
                                                                          dy: -obs.boundingBox.height * size.height * 0.25)
            }
        }
    }

    /// Empty query redacts every line of text; otherwise only the matching words.
    func detectText(matching query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        runDetection(label: q.isEmpty ? "text lines" : "matches for “\(q)”") { image, size in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.006
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            var rects: [CGRect] = []
            for obs in request.results ?? [] {
                guard let candidate = obs.topCandidates(1).first else { continue }
                if q.isEmpty {
                    rects.append(RedactModel.rect(from: obs.boundingBox, in: size).insetBy(dx: -2, dy: -2))
                    continue
                }
                var searchRange = candidate.string.startIndex..<candidate.string.endIndex
                while let found = candidate.string.range(of: q, options: .caseInsensitive, range: searchRange) {
                    let box = (try? candidate.boundingBox(for: found))?.boundingBox ?? obs.boundingBox
                    rects.append(RedactModel.rect(from: box, in: size).insetBy(dx: -3, dy: -3))
                    searchRange = found.upperBound..<candidate.string.endIndex
                }
            }
            return rects
        }
    }

    private func runDetection(label: String, _ detect: @escaping (CGImage, CGSize) throws -> [CGRect]) {
        guard !isBusy, let fullSize = picture?.fullSize else { return }
        isBusy = true
        status = "Looking for \(label)…"
        let url = file.url
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result<[CGRect], Error> {
                let loaded = try ImageConverter.load(url, maxPixel: 3000)
                let scale = fullSize.width / CGFloat(loaded.image.width)
                let rects = try detect(loaded.image, CGSize(width: loaded.image.width, height: loaded.image.height))
                return rects.map { CGRect(x: $0.minX * scale, y: $0.minY * scale, width: $0.width * scale, height: $0.height * scale) }
            }
            Task { @MainActor in
                self.isBusy = false
                switch result {
                case .success(let rects): self.add(rects: rects, label: label)
                case .failure(let e): self.status = e.localizedDescription
                }
            }
        }
    }

    /// Vision boxes are normalised with a bottom-left origin.
    nonisolated static func rect(from box: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height, width: box.width * size.width, height: box.height * size.height)
    }

    // MARK: Export

    var outputType: UTType {
        if let t = outputFormat.utType { return t }
        let t = ImageConverter.writableType(for: file) ?? .jpeg
        return t == .gif ? .png : t
    }

    func spec() -> RedactSpec {
        RedactSpec(url: file.url, regions: regions.map { ($0.rect, $0.style) }, type: outputType)
    }

    /// Full-resolution burn-in; metadata is always dropped so nothing leaks through EXIF or thumbnails.
    nonisolated static func export(_ s: RedactSpec) throws -> URL {
        let loaded = try ImageConverter.load(s.url)
        let img = CIPipeline.redacted(CIImage(cgImage: loaded.image), rects: s.regions, scale: 1)
        guard let cg = CIPipeline.render(img, colorSpace: loaded.image.colorSpace) else { throw ClementineError.cannotRead(s.url) }
        let dest = Output.sibling(of: s.url, ext: ImageConverter.ext(for: s.type), suffix: "Redacted")
        return try Output.write(to: dest) { tmp in
            try ImageConverter.write(cg, to: tmp, type: s.type, quality: 0.92, properties: nil)
            // ImageIO still writes a minimal EXIF (orientation, size); drop it losslessly where we can.
            if let data = try? Data(contentsOf: tmp) {
                if s.type == .png, let stripped = LosslessStrip.png(data) { try stripped.write(to: tmp) }
                if s.type == .jpeg, let stripped = LosslessStrip.jpeg(data, orientation: 1) { try stripped.write(to: tmp) }
            }
        }
    }
}

struct RedactEditorView: View {
    @ObservedObject var model: RedactModel
    unowned let controller: EditorWindowController
    @State private var dragOrigin: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                canvas
                Divider()
                sidebar.frame(width: 290)
            }
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 520)
    }

    private var canvas: some View {
        GeometryReader { geo in
            let size = model.imageSize
            let g = CanvasGeometry(imageSize: size, in: geo.size, inset: 20)
            ZStack(alignment: .topLeading) {
                Color(nsColor: .underPageBackgroundColor)
                if let cg = model.preview, size.width > 0 {
                    Image(decorative: cg, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: g.fitted.width, height: g.fitted.height)
                        .position(x: g.fitted.midX, y: g.fitted.midY)
                        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("redactCanvas")).onChanged { v in
                            let start = g.clampToImage(g.toImage(v.startLocation))
                            let cur = g.clampToImage(g.toImage(v.location))
                            model.draft = CGRect(x: min(start.x, cur.x), y: min(start.y, cur.y), width: abs(cur.x - start.x), height: abs(cur.y - start.y))
                        }.onEnded { _ in
                            if let d = model.draft { model.add(d) }
                            model.draft = nil
                        })
                        .onTapGesture { model.selected = nil }
                    ForEach(model.regions) { region in
                        if region.id != model.selected {
                            let r = g.toView(region.rect)
                            Rectangle()
                                .fill(Color.red.opacity(0.08))
                                .overlay(Rectangle().stroke(Color.red.opacity(0.9), lineWidth: 1))
                                .frame(width: max(r.width, 2), height: max(r.height, 2))
                                .position(x: r.midX, y: r.midY)
                                .contentShape(Rectangle())
                                .onTapGesture { model.selected = region.id; model.style = region.style }
                        }
                    }
                    if let s = model.selected, model.regions.contains(where: { $0.id == s }) {
                        RectHandlesOverlay(geometry: g, rect: model.binding(for: s), color: Color.clementine)
                    }
                    if let d = model.draft {
                        let r = g.toView(d)
                        Rectangle().stroke(Color.clementine, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                            .frame(width: max(r.width, 1), height: max(r.height, 1)).position(x: r.midX, y: r.midY).allowsHitTesting(false)
                    }
                } else if let e = model.error {
                    Text(e).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .coordinateSpace(name: "redactCanvas")
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Drag on the image to draw a region. Click a region to select it, then move or resize it.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Style").font(.headline)
                Picker("Style", selection: $model.style) {
                    ForEach(RedactStyle.allCases) { s in Label(s.label, systemImage: s.symbol).tag(s) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Text(model.style == .blur ? "Blur is the weakest option; prefer pixelate or solid for text." : "Applied at full resolution and flattened; metadata is removed on save.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Find automatically").font(.headline)
                Button { model.detectFaces() } label: { Label("Faces", systemImage: "face.smiling") }.disabled(model.isBusy)
                HStack {
                    TextField("Word or number…", text: $model.searchText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.detectText(matching: model.searchText) }
                    Button("Find") { model.detectText(matching: model.searchText) }.disabled(model.isBusy)
                }
                Button { model.detectText(matching: "") } label: { Label("All text", systemImage: "text.viewfinder") }.disabled(model.isBusy)
                if let s = model.status {
                    HStack(spacing: 6) {
                        if model.isBusy { ProgressView().controlSize(.small) }
                        Text(s).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Regions: \(model.regions.count)").font(.headline)
                HStack {
                    Button("Delete") { model.deleteSelected() }.keyboardShortcut(.delete, modifiers: []).disabled(model.selected == nil)
                    Button("Undo") { model.undo() }.keyboardShortcut("z", modifiers: .command)
                    Button("Clear") { model.clearAll() }.disabled(model.regions.isEmpty)
                }
                .controlSize(.small)
            }
            .padding(16)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Picker("Format", selection: $model.outputFormat) {
                ForEach(EditOutputFormat.offered) { f in Text(f.label).tag(f) }
            }
            .frame(maxWidth: 220)
            Spacer()
            Text("Saves as “\(model.file.baseName) Redacted.\(ImageConverter.ext(for: model.outputType))”, metadata removed")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Button("Cancel") { controller.dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save") {
                let spec = model.spec()
                EditorManager.shared.save(title: "Redact", source: model.file.url) { try RedactModel.export(spec) }
                controller.dismiss()
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .tint(Color.clementine)
            .disabled(model.regions.isEmpty)
        }
        .padding(12)
    }
}
