import AVFoundation
import AppKit
import SwiftUI

struct VideoEditSpec: @unchecked Sendable {
    let url: URL
    let inTime: Double
    let outTime: Double
    let duration: Double
    let crop: CGRect?       // in display (oriented) pixel coordinates
    let mute: Bool
}

@MainActor
final class VideoEditModel: ObservableObject {
    let file: FileItem
    let player: PlayerController
    @Published var inTime: Double = 0
    @Published var outTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var thumbnails: [CGImage?] = []
    @Published var cropping = false
    @Published private(set) var frame: CGImage?
    @Published var crop: CGRect? = nil
    @Published var aspect: AspectPreset = .free
    @Published var mute = false
    @Published var error: String?

    var displaySize: CGSize { frame.map { CGSize(width: $0.width, height: $0.height) } ?? .zero }
    var effectiveCrop: CGRect { crop ?? CGRect(origin: .zero, size: displaySize) }
    var cropBinding: Binding<CGRect> { Binding(get: { self.effectiveCrop }, set: { self.crop = $0 }) }
    var isTrimmed: Bool { inTime > 0.01 || outTime < duration - 0.01 }

    init(file: FileItem) {
        self.file = file
        player = PlayerController(url: file.url)
        let url = file.url
        Task { @MainActor in
            do {
                let d = try await AVURLAsset(url: url).load(.duration).seconds
                self.duration = d
                self.outTime = d
                self.player.stopAt = d
            } catch { self.error = error.localizedDescription }
        }
        MediaThumbnails.generate(url: url, count: 16, height: 56) { [weak self] frames in self?.thumbnails = frames }
    }

    func setIn() { inTime = min(player.currentTime, outTime - 0.05); player.stopAt = outTime }
    func setOut() { outTime = max(player.currentTime, inTime + 0.05); player.stopAt = outTime }
    func previewRange() { player.stopAt = outTime; player.play(from: inTime) }

    func toggleCrop() {
        cropping.toggle()
        if cropping { player.pause(); loadFrame() }
    }

    func loadFrame() {
        let t = player.currentTime
        let url = file.url
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try MediaThumbnails.frame(url: url, at: t) }
            Task { @MainActor in
                switch result {
                case .success(let img):
                    let sameSize = self.frame.map { $0.width == img.width && $0.height == img.height } ?? false
                    self.frame = img
                    if !sameSize { self.crop = nil }
                case .failure(let e): self.error = e.localizedDescription
                }
            }
        }
    }

    func setAspect(_ a: AspectPreset) {
        aspect = a
        if let ratio = a.ratio(original: displaySize) { crop = RectMath.centered(aspect: ratio, in: displaySize) }
    }
    func resetCrop() { crop = nil; aspect = .free }

    func spec() -> VideoEditSpec {
        let c = (crop?.width ?? 0) >= 16 && (crop?.height ?? 0) >= 16 && crop != CGRect(origin: .zero, size: displaySize) ? crop : nil
        return VideoEditSpec(url: file.url, inTime: inTime, outTime: outTime, duration: duration, crop: c, mute: mute)
    }

    /// Trim only: passthrough export, no re-encode. With a crop: a video composition rendered with the quality preset.
    nonisolated static func export(_ s: VideoEditSpec) throws -> URL {
        let asset = AVURLAsset(url: s.url)
        let range = CMTimeRange(start: CMTime(seconds: s.inTime, preferredTimescale: 600), end: CMTime(seconds: s.outTime, preferredTimescale: 600))
        let comp = AVMutableComposition()
        let vTracks = try Shell.sync { try await asset.loadTracks(withMediaType: .video) }
        guard let v = vTracks.first, let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ClementineError.unsupported("No video track.")
        }
        try cv.insertTimeRange(range, of: v, at: .zero)
        let transform = (try? Shell.sync { try await v.load(.preferredTransform) }) ?? .identity
        if !s.mute {
            for a in (try? Shell.sync { try await asset.loadTracks(withMediaType: .audio) }) ?? [] {
                let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                try ca?.insertTimeRange(range, of: a, at: .zero)
            }
        }
        var videoComposition: AVMutableVideoComposition?
        if let crop = s.crop {
            let natural = try Shell.sync { try await v.load(.naturalSize) }
            let displayed = CGRect(origin: .zero, size: natural).applying(transform)
            let normalize = CGAffineTransform(translationX: -displayed.minX, y: -displayed.minY)
            let cropT = transform.concatenating(normalize).concatenating(CGAffineTransform(translationX: -crop.minX.rounded(), y: -crop.minY.rounded()))
            let vc = AVMutableVideoComposition()
            vc.renderSize = CGSize(width: floor(crop.width / 2) * 2, height: floor(crop.height / 2) * 2)
            let minFrame = (try? Shell.sync { try await v.load(.minFrameDuration) }) ?? CMTime(value: 1, timescale: 30)
            vc.frameDuration = minFrame.seconds > 0 && minFrame.seconds < 1 ? minFrame : CMTime(value: 1, timescale: 30)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: cv)
            layer.setTransform(cropT, at: .zero)
            instruction.layerInstructions = [layer]
            vc.instructions = [instruction]
            videoComposition = vc
        } else {
            cv.preferredTransform = transform
        }
        var parts: [String] = []
        if s.inTime > 0.01 || s.outTime < s.duration - 0.01 { parts.append("Trimmed") }
        if s.crop != nil { parts.append("Cropped") }
        if s.mute { parts.append("Muted") }
        let suffix = parts.isEmpty ? "Edited" : parts.joined(separator: " ")
        let srcExt = s.url.pathExtension.lowercased()
        let ext = videoComposition == nil ? (["mp4", "mov", "m4v"].contains(srcExt) ? srcExt : "mov") : "mp4"
        let fileType: AVFileType = ext == "mp4" ? .mp4 : (ext == "m4v" ? .m4v : .mov)
        let preset = videoComposition == nil ? AVAssetExportPresetPassthrough : VideoConverter.qualityPreset()
        let dest = Output.sibling(of: s.url, ext: ext, suffix: suffix)
        return try Output.write(to: dest) { tmp in
            try VideoConverter.export(asset: comp, preset: preset, fileType: fileType, to: tmp, ctx: JobContext()) { session in
                session.videoComposition = videoComposition
            }
        }
    }
}

struct VideoEditorView: View {
    @ObservedObject var model: VideoEditModel
    @ObservedObject var player: PlayerController
    unowned let controller: EditorWindowController

    init(model: VideoEditModel, controller: EditorWindowController) {
        self.model = model
        self.player = model.player
        self.controller = controller
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if model.cropping { cropCanvas } else { PlayerSurface(player: player.player) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            controls
            timeline.frame(height: 64).padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    private var cropCanvas: some View {
        GeometryReader { geo in
            let size = model.displaySize
            let g = CanvasGeometry(imageSize: size, in: geo.size, inset: 16)
            ZStack(alignment: .topLeading) {
                if let f = model.frame, size.width > 0 {
                    Image(decorative: f, scale: 1).resizable().interpolation(.high)
                        .frame(width: g.fitted.width, height: g.fitted.height).position(x: g.fitted.midX, y: g.fitted.midY)
                    let r = g.toView(model.effectiveCrop)
                    Path { p in p.addRect(g.fitted); p.addRect(r) }.fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true)).allowsHitTesting(false)
                    RectHandlesOverlay(geometry: g, rect: model.cropBinding, aspect: model.aspect.ratio(original: size))
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 22) }
                .keyboardShortcut(.space, modifiers: [])
            Button { model.previewRange() } label: { Label("Play selection", systemImage: "play.rectangle") }
            Text("\(MediaTime.string(player.currentTime)) / \(MediaTime.string(model.duration))").font(.system(.caption, design: .monospaced))
            Divider().frame(height: 18)
            Button("Set In") { model.setIn() }.keyboardShortcut("i", modifiers: [])
            Text(MediaTime.string(model.inTime)).font(.system(.caption, design: .monospaced)).foregroundStyle(Color.clementine)
            Button("Set Out") { model.setOut() }.keyboardShortcut("o", modifiers: [])
            Text(MediaTime.string(model.outTime)).font(.system(.caption, design: .monospaced)).foregroundStyle(Color.clementine)
            Text("keeps \(MediaTime.string(model.outTime - model.inTime, showMillis: false))").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if model.cropping {
                Picker("Aspect", selection: Binding(get: { model.aspect }, set: { model.setAspect($0) })) {
                    ForEach(AspectPreset.allCases) { a in Text(a.label).tag(a) }
                }
                .frame(width: 150)
                Text("\(Int(model.effectiveCrop.width)) × \(Int(model.effectiveCrop.height))").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                Button("Reset") { model.resetCrop() }.disabled(model.crop == nil)
                Button("Use this frame") { model.loadFrame() }.help("Refresh the still frame from the playhead")
            }
            Toggle(isOn: Binding(get: { model.cropping }, set: { _ in model.toggleCrop() })) { Label("Crop", systemImage: "crop") }
                .toggleStyle(.button)
        }
        .padding(10)
    }

    private var timeline: some View {
        TrimTimeline(duration: model.duration, inTime: $model.inTime, outTime: $model.outTime, current: player.currentTime,
                     onScrub: { t in player.pause(); player.seek(to: t); model.player.stopAt = model.outTime },
                     background: {
                         HStack(spacing: 0) {
                             ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, img in
                                 if let img { Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fill).frame(maxWidth: .infinity).clipped() }
                                 else { Rectangle().fill(Color.gray.opacity(0.3)) }
                             }
                         }
                     },
                     overlay: { _ in EmptyView() })
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Toggle("Remove audio", isOn: $model.mute)
            Text(model.crop == nil ? "Trim only is lossless and fast (no re-encoding)." : "Cropping re-encodes with the video quality setting.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { controller.dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save") {
                let spec = model.spec()
                player.pause()
                EditorManager.shared.save(title: "Trim & Crop", source: model.file.url) { try VideoEditModel.export(spec) }
                controller.dismiss()
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .tint(Color.clementine)
            .disabled(model.duration <= 0 || (!model.isTrimmed && model.crop == nil && !model.mute))
        }
        .padding(12)
    }
}
