import AppKit
import CryptoKit
import Vision
import UniformTypeIdentifiers

enum OCR {
    /// Two passes: the fast detector finds where text is (the accurate model misses small text on a mostly
    /// blank page), then the accurate model reads a crop around that region. Falls back to the fast result.
    static func recognize(_ image: CGImage) throws -> String {
        let fast = try observations(image, level: .fast)
        guard !fast.isEmpty else { return "" }
        var union = fast.reduce(CGRect.null) { $0.union($1.boundingBox) }
        union = union.insetBy(dx: -0.03, dy: -0.03).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let cropRect = CGRect(x: union.minX * w, y: (1 - union.maxY) * h, width: union.width * w, height: union.height * h).integral
        let region = image.cropping(to: cropRect) ?? image
        let accurate = (try? observations(region, level: .accurate)) ?? []
        let fastText = text(from: fast), accurateText = text(from: accurate)
        return accurateText.count >= Int(Double(fastText.count) * 0.8) ? accurateText : fastText
    }

    private static func observations(_ image: CGImage, level: VNRequestTextRecognitionLevel) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = level == .accurate
        request.automaticallyDetectsLanguage = true
        request.minimumTextHeight = 0.006
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return request.results ?? []
    }

    /// Vision reports in bottom-left coordinates; sort top to bottom, then left to right.
    private static func text(from observations: [VNRecognizedTextObservation]) -> String {
        let sorted = observations.sorted {
            let dy = $0.boundingBox.midY - $1.boundingBox.midY
            if abs(dy) > 0.012 { return dy > 0 }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }
        return sorted.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func imageToText(_ file: FileItem, ctx: JobContext) throws -> URL {
        let loaded = try ImageConverter.load(file.url, maxPixel: 4000)
        ctx.report(0.3)
        let text = try recognize(loaded.image)
        let dest = Output.sibling(of: file.url, ext: "txt", suffix: "OCR")
        return try Output.write(to: dest) { tmp in try text.write(to: tmp, atomically: true, encoding: .utf8) }
    }

    static func readCodes(_ file: FileItem) throws -> [String] {
        let loaded = try ImageConverter.load(file.url, maxPixel: 3000)
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: loaded.image, options: [:])
        try handler.perform([request])
        return (request.results ?? []).compactMap { $0.payloadStringValue }
    }
}

enum ArchiveTool {
    static func zip(_ files: [FileItem], ctx: JobContext) throws -> URL {
        guard let first = files.first else { throw ClementineError.noOutput }
        let parent = first.url.deletingLastPathComponent()
        let sameParent = files.allSatisfy { $0.url.deletingLastPathComponent() == parent }
        let name = files.count == 1 ? first.baseName : "Archive"
        let dest = Output.unique(parent.appendingPathComponent(name).appendingPathExtension("zip"))
        return try Output.write(to: dest) { tmp in
            if sameParent {
                let r = try Shell.run(URL(fileURLWithPath: "/usr/bin/zip"), ["-r", "-y", "-q", "-X", tmp.path] + files.map(\.name), cwd: parent)
                guard r.status == 0 else { throw ClementineError.helperFailed(r.stderr.isEmpty ? "zip failed" : r.stderr) }
            } else {
                // Stage into one folder so relative paths stay flat.
                let stage = try Output.jobDirectory("zip")
                defer { try? FileManager.default.removeItem(at: stage) }
                for f in files { try FileManager.default.copyItem(at: f.url, to: stage.appendingPathComponent(f.name)) }
                let r = try Shell.run(URL(fileURLWithPath: "/usr/bin/zip"), ["-r", "-y", "-q", "-X", tmp.path] + files.map(\.name), cwd: stage)
                guard r.status == 0 else { throw ClementineError.helperFailed(r.stderr.isEmpty ? "zip failed" : r.stderr) }
            }
        }
    }

    static func extract(_ file: FileItem, ctx: JobContext) throws -> URL {
        let folder = Output.unique(file.url.deletingLastPathComponent().appendingPathComponent(file.baseName))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let r: Shell.Outcome
        if file.type?.conforms(to: .zip) == true || file.ext == "zip" {
            r = try Shell.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", file.url.path, folder.path])
        } else {
            r = try Shell.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xf", file.url.path, "-C", folder.path])
        }
        guard r.status == 0 else {
            try? FileManager.default.removeItem(at: folder)
            throw ClementineError.helperFailed(r.stderr.isEmpty ? "Extraction failed" : r.stderr)
        }
        return folder
    }
}

enum ChecksumTool {
    static func sha256(_ file: FileItem) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: file.url) else { throw ClementineError.cannotRead(file.url) }
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 4 << 20)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func write(_ file: FileItem) throws -> URL {
        let digest = try sha256(file)
        let dest = Output.sibling(of: file.url, ext: file.ext.isEmpty ? "sha256" : file.ext + ".sha256")
        return try Output.write(to: dest) { tmp in
            try "\(digest)  \(file.name)\n".write(to: tmp, atomically: true, encoding: .utf8)
        }
    }
}
