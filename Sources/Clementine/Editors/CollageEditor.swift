import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum CollageLayout: String, CaseIterable, Identifiable {
    case auto, two, three, row, column
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto grid"
        case .two: return "2 columns"
        case .three: return "3 columns"
        case .row: return "One row"
        case .column: return "One column"
        }
    }
    func columns(for count: Int) -> Int {
        switch self {
        case .auto: return max(1, Int(ceil(sqrt(Double(count)))))
        case .two: return min(2, count)
        case .three: return min(3, count)
        case .row: return count
        case .column: return 1
        }
    }
}

enum CollageBackground: String, CaseIterable, Identifiable {
    case white, black, transparent
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct CollageSpec: @unchecked Sendable {
    let urls: [URL]
    let layout: CollageLayout
    let gap: CGFloat
    let background: CollageBackground
    let fillCells: Bool
    let width: Int
    let type: UTType
}

@MainActor
final class CollageModel: ObservableObject {
    let files: [FileItem]
    @Published var layout: CollageLayout = .auto { didSet { requestPreview() } }
    @Published var gap: Double = 16 { didSet { requestPreview() } }
    @Published var background: CollageBackground = .white { didSet { requestPreview() } }
    @Published var fillCells = true { didSet { requestPreview() } }
    @Published var width = 2400
    @Published var format: EditOutputFormat = .jpeg
    @Published private(set) var preview: CGImage?
    @Published var error: String?
    private let coalescer = RenderCoalescer()
    private let queue = DispatchQueue(label: "clementine.collage.preview", qos: .userInitiated)
    private var cache: [CGImage]?

    init(files: [FileItem]) {
        self.files = files
        let urls = files.map(\.url)
        queue.async { [weak self] in
            let loaded = urls.compactMap { try? ImageConverter.load($0, maxPixel: 600).image }
            Task { @MainActor in self?.cache = loaded; self?.requestPreview() }
        }
    }

    func requestPreview() {
        guard let cache, !cache.isEmpty else { return }
        let g = coalescer.next()
        let spec = CollageSpec(urls: [], layout: layout, gap: CGFloat(gap) / 3, background: background, fillCells: fillCells, width: 800, type: .png)
        let coalescer = self.coalescer
        queue.async {
            guard coalescer.isCurrent(g) else { return }
            let img = try? CollageModel.compose(cache, spec)
            Task { @MainActor in if coalescer.isCurrent(g) { self.preview = img } }
        }
    }

    var outputType: UTType { background == .transparent ? .png : (format.utType ?? .jpeg) }

    func spec() -> CollageSpec {
        CollageSpec(urls: files.map(\.url), layout: layout, gap: CGFloat(gap), background: background, fillCells: fillCells, width: width, type: outputType)
    }

    nonisolated static func export(_ s: CollageSpec) throws -> URL {
        let images = try s.urls.map { try ImageConverter.load($0, maxPixel: s.width).image }
        let out = try compose(images, s)
        let dir = s.urls[0].deletingLastPathComponent()
        let dest = Output.unique(dir.appendingPathComponent("Collage").appendingPathExtension(ImageConverter.ext(for: s.type)))
        return try Output.write(to: dest) { tmp in
            try ImageConverter.write(out, to: tmp, type: s.type, quality: max(Settings.shared.imageQuality, 0.88), properties: nil)
        }
    }

    nonisolated static func compose(_ images: [CGImage], _ s: CollageSpec) throws -> CGImage {
        guard !images.isEmpty else { throw ClementineError.noOutput }
        let n = images.count
        let cols = s.layout.columns(for: n)
        let rows = Int(ceil(Double(n) / Double(cols)))
        let gap = s.gap
        let width = CGFloat(s.width)
        let cellW = (width - gap * CGFloat(cols + 1)) / CGFloat(cols)
        // Cell height: square when filling, otherwise the median aspect ratio of the sources.
        let aspects = images.map { CGFloat($0.width) / CGFloat($0.height) }.sorted()
        let median = aspects[aspects.count / 2]
        let cellH = s.fillCells ? cellW : cellW / max(median, 0.2)
        let height = cellH * CGFloat(rows) + gap * CGFloat(rows + 1)
        guard let c = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ClementineError.noOutput
        }
        switch s.background {
        case .white: c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: width, height: height))
        case .black: c.setFillColor(CGColor(gray: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: width, height: height))
        case .transparent: break
        }
        c.interpolationQuality = .high
        for (i, img) in images.enumerated() {
            let col = i % cols, row = i / cols
            // CG is y-up: first row goes at the top.
            let cell = CGRect(x: gap + CGFloat(col) * (cellW + gap), y: height - gap - CGFloat(row + 1) * cellH - CGFloat(row) * gap, width: cellW, height: cellH)
            let iw = CGFloat(img.width), ih = CGFloat(img.height)
            let scale = s.fillCells ? max(cellW / iw, cellH / ih) : min(cellW / iw, cellH / ih)
            let w = iw * scale, h = ih * scale
            let target = CGRect(x: cell.midX - w / 2, y: cell.midY - h / 2, width: w, height: h)
            c.saveGState()
            c.clip(to: cell)
            c.draw(img, in: target)
            c.restoreGState()
        }
        guard let out = c.makeImage() else { throw ClementineError.noOutput }
        return out
    }
}

struct CollageView: View {
    @ObservedObject var model: CollageModel
    unowned let controller: EditorWindowController

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let p = model.preview {
                    Image(decorative: p, scale: 1).resizable().aspectRatio(contentMode: .fit).padding(16)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                Text("\(model.files.count) images").font(.headline)
                Picker("Layout", selection: $model.layout) { ForEach(CollageLayout.allCases) { l in Text(l.label).tag(l) } }
                Picker("Cells", selection: $model.fillCells) {
                    Text("Fill (crop)").tag(true)
                    Text("Fit (letterbox)").tag(false)
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gap: \(Int(model.gap)) px").font(.caption)
                    Slider(value: $model.gap, in: 0...80, step: 4)
                }
                Picker("Background", selection: $model.background) { ForEach(CollageBackground.allCases) { b in Text(b.label).tag(b) } }
                Picker("Width", selection: $model.width) {
                    Text("1600 px").tag(1600)
                    Text("2400 px").tag(2400)
                    Text("3200 px").tag(3200)
                    Text("4800 px").tag(4800)
                }
                Picker("Format", selection: $model.format) {
                    ForEach(EditOutputFormat.offered.filter { $0 != .same }) { f in Text(f.label).tag(f) }
                }
                .disabled(model.background == .transparent)
                if model.background == .transparent { Text("Transparent backgrounds save as PNG.").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text("Saves “Collage.\(ImageConverter.ext(for: model.outputType))” next to the first image.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { controller.dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Save") {
                        let spec = model.spec()
                        EditorManager.shared.save(title: "Collage", source: model.files[0].url) { try CollageModel.export(spec) }
                        controller.dismiss()
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.clementine)
                    .disabled(model.preview == nil)
                }
            }
            .padding(16)
            .frame(width: 280)
        }
        .frame(minWidth: 760, minHeight: 480)
    }
}
