import AppKit
import UniformTypeIdentifiers

/// Decides which petals appear for a given set of files, per wheel.
enum OperationCatalog {
    static let maxPetals = 8

    /// The wheel shows the first eight; the picker window and the command line see everything.
    static func operations(for files: [FileItem], kind: WheelKind) -> [Operation] {
        Array(allOperations(for: files, kind: kind).prefix(maxPetals))
    }

    static func allOperations(for files: [FileItem], kind: WheelKind) -> [Operation] {
        guard !files.isEmpty else { return [] }
        switch kind {
        case .convert: return convert(files)
        case .tools: return tools(files)
        case .actions: return actions(files)
        }
    }

    static func all(for files: [FileItem]) -> [Operation] {
        WheelKind.allCases.flatMap { allOperations(for: files, kind: $0) }
    }

    static func operation(id: String, for files: [FileItem]) -> Operation? {
        all(for: files).first { $0.id == id }
    }

    // MARK: Convert

    private static func convert(_ files: [FileItem]) -> [Operation] {
        var ops: [Operation] = []
        let exts = Set(files.map(\.ext))

        if files.allImages {
            for t in ImageConverter.writableTargets() {
                let targetExts = Set([t.type.preferredFilenameExtension ?? ""] + (t.type.tags[.filenameExtension] ?? []))
                if exts.count == 1, targetExts.contains(exts.first!) { continue }
                ops.append(Operation("convert.image.\(ImageConverter.ext(for: t.type))", t.title, t.symbol, .convert) { input in
                    try perFile(input) { f, c in [try ImageConverter.convert(f, to: t.type, ctx: c)] }
                })
            }
            ops.append(Operation("convert.image.pdf", "PDF", "doc.richtext", .convert) { input in
                OperationResult(outputs: [try PDFConverter.combine(input.files, ctx: input.ctx)])
            })
        } else if files.allAudio {
            for t in AudioConverter.targets() where !(exts.count == 1 && exts.first == t.ext && t.suffix == nil) {
                ops.append(Operation("convert.audio.\(t.id)", t.title, t.symbol, .convert) { input in
                    try perFile(input) { f, c in [try AudioConverter.convert(f, to: t, ctx: c)] }
                })
            }
        } else if files.allVideo {
            for t in VideoConverter.targets(for: files) where !(exts.count == 1 && exts.first == t.ext && t.id != "hevc") {
                ops.append(Operation("convert.video.\(t.id)", t.title, t.symbol, .convert) { input in
                    try perFile(input) { f, c in [try VideoConverter.convert(f, to: t, ctx: c)] }
                })
            }
        } else if files.allPDF {
            ops.append(Operation("convert.pdf.png", "PNG pages", "photo.on.rectangle", .convert) { input in
                try perFile(input) { f, c in try PDFConverter.toImages(f, type: .png, ctx: c) }
            })
            ops.append(Operation("convert.pdf.jpg", "JPEG pages", "photo", .convert) { input in
                try perFile(input) { f, c in try PDFConverter.toImages(f, type: .jpeg, ctx: c) }
            })
            ops.append(Operation("convert.pdf.docx", "Word", "doc.text", .convert) { input in
                try perFile(input) { f, c in [try PDFConverter.toDocument(f, type: .officeOpenXML, ext: "docx", ctx: c)] }
            })
            ops.append(Operation("convert.pdf.rtf", "RTF", "doc.plaintext", .convert) { input in
                try perFile(input) { f, c in [try PDFConverter.toDocument(f, type: .rtf, ext: "rtf", ctx: c)] }
            })
            ops.append(Operation("convert.pdf.txt", "Text", "text.alignleft", .convert) { input in
                try perFile(input) { f, c in [try PDFConverter.toText(f, forceOCR: false, ctx: c)] }
            })
            if files.count > 1 {
                ops.append(Operation("convert.pdf.merge", "Merge", "rectangle.stack", .convert) { input in
                    OperationResult(outputs: [try PDFConverter.combine(input.files, ctx: input.ctx)])
                })
            }
        } else if files.allTextual {
            for t in DocumentConverter.targets where !(exts.count == 1 && exts.first == t.ext) {
                if t.id == "md", files.contains(where: { $0.kind == .text }) { continue }
                ops.append(Operation("convert.doc.\(t.id)", t.title, t.symbol, .convert) { input in
                    try perFile(input) { f, c in
                        // Word files get Pages' layout engine for PDF when it is installed; TextKit is the fallback.
                        if t.id == "pdf", ["docx", "doc"].contains(f.ext), OfficeBridge.canConvert(f),
                           let pdf = try? OfficeBridge.convert(f, to: OfficeBridge.Target(id: "pdf", title: "PDF", symbol: "doc.richtext", ext: "pdf", format: "PDF"), ctx: c) {
                            return [pdf]
                        }
                        return [try DocumentConverter.convert(f, to: t, ctx: c)]
                    }
                })
            }
            if files.allSatisfy({ OfficeBridge.family(of: $0) == .text && OfficeBridge.canConvert($0) }) {
                ops.append(Operation("convert.doc.epub", "EPUB", "book", .convert) { input in
                    try perFile(input) { f, c in
                        [try OfficeBridge.convert(f, to: OfficeBridge.Target(id: "epub", title: "EPUB", symbol: "book", ext: "epub", format: "EPUB"), ctx: c)]
                    }
                })
            }
        } else if files.allOffice, let first = files.first,
                  files.allSatisfy({ OfficeBridge.family(of: $0) == OfficeBridge.family(of: first) }) {
            for t in OfficeBridge.targets(for: first) {
                ops.append(Operation("convert.office.\(t.id)", t.title, t.symbol, .convert) { input in
                    try perFile(input) { f, c in [try OfficeBridge.convert(f, to: t, ctx: c)] }
                })
            }
        } else if files.allSubtitles {
            if exts != ["vtt"] {
                ops.append(Operation("convert.subtitle.vtt", "WebVTT", "captions.bubble", .convert) { input in
                    try perFile(input) { f, c in [try Subtitles.convert(f, to: "vtt", ctx: c)] }
                })
            }
            if exts != ["srt"] {
                ops.append(Operation("convert.subtitle.srt", "SRT", "captions.bubble.fill", .convert) { input in
                    try perFile(input) { f, c in [try Subtitles.convert(f, to: "srt", ctx: c)] }
                })
            }
            ops.append(Operation("convert.subtitle.txt", "Transcript", "text.alignleft", .convert) { input in
                try perFile(input) { f, c in [try Subtitles.convert(f, to: "txt", ctx: c)] }
            })
        } else if files.allArchives {
            ops.append(Operation("convert.archive.extract", "Extract", "shippingbox.and.arrow.backward", .convert) { input in
                try perFile(input) { f, c in [try ArchiveTool.extract(f, ctx: c)] }
            })
        } else if files.allPrintable {
            ops.append(Operation("convert.mixed.pdf", "Combine to PDF", "doc.richtext", .convert) { input in
                OperationResult(outputs: [try PDFConverter.combine(input.files, ctx: input.ctx)])
            })
        }
        ops.append(zipOperation)
        return ops
    }

    // MARK: Tools

    private static func tools(_ files: [FileItem]) -> [Operation] {
        var ops: [Operation] = []
        if files.allImages {
            ops.append(Operation("edit.image", "Crop & Adjust", "crop.rotate", .tools, editor: .image))
            ops.append(Operation("edit.redact", "Redact", "rectangle.slash", .tools, editor: .redact))
            ops.append(Operation("edit.annotate", "Annotate", "pencil.and.outline", .tools, editor: .annotate))
            ops.append(Operation("tool.image.compress", "Compress", "arrow.down.right.and.arrow.up.left", .tools) { input in
                try perFile(input) { f, c in [try ImageConverter.compress(f, ctx: c)] }
            })
            ops.append(Operation("edit.targetsize", "Target Size…", "scalemass", .tools, editor: .targetSize))
            if files.count > 1 {
                ops.append(Operation("tool.image.combinepdf", "Combine to PDF", "doc.richtext", .tools) { input in
                    OperationResult(outputs: [try PDFConverter.combine(input.files, ctx: input.ctx)])
                })
                ops.append(Operation("edit.collage", "Collage…", "square.grid.2x2", .tools, editor: .collage))
            }
            ops.append(Operation("tool.image.strip", "Remove Metadata", "eye.slash", .tools) { input in
                try perFile(input) { f, c in [try ImageConverter.stripMetadata(f, ctx: c)] }
            })
            ops.append(Operation("edit.metadata", "Metadata…", "info.circle", .tools, editor: .metadata))
            ops.append(Operation("tool.image.ocr", "OCR to Text", "text.viewfinder", .tools) { input in
                try perFile(input) { f, c in [try OCR.imageToText(f, ctx: c)] }
            })
            ops.append(Operation("tool.image.qr", "Read QR", "qrcode.viewfinder", .tools) { input in
                var found: [String] = []
                for f in input.files { found += try OCR.readCodes(f) }
                guard !found.isEmpty else { return OperationResult(outputs: [], message: "No QR or barcode found", revealable: false) }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(found.joined(separator: "\n"), forType: .string)
                return OperationResult(outputs: [], message: "Copied: " + found.joined(separator: " · "), revealable: false)
            })
        } else if files.allPDF {
            ops.append(Operation("edit.pdf.organize", "Organize", "rectangle.grid.2x2", .tools, editor: .pdfOrganizer))
            if files.count > 1 {
                ops.append(Operation("tool.pdf.merge", "Merge", "rectangle.stack", .tools) { input in
                    OperationResult(outputs: [try PDFConverter.combine(input.files, ctx: input.ctx)])
                })
            }
            ops.append(Operation("tool.pdf.split", "Split Pages", "rectangle.split.3x1", .tools) { input in
                try perFile(input) { f, c in try PDFConverter.split(f, ctx: c) }
            })
            ops.append(Operation("tool.pdf.compress", "Compress", "arrow.down.right.and.arrow.up.left", .tools) { input in
                try perFile(input) { f, c in [try PDFConverter.compress(f, ctx: c)] }
            })
            ops.append(Operation("tool.pdf.ocr", "OCR to Text", "text.viewfinder", .tools) { input in
                try perFile(input) { f, c in [try PDFConverter.toText(f, forceOCR: true, ctx: c)] }
            })
            ops.append(Operation("tool.pdf.rotate", "Rotate 90°", "rotate.right", .tools) { input in
                try perFile(input) { f, c in [try PDFConverter.rotate(f, ctx: c)] }
            })
            ops.append(Operation("tool.pdf.images", "Pages to PNG", "photo.on.rectangle", .tools) { input in
                try perFile(input) { f, c in try PDFConverter.toImages(f, type: .png, ctx: c) }
            })
        } else if files.allVideo {
            ops.append(Operation("edit.video.trim", "Trim & Crop", "scissors", .tools, editor: .videoTrim))
            ops.append(Operation("tool.video.compress", "Compress 720p", "arrow.down.right.and.arrow.up.left", .tools) { input in
                try perFile(input) { f, c in [try VideoConverter.compress(f, ctx: c)] }
            })
            ops.append(Operation("edit.targetsize", "Target Size…", "scalemass", .tools, editor: .targetSize))
            ops.append(Operation("tool.video.mute", "Mute", "speaker.slash", .tools) { input in
                try perFile(input) { f, c in [try VideoConverter.mute(f, ctx: c)] }
            })
            ops.append(Operation("tool.video.audio", "Extract Audio", "waveform", .tools) { input in
                try perFile(input) { f, c in
                    let t = VideoConverter.Target(title: "M4A", ext: "m4a", symbol: "waveform", id: "m4a")
                    return [try VideoConverter.convert(f, to: t, ctx: c)]
                }
            })
            ops.append(Operation("tool.video.snapshot", "Snapshot", "camera", .tools) { input in
                try perFile(input) { f, c in [try VideoConverter.snapshot(f, ctx: c)] }
            })
            ops.append(Operation("tool.video.gif", "GIF Preview", "photo.stack", .tools) { input in
                try perFile(input) { f, c in
                    let t = VideoConverter.Target(title: "GIF", ext: "gif", symbol: "photo.stack", id: "gif")
                    return [try VideoConverter.convert(f, to: t, ctx: c)]
                }
            })
            ops.append(Operation("tool.video.speed2", "Speed 2×", "hare", .tools) { input in
                try perFile(input) { f, c in [try VideoConverter.speed(f, factor: 2, ctx: c)] }
            })
        } else if files.kinds == [.image, .video] {
            ops.append(Operation("edit.targetsize", "Target Size…", "scalemass", .tools, editor: .targetSize))
        } else if files.allAudio {
            ops.append(Operation("edit.audio.trim", "Trim & Bleep", "scissors", .tools, editor: .audioTrim))
            ops.append(Operation("tool.audio.compress", "Compress", "arrow.down.right.and.arrow.up.left", .tools) { input in
                try perFile(input) { f, c in [try AudioConverter.compress(f, ctx: c)] }
            })
            ops.append(Operation("tool.audio.mono", "Mono", "speaker.wave.1", .tools) { input in
                try perFile(input) { f, c in [try AudioConverter.mono(f, ctx: c)] }
            })
            ops.append(Operation("tool.audio.speed15", "Speed 1.5×", "hare", .tools) { input in
                try perFile(input) { f, c in [try AudioConverter.speed(f, factor: 1.5, ctx: c)] }
            })
            ops.append(Operation("tool.audio.speedhalf", "Slow 0.5×", "tortoise", .tools) { input in
                try perFile(input) { f, c in [try AudioConverter.speed(f, factor: 0.5, ctx: c)] }
            })
            ops.append(Operation("edit.visualizer", "Visualizer…", "waveform.and.magnifyingglass", .tools, editor: .visualizer))
        } else if files.allTextual {
            ops.append(Operation("tool.doc.pdf", "Print to PDF", "doc.richtext", .tools) { input in
                try perFile(input) { f, c in [try DocumentConverter.convert(f, to: DocumentConverter.targets[0], ctx: c)] }
            })
        } else if files.allPrintable {
            ops.append(Operation("tool.mixed.combinepdf", "Combine to PDF", "doc.richtext", .tools) { input in
                OperationResult(outputs: [try PDFConverter.combine(input.files, ctx: input.ctx)])
            })
        }
        ops.append(zipOperation)
        ops.append(Operation("tool.any.checksum", "SHA-256", "number.square", .tools) { input in
            try perFile(input) { f, _ in [try ChecksumTool.write(f)] }
        })
        ops.append(Operation("tool.any.duplicate", "Duplicate", "plus.square.on.square", .tools) { input in
            try FileActions.duplicate(input.files)
        })
        if files.allVideo {
            ops.append(Operation("tool.video.subtitles", "Subtitles", "captions.bubble", .tools) { input in
                try perFile(input) { f, c in [try Subtitles.extract(from: f, ctx: c)] }
            })
            ops.append(Operation("tool.video.speedhalf", "Slow 0.5×", "tortoise", .tools) { input in
                try perFile(input) { f, c in [try VideoConverter.speed(f, factor: 0.5, ctx: c)] }
            })
        }
        if files.allImages {
            // Past the eight wheel petals, still reachable from the picker and the command line.
            ops.append(Operation("tool.image.resize1920", "Resize 1920", "arrow.down.left.and.arrow.up.right.rectangle", .tools) { input in
                try perFile(input) { f, c in [try ImageConverter.resize(f, maxPixel: 1920, ctx: c)] }
            })
            ops.append(Operation("tool.image.resize800", "Resize 800", "rectangle.compress.vertical", .tools) { input in
                try perFile(input) { f, c in [try ImageConverter.resize(f, maxPixel: 800, ctx: c)] }
            })
            ops.append(Operation("tool.image.rotate", "Rotate 90°", "rotate.right", .tools) { input in
                try perFile(input) { f, c in [try ImageConverter.rotate(f, ctx: c)] }
            })
        }
        return ops
    }

    private static var zipOperation: Operation {
        Operation("any.zip", "Zip", "doc.zipper", .tools) { input in
            OperationResult(outputs: [try ArchiveTool.zip(input.files, ctx: input.ctx)])
        }
    }

    // MARK: Actions

    private static func actions(_ files: [FileItem]) -> [Operation] {
        var ops: [Operation] = [
            Operation("action.float.new", "New Float", "paperclip", .actions) { input in
                let urls = input.urls
                Task { @MainActor in FloatManager.shared.newFloat(with: urls) }
                return .none
            },
        ]
        if FloatManager.hasFloats {
            ops.append(Operation("action.float.add", "Add to Float", "paperclip.badge.ellipsis", .actions) { input in
                let urls = input.urls
                Task { @MainActor in FloatManager.shared.addToLatest(urls) }
                return .none
            })
        }
        ops += [
            Operation("action.copypath", "Copy Path", "text.quote", .actions) { input in FileActions.copyPaths(input.files) },
            Operation("action.copyfiles", "Copy Files", "doc.on.doc", .actions) { input in FileActions.copyFiles(input.files) },
            Operation("action.reveal", "Reveal", "folder", .actions) { input in FileActions.reveal(input.files) },
            Operation("action.terminal", "Terminal Here", "terminal", .actions) { input in FileActions.openTerminal(input.files) },
            Operation("action.airdrop", "AirDrop", "wifi", .actions) { input in FileActions.airdrop(input.files) },
            Operation("action.trash", "Move to Trash", "trash", .actions) { input in FileActions.trash(input.files) },
        ]
        return ops
    }
}
