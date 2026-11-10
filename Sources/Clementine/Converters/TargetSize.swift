import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct TargetSizeRequest: @unchecked Sendable {
    let bytes: Int
    let allowDownscale: Bool
    let imageFormat: EditOutputFormat
    var label: String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file).replacingOccurrences(of: ",", with: ".") }
}

/// Hit a file-size budget: binary search on quality (plus optional downscaling) for images,
/// bitrate-targeted H.264 for video with one corrective retry.
enum TargetSize {
    static func image(_ file: FileItem, _ r: TargetSizeRequest, ctx: JobContext) throws -> URL {
        let loaded = try ImageConverter.load(file.url)
        let type: UTType
        switch r.imageFormat {
        case .heic: type = .heic
        case .webp: type = .webP
        case .png, .jpeg: type = .jpeg
        case .same: type = file.type == .heic ? .heic : (file.type == .webP && WebPEncoder.isAvailable ? .webP : .jpeg)
        }
        var image = loaded.image
        let props = ImageConverter.metadataOnly(loaded.properties)
        for pass in 0..<6 {
            var lo = 0.25, hi = 0.97
            var best: Data?
            for step in 0..<7 {
                let q = (lo + hi) / 2
                let data = try encode(image, type: type, quality: q, properties: props)
                if data.count <= r.bytes { best = data; lo = q } else { hi = q }
                ctx.report((Double(pass) + Double(step) / 7) / 6)
            }
            if best == nil {
                let floor = try encode(image, type: type, quality: lo, properties: props)
                if floor.count <= r.bytes { best = floor }
            }
            if let best {
                let dest = Output.sibling(of: file.url, ext: ImageConverter.ext(for: type), suffix: r.label)
                return try Output.write(to: dest) { try best.write(to: $0) }
            }
            guard r.allowDownscale else { break }
            let atFloor = try encode(image, type: type, quality: 0.25, properties: props)
            let factor = max(0.3, min(0.92, (Double(r.bytes) / Double(atFloor.count)).squareRoot() * 0.95))
            image = try scaled(image, by: factor)
            if min(image.width, image.height) < 64 { break }
        }
        throw ClementineError.unsupported("Could not get \(file.name) under \(r.label)\(r.allowDownscale ? "" : " without downscaling").")
    }

    private static func encode(_ image: CGImage, type: UTType, quality: Double, properties: [String: Any]) throws -> Data {
        if type == .webP { return try WebPEncoder.encode(image, quality: quality) }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw ClementineError.unsupported("Cannot encode \(type.identifier)")
        }
        var p = properties
        p[kCGImageDestinationLossyCompressionQuality as String] = quality
        p[kCGImagePropertyOrientation as String] = 1
        CGImageDestinationAddImage(dest, type == .jpeg ? ImageConverter.flattenedOnWhite(image) : image, p as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ClementineError.noOutput }
        return data as Data
    }

    private static func scaled(_ image: CGImage, by factor: Double) throws -> CGImage {
        let w = max(Int(Double(image.width) * factor), 16), h = max(Int(Double(image.height) * factor), 16)
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ClementineError.noOutput }
        c.interpolationQuality = .high
        c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = c.makeImage() else { throw ClementineError.noOutput }
        return out
    }

    // MARK: Video

    static func video(_ file: FileItem, _ r: TargetSizeRequest, ctx: JobContext) throws -> URL {
        let asset = AVURLAsset(url: file.url)
        let duration = try Shell.sync { try await asset.load(.duration) }.seconds
        guard duration > 0 else { throw ClementineError.unsupported("Unknown duration.") }
        let hasAudio = !((try? Shell.sync { try await asset.loadTracks(withMediaType: .audio) }) ?? []).isEmpty
        let totalBits = Double(r.bytes) * 8 * 0.94 // container and key-frame overhead
        let audioBitrate = hasAudio ? (totalBits / duration > 600_000 ? 96_000 : 64_000) : 0
        var videoBitrate = Int(totalBits / duration) - audioBitrate
        guard videoBitrate >= 80_000 else {
            throw ClementineError.unsupported("\(r.label) is too small for a \(Int(duration)) s video.")
        }
        let dest = Output.sibling(of: file.url, ext: "mp4", suffix: r.label)
        return try Output.write(to: dest) { tmp in
            try VideoConverter.encode(asset: asset, to: tmp, videoBitrate: videoBitrate, audioBitrate: audioBitrate, ctx: ctx.sub(0, of: 2))
            let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int) ?? 0
            if size > r.bytes {
                videoBitrate = Int(Double(videoBitrate) * Double(r.bytes) / Double(size) * 0.96)
                try? FileManager.default.removeItem(at: tmp)
                try VideoConverter.encode(asset: asset, to: tmp, videoBitrate: videoBitrate, audioBitrate: audioBitrate, ctx: ctx.sub(1, of: 2))
            }
        }
    }
}

extension VideoConverter {
    /// Bitrate-controlled H.264 through AVAssetReader/Writer. Resolution follows the bit budget so low
    /// targets do not turn into blocky full-resolution video.
    static func encode(asset: AVAsset, to out: URL, videoBitrate: Int, audioBitrate: Int, ctx: JobContext) throws {
        let videoTracks = try Shell.sync { try await asset.loadTracks(withMediaType: .video) }
        guard let vTrack = videoTracks.first else { throw ClementineError.unsupported("No video track.") }
        let natural = try Shell.sync { try await vTrack.load(.naturalSize) }
        let transform = (try? Shell.sync { try await vTrack.load(.preferredTransform) }) ?? .identity
        let fps = max(Double((try? Shell.sync { try await vTrack.load(.nominalFrameRate) }) ?? 30), 1)
        let duration = try Shell.sync { try await asset.load(.duration) }.seconds

        // Bits per pixel per frame; keep it above ~0.05 for watchable H.264 by shrinking the frame.
        var w = natural.width, h = natural.height
        let bpp = Double(videoBitrate) / (w * h * fps)
        if bpp < 0.05 {
            let scale = (bpp / 0.05).squareRoot()
            w = max((w * scale).rounded(), 320)
            h = max((h * scale).rounded(), 180)
        }
        let width = Int(w) / 2 * 2, height = Int(h) / 2 * 2

        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        let audioTracks = (try? Shell.sync { try await asset.loadTracks(withMediaType: .audio) }) ?? []
        var audioOut: AVAssetReaderAudioMixOutput?
        if audioBitrate > 0, !audioTracks.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            o.alwaysCopiesSampleData = false
            reader.add(o)
            audioOut = o
        }

        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: Int(fps * 2),
                AVVideoAllowFrameReorderingKey: true,
                AVVideoExpectedSourceFrameRateKey: Int(fps),
            ],
        ])
        videoIn.expectsMediaDataInRealTime = false
        videoIn.transform = transform
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: audioBitrate,
            ])
            a.expectsMediaDataInRealTime = false
            writer.add(a)
            audioIn = a
        }

        guard writer.startWriting() else { throw writer.error ?? ClementineError.cannotWrite(out) }
        guard reader.startReading() else { throw reader.error ?? ClementineError.unsupported("Could not read the video.") }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        func pump(_ input: AVAssetWriterInput, _ output: AVAssetReaderOutput, label: String, reportsProgress: Bool) {
            group.enter()
            let q = DispatchQueue(label: "clementine.encode.\(label)")
            input.requestMediaDataWhenReady(on: q) {
                while input.isReadyForMoreMediaData {
                    if ctx.isCancelled { reader.cancelReading(); input.markAsFinished(); group.leave(); return }
                    if let sb = output.copyNextSampleBuffer() {
                        input.append(sb)
                        if reportsProgress, duration > 0 { ctx.report(CMSampleBufferGetPresentationTimeStamp(sb).seconds / duration) }
                    } else {
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }
        }
        pump(videoIn, videoOut, label: "video", reportsProgress: true)
        if let audioIn, let audioOut { pump(audioIn, audioOut, label: "audio", reportsProgress: false) }
        group.wait()
        if ctx.isCancelled { writer.cancelWriting(); throw ClementineError.helperFailed("Cancelled") }
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if reader.status == .failed { throw reader.error ?? ClementineError.unsupported("Could not read the video.") }
        guard writer.status == .completed else { throw writer.error ?? ClementineError.cannotWrite(out) }
    }
}
