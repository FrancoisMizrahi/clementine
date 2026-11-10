import AVFoundation
import CoreGraphics
import Foundation
#if canImport(CWebP)
import CWebP
#endif
#if canImport(CLame)
import CLame
#endif

/// WebP through libwebp when it was linked at build time (Tools/fetch-webp.sh), otherwise unavailable.
enum WebPEncoder {
    static var isAvailable: Bool {
        #if canImport(CWebP)
        return true
        #else
        return false
        #endif
    }

    /// quality 0...1; 1 means lossless.
    static func encode(_ image: CGImage, quality: Double) throws -> Data {
        #if canImport(CWebP)
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= 16_383, h <= 16_383 else { throw ClementineError.unsupported("WebP images are limited to 16383 pixels per side.") }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let raw = ctx.data else { throw ClementineError.noOutput }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bytes = raw.assumingMemoryBound(to: UInt8.self)
        let hasAlpha = ![CGImageAlphaInfo.none, .noneSkipLast, .noneSkipFirst].contains(image.alphaInfo)
        if hasAlpha { // un-premultiply for WebP
            for i in stride(from: 0, to: w * h * 4, by: 4) {
                let a = Int(bytes[i + 3])
                if a > 0 && a < 255 {
                    bytes[i] = UInt8(min(255, Int(bytes[i]) * 255 / a))
                    bytes[i + 1] = UInt8(min(255, Int(bytes[i + 1]) * 255 / a))
                    bytes[i + 2] = UInt8(min(255, Int(bytes[i + 2]) * 255 / a))
                }
            }
        }
        var out: UnsafeMutablePointer<UInt8>? = nil
        let size: Int
        if quality >= 0.999 {
            size = WebPEncodeLosslessRGBA(bytes, Int32(w), Int32(h), Int32(w * 4), &out)
        } else {
            size = WebPEncodeRGBA(bytes, Int32(w), Int32(h), Int32(w * 4), Float(max(quality, 0.05) * 100), &out)
        }
        guard size > 0, let out else { throw ClementineError.helperFailed("libwebp could not encode the image.") }
        defer { WebPFree(out) }
        return Data(bytes: out, count: size)
        #else
        throw ClementineError.unsupported("WebP encoding is not built in. Run Tools/fetch-webp.sh, then ./build.sh.")
        #endif
    }
}

/// MP3 through LAME when it was linked at build time (ThirdParty/lame).
enum MP3Encoder {
    static var isAvailable: Bool {
        #if canImport(CLame)
        return true
        #else
        return false
        #endif
    }

    /// VBR quality 0 (best) ... 9; 2 is the usual "~190 kbps" setting.
    static func encode(_ input: URL, to output: URL, vbrQuality: Float = 2, ctx: JobContext) throws {
        #if canImport(CLame)
        let asset = AVURLAsset(url: input)
        let tracks = try Shell.sync { try await asset.loadTracks(withMediaType: .audio) }
        guard let track = tracks.first else { throw ClementineError.unsupported("No audio track in \(input.lastPathComponent).") }
        let duration = try Shell.sync { try await asset.load(.duration) }.seconds
        var rate = 44_100.0
        var channels = 2
        if let d = (try? Shell.sync { try await track.load(.formatDescriptions) })?.first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d)?.pointee {
            if asbd.mSampleRate > 0 { rate = asbd.mSampleRate }
            if asbd.mChannelsPerFrame > 0 { channels = Int(asbd.mChannelsPerFrame) }
        }
        channels = min(channels, 2)
        if ![8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000].contains(Int(rate)) { rate = 44_100 }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(out)
        guard let lame = lame_init() else { throw ClementineError.helperFailed("LAME could not start.") }
        defer { lame_close(lame) }
        lame_set_in_samplerate(lame, Int32(rate))
        lame_set_num_channels(lame, Int32(channels))
        lame_set_mode(lame, channels == 1 ? MONO : JOINT_STEREO)
        lame_set_VBR(lame, vbr_default)
        lame_set_VBR_quality(lame, vbrQuality)
        lame_set_quality(lame, 3)
        guard lame_init_params(lame) >= 0 else { throw ClementineError.helperFailed("LAME rejected the audio format.") }
        guard let fp = fopen(output.path, "w+b") else { throw ClementineError.cannotWrite(output) }
        defer { fclose(fp) }
        guard reader.startReading() else { throw reader.error ?? ClementineError.cannotRead(input) }
        var mp3 = [UInt8](repeating: 0, count: 2 * 1024 * 1024)
        var seconds = 0.0
        while let sb = out.copyNextSampleBuffer() {
            if ctx.isCancelled { reader.cancelReading(); throw ClementineError.helperFailed("Cancelled") }
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let p = pointer else { continue }
            let frames = length / (2 * channels)
            let written: Int32 = p.withMemoryRebound(to: Int16.self, capacity: frames * channels) { pcm in
                mp3.withUnsafeMutableBufferPointer { buf in
                    channels == 2
                        ? lame_encode_buffer_interleaved(lame, pcm, Int32(frames), buf.baseAddress, Int32(buf.count))
                        : lame_encode_buffer(lame, pcm, nil, Int32(frames), buf.baseAddress, Int32(buf.count))
                }
            }
            guard written >= 0 else { throw ClementineError.helperFailed("LAME encode error \(written).") }
            if written > 0 { fwrite(mp3, 1, Int(written), fp) }
            seconds += Double(frames) / rate
            if duration > 0 { ctx.report(seconds / duration) }
        }
        if reader.status == .failed { throw reader.error ?? ClementineError.cannotRead(input) }
        let tail = mp3.withUnsafeMutableBufferPointer { buf in lame_encode_flush(lame, buf.baseAddress, Int32(buf.count)) }
        if tail > 0 { fwrite(mp3, 1, Int(tail), fp) }
        fflush(fp)
        lame_mp3_tags_fid(lame, fp) // Xing/LAME header so players show the right duration
        #else
        throw ClementineError.unsupported("MP3 encoding is not built in (ThirdParty/lame missing).")
        #endif
    }
}
