import Foundation
import AVFoundation

/// Optional helper: if a Homebrew or /usr/local ffmpeg exists it unlocks WebP, MP3, FLAC, OGG, Opus, WebM, MKV.
/// Nothing is bundled: Clementine only borrows an ffmpeg that is already installed.
final class FFmpeg {
    static let shared = FFmpeg()
    private let lock = NSLock()
    private var _url: URL?
    private var _encoders: Set<String> = []
    private var detected = false

    var url: URL? { detectIfNeeded(); lock.lock(); defer { lock.unlock() }; return _url }
    var isAvailable: Bool { Settings.shared.useFFmpeg && url != nil }
    func has(_ encoder: String) -> Bool {
        guard isAvailable else { return false }
        lock.lock(); defer { lock.unlock() }
        return _encoders.contains(encoder)
    }
    var version: String {
        guard let url else { return "not found" }
        let r = try? Shell.run(url, ["-version"])
        return r?.stdout.split(separator: "\n").first.map(String.init) ?? url.path
    }

    func detectIfNeeded() {
        lock.lock()
        if detected { lock.unlock(); return }
        detected = true
        lock.unlock()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/local/bin/ffmpeg"),
            home.appendingPathComponent(".local/bin/ffmpeg"),
        ]
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { return }
        var encoders = Set<String>()
        if let r = try? Shell.run(found, ["-hide_banner", "-encoders"]) {
            for line in r.stdout.split(separator: "\n") {
                // " V....D libwebp              libwebp WebP image (codec webp)"
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 2, parts[0].count == 6 else { continue }
                encoders.insert(String(parts[1]))
            }
        }
        lock.lock()
        _url = found
        _encoders = encoders
        lock.unlock()
    }

    /// Runs ffmpeg on one input. Progress is parsed from `-progress pipe:1` against the known duration.
    func convert(input: URL, output: URL, args: [String], ctx: JobContext) throws {
        guard let exe = url else { throw ClementineError.unsupported("ffmpeg is not installed.") }
        let duration = (try? Shell.sync { try await AVURLAsset(url: input).load(.duration).seconds }) ?? 0
        var full = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-nostats", "-progress", "pipe:1", "-i", input.path]
        full += args
        full.append(output.path)
        let r = try Shell.run(exe, full, env: ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory()]) { line in
            guard duration > 0 else { return }
            if line.hasPrefix("out_time_us="), let us = Double(line.dropFirst("out_time_us=".count)) {
                ctx.report(us / 1_000_000 / duration)
            } else if line.hasPrefix("out_time_ms="), let ms = Double(line.dropFirst("out_time_ms=".count)) {
                ctx.report(ms / 1_000_000 / duration) // ffmpeg's out_time_ms is actually microseconds
            }
        }
        guard r.status == 0 else {
            let msg = r.stderr.split(separator: "\n").last.map(String.init) ?? "ffmpeg exited with \(r.status)"
            throw ClementineError.helperFailed(msg)
        }
    }
}
