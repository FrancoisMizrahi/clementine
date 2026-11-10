import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum AspectPreset: String, CaseIterable, Identifiable {
    case free, original, square, r4x3, r3x2, r16x9, r9x16
    var id: String { rawValue }
    var label: String {
        switch self {
        case .free: return "Free"
        case .original: return "Original"
        case .square: return "Square"
        case .r4x3: return "4:3"
        case .r3x2: return "3:2"
        case .r16x9: return "16:9"
        case .r9x16: return "9:16"
        }
    }
    func ratio(original: CGSize) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original: return original.height > 0 ? original.width / original.height : nil
        case .square: return 1
        case .r4x3: return 4.0 / 3.0
        case .r3x2: return 3.0 / 2.0
        case .r16x9: return 16.0 / 9.0
        case .r9x16: return 9.0 / 16.0
        }
    }
}

enum EditOutputFormat: String, CaseIterable, Identifiable {
    case same, jpeg, png, heic, webp
    var id: String { rawValue }
    var label: String {
        switch self {
        case .same: return "Same as source"
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .heic: return "HEIC"
        case .webp: return "WebP"
        }
    }
    /// Formats to offer in pickers; WebP only when the encoder was linked in.
    static var offered: [EditOutputFormat] { allCases.filter { $0 != .webp || WebPEncoder.isAvailable } }
    var utType: UTType? {
        switch self {
        case .same: return nil
        case .jpeg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        case .webp: return .webP
        }
    }
}

struct ImageEditSpec: @unchecked Sendable {
    let url: URL
    let orientation: EditOrientation
    let crop: CGRect?
    let adjustments: Adjustments
    let type: UTType
    let keepMetadata: Bool
    let quality: Double
}

@MainActor
final class ImageEditModel: ObservableObject {
    let file: FileItem
    @Published private(set) var picture: EditablePicture?
    @Published var orientation = EditOrientation() { didSet { requestRender() } }
    @Published var adjustments = Adjustments() { didSet { requestRender() } }
    @Published var crop: CGRect? = nil
    @Published var aspect: AspectPreset = .free
    @Published private(set) var preview: CGImage?
    @Published var outputFormat: EditOutputFormat = .same
    @Published var keepMetadata = true
    @Published var error: String?
    private let coalescer = RenderCoalescer()
    private let renderQueue = DispatchQueue(label: "clementine.editor.render", qos: .userInteractive)

    var orientedSize: CGSize {
        guard let p = picture else { return .zero }
        return orientation.rotation % 2 == 0 ? p.fullSize : CGSize(width: p.fullSize.height, height: p.fullSize.width)
    }
    var effectiveCrop: CGRect { crop ?? CGRect(origin: .zero, size: orientedSize) }
    var cropBinding: Binding<CGRect> { Binding(get: { self.effectiveCrop }, set: { self.crop = $0 }) }
    var isPristine: Bool { orientation.isIdentity && adjustments.isNeutral && crop == nil }

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
        let o = orientation, a = adjustments
        let coalescer = self.coalescer
        renderQueue.async {
            guard coalescer.isCurrent(g) else { return }
            let img = CIPipeline.adjusted(CIPipeline.oriented(p.preview, o), a)
            let cg = CIPipeline.render(img, colorSpace: nil)
            Task { @MainActor in
                if coalescer.isCurrent(g) { self.preview = cg }
            }
        }
    }

    func rotateClockwise() {
        let s = orientedSize
        crop = crop.map { RectMath.rotatedClockwise($0, size: s) }
        orientation.rotateClockwise()
    }
    func rotateCounterclockwise() {
        let s = orientedSize
        crop = crop.map { RectMath.rotatedCounterclockwise($0, size: s) }
        orientation.rotateCounterclockwise()
    }
    func flipHorizontal() {
        crop = crop.map { RectMath.flippedHorizontally($0, size: orientedSize) }
        orientation.flipHorizontal()
    }
    func flipVertical() {
        crop = crop.map { RectMath.flippedVertically($0, size: orientedSize) }
        orientation.flipVertical()
    }
    func setAspect(_ a: AspectPreset) {
        aspect = a
        if let ratio = a.ratio(original: orientedSize) { crop = RectMath.centered(aspect: ratio, in: orientedSize) }
    }
    func resetCrop() { crop = nil; aspect = .free }
    func resetAll() { orientation = EditOrientation(); adjustments = Adjustments(); crop = nil; aspect = .free }

    var outputType: UTType { outputFormat.utType ?? (ImageConverter.writableType(for: file) ?? .jpeg) }

    func spec() -> ImageEditSpec {
        ImageEditSpec(url: file.url, orientation: orientation, crop: crop, adjustments: adjustments,
                      type: outputType, keepMetadata: keepMetadata, quality: max(Settings.shared.imageQuality, 0.9))
    }

    /// Runs on the job queue: full-resolution render of the same pipeline the preview used.
    nonisolated static func export(_ s: ImageEditSpec) throws -> URL {
        let loaded = try ImageConverter.load(s.url)
        var img = CIImage(cgImage: loaded.image)
        img = CIPipeline.cropped(CIPipeline.adjusted(CIPipeline.oriented(img, s.orientation), s.adjustments), s.crop)
        guard let cg = CIPipeline.render(img, colorSpace: loaded.image.colorSpace) else { throw ClementineError.cannotRead(s.url) }
        let dest = Output.sibling(of: s.url, ext: ImageConverter.ext(for: s.type), suffix: "Edited")
        return try Output.write(to: dest) { tmp in
            try ImageConverter.write(cg, to: tmp, type: s.type, quality: s.quality,
                                     properties: s.keepMetadata ? ImageConverter.metadataOnly(loaded.properties) : nil)
        }
    }
}

struct ImageEditorView: View {
    @ObservedObject var model: ImageEditModel
    unowned let controller: EditorWindowController

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
            let size = model.orientedSize
            let g = CanvasGeometry(imageSize: size, in: geo.size, inset: 20)
            ZStack(alignment: .topLeading) {
                Color(nsColor: .underPageBackgroundColor)
                if let cg = model.preview, size.width > 0 {
                    Image(decorative: cg, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: g.fitted.width, height: g.fitted.height)
                        .position(x: g.fitted.midX, y: g.fitted.midY)
                    let r = g.toView(model.effectiveCrop)
                    Path { p in p.addRect(g.fitted); p.addRect(r) }
                        .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                    Path { p in
                        for i in 1...2 {
                            let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                            p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                            p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                        }
                    }
                    .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                    .allowsHitTesting(false)
                    RectHandlesOverlay(geometry: g, rect: model.cropBinding, aspect: model.aspect.ratio(original: size))
                } else if let e = model.error {
                    Text(e).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Group {
                    Text("Orientation").font(.headline)
                    HStack(spacing: 8) {
                        tool("rotate.left", "Rotate left") { model.rotateCounterclockwise() }
                        tool("rotate.right", "Rotate right") { model.rotateClockwise() }
                        tool("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip horizontally") { model.flipHorizontal() }
                        tool("arrow.up.and.down.righttriangle.up.righttriangle.down", "Flip vertically") { model.flipVertical() }
                    }
                }
                Group {
                    Text("Crop").font(.headline)
                    Picker("Aspect", selection: Binding(get: { model.aspect }, set: { model.setAspect($0) })) {
                        ForEach(AspectPreset.allCases) { a in Text(a.label).tag(a) }
                    }
                    HStack {
                        Text("\(Int(model.effectiveCrop.width)) × \(Int(model.effectiveCrop.height)) px")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset crop") { model.resetCrop() }.controlSize(.small).disabled(model.crop == nil)
                    }
                }
                Group {
                    HStack {
                        Text("Adjust").font(.headline)
                        Spacer()
                        Button("Reset") { model.adjustments = Adjustments() }.controlSize(.small).disabled(model.adjustments.isNeutral)
                    }
                    slider("Exposure", $model.adjustments.exposure, -2...2, neutral: 0)
                    slider("Brightness", $model.adjustments.brightness, -0.5...0.5, neutral: 0)
                    slider("Contrast", $model.adjustments.contrast, 0.5...1.5, neutral: 1)
                    slider("Saturation", $model.adjustments.saturation, 0...2, neutral: 1)
                    slider("Vibrance", $model.adjustments.vibrance, -1...1, neutral: 0)
                    slider("Warmth", $model.adjustments.warmth, -1...1, neutral: 0)
                    slider("Sharpness", $model.adjustments.sharpness, 0...2, neutral: 0)
                }
                Button("Reset everything") { model.resetAll() }.controlSize(.small).disabled(model.isPristine)
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
            Toggle("Keep metadata", isOn: $model.keepMetadata)
            Spacer()
            Text("Saves next to the original as “\(model.file.baseName) Edited.\(ImageConverter.ext(for: model.outputType))”")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Button("Cancel") { controller.dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save") {
                let spec = model.spec()
                EditorManager.shared.save(title: "Crop & Adjust", source: model.file.url) { try ImageEditModel.export(spec) }
                controller.dismiss()
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .tint(Color.clementine)
            .disabled(model.picture == nil)
        }
        .padding(12)
    }

    private func tool(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15)).frame(width: 40, height: 28)
        }
        .help(help)
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, neutral: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button { value.wrappedValue = neutral } label: { Image(systemName: "arrow.counterclockwise").font(.system(size: 9)) }
                    .buttonStyle(.plain).opacity(value.wrappedValue == neutral ? 0.25 : 1)
            }
            Slider(value: value, in: range)
        }
    }
}
