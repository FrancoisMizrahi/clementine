import AVFoundation
import AppKit
import SwiftUI

struct BleepRange: Identifiable, Equatable {
    let id: UUID
    var start: Double
    var end: Double
}

struct AudioEditSpec: @unchecked Sendable {
    let url: URL
    let inTime: Double
    let outTime: Double
    let duration: Double
    let bleeps: [(Double, Double)]
}

enum ToneGenerator {
    /// 16-bit mono PCM WAV sine, used as the bleep.
    static func wav(seconds: Double, frequency: Double = 1000, sampleRate: Int = 44_100) -> Data {
        let frames = Int(seconds * Double(sampleRate))
        var pcm = Data(capacity: frames * 2)
        for i in 0..<frames {
            let v = Int16(0.6 * 32767 * sin(Double(i) * frequency * 2 * .pi / Double(sampleRate)))
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }
}

@MainActor
final class AudioEditModel: ObservableObject {
    enum Mode { case scrub, bleep }
    let file: FileItem
    let player: PlayerController
    @Published var inTime: Double = 0
    @Published var outTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var peaks: [Float] = []
    @Published var bleeps: [BleepRange] = []
    @Published var selectedBleep: UUID?
    @Published var mode: Mode = .scrub
    @Published var draftRange: (Double, Double)?
    @Published var error: String?
    private var undoStack: [[BleepRange]] = []

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
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Waveform.peaks(url: url, buckets: 1200) }
            Task { @MainActor in
                switch result {
                case .success(let p): self.peaks = p
                case .failure(let e): self.error = e.localizedDescription
                }
            }
        }
    }

    func setIn() { inTime = min(player.currentTime, outTime - 0.05); player.stopAt = outTime }
    func setOut() { outTime = max(player.currentTime, inTime + 0.05); player.stopAt = outTime }
    func previewRange() { player.stopAt = outTime; player.play(from: inTime) }

    private func pushUndo() { undoStack.append(bleeps); if undoStack.count > 50 { undoStack.removeFirst() } }
    func undo() { if let last = undoStack.popLast() { bleeps = last; if let s = selectedBleep, !bleeps.contains(where: { $0.id == s }) { selectedBleep = nil } } }

    func addBleep(_ start: Double, _ end: Double) {
        let s = max(0, min(start, end)), e = min(duration, max(start, end))
        guard e - s >= 0.05 else { return }
        pushUndo()
        let r = BleepRange(id: UUID(), start: s, end: e)
        bleeps.append(r)
        bleeps.sort { $0.start < $1.start }
        selectedBleep = r.id
    }
    func addBleepAtPlayhead() { addBleep(player.currentTime - 0.5, player.currentTime + 0.5) }
    func deleteSelected() {
        guard let s = selectedBleep else { return }
        pushUndo()
        bleeps.removeAll { $0.id == s }
        selectedBleep = nil
    }
    func clearBleeps() { guard !bleeps.isEmpty else { return }; pushUndo(); bleeps.removeAll(); selectedBleep = nil }

    func spec() -> AudioEditSpec {
        AudioEditSpec(url: file.url, inTime: inTime, outTime: outTime, duration: duration,
                      bleeps: bleeps.map { ($0.start, $0.end) }.filter { $0.1 > inTime && $0.0 < outTime })
    }

    /// Composition trimmed to the kept range; bleeps mute the source and lay a tone track over it via an audio mix.
    nonisolated static func export(_ s: AudioEditSpec) throws -> URL {
        let asset = AVURLAsset(url: s.url)
        let range = CMTimeRange(start: CMTime(seconds: s.inTime, preferredTimescale: 600), end: CMTime(seconds: s.outTime, preferredTimescale: 600))
        let comp = AVMutableComposition()
        let srcTracks = try Shell.sync { try await asset.loadTracks(withMediaType: .audio) }
        guard let src = srcTracks.first, let ct = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ClementineError.unsupported("No audio track in \(s.url.lastPathComponent).")
        }
        try ct.insertTimeRange(range, of: src, at: .zero)
        var mix: AVMutableAudioMix?
        var job: URL?
        defer { if let job { try? FileManager.default.removeItem(at: job) } }
        if !s.bleeps.isEmpty {
            let dir = try Output.jobDirectory("bleep")
            job = dir
            let longest = s.bleeps.map { $0.1 - $0.0 }.max() ?? 1
            let toneURL = dir.appendingPathComponent("tone.wav")
            try ToneGenerator.wav(seconds: min(longest + 0.5, 3600)).write(to: toneURL)
            let toneAsset = AVURLAsset(url: toneURL)
            guard let toneTrack = try Shell.sync({ try await toneAsset.loadTracks(withMediaType: .audio) }).first,
                  let bt = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw ClementineError.helperFailed("Could not create the bleep track.")
            }
            let srcParams = AVMutableAudioMixInputParameters(track: ct)
            for (a, b) in s.bleeps {
                let start = max(a - s.inTime, 0), end = min(b - s.inTime, s.outTime - s.inTime)
                guard end - start >= 0.02 else { continue }
                let startT = CMTime(seconds: start, preferredTimescale: 600), endT = CMTime(seconds: end, preferredTimescale: 600)
                try bt.insertTimeRange(CMTimeRange(start: .zero, duration: endT - startT), of: toneTrack, at: startT)
                srcParams.setVolume(0, at: startT)
                srcParams.setVolume(1, at: endT)
            }
            let beepParams = AVMutableAudioMixInputParameters(track: bt)
            beepParams.setVolume(0.35, at: .zero)
            let m = AVMutableAudioMix()
            m.inputParameters = [srcParams, beepParams]
            mix = m
        }
        var parts: [String] = []
        if s.inTime > 0.01 || s.outTime < s.duration - 0.01 { parts.append("Trimmed") }
        if !s.bleeps.isEmpty { parts.append("Bleeped") }
        let suffix = parts.isEmpty ? "Edited" : parts.joined(separator: " ")
        let ext = s.url.pathExtension.lowercased()
        switch ext {
        case "wav", "aif", "aiff", "caf":
            let fileType: AVFileType = ext == "wav" ? .wav : (ext == "caf" ? .caf : .aiff)
            let dest = Output.sibling(of: s.url, ext: ext, suffix: suffix)
            return try Output.write(to: dest) { tmp in
                try AudioConverter.transcode(asset: comp, audioMix: mix, to: tmp, fileType: fileType, ctx: JobContext())
            }
        case "flac":
            let dest = Output.sibling(of: s.url, ext: "flac", suffix: suffix)
            return try Output.write(to: dest) { tmp in
                let dir = try Output.jobDirectory("flac")
                defer { try? FileManager.default.removeItem(at: dir) }
                let wav = dir.appendingPathComponent("edit.wav")
                try AudioConverter.transcode(asset: comp, audioMix: mix, to: wav, fileType: .wav, ctx: JobContext())
                try AudioToolboxEncoder.encode(wav, to: tmp, codec: .flac, ctx: JobContext())
            }
        case "mp3" where MP3Encoder.isAvailable:
            let dest = Output.sibling(of: s.url, ext: "mp3", suffix: suffix)
            return try Output.write(to: dest) { tmp in
                let dir = try Output.jobDirectory("mp3")
                defer { try? FileManager.default.removeItem(at: dir) }
                let wav = dir.appendingPathComponent("edit.wav")
                try AudioConverter.transcode(asset: comp, audioMix: mix, to: wav, fileType: .wav, ctx: JobContext())
                try MP3Encoder.encode(wav, to: tmp, ctx: JobContext())
            }
        default:
            let dest = Output.sibling(of: s.url, ext: "m4a", suffix: suffix)
            return try Output.write(to: dest) { tmp in
                try AudioConverter.transcode(asset: comp, audioMix: mix, to: tmp, fileType: .m4a, aacBitrate: 256_000, ctx: JobContext())
            }
        }
    }
}

struct AudioEditorView: View {
    @ObservedObject var model: AudioEditModel
    @ObservedObject var player: PlayerController
    unowned let controller: EditorWindowController

    init(model: AudioEditModel, controller: EditorWindowController) {
        self.model = model
        self.player = model.player
        self.controller = controller
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            waveform.padding(12)
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 360)
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
            Spacer()
            Picker("", selection: $model.mode) {
                Label("Scrub", systemImage: "cursorarrow").tag(AudioEditModel.Mode.scrub)
                Label("Draw bleep", systemImage: "speaker.slash").tag(AudioEditModel.Mode.bleep)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            Button("Bleep at playhead") { model.addBleepAtPlayhead() }.keyboardShortcut("b", modifiers: [])
            Button("Delete") { model.deleteSelected() }.keyboardShortcut(.delete, modifiers: []).disabled(model.selectedBleep == nil)
            Button("Undo") { model.undo() }.keyboardShortcut("z", modifiers: .command)
        }
        .padding(10)
    }

    private var waveform: some View {
        VStack(spacing: 6) {
            TrimTimeline(duration: model.duration, inTime: $model.inTime, outTime: $model.outTime, current: player.currentTime,
                         onScrub: { t in player.pause(); player.seek(to: t); model.player.stopAt = model.outTime },
                         onDragRange: { a, b, finished in
                             if finished { model.draftRange = nil; model.addBleep(a, b) } else { model.draftRange = (a, b) }
                         },
                         dragCreatesRange: model.mode == .bleep,
                         background: {
                             Canvas { context, size in
                                 context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(nsColor: .underPageBackgroundColor)))
                                 let peaks = model.peaks
                                 guard !peaks.isEmpty else { return }
                                 let w = size.width / CGFloat(peaks.count)
                                 var path = Path()
                                 for (i, p) in peaks.enumerated() {
                                     let h = max(CGFloat(p) * size.height * 0.95, 1)
                                     path.addRect(CGRect(x: CGFloat(i) * w, y: (size.height - h) / 2, width: max(w - 0.5, 0.5), height: h))
                                 }
                                 context.fill(path, with: .color(Color.clementine.opacity(0.85)))
                             }
                         },
                         overlay: { x in
                             ZStack(alignment: .topLeading) {
                                 ForEach(model.bleeps) { b in
                                     Rectangle()
                                         .fill(Color.red.opacity(model.selectedBleep == b.id ? 0.5 : 0.3))
                                         .overlay(Rectangle().stroke(Color.red, lineWidth: model.selectedBleep == b.id ? 2 : 1))
                                         .frame(width: max(x(b.end) - x(b.start), 2))
                                         .offset(x: x(b.start))
                                         .onTapGesture { model.selectedBleep = b.id }
                                 }
                                 if let d = model.draftRange {
                                     Rectangle().fill(Color.red.opacity(0.25)).frame(width: max(x(d.1) - x(d.0), 1)).offset(x: x(d.0))
                                 }
                             }
                         })
                .frame(height: 140)
            HStack {
                Text(model.peaks.isEmpty ? "Reading audio…" : (model.mode == .bleep ? "Drag across the waveform to add a bleep. Click one to select it." : "Click or drag to move the playhead. Switch to Draw bleep to mark ranges."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(model.bleeps.count) bleep\(model.bleeps.count == 1 ? "" : "s") · keeps \(MediaTime.string(model.outTime - model.inTime, showMillis: false))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(outputNote).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { controller.dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save") {
                let spec = model.spec()
                player.pause()
                EditorManager.shared.save(title: "Trim & Bleep", source: model.file.url) { try AudioEditModel.export(spec) }
                controller.dismiss()
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .tint(Color.clementine)
            .disabled(model.duration <= 0 || (!model.isTrimmed && model.bleeps.isEmpty))
        }
        .padding(12)
    }

    private var outputNote: String {
        switch model.file.ext {
        case "wav", "aif", "aiff", "caf", "flac": return "Saves as \(model.file.ext.uppercased()) next to the original; bleeps are a 1 kHz tone."
        default: return "Saves as M4A (AAC 256 kbps) next to the original; bleeps are a 1 kHz tone."
        }
    }
}
