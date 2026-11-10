import AVFoundation
import AVKit
import SwiftUI

/// Thin AVPlayer wrapper that publishes the playhead for SwiftUI.
@MainActor
final class PlayerController: ObservableObject {
    let player: AVPlayer
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double = 0
    private var observer: Any?
    private var endObserver: Any?
    /// Playback stops here when set (the out point).
    var stopAt: Double?

    init(url: URL) {
        player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = t.seconds
                if let stop = self.stopAt, self.isPlaying, t.seconds >= stop { self.pause(); self.seek(to: stop) }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }
        Task { @MainActor [weak self] in
            if let d = try? await AVURLAsset(url: url).load(.duration).seconds, d.isFinite { self?.duration = d }
        }
    }

    deinit {
        if let observer { player.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func play(from start: Double? = nil) {
        if let start { seek(to: start) }
        player.play()
        isPlaying = true
    }
    func pause() { player.pause(); isPlaying = false }
    func toggle() { isPlaying ? pause() : play() }
    func seek(to seconds: Double) {
        let t = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = max(0, seconds)
    }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        v.showsFullScreenToggleButton = false
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { v.player = player }
}

enum MediaTime {
    static func string(_ seconds: Double, showMillis: Bool = true) -> String {
        guard seconds.isFinite else { return "--:--" }
        let s = max(0, seconds)
        let h = Int(s / 3600), m = Int(s.truncatingRemainder(dividingBy: 3600) / 60)
        let sec = s.truncatingRemainder(dividingBy: 60)
        let base = h > 0 ? String(format: "%d:%02d:%05.2f", h, m, sec) : String(format: "%d:%05.2f", m, sec)
        return showMillis ? base : String(base.dropLast(3))
    }
}

/// A strip with in/out handles, a playhead and a custom background (thumbnails or a waveform).
/// Times are seconds; the strip maps them linearly across its width.
struct TrimTimeline<Background: View, Overlay: View>: View {
    let duration: Double
    @Binding var inTime: Double
    @Binding var outTime: Double
    let current: Double
    var onScrub: (Double) -> Void
    var onDragRange: ((Double, Double, Bool) -> Void)? = nil   // start, end, finished; for drawing bleep ranges
    var dragCreatesRange = false
    @ViewBuilder var background: () -> Background
    @ViewBuilder var overlay: (_ x: @escaping (Double) -> CGFloat) -> Overlay
    @State private var dragStart: Double?
    @State private var dragging: Handle?
    private enum Handle { case inPoint, outPoint }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x: (Double) -> CGFloat = { t in duration > 0 ? CGFloat(t / duration) * w : 0 }
            let t: (CGFloat) -> Double = { px in duration > 0 ? min(max(Double(px / w) * duration, 0), duration) : 0 }
            ZStack(alignment: .topLeading) {
                background().frame(width: w, height: geo.size.height).clipped()
                overlay(x)
                // dim outside the kept range
                Rectangle().fill(Color.black.opacity(0.55)).frame(width: max(x(inTime), 0), height: geo.size.height)
                Rectangle().fill(Color.black.opacity(0.55)).frame(width: max(w - x(outTime), 0), height: geo.size.height).offset(x: x(outTime))
                Rectangle().stroke(Color.clementine, lineWidth: 2)
                    .frame(width: max(x(outTime) - x(inTime), 2), height: geo.size.height).offset(x: x(inTime))
                // playhead
                Rectangle().fill(Color.white).frame(width: 2, height: geo.size.height).offset(x: x(current) - 1).shadow(radius: 1)
                // handles
                handle(at: x(inTime), isIn: true, height: geo.size.height)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        inTime = min(max(t(v.location.x), 0), outTime - 0.05); onScrub(inTime)
                    })
                handle(at: x(outTime), isIn: false, height: geo.size.height)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        outTime = max(min(t(v.location.x), duration), inTime + 0.05); onScrub(outTime)
                    })
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                if dragCreatesRange, let onDragRange {
                    if dragStart == nil { dragStart = t(v.startLocation.x) }
                    onDragRange(min(dragStart!, t(v.location.x)), max(dragStart!, t(v.location.x)), false)
                } else {
                    onScrub(t(v.location.x))
                }
            }.onEnded { v in
                if dragCreatesRange, let onDragRange, let s = dragStart {
                    onDragRange(min(s, t(v.location.x)), max(s, t(v.location.x)), true)
                }
                dragStart = nil
            })
        }
    }

    private func handle(at x: CGFloat, isIn: Bool, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.clementine)
            .frame(width: 12, height: height)
            .overlay(Image(systemName: isIn ? "chevron.compact.right" : "chevron.compact.left").font(.system(size: 11, weight: .bold)).foregroundStyle(.white))
            .offset(x: isIn ? x - 12 : x)
            .contentShape(Rectangle())
    }
}

enum MediaThumbnails {
    /// Evenly spaced frames for a timeline strip, delivered on the main thread as they arrive.
    static func generate(url: URL, count: Int, height: CGFloat, completion: @escaping @MainActor ([CGImage?]) -> Void) {
        let asset = AVURLAsset(url: url)
        Task.detached(priority: .userInitiated) {
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            guard duration > 0 else { await completion([]); return }
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: height * 4, height: height * 2)
            gen.requestedTimeToleranceBefore = CMTime(seconds: duration / Double(count) / 2, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter = gen.requestedTimeToleranceBefore
            var frames: [CGImage?] = []
            for i in 0..<count {
                let t = CMTime(seconds: (Double(i) + 0.5) / Double(count) * duration, preferredTimescale: 600)
                frames.append(try? gen.copyCGImage(at: t, actualTime: nil))
            }
            let result = frames
            await completion(result)
        }
    }

    /// Full-resolution frame in display orientation.
    static func frame(url: URL, at seconds: Double) throws -> CGImage {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        return try gen.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
    }
}

enum Waveform {
    /// Peak amplitude per bucket (0...1), computed from a mono 8 kHz decode.
    static func peaks(url: URL, buckets: Int) throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try Shell.sync { try await asset.loadTracks(withMediaType: .audio) }
        guard !tracks.isEmpty else { throw ClementineError.unsupported("No audio track.") }
        let duration = try Shell.sync { try await asset.load(.duration) }.seconds
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 8000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ClementineError.cannotRead(url) }
        let totalSamples = max(Int(duration * 8000), 1)
        let perBucket = max(totalSamples / buckets, 1)
        var peaks = [Float](repeating: 0, count: buckets)
        var index = 0
        while let sb = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr, let p = pointer else { continue }
            p.withMemoryRebound(to: Int16.self, capacity: length / 2) { samples in
                for i in 0..<(length / 2) {
                    let b = min(index / perBucket, buckets - 1)
                    let v = abs(Float(samples[i])) / 32768
                    if v > peaks[b] { peaks[b] = v }
                    index += 1
                }
            }
        }
        return peaks
    }
}
