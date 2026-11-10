import AudioToolbox
import AVFoundation

/// Lossless and Opus output through AudioToolbox's own encoders, no ffmpeg needed.
enum NativeAudioCodec: String {
    case flac, alac, opusCAF
    var fileType: AudioFileTypeID {
        switch self {
        case .flac: return kAudioFileFLACType
        case .alac: return kAudioFileM4AType
        case .opusCAF: return kAudioFileCAFType
        }
    }
    var formatID: AudioFormatID {
        switch self {
        case .flac: return kAudioFormatFLAC
        case .alac: return kAudioFormatAppleLossless
        case .opusCAF: return kAudioFormatOpus
        }
    }
    var ext: String {
        switch self {
        case .flac: return "flac"
        case .alac: return "m4a"
        case .opusCAF: return "caf"
        }
    }
}

enum AudioToolboxEncoder {
    /// Encodes any file AVFoundation can read. Formats AudioFile cannot open directly (ogg, video containers)
    /// are first decoded to a temporary WAV.
    static func encode(_ input: URL, to output: URL, codec: NativeAudioCodec, ctx: JobContext) throws {
        var probe: ExtAudioFileRef?
        if ExtAudioFileOpenURL(input as CFURL, &probe) == noErr, let p = probe {
            ExtAudioFileDispose(p)
            try encodeDirect(input, to: output, codec: codec, ctx: ctx)
            return
        }
        let job = try Output.jobDirectory("audio")
        defer { try? FileManager.default.removeItem(at: job) }
        let wav = job.appendingPathComponent("decoded.wav")
        try AudioConverter.transcode(input, to: wav, fileType: .wav, ctx: ctx.sub(0, of: 2))
        try encodeDirect(wav, to: output, codec: codec, ctx: ctx.sub(1, of: 2))
    }

    private static func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw ClementineError.helperFailed("\(what) failed (AudioToolbox error \(status)).") }
    }

    private static func encodeDirect(_ input: URL, to output: URL, codec: NativeAudioCodec, ctx: JobContext) throws {
        var inFile: ExtAudioFileRef?
        try check(ExtAudioFileOpenURL(input as CFURL, &inFile), "Opening \(input.lastPathComponent)")
        guard let inF = inFile else { throw ClementineError.cannotRead(input) }
        defer { ExtAudioFileDispose(inF) }

        var src = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(ExtAudioFileGetProperty(inF, kExtAudioFileProperty_FileDataFormat, &size, &src), "Reading format")
        var totalFrames: Int64 = 0
        var lenSize = UInt32(MemoryLayout<Int64>.size)
        ExtAudioFileGetProperty(inF, kExtAudioFileProperty_FileLengthFrames, &lenSize, &totalFrames)

        let srcChannels = max(src.mChannelsPerFrame, 1)
        if codec == .opusCAF, srcChannels > 2 {
            throw ClementineError.unsupported("Opus output supports mono and stereo sources only.")
        }
        let channels = min(srcChannels, 8)
        let srcRate = src.mSampleRate > 0 ? src.mSampleRate : 44_100
        let rate: Double = codec == .opusCAF ? 48_000 : srcRate

        var client = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2 * channels, mFramesPerPacket: 1, mBytesPerFrame: 2 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: 16, mReserved: 0)
        try check(ExtAudioFileSetProperty(inF, kExtAudioFileProperty_ClientDataFormat, size, &client), "Configuring decoder")

        var out = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: codec.formatID,
            mFormatFlags: codec == .alac ? kAppleLosslessFormatFlag_16BitSourceData : 0,
            mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0,
            mChannelsPerFrame: channels, mBitsPerChannel: codec == .flac ? 16 : 0, mReserved: 0)
        var outSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &outSize, &out)
        // FormatInfo picks 2.5 ms Opus packets, where per-packet overhead swamps the bitrate; use 20 ms frames.
        if codec == .opusCAF { out.mFramesPerPacket = 960 }

        var outFile: ExtAudioFileRef?
        try check(ExtAudioFileCreateWithURL(output as CFURL, codec.fileType, &out, nil, AudioFileFlags.eraseFile.rawValue, &outFile),
                  "Creating \(codec.ext.uppercased()) file")
        guard let outF = outFile else { throw ClementineError.cannotWrite(output) }
        defer { ExtAudioFileDispose(outF) }
        try check(ExtAudioFileSetProperty(outF, kExtAudioFileProperty_ClientDataFormat, size, &client), "Configuring encoder")

        if codec == .opusCAF {
            var converter: AudioConverterRef?
            var convSize = UInt32(MemoryLayout<AudioConverterRef?>.size)
            if ExtAudioFileGetProperty(outF, kExtAudioFileProperty_AudioConverter, &convSize, &converter) == noErr, let conv = converter {
                var bitrate: UInt32 = channels == 1 ? 80_000 : 128_000
                AudioConverterSetProperty(conv, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &bitrate)
                var config: CFPropertyList? = nil
                ExtAudioFileSetProperty(outF, kExtAudioFileProperty_ConverterConfig, UInt32(MemoryLayout<CFPropertyList?>.size), &config)
            }
        }

        let framesPerChunk: UInt32 = 32_768
        let bytes = Int(framesPerChunk) * Int(client.mBytesPerFrame)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
        defer { buffer.deallocate() }
        let expectedFrames = Double(totalFrames) * (rate / srcRate)
        var done: Double = 0
        while true {
            if ctx.isCancelled { throw ClementineError.helperFailed("Cancelled") }
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: UInt32(bytes), mData: buffer))
            var frames = framesPerChunk
            try check(ExtAudioFileRead(inF, &frames, &list), "Decoding")
            if frames == 0 { break }
            try check(ExtAudioFileWrite(outF, frames, &list), "Encoding")
            done += Double(frames)
            if expectedFrames > 0 { ctx.report(done / expectedFrames) }
        }
    }
}
