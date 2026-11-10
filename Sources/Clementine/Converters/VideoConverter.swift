import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

enum VideoConverter {
    struct Target {
        let title: String
        let ext: String
        let symbol: String
        let id: String
    }

    static func targets(for files: [FileItem]) -> [Target] {
        var t = [
            Target(title: "MP4", ext: "mp4", symbol: "film", id: "mp4"),
            Target(title: "MP4 HEVC", ext: "mp4", symbol: "film.stack", id: "hevc"),
            Target(title: "MOV", ext: "mov", symbol: "video", id: "mov"),
            Target(title: "M4V", ext: "m4v", symbol: "tv", id: "m4v"),
            Target(title: "GIF", ext: "gif", symbol: "photo.stack", id: "gif"),
            Target(title: "Audio M4A", ext: "m4a", symbol: "waveform", id: "m4a"),
        ]
        if FFmpeg.shared.has("libvpx-vp9") { t.append(Target(title: "WebM", ext: "webm", symbol: "globe", id: "webm")) }
        if FFmpeg.shared.isAvailable { t.append(Target(title: "MKV", ext: "mkv", symbol: "shippingbox", id: "mkv")) }
        return t
    }

    static func qualityPreset() -> String {
        switch Settings.shared.videoQuality {
        case .highest: return AVAssetExportPresetHighestQuality
        case .p1080: return AVAssetExportPreset1920x1080
        case .p720: return AVAssetExportPreset1280x720
        }
    }

    static func convert(_ file: FileItem, to target: Target, ctx: JobContext) throws -> URL {
        let dest = Output.sibling(of: file.url, ext: target.ext, suffix: target.id == "hevc" ? "HEVC" : nil)
        let asset = AVURLAsset(url: file.url)
        return try Output.write(to: dest) { tmp in
            switch target.id {
            case "mp4": try export(asset: asset, preset: qualityPreset(), fileType: .mp4, to: tmp, ctx: ctx)
            case "hevc":
                let preset = Settings.shared.videoQuality == .highest ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHEVC1920x1080
                try export(asset: asset, preset: preset, fileType: .mp4, to: tmp, ctx: ctx)
            case "mov": try export(asset: asset, preset: qualityPreset(), fileType: .mov, to: tmp, ctx: ctx)
            case "m4v": try export(asset: asset, preset: qualityPreset(), fileType: .m4v, to: tmp, ctx: ctx)
            case "m4a": try export(asset: asset, preset: AVAssetExportPresetAppleM4A, fileType: .m4a, to: tmp, ctx: ctx)
            case "gif": try gif(asset: asset, to: tmp, ctx: ctx)
            case "webm": try FFmpeg.shared.convert(input: file.url, output: tmp, args: ["-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "32", "-row-mt", "1", "-c:a", "libopus"], ctx: ctx)
            case "mkv": try FFmpeg.shared.convert(input: file.url, output: tmp, args: ["-c", "copy"], ctx: ctx)
            default: throw ClementineError.unsupported("Unknown video target \(target.id)")
            }
        }
    }

    static func compress(_ file: FileItem, ctx: JobContext) throws -> URL {
        let dest = Output.sibling(of: file.url, ext: "mp4", suffix: "Compressed")
        return try Output.write(to: dest) { tmp in
            try export(asset: AVURLAsset(url: file.url), preset: AVAssetExportPreset1280x720, fileType: .mp4, to: tmp, ctx: ctx)
        }
    }

    static func mute(_ file: FileItem, ctx: JobContext) throws -> URL {
        let asset = AVURLAsset(url: file.url)
        let comp = AVMutableComposition()
        let duration = try Shell.sync { try await asset.load(.duration) }
        let videoTracks = try Shell.sync { try await asset.loadTracks(withMediaType: .video) }
        guard !videoTracks.isEmpty else { throw ClementineError.unsupported("No video track.") }
        for vt in videoTracks {
            let ct = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            try ct?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: vt, at: .zero)
            ct?.preferredTransform = (try? Shell.sync { try await vt.load(.preferredTransform) }) ?? .identity
        }
        let ext = ["mp4", "mov", "m4v"].contains(file.ext) ? file.ext : "mov"
        let fileType: AVFileType = ext == "mp4" ? .mp4 : (ext == "m4v" ? .m4v : .mov)
        let dest = Output.sibling(of: file.url, ext: ext, suffix: "Muted")
        return try Output.write(to: dest) { tmp in
            try export(asset: comp, preset: AVAssetExportPresetPassthrough, fileType: fileType, to: tmp, ctx: ctx)
        }
    }

    static func speed(_ file: FileItem, factor: Double, ctx: JobContext) throws -> URL {
        let asset = AVURLAsset(url: file.url)
        let comp = try scaledComposition(of: asset, factor: factor, includeVideo: true)
        let dest = Output.sibling(of: file.url, ext: "mp4", suffix: String(format: "%gx", factor))
        return try Output.write(to: dest) { tmp in
            try export(asset: comp, preset: qualityPreset(), fileType: .mp4, to: tmp, ctx: ctx) {
                $0.audioTimePitchAlgorithm = .spectral
            }
        }
    }

    static func snapshot(_ file: FileItem, ctx: JobContext) throws -> URL {
        let asset = AVURLAsset(url: file.url)
        let duration = try Shell.sync { try await asset.load(.duration) }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        let t = CMTime(seconds: min(1.0, duration.seconds / 2), preferredTimescale: 600)
        let image = try gen.copyCGImage(at: t, actualTime: nil)
        let dest = Output.sibling(of: file.url, ext: "png", suffix: "Frame")
        return try Output.write(to: dest) { tmp in
            try ImageConverter.write(image, to: tmp, type: .png, quality: 1, properties: nil)
        }
    }

    // MARK: Helpers

    static func scaledComposition(of asset: AVAsset, factor: Double, includeVideo: Bool) throws -> AVMutableComposition {
        let comp = AVMutableComposition()
        let duration = try Shell.sync { try await asset.load(.duration) }
        let range = CMTimeRange(start: .zero, duration: duration)
        let types: [AVMediaType] = includeVideo ? [.video, .audio] : [.audio]
        for type in types {
            for track in try Shell.sync({ try await asset.loadTracks(withMediaType: type) }) {
                let ct = comp.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)
                try ct?.insertTimeRange(range, of: track, at: .zero)
                if type == .video {
                    ct?.preferredTransform = (try? Shell.sync { try await track.load(.preferredTransform) }) ?? .identity
                }
            }
        }
        let newDuration = CMTimeMultiplyByFloat64(duration, multiplier: 1 / factor)
        comp.scaleTimeRange(range, toDuration: newDuration)
        return comp
    }

    static func export(asset: AVAsset, preset: String, fileType: AVFileType, to out: URL, ctx: JobContext,
                       configure: ((AVAssetExportSession) -> Void)? = nil) throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ClementineError.unsupported("Export preset \(preset) is not available for this file.")
        }
        session.outputURL = out
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true
        configure?(session)
        let done = DispatchSemaphore(value: 0)
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler {
            ctx.report(Double(session.progress))
            if ctx.isCancelled { session.cancelExport() }
        }
        timer.resume()
        session.exportAsynchronously { done.signal() }
        done.wait()
        timer.cancel()
        switch session.status {
        case .completed: return
        case .cancelled: throw ClementineError.helperFailed("Cancelled")
        default: throw session.error ?? ClementineError.cannotWrite(out)
        }
    }

    /// Up to 10 s at 10 fps, 480 px wide, via AVAssetImageGenerator + ImageIO.
    static func gif(asset: AVAsset, to out: URL, ctx: JobContext) throws {
        let duration = try Shell.sync { try await asset.load(.duration) }.seconds
        let seconds = min(duration, 10)
        let fps = 10.0
        let frames = max(1, Int(seconds * fps))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, frames, nil) else {
            throw ClementineError.cannotWrite(out)
        }
        let fileProps: [String: Any] = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]]
        CGImageDestinationSetProperties(dest, fileProps as CFDictionary)
        let frameProps: [String: Any] = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: 1 / fps]]
        for i in 0..<frames {
            if ctx.isCancelled { throw ClementineError.helperFailed("Cancelled") }
            let t = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            if let img = try? gen.copyCGImage(at: t, actualTime: nil) {
                CGImageDestinationAddImage(dest, img, frameProps as CFDictionary)
            }
            ctx.report(Double(i) / Double(frames))
        }
        guard CGImageDestinationFinalize(dest) else { throw ClementineError.cannotWrite(out) }
    }
}
