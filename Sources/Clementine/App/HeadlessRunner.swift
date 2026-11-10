import AppKit
import AVFoundation

/// Command-line access to the same engine the wheel uses, for scripting and tests:
///   Clementine --list file...                 show operation ids for these files
///   Clementine --run <operation-id> file...   run one and print the outputs
enum HeadlessRunner {
    static func main(_ args: [String]) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let mode = args.first else { return usage() }
        FFmpeg.shared.detectIfNeeded()
        switch mode {
        case "--list":
            let files = args.dropFirst().map { FileItem(url: URL(fileURLWithPath: $0)) }
            guard !files.isEmpty else { return usage() }
            for f in files { print("\(f.name): \(f.kind.rawValue) (\(f.type?.identifier ?? "?"))") }
            for kind in WheelKind.allCases {
                print("\n[\(kind.title)]")
                for op in OperationCatalog.operations(for: Array(files), kind: kind) { print("  \(op.id.padding(toLength: 28, withPad: " ", startingAt: 0)) \(op.title)\(op.editor != nil ? "  (editor window)" : "")") }
            }
            return 0
        case "--run":
            guard args.count >= 3 else { return usage() }
            let id = args[1]
            let files = args.dropFirst(2).map { FileItem(url: URL(fileURLWithPath: $0)) }
            guard let op = OperationCatalog.operation(id: id, for: Array(files)) else {
                FileHandle.standardError.write("No operation '\(id)' for these files. Use --list.\n".data(using: .utf8)!)
                return 2
            }
            var lastShown = -1
            let ctx = JobContext { p in
                let pct = Int(p * 100)
                if pct / 10 != lastShown / 10 { lastShown = pct; FileHandle.standardError.write("\r\(pct)%".data(using: .utf8)!) }
            }
            let start = Date()
            do {
                let result = try op.run(OperationInput(files: Array(files), ctx: ctx))
                FileHandle.standardError.write("\r".data(using: .utf8)!)
                for o in result.outputs { print(o.path) }
                if let m = result.message { print("message: \(m)") }
                print(String(format: "ok (%.2fs)", Date().timeIntervalSince(start)))
                return 0
            } catch {
                FileHandle.standardError.write("\rerror: \(error.localizedDescription)\n".data(using: .utf8)!)
                return 1
            }
        case "--target-size":
            // --target-size <bytes> <files...>  (what the Target Size dialog runs)
            guard args.count >= 3, let bytes = Int(args[1]) else { return usage() }
            let request = TargetSizeRequest(bytes: bytes, allowDownscale: true, imageFormat: .same)
            var failures = 0
            for path in args.dropFirst(2) {
                let f = FileItem(url: URL(fileURLWithPath: path))
                do {
                    let out = f.kind == .video ? try TargetSize.video(f, request, ctx: JobContext()) : try TargetSize.image(f, request, ctx: JobContext())
                    let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
                    print("\(out.lastPathComponent): \(size) bytes (target \(bytes))")
                } catch {
                    failures += 1
                    print("\(f.name): error: \(error.localizedDescription)")
                }
            }
            return failures == 0 ? 0 : 1
        case "--office-scripts":
            // --office-scripts <dir>  writes the generated AppleScripts so they can be checked with osacompile
            guard args.count >= 2 else { return usage() }
            let dir = URL(fileURLWithPath: args[1])
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for app in OfficeApp.allCases {
                let url = dir.appendingPathComponent(app.rawValue.replacingOccurrences(of: " ", with: "-") + ".applescript")
                try? OfficeBridge.script(for: app).write(to: url, atomically: true, encoding: .utf8)
                print("\(url.lastPathComponent) installed=\(app.isInstalled)")
            }
            return 0
        case "--selftest-phase4":
            // --selftest-phase4 <image> <audio> <markdown>
            guard args.count >= 4 else { return usage() }
            return selftestPhase4(image: URL(fileURLWithPath: args[1]), audio: URL(fileURLWithPath: args[2]), markdown: URL(fileURLWithPath: args[3]))
        case "--selftest-editors":
            guard args.count >= 3 else { return usage() }
            let base = selftestEditors(image: URL(fileURLWithPath: args[1]), pdf: URL(fileURLWithPath: args[2]))
            guard args.count >= 5 else { return base }
            return max(base, selftestMedia(image: URL(fileURLWithPath: args[1]), video: URL(fileURLWithPath: args[3]), audio: URL(fileURLWithPath: args[4])))
        default:
            return usage()
        }
    }

    private static func selftestPhase4(image: URL, audio: URL, markdown: URL) -> Int32 {
        var failures = 0
        func step(_ label: String, _ body: () throws -> String) {
            do { print("\(label): \(try body())") } catch { failures += 1; print("\(label): ERROR \(error.localizedDescription)") }
        }
        step("webp encoder") { WebPEncoder.isAvailable ? "linked" : "not linked (run Tools/fetch-webp.sh)" }
        step("mp3 encoder") { MP3Encoder.isAvailable ? "linked (LAME)" : "not linked" }
        step("epub write") {
            let attr = try DocumentConverter.read(FileItem(url: markdown))
            let out = Output.sibling(of: markdown, ext: "epub")
            try Output.write(to: out) { try EPUB.write(attr, title: "Clementine test", to: $0) }
            return out.lastPathComponent
        }
        step("epub read back") {
            let epub = markdown.deletingPathExtension().appendingPathExtension("epub")
            let back = try EPUB.read(epub)
            return "\(back.length) characters, starts with “\(back.string.prefix(40).replacingOccurrences(of: "\n", with: " "))”"
        }
        step("collage") {
            let out = try CollageModel.export(CollageSpec(urls: [image, image, image], layout: .auto, gap: 16, background: .white, fillCells: true, width: 1200, type: .jpeg))
            return out.lastPathComponent
        }
        step("metadata lossless rewrite") {
            let spec = MetadataEditSpec(url: image, values: ["artist": "Clementine Test", "keywords": "alpha, beta", "copyright": "© Test", "description": "Described"],
                                        originals: [:], latitude: 48.8566, longitude: 2.3522, removeGPS: false, stripAll: false)
            let out = try MetadataModel.export(spec)
            let props = CGImageSourceCreateWithURL(out as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [String: Any] ?? [:]
            let tiff = props["{TIFF}"] as? [String: Any] ?? [:], iptc = props["{IPTC}"] as? [String: Any] ?? [:], gps = props["{GPS}"] as? [String: Any] ?? [:]
            return "\(out.lastPathComponent): Artist=\(tiff["Artist"] ?? "nil") Keywords=\((iptc["Keywords"] as? [String])?.joined(separator: "|") ?? "nil") Lat=\(gps["Latitude"] ?? "nil")\(gps["LatitudeRef"] ?? "")"
        }
        if MP3Encoder.isAvailable {
            step("mp3 encode") {
                let out = Output.sibling(of: audio, ext: "mp3", suffix: "LAME")
                try Output.write(to: out) { try MP3Encoder.encode(audio, to: $0, ctx: JobContext()) }
                let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
                return "\(out.lastPathComponent) \(size) bytes"
            }
        }
        step("visualizer") {
            let spec = VisualizerSpec(url: audio, size: CGSize(width: 640, height: 360), style: .mirror, accent: CGColor(red: 1, green: 0.55, blue: 0.15, alpha: 1),
                                      backgroundImage: image, title: "Test", bars: 32, fps: 30)
            let out = try VisualizerModel.export(spec, ctx: JobContext())
            return out.lastPathComponent
        }
        return failures == 0 ? 0 : 1
    }

    private static func selftestMedia(image: URL, video: URL, audio: URL) -> Int32 {
        do {
            let pic = try EditablePicture.load(image)
            let s = pic.fullSize
            let red = CGColor(red: 0.95, green: 0.2, blue: 0.2, alpha: 1)
            let items: [Annotation] = [
                Annotation(id: UUID(), kind: .arrow, points: [CGPoint(x: s.width * 0.1, y: s.height * 0.8), CGPoint(x: s.width * 0.4, y: s.height * 0.5)], rect: .zero, color: red, strokeWidth: 6),
                Annotation(id: UUID(), kind: .rectangle, points: [], rect: CGRect(x: s.width * 0.5, y: s.height * 0.1, width: s.width * 0.3, height: s.height * 0.3), color: red, strokeWidth: 5),
                Annotation(id: UUID(), kind: .text, points: [], rect: CGRect(x: s.width * 0.05, y: s.height * 0.05, width: s.width * 0.5, height: s.height * 0.15), color: red, strokeWidth: 4, text: "Hello annotate", fontSize: s.height * 0.08),
                Annotation(id: UUID(), kind: .number, points: [], rect: CGRect(x: s.width * 0.8, y: s.height * 0.7, width: s.height * 0.15, height: s.height * 0.15), color: red, strokeWidth: 4, number: 1),
                Annotation(id: UUID(), kind: .magnifier, points: [], rect: CGRect(x: s.width * 0.55, y: s.height * 0.55, width: s.height * 0.35, height: s.height * 0.35), color: CGColor(gray: 1, alpha: 1), strokeWidth: 5),
            ]
            let out1 = try AnnotateModel.export(AnnotateSpec(url: image, items: items, type: .png, keepMetadata: false))
            print("annotate: \(out1.path)")

            let vDuration = try Shell.sync { try await AVURLAsset(url: video).load(.duration) }.seconds
            let out2 = try VideoEditModel.export(VideoEditSpec(url: video, inTime: 0.5, outTime: min(2.5, vDuration), duration: vDuration, crop: nil, mute: false))
            print("video trim (passthrough): \(out2.path)  (expect ~2.0 s)")
            let frame = try MediaThumbnails.frame(url: video, at: 1)
            let crop = CGRect(x: frame.width / 4, y: frame.height / 4, width: frame.width / 2, height: frame.height / 2)
            let out3 = try VideoEditModel.export(VideoEditSpec(url: video, inTime: 0, outTime: min(1.5, vDuration), duration: vDuration, crop: crop, mute: true))
            print("video crop+mute: \(out3.path)  (expect \(Int(crop.width))x\(Int(crop.height)), no audio, ~1.5 s)")

            let aDuration = try Shell.sync { try await AVURLAsset(url: audio).load(.duration) }.seconds
            let out4 = try AudioEditModel.export(AudioEditSpec(url: audio, inTime: 0.25, outTime: min(2.75, aDuration), duration: aDuration, bleeps: [(1.0, 1.5)]))
            print("audio trim+bleep: \(out4.path)  (expect ~2.5 s with a 1 kHz tone at 0.75-1.25 s)")
            return 0
        } catch {
            print("media error: \(error.localizedDescription)")
            return 1
        }
    }

    /// Exercises the editor export pipelines without a window.
    private static func selftestEditors(image: URL, pdf: URL) -> Int32 {
        do {
            let pic = try EditablePicture.load(image)
            let oriented = CGSize(width: pic.fullSize.height, height: pic.fullSize.width)
            let crop = CGRect(x: oriented.width * 0.25, y: oriented.height * 0.25, width: oriented.width * 0.5, height: oriented.height * 0.5)
            var o = EditOrientation(); o.rotateClockwise()
            var a = Adjustments(); a.warmth = 1; a.contrast = 1.2; a.sharpness = 0.5
            let out1 = try ImageEditModel.export(ImageEditSpec(url: image, orientation: o, crop: crop, adjustments: a,
                                                               type: .jpeg, keepMetadata: true, quality: 0.9))
            print("image edit: \(out1.path)  (expect \(Int(crop.width))x\(Int(crop.height)))")

            let s = pic.fullSize
            let regions: [(CGRect, RedactStyle)] = [
                (CGRect(x: 0, y: 0, width: s.width / 3, height: s.height / 2), .pixelate),
                (CGRect(x: s.width / 3, y: 0, width: s.width / 3, height: s.height / 2), .blur),
                (CGRect(x: 2 * s.width / 3, y: 0, width: s.width / 3, height: s.height / 2), .solid),
            ]
            let out2 = try RedactModel.export(RedactSpec(url: image, regions: regions, type: .png))
            print("redact: \(out2.path)")

            let doc = try PDFConverter.open(pdf)
            var pages: [(url: URL, index: Int, rotation: Int)] = (0..<doc.pageCount).reversed().map { (url: pdf, index: $0, rotation: 0) }
            pages.append((url: pdf, index: 0, rotation: 90))
            let dest = Output.sibling(of: pdf, ext: "pdf", suffix: "Organized")
            let out3 = try PDFOrganizerModel.export(PDFOrganizeSpec(pages: pages, destination: dest))
            print("pdf organize: \(out3.path)  (expect \(doc.pageCount + 1) pages)")

            let gray = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
            var warm = Adjustments(); warm.warmth = 1
            if let cg = CIPipeline.render(CIPipeline.adjusted(gray, warm), colorSpace: nil),
               let data = cg.dataProvider?.data as Data? {
                print("warmth +1 on gray -> R=\(data[0]) G=\(data[1]) B=\(data[2])  (expect R > B)")
            }
            return 0
        } catch {
            print("error: \(error.localizedDescription)")
            return 1
        }
    }

    private static func usage() -> Int32 {
        print("""
        Clementine headless mode
          --list <files...>                 list operations available for these files
          --run <operation-id> <files...>   run one operation
          --render-wheel out.png [convert|tools|actions] [sample files...]
        """)
        return 64
    }
}
