import AppKit
import Foundation
import NaturalLanguage

/// Native EPUB 3 writer (from any attributed string) and reader (spine order through TextKit's HTML importer).
enum EPUB {
    // MARK: Writing

    private struct Chapter {
        var title: String
        var body = ""
    }

    static func write(_ attr: NSAttributedString, title: String, to url: URL) throws {
        let stage = try Output.jobDirectory("epub")
        defer { try? FileManager.default.removeItem(at: stage) }
        let oebps = stage.appendingPathComponent("OEBPS")
        let imagesDir = oebps.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stage.appendingPathComponent("META-INF"), withIntermediateDirectories: true)

        var images: [(href: String, type: String)] = []
        var chapters: [Chapter] = [Chapter(title: title)]
        var listOpen: String? = nil
        let text = attr.string as NSString

        func closeList() {
            if let tag = listOpen { chapters[chapters.count - 1].body += "</\(tag)>\n"; listOpen = nil }
        }

        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byParagraphs) { _, range, _, _ in
            let paragraph = attr.attributedSubstring(from: range)
            var trimmed = paragraph.string.trimmingCharacters(in: .whitespacesAndNewlines)
            let font = (paragraph.length > 0 ? paragraph.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil) ?? NSFont.systemFont(ofSize: 12)
            let bold = font.fontDescriptor.symbolicTraits.contains(.bold)
            let inline = inlineHTML(paragraph, images: &images, imagesDir: imagesDir)
            if trimmed.isEmpty && !inline.contains("<img") { return }
            // Headings by size, lists by leading bullet or number.
            var tag = "p"
            if font.pointSize >= 24 { tag = "h1" } else if font.pointSize >= 19 { tag = "h2" } else if font.pointSize >= 15 && bold { tag = "h3" }
            var content = inline
            var listTag: String? = nil
            if let m = trimmed.range(of: #"^\s*(?:[•·◦\-\*]|\d+[\.\)])\s+"#, options: .regularExpression) {
                listTag = trimmed[m].trimmingCharacters(in: .whitespaces).first.map { $0.isNumber ? "ol" : "ul" }
                content = String(content.drop(while: { $0 == "\t" || $0 == " " }))
                if let r = content.range(of: #"^(?:[•·◦\-\*]|\d+[\.\)])\s*"#, options: .regularExpression) { content.removeSubrange(r) }
                trimmed = String(trimmed[m.upperBound...])
            }
            if tag == "h1", !chapters[chapters.count - 1].body.isEmpty {
                closeList()
                chapters.append(Chapter(title: trimmed))
            } else if tag == "h1" {
                chapters[chapters.count - 1].title = trimmed
            }
            if let listTag {
                if listOpen != listTag { closeList(); chapters[chapters.count - 1].body += "<\(listTag)>\n"; listOpen = listTag }
                chapters[chapters.count - 1].body += "<li>\(content)</li>\n"
            } else {
                closeList()
                chapters[chapters.count - 1].body += "<\(tag)>\(content)</\(tag)>\n"
            }
        }
        closeList()
        if chapters.count == 1, chapters[0].body.isEmpty { throw ClementineError.unsupported("The document has no text to put in an EPUB.") }

        let language = NLLanguageRecognizer.dominantLanguage(for: String((text as String).prefix(4000)))?.rawValue ?? "en"
        let bookID = "urn:uuid:" + UUID().uuidString.lowercased()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)

        try "application/epub+zip".write(to: stage.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.write(to: stage.appendingPathComponent("META-INF/container.xml"), atomically: true, encoding: .utf8)
        try """
        body { font-family: -apple-system, Georgia, serif; line-height: 1.5; margin: 1em; }
        h1, h2, h3 { line-height: 1.2; }
        img { max-width: 100%; height: auto; }
        pre, code { font-family: Menlo, monospace; font-size: 0.9em; }
        """.write(to: oebps.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)

        var manifest = """
          <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
          <item id="css" href="style.css" media-type="text/css"/>

        """
        var spine = ""
        var navItems = ""
        for (i, ch) in chapters.enumerated() {
            let name = "ch\(i + 1).xhtml"
            try xhtml(title: ch.title.isEmpty ? title : ch.title, body: ch.body, language: language)
                .write(to: oebps.appendingPathComponent(name), atomically: true, encoding: .utf8)
            manifest += "  <item id=\"ch\(i + 1)\" href=\"\(name)\" media-type=\"application/xhtml+xml\"/>\n"
            spine += "  <itemref idref=\"ch\(i + 1)\"/>\n"
            navItems += "      <li><a href=\"\(name)\">\(escape(ch.title.isEmpty ? title : ch.title))</a></li>\n"
        }
        for (i, img) in images.enumerated() {
            manifest += "  <item id=\"img\(i + 1)\" href=\"\(img.href)\" media-type=\"\(img.type)\"/>\n"
        }
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" xml:lang="\(language)">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">\(bookID)</dc:identifier>
            <dc:title>\(escape(title))</dc:title>
            <dc:language>\(language)</dc:language>
            <meta property="dcterms:modified">\(stamp)</meta>
          </metadata>
          <manifest>
        \(manifest)  </manifest>
          <spine>
        \(spine)  </spine>
        </package>
        """.write(to: oebps.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(language)">
        <head><title>\(escape(title))</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
        <body>
          <nav epub:type="toc" id="toc"><h1>\(escape(title))</h1>
            <ol>
        \(navItems)    </ol>
          </nav>
        </body>
        </html>
        """.write(to: oebps.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)

        // mimetype must be first and stored uncompressed.
        let zip = URL(fileURLWithPath: "/usr/bin/zip")
        let out = stage.appendingPathComponent("book.epub")
        var r = try Shell.run(zip, ["-X", "-0", "-q", out.path, "mimetype"], cwd: stage)
        guard r.status == 0 else { throw ClementineError.helperFailed(r.stderr) }
        r = try Shell.run(zip, ["-X", "-r", "-9", "-q", out.path, "META-INF", "OEBPS"], cwd: stage)
        guard r.status == 0 else { throw ClementineError.helperFailed(r.stderr) }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: out, to: url)
    }

    private static func inlineHTML(_ paragraph: NSAttributedString, images: inout [(href: String, type: String)], imagesDir: URL) -> String {
        var html = ""
        paragraph.enumerateAttributes(in: NSRange(location: 0, length: paragraph.length)) { attrs, range, _ in
            if let attachment = attrs[.attachment] as? NSTextAttachment {
                if let (href, type) = saveImage(attachment, index: images.count + 1, into: imagesDir) {
                    images.append((href, type))
                    html += "<img src=\"\(href)\" alt=\"\"/>"
                }
                return
            }
            var text = escape((paragraph.string as NSString).substring(with: range).replacingOccurrences(of: "\n", with: ""))
            guard !text.isEmpty else { return }
            if let font = attrs[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.monoSpace) { text = "<code>\(text)</code>" }
                if traits.contains(.italic) { text = "<em>\(text)</em>" }
                if traits.contains(.bold), font.pointSize < 14 { text = "<strong>\(text)</strong>" }
            }
            if let u = attrs[.underlineStyle] as? Int, u != 0 { text = "<u>\(text)</u>" }
            if let s = attrs[.strikethroughStyle] as? Int, s != 0 { text = "<s>\(text)</s>" }
            if let link = attrs[.link] {
                let href = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                if !href.isEmpty { text = "<a href=\"\(escape(href))\">\(text)</a>" }
            }
            html += text
        }
        return html
    }

    private static func saveImage(_ attachment: NSTextAttachment, index: Int, into dir: URL) -> (String, String)? {
        if let wrapper = attachment.fileWrapper, let data = wrapper.regularFileContents {
            let ext = (wrapper.preferredFilename as NSString?)?.pathExtension.lowercased() ?? ""
            if ["png", "jpg", "jpeg", "gif", "svg"].contains(ext) {
                let name = "images/img\(index).\(ext == "jpeg" ? "jpg" : ext)"
                try? data.write(to: dir.appendingPathComponent("img\(index).\(ext == "jpeg" ? "jpg" : ext)"))
                let type = ext == "png" ? "image/png" : (ext == "gif" ? "image/gif" : (ext == "svg" ? "image/svg+xml" : "image/jpeg"))
                return (name, type)
            }
        }
        let image = attachment.image ?? attachment.fileWrapper?.regularFileContents.flatMap { NSImage(data: $0) }
        guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        try? png.write(to: dir.appendingPathComponent("img\(index).png"))
        return ("images/img\(index).png", "image/png")
    }

    private static func xhtml(title: String, body: String, language: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="\(language)">
        <head><title>\(escape(title))</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
        <body>
        \(body)</body>
        </html>
        """
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: Reading

    static func read(_ url: URL) throws -> NSAttributedString {
        let dir = try Output.jobDirectory("epub-read")
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try Shell.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", url.path, dir.path])
        guard r.status == 0 else { throw ClementineError.helperFailed("Could not unpack the EPUB.") }
        let container = try XMLDocument(contentsOf: dir.appendingPathComponent("META-INF/container.xml"))
        guard let rootPath = try container.nodes(forXPath: "//*[local-name()='rootfile']/@full-path").first?.stringValue else {
            throw ClementineError.unsupported("The EPUB has no package file.")
        }
        let opfURL = dir.appendingPathComponent(rootPath)
        let opf = try XMLDocument(contentsOf: opfURL)
        var hrefs: [String: String] = [:]
        for item in try opf.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']") {
            guard let el = item as? XMLElement, let id = el.attribute(forName: "id")?.stringValue, let href = el.attribute(forName: "href")?.stringValue else { continue }
            hrefs[id] = href
        }
        let spine = try opf.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']/@idref").compactMap(\.stringValue)
        let result = NSMutableAttributedString()
        let base = opfURL.deletingLastPathComponent()
        for (i, id) in spine.enumerated() {
            guard let href = hrefs[id] else { continue }
            let fileURL = base.appendingPathComponent(href.removingPercentEncoding ?? href)
            let read: () throws -> NSAttributedString = {
                try NSAttributedString(url: fileURL, options: [.documentType: NSAttributedString.DocumentType.html, .baseURL: fileURL.deletingLastPathComponent()], documentAttributes: nil)
            }
            var chapter: NSAttributedString?
            if Thread.isMainThread { chapter = try? read() } else { DispatchQueue.main.sync { chapter = try? read() } }
            guard let chapter, chapter.length > 0 else { continue }
            if i > 0 { result.append(NSAttributedString(string: "\n\u{000C}\n")) }
            result.append(chapter)
        }
        guard result.length > 0 else { throw ClementineError.unsupported("The EPUB has no readable chapters.") }
        return result
    }
}
