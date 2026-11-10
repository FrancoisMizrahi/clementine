import AVFoundation
import Foundation

struct SubtitleCue {
    var start: Double
    var end: Double
    var text: String
}

/// SRT and WebVTT in both directions, plain transcripts, and extraction of embedded subtitle tracks.
enum Subtitles {
    static func parse(_ raw: String) -> [SubtitleCue] {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            if let first = lines.first, first.hasPrefix("WEBVTT") || first.hasPrefix("NOTE") || first.hasPrefix("STYLE") || first.hasPrefix("REGION") { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2, let start = time(parts[0]), let end = time(parts[1]) else { continue }
            let body = lines[(timingIndex + 1)...].joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "{\\\\[^}]*}", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: body))
        }
        return cues
    }

    /// Accepts `HH:MM:SS,mmm`, `HH:MM:SS.mmm`, `MM:SS.mmm`, with trailing cue settings.
    private static func time(_ s: String) -> Double? {
        let token = s.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        let normalized = token.replacingOccurrences(of: ",", with: ".")
        let pieces = normalized.split(separator: ":").map(String.init)
        guard (2...3).contains(pieces.count), let secs = Double(pieces.last!) else { return nil }
        var total = secs
        if pieces.count == 3, let h = Double(pieces[0]), let m = Double(pieces[1]) { total += h * 3600 + m * 60 }
        if pieces.count == 2, let m = Double(pieces[0]) { total += m * 60 }
        return total
    }

    private static func stamp(_ t: Double, separator: String) -> String {
        let total = max(t, 0)
        let h = Int(total / 3600), m = Int(total.truncatingRemainder(dividingBy: 3600) / 60)
        let s = Int(total.truncatingRemainder(dividingBy: 60)), ms = Int((total - floor(total)) * 1000 + 0.5) % 1000
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, separator, ms)
    }

    static func srt(_ cues: [SubtitleCue]) -> String {
        cues.enumerated().map { i, c in "\(i + 1)\n\(stamp(c.start, separator: ",")) --> \(stamp(c.end, separator: ","))\n\(c.text)" }
            .joined(separator: "\n\n") + "\n"
    }

    static func vtt(_ cues: [SubtitleCue]) -> String {
        "WEBVTT\n\n" + cues.map { c in "\(stamp(c.start, separator: ".")) --> \(stamp(c.end, separator: "."))\n\(c.text)" }
            .joined(separator: "\n\n") + "\n"
    }

    static func transcript(_ cues: [SubtitleCue]) -> String {
        var lines: [String] = []
        for c in cues {
            let t = c.text.replacingOccurrences(of: "\n", with: " ")
            if lines.last != t { lines.append(t) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func convert(_ file: FileItem, to format: String, ctx: JobContext) throws -> URL {
        let raw = try (try? String(contentsOf: file.url, encoding: .utf8)) ?? String(contentsOf: file.url, encoding: .isoLatin1)
        let cues = parse(raw)
        guard !cues.isEmpty else { throw ClementineError.unsupported("No subtitle cues found in \(file.name).") }
        let body: String
        switch format {
        case "srt": body = srt(cues)
        case "vtt": body = vtt(cues)
        default: body = transcript(cues)
        }
        let dest = Output.sibling(of: file.url, ext: format, suffix: format == "txt" ? "Transcript" : nil)
        return try Output.write(to: dest) { try body.write(to: $0, atomically: true, encoding: .utf8) }
    }

    /// Reads tx3g/WebVTT tracks natively from MP4/MOV; other containers go through ffmpeg when available.
    static func extract(from file: FileItem, ctx: JobContext) throws -> URL {
        let asset = AVURLAsset(url: file.url)
        var tracks = (try? Shell.sync { try await asset.loadTracks(withMediaType: .text) }) ?? []
        if tracks.isEmpty { tracks = (try? Shell.sync { try await asset.loadTracks(withMediaType: .subtitle) }) ?? [] }
        let dest = Output.sibling(of: file.url, ext: "srt")
        if tracks.isEmpty {
            guard FFmpeg.shared.isAvailable else { throw ClementineError.unsupported("No subtitle track in \(file.name).") }
            return try Output.write(to: dest) { tmp in
                try FFmpeg.shared.convert(input: file.url, output: tmp, args: ["-map", "0:s:0"], ctx: ctx)
            }
        }
        let track = tracks[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ClementineError.cannotRead(file.url) }
        var cues: [SubtitleCue] = []
        let duration = (try? Shell.sync { try await asset.load(.duration) })?.seconds ?? 0
        while let sb = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let p = pointer, length >= 2 else { continue }
            let data = Data(bytes: p, count: length)
            let n = Int(data[0]) << 8 | Int(data[1])
            guard n > 0, n + 2 <= data.count, let text = String(data: data[2..<(2 + n)], encoding: .utf8) else { continue }
            let start = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            let dur = CMSampleBufferGetDuration(sb).seconds
            cues.append(SubtitleCue(start: start, end: start + (dur.isFinite ? dur : 2), text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
            if duration > 0 { ctx.report(start / duration) }
        }
        guard !cues.isEmpty else { throw ClementineError.unsupported("The subtitle track in \(file.name) is empty.") }
        return try Output.write(to: dest) { try srt(cues).write(to: $0, atomically: true, encoding: .utf8) }
    }
}
