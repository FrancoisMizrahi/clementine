import AppKit
import SwiftUI

/// Small dialog for "Target Size…": pick a budget, then the job runs like any other.
@MainActor
final class TargetSizeModel: ObservableObject {
    let files: [FileItem]
    @Published var preset: Int
    @Published var customValue: String = ""
    @Published var customUnit: Int = 1_000_000
    @Published var allowDownscale = true
    @Published var imageFormat: EditOutputFormat = .same

    var isVideo: Bool { files.allSatisfy { $0.kind == .video } }
    var presets: [Int] {
        isVideo ? [8_000_000, 10_000_000, 25_000_000, 50_000_000, 100_000_000, 250_000_000]
                : [100_000, 250_000, 500_000, 1_000_000, 2_000_000, 5_000_000]
    }
    var bytes: Int {
        if let v = Double(customValue.replacingOccurrences(of: ",", with: ".")), v > 0 { return Int(v * Double(customUnit)) }
        return preset
    }
    var inputTotal: Int64 {
        files.reduce(0) { $0 + Int64((try? $1.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    init(files: [FileItem]) {
        self.files = files
        let video = files.allSatisfy { $0.kind == .video }
        preset = video ? 25_000_000 : 1_000_000
    }

    func run() {
        let request = TargetSizeRequest(bytes: bytes, allowDownscale: allowDownscale, imageFormat: imageFormat)
        let op = Operation("tool.targetsize.run", "Target \(request.label)", "scalemass", .tools) { input in
            try perFile(input) { f, c in
                switch f.kind {
                case .image: return [try TargetSize.image(f, request, ctx: c)]
                case .video: return [try TargetSize.video(f, request, ctx: c)]
                default: throw ClementineError.unsupported("\(f.name) is neither an image nor a video.")
                }
            }
        }
        JobCenter.shared.run(op, urls: files.map(\.url))
    }
}

struct TargetSizeView: View {
    @ObservedObject var model: TargetSizeModel
    unowned let controller: EditorWindowController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "scalemass").font(.system(size: 26)).foregroundStyle(Color.clementine)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Compress to a target size").font(.headline)
                    Text("\(model.files.count == 1 ? model.files[0].name : "\(model.files.count) files") · \(ByteCountFormatter.string(fromByteCount: model.inputTotal, countStyle: .file)) now")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Picker("Target", selection: $model.preset) {
                ForEach(model.presets, id: \.self) { b in Text(ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)).tag(b) }
            }
            .pickerStyle(.segmented)
            HStack {
                Text("Or custom").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. 1.5", text: $model.customValue).textFieldStyle(.roundedBorder).frame(width: 90)
                Picker("", selection: $model.customUnit) {
                    Text("KB").tag(1_000)
                    Text("MB").tag(1_000_000)
                }
                .labelsHidden().frame(width: 70)
                Spacer()
            }
            if model.isVideo {
                Text("Re-encodes as H.264 MP4 with the bitrate that fits the budget; the frame is shrunk when the budget is tight. Audio becomes AAC.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle("Allow downscaling when quality alone is not enough", isOn: $model.allowDownscale)
                Picker("Format", selection: $model.imageFormat) {
                    Text("Same (JPEG for PNG)").tag(EditOutputFormat.same)
                    Text("JPEG").tag(EditOutputFormat.jpeg)
                    Text("HEIC").tag(EditOutputFormat.heic)
                    if WebPEncoder.isAvailable { Text("WebP").tag(EditOutputFormat.webp) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { controller.dismiss() }.keyboardShortcut(.cancelAction)
                Button("Compress") {
                    model.run()
                    controller.dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Color.clementine)
                .disabled(model.bytes <= 0)
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}
