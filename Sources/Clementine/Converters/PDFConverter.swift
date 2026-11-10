import AppKit
import PDFKit
import Quartz
import Vision
import UniformTypeIdentifiers

enum PDFConverter {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw ClementineError.cannotRead(url) }
        if doc.isLocked { throw ClementineError.unsupported("\(url.lastPathComponent) is password protected.") }
        return doc
    }

    /// Merges PDFs and images (as pages) in drop order into one PDF next to the first file.
    static func combine(_ files: [FileItem], ctx: JobContext) throws -> URL {
        let out = PDFDocument()
        for (i, f) in files.enumerated() {
            if f.kind == .pdf {
                let d = try open(f.url)
                for p in 0..<d.pageCount { if let page = d.page(at: p) { out.insert(page, at: out.pageCount) } }
            } else if f.kind == .image {
                let loaded = try ImageConverter.load(f.url)
                let ns = NSImage(cgImage: loaded.image, size: NSSize(width: loaded.image.width, height: loaded.image.height))
                guard let page = PDFPage(image: ns) else { throw ClementineError.cannotRead(f.url) }
                out.insert(page, at: out.pageCount)
            }
            ctx.report(Double(i + 1) / Double(files.count))
        }
        guard out.pageCount > 0 else { throw ClementineError.noOutput }
        let first = files[0].url
        let name = files.count == 1 ? files[0].baseName : (files.allPDF ? "Merged" : "Combined")
        let dest = Output.unique(first.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension("pdf"))
        return try Output.write(to: dest) { tmp in
            guard out.write(to: tmp) else { throw ClementineError.cannotWrite(tmp) }
        }
    }

    static func split(_ file: FileItem, ctx: JobContext) throws -> [URL] {
        let doc = try open(file.url)
        let folder = try Output.siblingFolder(of: file.url, suffix: "Pages")
        var outs: [URL] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            let dest = folder.appendingPathComponent("\(file.baseName) - Page \(i + 1).pdf")
            guard single.write(to: dest) else { throw ClementineError.cannotWrite(dest) }
            outs.append(dest)
            ctx.report(Double(i + 1) / Double(doc.pageCount))
        }
        return outs.isEmpty ? [] : [folder]
    }

    static func toImages(_ file: FileItem, type: UTType, ctx: JobContext) throws -> [URL] {
        let doc = try open(file.url)
        let folder = try Output.siblingFolder(of: file.url, suffix: "Pages")
        let ext = ImageConverter.ext(for: type)
        let scale: CGFloat = 200.0 / 72.0
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
            guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            c.setFillColor(CGColor(gray: 1, alpha: 1))
            c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            c.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: c)
            guard let img = c.makeImage() else { continue }
            let dest = folder.appendingPathComponent("\(file.baseName) - Page \(i + 1).\(ext)")
            try ImageConverter.write(img, to: dest, type: type, quality: Settings.shared.imageQuality, properties: nil)
            ctx.report(Double(i + 1) / Double(doc.pageCount))
        }
        return [folder]
    }

    /// Uses the system "Reduce File Size" Quartz filter, like Preview's export.
    static func compress(_ file: FileItem, ctx: JobContext) throws -> URL {
        let doc = try open(file.url)
        let filterURL = URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")
        guard let filter = QuartzFilter(url: filterURL) else { throw ClementineError.unsupported("The Reduce File Size filter is missing.") }
        let dest = Output.sibling(of: file.url, ext: "pdf", suffix: "Compressed")
        return try Output.write(to: dest) { tmp in
            guard let first = doc.page(at: 0) else { throw ClementineError.noOutput }
            var mediaBox = first.bounds(for: .mediaBox)
            guard let consumer = CGDataConsumer(url: tmp as CFURL),
                  let c = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw ClementineError.cannotWrite(tmp) }
            filter.apply(to: c)
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                var box = page.bounds(for: .mediaBox)
                c.beginPage(mediaBox: &box)
                page.draw(with: .mediaBox, to: c)
                c.endPage()
                ctx.report(Double(i + 1) / Double(doc.pageCount))
            }
            c.closePDF()
        }
    }

    static func rotate(_ file: FileItem, ctx: JobContext) throws -> URL {
        let doc = try open(file.url)
        for i in 0..<doc.pageCount { doc.page(at: i)?.rotation += 90 }
        let dest = Output.sibling(of: file.url, ext: "pdf", suffix: "Rotated")
        return try Output.write(to: dest) { tmp in
            guard doc.write(to: tmp) else { throw ClementineError.cannotWrite(tmp) }
        }
    }

    /// Embedded text when present, OCR for pages without any.
    static func extractText(_ file: FileItem, forceOCR: Bool, ctx: JobContext) throws -> String {
        let doc = try open(file.url)
        var parts: [String] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let embedded = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !forceOCR, embedded.count > 20 {
                parts.append(embedded)
            } else {
                let bounds = page.bounds(for: .mediaBox)
                let scale: CGFloat = 300.0 / 72.0
                let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
                if let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                    c.setFillColor(CGColor(gray: 1, alpha: 1))
                    c.fill(CGRect(x: 0, y: 0, width: w, height: h))
                    c.scaleBy(x: scale, y: scale)
                    page.draw(with: .mediaBox, to: c)
                    if let img = c.makeImage() { parts.append(try OCR.recognize(img)) }
                }
            }
            ctx.report(Double(i + 1) / Double(doc.pageCount))
        }
        return parts.joined(separator: "\n\n")
    }

    static func toText(_ file: FileItem, forceOCR: Bool, ctx: JobContext) throws -> URL {
        let text = try extractText(file, forceOCR: forceOCR, ctx: ctx)
        let dest = Output.sibling(of: file.url, ext: "txt", suffix: forceOCR ? "OCR" : nil)
        return try Output.write(to: dest) { tmp in try text.write(to: tmp, atomically: true, encoding: .utf8) }
    }

    static func toDocument(_ file: FileItem, type: NSAttributedString.DocumentType, ext: String, ctx: JobContext) throws -> URL {
        let doc = try open(file.url)
        let attr = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 12)
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            var text = page.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count <= 20 {
                text = (try? extractText(FileItem(url: file.url), forceOCR: true, ctx: JobContext())) ?? text
            }
            attr.append(NSAttributedString(string: text, attributes: [.font: body]))
            if i < doc.pageCount - 1 { attr.append(NSAttributedString(string: "\u{000C}\n", attributes: [.font: body])) }
            ctx.report(Double(i + 1) / Double(doc.pageCount))
        }
        let dest = Output.sibling(of: file.url, ext: ext)
        return try Output.write(to: dest) { tmp in
            try DocumentConverter.write(attr, to: tmp, type: type)
        }
    }
}
