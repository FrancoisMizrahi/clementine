import AVFoundation
import Foundation

enum AudioConverter {
    struct Target {
        let title: String
        let ext: String
        let symbol: String
        let id: String
        var suffix: String? = nil
    }

    /// Native first (AAC, PCM, FLAC, ALAC, Opus-in-CAF), ffmpeg only for what Apple cannot encode.
    static func targets() -> [Target] {
        var t = [Target(title: "M4A", ext: "m4a", symbol: "waveform", id: "m4a")]
        if MP3Encoder.isAvailable || FFmpeg.shared.has("libmp3lame") { t.append(Target(title: "MP3", ext: "mp3", symbol: "music.note", id: "mp3")) }
        t.append(Target(title: "FLAC", ext: "flac", symbol: "music.quarternote.3", id: "flac"))
        t.append(Target(title: "Lossless", ext: "m4a", symbol: "music.note.house", id: "alac", suffix: "Lossless"))
        t.append(Target(title: "WAV", ext: "wav", symbol: "waveform.path", id: "wav"))
        t.append(Target(title: "AIFF", ext: "aiff", symbol: "waveform.path.ecg", id: "aiff"))
        if FFmpeg.shared.has("libopus") {
            t.append(Target(title: "Opus", ext: "opus", symbol: "music.mic", id: "opus"))
        } else {
            t.append(Target(title: "Opus", ext: "caf", symbol: "music.mic", id: "opus-caf", suffix: "Opus"))
        }
        t.append(Target(title: "CAF", ext: "caf", symbol: "waveform.circle", id: "caf"))
        if FFmpeg.shared.has("libvorbis") { t.append(Target(title: "OGG", ext: "ogg", symbol: "music.note.list", id: "ogg")) }
        return t
    }

    static func convert(_ file: FileItem, to target: Target, ctx: JobContext) throws -> URL {
        let dest = Output.sibling(of: file.url, ext: target.ext, suffix: target.suffix)
        return try Output.write(to: dest) { tmp in
            switch target.id {
            case "m4a": try transcode(file.url, to: tmp, fileType: .m4a, aacBitrate: 192_000, ctx: ctx)
            case "wav": try transcode(file.url, to: tmp, fileType: .wav, ctx: ctx)
            case "aiff": try transcode(file.url, to: tmp, fileType: .aiff, ctx: ctx)
            case "caf": try transcode(file.url, to: tmp, fileType: .caf, ctx: ctx)
            case "flac": try AudioToolboxEncoder.encode(file.url, to: tmp, codec: .flac, ctx: ctx)
            case "alac": try AudioToolboxEncoder.encode(file.url, to: tmp, codec: .alac, ctx: ctx)
            case "opus-caf": try AudioToolboxEncoder.encode(file.url, to: tmp, codec: .opusCAF, ctx: ctx)
            case "mp3":
                if MP3Encoder.isAvailable { try MP3Encoder.encode(file.url, to: tmp, ctx: ctx) }
                else { try FFmpeg.shared.convert(input: file.url, output: tmp, args: ["-vn", "-c:a", "libmp3lame", "-q:a", "2"], ctx: ctx) }
            case "ogg": try FFmpeg.shared.convert(input: file.url, output: tmp, args: ["-vn", "-c:a", "libvorbis", "-q:a", "5"], ctx: ctx)
            case "opus": try FFmpeg.shared.convert(input: file.url, output: tmp, args: ["-vn", "-c:a", "libopus", "-b:a", "128k"], ctx: ctx)
            default: throw ClementineError.unsupported("Unknown audio target \(target.id)")
            }
        }
    }

    static func mono(_ file: FileItem, ctx: JobContext) throws -> URL {
        let dest = Output.sibling(of: file.url, ext: "m4a", suffix: "Mono")
        return try Output.write(to: dest) { tmp in
            try transcode(file.url, to: tmp, fileType: .m4a, aacBitrate: 128_000, channels: 1, ctx: ctx)
        }
    }

    static func compress(_ file: FileItem, ctx: JobContext) throws -> URL {
        let dest = Output.sibling(of: file.url, ext: "m4a", suffix: "Compressed")
        return try Output.write(to: dest) { tmp in
            try transcode(file.url, to: tmp, fileType: .m4a, aacBitrate: 64_000, ctx: ctx)
        }
    }

    static func speed(_ file: FileItem, factor: Double, ctx: JobContext) throws -> URL {
        let dest = Output.sibling(of: file.url, ext: "m4a", suffix: String(format: "%gx", factor))
        return try Output.write(to: dest) { tmp in
            let asset = AVURLAsset(url: file.url)
            let comp = try VideoConverter.scaledComposition(of: asset, factor: factor, includeVideo: false)
            try VideoConverter.export(asset: comp, preset: AVAssetExportPresetAppleM4A, fileType: .m4a, to: tmp, ctx: ctx) {
                $0.audioTimePitchAlgorithm = .spectral
            }
        }
    }

    // MARK: Reader/writer transcode

    /// PCM (wav/aiff/caf) or AAC (m4a) through AVAssetReader + AVAssetWriter.
    static func transcode(_ url: URL, to out: URL, fileType: AVFileType, aacBitrate: Int? = nil,
                          channels forcedChannels: Int? = nil, ctx: JobContext) throws {
        try transcode(asset: AVURLAsset(url: url), audioMix: nil, to: out, fileType: fileType, aacBitrate: aacBitrate, channels: forcedChannels, ctx: ctx)
    }

    static func transcode(asset: AVAsset, audioMix: AVAudioMix?, to out: URL, fileType: AVFileType, aacBitrate: Int? = nil,
                          channels forcedChannels: Int? = nil, ctx: JobContext) throws {
        let url = out
        let tracks = try Shell.sync { try await asset.loadTracks(withMediaType: .audio) }
        guard let track = tracks.first else { throw ClementineError.unsupported("No audio track.") }
        let duration = try Shell.sync { try await asset.load(.duration) }
        let descs = try Shell.sync { try await track.load(.formatDescriptions) }
        var sampleRate = 44_100.0
        var channels = 2
        if let d = descs.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d)?.pointee {
            sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : sampleRate
            channels = Int(asbd.mChannelsPerFrame) > 0 ? Int(asbd.mChannelsPerFrame) : channels
        }
        channels = min(forcedChannels ?? channels, 2)

        let pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: fileType == .aiff,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: pcm)
        output.alwaysCopiesSampleData = false
        output.audioMix = audioMix
        reader.add(output)

        let writerSettings: [String: Any]
        if let aacBitrate {
            writerSettings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: min(sampleRate, 48_000),
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: aacBitrate,
            ]
        } else {
            writerSettings = pcm
        }
        let writer = try AVAssetWriter(outputURL: out, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw ClementineError.unsupported("Cannot write \(fileType.rawValue).") }
        writer.add(input)

        guard writer.startWriting() else { throw writer.error ?? ClementineError.cannotWrite(out) }
        guard reader.startReading() else { throw reader.error ?? ClementineError.cannotRead(url) }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "clementine.audio.transcode")
        let done = DispatchSemaphore(value: 0)
        let total = duration.seconds
        input.requestMediaDataWhenReady(on: queue) {
            while input.isReadyForMoreMediaData {
                if ctx.isCancelled { reader.cancelReading(); input.markAsFinished(); writer.cancelWriting(); done.signal(); return }
                if let sb = output.copyNextSampleBuffer() {
                    input.append(sb)
                    if total > 0 { ctx.report(CMSampleBufferGetPresentationTimeStamp(sb).seconds / total) }
                } else {
                    input.markAsFinished()
                    writer.finishWriting { done.signal() }
                    return
                }
            }
        }
        done.wait()
        if reader.status == .failed { throw reader.error ?? ClementineError.cannotRead(url) }
        if writer.status != .completed { throw writer.error ?? ClementineError.cannotWrite(out) }
    }
}
