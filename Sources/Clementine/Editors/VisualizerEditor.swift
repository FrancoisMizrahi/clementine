import Accelerate
import AVFoundation
import AppKit
import SwiftUI

enum VisualizerSize: String, CaseIterable, Identifiable {
    case landscape, square, portrait
    var id: String { rawValue }
    var label: String {
        switch self {
        case .landscape: return "1280 × 720"
        case .square: return "1080 × 1080"
        case .portrait: return "1080 × 1920"
        }
    }
    var size: CGSize {
        switch self {
        case .landscape: return CGSize(width: 1280, height: 720)
        case .square: return CGSize(width: 1080, height: 1080)
        case .portrait: return CGSize(width: 1080, height: 1920)
        }
    }
}

enum VisualizerStyle: String, CaseIterable, Identifiable {
    case bars, mirror, line
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct VisualizerSpec: @unchecked Sendable {
    let url: URL
    let size: CGSize
    let style: VisualizerStyle
    let accent: CGColor
    let backgroundImage: URL?
    let title: String?
    let bars: Int
    let fps: Int
}

@MainActor
final class VisualizerModel: ObservableObject {
    let files: [FileItem]
    @Published var sizePreset: VisualizerSize = .landscape
    @Published var style: VisualizerStyle = .bars
    @Published var colorIndex = 1
    @Published var backgroundImage: URL?
    @Published var showTitle = true
    @Published var bars = 48

    init(files: [FileItem]) { self.files = files }

    func chooseBackground() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { backgroundImage = panel.url }
    }

    func specs() -> [VisualizerSpec] {
        files.map { f in
            VisualizerSpec(url: f.url, size: sizePreset.size, style: style, accent: AnnotateModel.palette[colorIndex].1,
                           backgroundImage: backgroundImage, title: showTitle ? f.baseName : nil, bars: bars, fps: 30)
        }
    }

    /// Streams PCM, runs an FFT per video frame, draws bars with Core Graphics, muxes the original audio as AAC.
    nonisolated static func export(_ s: VisualizerSpec, ctx: JobContext) throws -> URL {
        let asset = AVURLAsset(url: s.url)
        let tracks = try Shell.sync { try await asset.loadTracks(withMediaType: .audio) }
        guard !tracks.isEmpty else { throw ClementineError.unsupported("No audio track in \(s.url.lastPathComponent).") }
        let duration = try Shell.sync { try await asset.load(.duration) }.seconds
        let sampleRate = 44_100.0
        let W = Int(s.size.width), H = Int(s.size.height)
        let totalFrames = Int(duration * Double(s.fps))
        let hop = Int(sampleRate / Double(s.fps))
        let window = 2048
        let log2n = vDSP_Length(11)
        guard let fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { throw ClementineError.noOutput }
        defer { vDSP_destroy_fftsetup(fft) }
        var hann = [Float](repeating: 0, count: window)
        vDSP_hann_window(&hann, vDSP_Length(window), Int32(vDSP_HANN_NORM))

        // Log-spaced bands between 40 Hz and 16 kHz.
        let binHz = sampleRate / Double(window)
        let bands: [(Int, Int)] = (0..<s.bars).map { i in
            let f0 = 40 * pow(16_000 / 40, Double(i) / Double(s.bars))
            let f1 = 40 * pow(16_000 / 40, Double(i + 1) / Double(s.bars))
            let b0 = max(1, Int(f0 / binHz)), b1 = max(b0 + 1, Int(f1 / binHz))
            return (b0, min(b1, window / 2 - 1))
        }

        let dest = Output.sibling(of: s.url, ext: "mp4", suffix: "Visualizer")
        return try Output.write(to: dest) { tmp in
            let job = try Output.jobDirectory("visualizer")
            defer { try? FileManager.default.removeItem(at: job) }
            let videoURL = job.appendingPathComponent("video.mp4")
            let audioURL = job.appendingPathComponent("audio.m4a")

            // Pass 1: silent video from a mono float decode. A single writer input avoids interleaving stalls.
            let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
            let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: W * H * 6, AVVideoExpectedSourceFrameRateKey: s.fps, AVVideoMaxKeyFrameIntervalKey: s.fps * 2],
            ])
            videoIn.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoIn, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
            ])
            writer.add(videoIn)
            guard writer.startWriting() else { throw writer.error ?? ClementineError.cannotWrite(tmp) }
            writer.startSession(atSourceTime: .zero)

            let reader = try AVAssetReader(asset: asset)
            let mono = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            reader.add(mono)
            guard reader.startReading() else { throw reader.error ?? ClementineError.cannotRead(s.url) }
            let background = try backgroundImage(for: s)
            var fifo = [Float]()
            var consumed = 0
            var frameIndex = 0
            var smoothed = [Float](repeating: 0, count: s.bars)
            var real = [Float](repeating: 0, count: window / 2), imag = [Float](repeating: 0, count: window / 2)
            var magnitudes = [Float](repeating: 0, count: window / 2)
            var windowed = [Float](repeating: 0, count: window)
            let titleAttr: NSAttributedString? = s.title.map {
                NSAttributedString(string: $0, attributes: [.font: NSFont.systemFont(ofSize: CGFloat(H) * 0.035, weight: .semibold),
                                                            .foregroundColor: NSColor.white.withAlphaComponent(0.9)])
            }

            func emitFrame(_ samples: ArraySlice<Float>) throws {
                for i in 0..<window { windowed[i] = (i < samples.count ? samples[samples.startIndex + i] : 0) * hann[i] }
                windowed.withUnsafeBufferPointer { wp in
                    real.withUnsafeMutableBufferPointer { rp in
                        imag.withUnsafeMutableBufferPointer { ip in
                            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                            wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: window / 2) { cp in
                                vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(window / 2))
                            }
                            vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                            vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(window / 2))
                        }
                    }
                }
                var levels = [CGFloat](repeating: 0, count: s.bars)
                for (i, band) in bands.enumerated() {
                    var sum: Float = 0
                    for b in band.0..<band.1 { sum += magnitudes[b] }
                    let avg = sum / Float(max(band.1 - band.0, 1))
                    let db = 20 * log10(max(avg / Float(window), 1e-7))
                    let norm = max(0, min(1, (db + 60) / 60))
                    smoothed[i] = max(norm, smoothed[i] * 0.78)
                    levels[i] = CGFloat(smoothed[i])
                }
                var pb: CVPixelBuffer?
                guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let buffer = pb else {
                    throw ClementineError.noOutput
                }
                CVPixelBufferLockBaseAddress(buffer, [])
                defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                guard let c = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: W, height: H, bitsPerComponent: 8,
                                        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
                    throw ClementineError.noOutput
                }
                c.draw(background, in: CGRect(x: 0, y: 0, width: W, height: H))
                drawBars(levels, in: c, size: CGSize(width: W, height: H), style: s.style, accent: s.accent)
                if let titleAttr {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
                    let size = titleAttr.size()
                    titleAttr.draw(at: NSPoint(x: (CGFloat(W) - size.width) / 2, y: CGFloat(H) * 0.08))
                    NSGraphicsContext.restoreGraphicsState()
                }
                var waited = 0
                while !videoIn.isReadyForMoreMediaData {
                    usleep(2000)
                    waited += 1
                    if waited > 5000 { throw ClementineError.helperFailed("The video writer stopped accepting frames.") }
                }
                let t = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(s.fps))
                guard adaptor.append(buffer, withPresentationTime: t) else { throw writer.error ?? ClementineError.noOutput }
                frameIndex += 1
                if totalFrames > 0 { ctx.report(Double(frameIndex) / Double(totalFrames) * 0.85) }
            }

            while let sb = mono.copyNextSampleBuffer() {
                if ctx.isCancelled { reader.cancelReading(); writer.cancelWriting(); throw ClementineError.helperFailed("Cancelled") }
                guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr, let p = pointer else { continue }
                p.withMemoryRebound(to: Float.self, capacity: length / 4) { fifo.append(contentsOf: UnsafeBufferPointer(start: $0, count: length / 4)) }
                while fifo.count - consumed >= window, frameIndex < totalFrames {
                    try emitFrame(fifo[consumed..<(consumed + window)])
                    consumed += hop
                }
                if consumed > 1_000_000 { fifo.removeFirst(consumed); consumed = 0 }
            }
            while frameIndex < totalFrames { try emitFrame(fifo.suffix(window)[...]) }
            videoIn.markAsFinished()
            let done = DispatchSemaphore(value: 0)
            writer.finishWriting { done.signal() }
            done.wait()
            guard writer.status == .completed else { throw writer.error ?? ClementineError.cannotWrite(videoURL) }

            // Pass 2: AAC audio, then a passthrough mux of both into the final MP4.
            try AudioConverter.transcode(asset: asset, audioMix: nil, to: audioURL, fileType: .m4a, aacBitrate: 192_000, ctx: JobContext())
            ctx.report(0.92)
            let comp = AVMutableComposition()
            let videoAsset = AVURLAsset(url: videoURL), audioAsset = AVURLAsset(url: audioURL)
            if let v = try Shell.sync({ try await videoAsset.loadTracks(withMediaType: .video) }).first,
               let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try cv.insertTimeRange(CMTimeRange(start: .zero, duration: try Shell.sync { try await videoAsset.load(.duration) }), of: v, at: .zero)
            }
            if let a = try Shell.sync({ try await audioAsset.loadTracks(withMediaType: .audio) }).first,
               let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try ca.insertTimeRange(CMTimeRange(start: .zero, duration: try Shell.sync { try await audioAsset.load(.duration) }), of: a, at: .zero)
            }
            try VideoConverter.export(asset: comp, preset: AVAssetExportPresetPassthrough, fileType: .mp4, to: tmp, ctx: JobContext())
        }
    }

    private nonisolated static func backgroundImage(for s: VisualizerSpec) throws -> CGImage {
        let W = Int(s.size.width), H = Int(s.size.height)
        guard let c = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ClementineError.noOutput }
        if let url = s.backgroundImage, let img = try? ImageConverter.load(url, maxPixel: max(W, H) * 2).image {
            let scale = max(CGFloat(W) / CGFloat(img.width), CGFloat(H) / CGFloat(img.height))
            let w = CGFloat(img.width) * scale, h = CGFloat(img.height) * scale
            c.interpolationQuality = .high
            c.draw(img, in: CGRect(x: (CGFloat(W) - w) / 2, y: (CGFloat(H) - h) / 2, width: w, height: h))
            c.setFillColor(CGColor(gray: 0, alpha: 0.35))
            c.fill(CGRect(x: 0, y: 0, width: W, height: H))
        } else {
            let colors = [CGColor(red: 0.10, green: 0.08, blue: 0.16, alpha: 1), CGColor(red: 0.02, green: 0.02, blue: 0.05, alpha: 1)] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1]) {
                c.drawLinearGradient(grad, start: CGPoint(x: 0, y: CGFloat(H)), end: CGPoint(x: CGFloat(W), y: 0), options: [])
            }
        }
        guard let img = c.makeImage() else { throw ClementineError.noOutput }
        return img
    }

    private nonisolated static func drawBars(_ levels: [CGFloat], in c: CGContext, size: CGSize, style: VisualizerStyle, accent: CGColor) {
        let n = levels.count
        let margin = size.width * 0.08
        let usable = size.width - 2 * margin
        let slot = usable / CGFloat(n)
        let barW = slot * 0.62
        let maxH = size.height * (style == .mirror ? 0.28 : 0.5)
        let base = style == .mirror ? size.height / 2 : size.height * 0.2
        c.setFillColor(accent)
        c.setStrokeColor(accent)
        c.setShadow(offset: .zero, blur: barW * 0.6, color: accent.copy(alpha: 0.6))
        switch style {
        case .bars, .mirror:
            for (i, level) in levels.enumerated() {
                let h = max(level * maxH, barW * 0.3)
                let x = margin + CGFloat(i) * slot + (slot - barW) / 2
                let r = CGRect(x: x, y: base, width: barW, height: h)
                c.addPath(CGPath(roundedRect: r, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
                if style == .mirror {
                    c.addPath(CGPath(roundedRect: CGRect(x: x, y: base - h, width: barW, height: h), cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
                }
            }
            c.fillPath()
        case .line:
            c.setLineWidth(max(size.width * 0.004, 2))
            c.setLineJoin(.round)
            let path = CGMutablePath()
            for (i, level) in levels.enumerated() {
                let p = CGPoint(x: margin + (CGFloat(i) + 0.5) * slot, y: base + level * maxH)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            c.addPath(path)
            c.strokePath()
            c.setShadow(offset: .zero, blur: 0, color: nil)
            c.setFillColor(accent.copy(alpha: 0.18) ?? accent)
            let fill = path.mutableCopy()!
            fill.addLine(to: CGPoint(x: margin + (CGFloat(n) - 0.5) * slot, y: base))
            fill.addLine(to: CGPoint(x: margin + 0.5 * slot, y: base))
            fill.closeSubpath()
            c.addPath(fill)
            c.fillPath()
        }
    }
}

struct VisualizerView: View {
    @ObservedObject var model: VisualizerModel
    unowned let controller: EditorWindowController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.and.magnifyingglass").font(.system(size: 26)).foregroundStyle(Color.clementine)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Audio visualizer video").font(.headline)
                    Text(model.files.count == 1 ? model.files[0].name : "\(model.files.count) files, one video each").font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("Size", selection: $model.sizePreset) { ForEach(VisualizerSize.allCases) { s in Text(s.label).tag(s) } }.pickerStyle(.segmented)
            Picker("Style", selection: $model.style) { ForEach(VisualizerStyle.allCases) { s in Text(s.label).tag(s) } }.pickerStyle(.segmented)
            HStack(spacing: 8) {
                Text("Colour").font(.caption)
                ForEach(Array(AnnotateModel.palette.enumerated()), id: \.offset) { i, entry in
                    Circle().fill(Color(cgColor: entry.1))
                        .overlay(Circle().stroke(model.colorIndex == i ? Color.primary : Color.primary.opacity(0.2), lineWidth: model.colorIndex == i ? 2 : 1))
                        .frame(width: 18, height: 18).onTapGesture { model.colorIndex = i }
                }
            }
            HStack {
                Text("Background").font(.caption)
                Text(model.backgroundImage?.lastPathComponent ?? "Dark gradient").lineLimit(1).truncationMode(.middle)
                Button("Choose image…") { model.chooseBackground() }
                if model.backgroundImage != nil { Button("Clear") { model.backgroundImage = nil } }
            }
            Stepper("Bars: \(model.bars)", value: $model.bars, in: 16...96, step: 8)
            Toggle("Show the file name as a title", isOn: $model.showTitle)
            Text("Renders at 30 fps as H.264 MP4 with the audio as AAC. A three-minute song takes about a minute.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { controller.dismiss() }.keyboardShortcut(.cancelAction)
                Button("Render") {
                    let specs = model.specs()
                    let op = Operation("tool.visualizer.run", "Visualizer", "waveform.and.magnifyingglass", .tools) { input in
                        var outs: [URL] = []
                        for (i, s) in specs.enumerated() { outs.append(try VisualizerModel.export(s, ctx: input.ctx.sub(i, of: specs.count))) }
                        return OperationResult(outputs: outs)
                    }
                    JobCenter.shared.run(op, urls: model.files.map(\.url))
                    controller.dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Color.clementine)
            }
        }
        .padding(18)
        .frame(width: 520)
    }
}
