import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Rich text through TextKit: reads docx, doc, rtf, rtfd, html, txt and markdown; writes docx, rtf, html, txt and PDF.
enum DocumentConverter {
    struct Target {
        let title: String
        let ext: String
        let symbol: String
        let id: String
    }

    static let targets = [
        Target(title: "PDF", ext: "pdf", symbol: "doc.richtext", id: "pdf"),
        Target(title: "Word", ext: "docx", symbol: "doc.text", id: "docx"),
        Target(title: "RTF", ext: "rtf", symbol: "doc.plaintext", id: "rtf"),
        Target(title: "HTML", ext: "html", symbol: "chevron.left.forwardslash.chevron.right", id: "html"),
        Target(title: "Text", ext: "txt", symbol: "text.alignleft", id: "txt"),
        Target(title: "Markdown", ext: "md", symbol: "number", id: "md"),
        Target(title: "EPUB", ext: "epub", symbol: "book", id: "epub"),
    ]

    static func read(_ file: FileItem) throws -> NSAttributedString {
        if file.ext == "epub" { return try EPUB.read(file.url) }
        if let md = FileItem.markdown, file.type?.conforms(to: md) == true || file.ext == "md" || file.ext == "markdown" {
            let text = try String(contentsOf: file.url, encoding: .utf8)
            return Markdown.attributedString(from: text)
        }
        if file.kind == .text {
            let text = try (try? String(contentsOf: file.url, encoding: .utf8)) ?? String(contentsOf: file.url, encoding: .isoLatin1)
            let para = NSMutableParagraphStyle()
            para.paragraphSpacing = 4
            return NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .paragraphStyle: para,
            ])
        }
        // HTML import must happen on the main thread (it uses WebKit's legacy importer).
        let readIt: () throws -> NSAttributedString = {
            var attrs: NSDictionary?
            return try NSAttributedString(url: file.url, options: [:], documentAttributes: &attrs)
        }
        if file.type?.conforms(to: .html) == true, !Thread.isMainThread {
            var result: Result<NSAttributedString, Error>!
            DispatchQueue.main.sync { result = Result { try readIt() } }
            return try result.get()
        }
        return try readIt()
    }

    static func write(_ attr: NSAttributedString, to url: URL, type: NSAttributedString.DocumentType) throws {
        var options: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
        if type == .html { options[.characterEncoding] = String.Encoding.utf8.rawValue }
        let data = try attr.data(from: NSRange(location: 0, length: attr.length), documentAttributes: options)
        try data.write(to: url)
    }

    static func convert(_ file: FileItem, to target: Target, ctx: JobContext) throws -> URL {
        let attr = try read(file)
        ctx.report(0.4)
        let dest = Output.sibling(of: file.url, ext: target.ext)
        return try Output.write(to: dest) { tmp in
            switch target.id {
            case "pdf": try renderPDF(attr, to: tmp)
            case "docx": try write(attr, to: tmp, type: .officeOpenXML)
            case "rtf": try write(attr, to: tmp, type: .rtf)
            case "html": try write(attr, to: tmp, type: .html)
            case "txt": try attr.string.write(to: tmp, atomically: true, encoding: .utf8)
            case "md": try Markdown.markdown(from: attr).write(to: tmp, atomically: true, encoding: .utf8)
            case "epub": try EPUB.write(attr, title: file.baseName, to: tmp)
            default: throw ClementineError.unsupported("Unknown document target \(target.id)")
            }
        }
    }

    /// Paginates with TextKit onto A4 (Letter when the region uses it) and draws into a PDF context.
    static func renderPDF(_ attr: NSAttributedString, to url: URL) throws {
        let usesLetter = Locale.current.measurementSystem == .us
        var pageRect = usesLetter ? CGRect(x: 0, y: 0, width: 612, height: 792) : CGRect(x: 0, y: 0, width: 595, height: 842)
        let inset: CGFloat = 56
        let textRect = pageRect.insetBy(dx: inset, dy: inset)
        let storage = NSTextStorage(attributedString: attr)
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let c = CGContext(consumer: consumer, mediaBox: &pageRect, nil) else { throw ClementineError.cannotWrite(url) }
        var glyph = 0
        var pages = 0
        repeat {
            let container = NSTextContainer(size: textRect.size)
            container.lineFragmentPadding = 0
            lm.addTextContainer(container)
            let range = lm.glyphRange(for: container)
            c.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
            c.translateBy(x: 0, y: pageRect.height)
            c.scaleBy(x: 1, y: -1)
            lm.drawBackground(forGlyphRange: range, at: textRect.origin)
            lm.drawGlyphs(forGlyphRange: range, at: textRect.origin)
            NSGraphicsContext.restoreGraphicsState()
            c.endPDFPage()
            pages += 1
            glyph = NSMaxRange(range)
            if range.length == 0 { break }
        } while glyph < lm.numberOfGlyphs && pages < 2000
        c.closePDF()
    }
}

/// Small markdown bridge built on Foundation's parser; enough for notes, READMEs and exports.
enum Markdown {
    static func attributedString(from text: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: true,
                                                              interpretedSyntax: .full,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        }
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 12)
        var lastBlock: Int? = nil
        var listCounters: [Int: Int] = [:]
        for run in parsed.runs {
            let substring = String(parsed[run.range].characters)
            var font = body
            var attrs: [NSAttributedString.Key: Any] = [:]
            var prefix = ""
            var blockID: Int? = nil
            var isCodeBlock = false
            let para = NSMutableParagraphStyle()
            para.paragraphSpacing = 6
            if let intent = run.presentationIntent {
                for comp in intent.components {
                    switch comp.kind {
                    case .header(let level):
                        let size: CGFloat = [26, 21, 17, 15, 13, 12][min(max(level - 1, 0), 5)]
                        font = NSFont.boldSystemFont(ofSize: size)
                        para.paragraphSpacingBefore = 10
                        blockID = comp.identity
                    case .paragraph: blockID = comp.identity
                    case .codeBlock: isCodeBlock = true; blockID = comp.identity
                    case .blockQuote: para.headIndent = 16; para.firstLineHeadIndent = 16; attrs[.foregroundColor] = NSColor(white: 0.38, alpha: 1)
                    case .listItem(let ordinal):
                        para.headIndent = 18; para.firstLineHeadIndent = 0
                        let listID = intent.components.first(where: {
                            if case .orderedList = $0.kind { return true }
                            if case .unorderedList = $0.kind { return true }
                            return false
                        })?.identity ?? 0
                        if case .orderedList = intent.components.first(where: { if case .orderedList = $0.kind { return true }; return false })?.kind ?? .paragraph {
                            listCounters[listID] = ordinal
                            prefix = "\(ordinal). "
                        } else {
                            prefix = "•  "
                        }
                    case .thematicBreak: prefix = "――――――――――――\n"; blockID = comp.identity
                    default: break
                    }
                }
            }
            if let inline = run.inlinePresentationIntent {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if inline.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if inline.contains(.emphasized) { traits.insert(.italic) }
                if inline.contains(.code) { font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular) }
                if inline.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if !traits.isEmpty, let d = font.fontDescriptor.withSymbolicTraits(traits) as NSFontDescriptor? {
                    font = NSFont(descriptor: d, size: font.pointSize) ?? font
                }
            }
            if isCodeBlock { font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular); attrs[.backgroundColor] = NSColor(white: 0.93, alpha: 1) }
            if let link = run.link { attrs[.link] = link; attrs[.foregroundColor] = NSColor(red: 0.0, green: 0.45, blue: 0.9, alpha: 1) }
            attrs[.font] = font
            attrs[.paragraphStyle] = para
            let newBlock = blockID != nil && blockID != lastBlock
            if newBlock, out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: [.font: body])) }
            if newBlock || (blockID == nil && !prefix.isEmpty && lastBlock == nil) {
                if !prefix.isEmpty { out.append(NSAttributedString(string: prefix, attributes: attrs)) }
            } else if !prefix.isEmpty, newBlock {
                out.append(NSAttributedString(string: prefix, attributes: attrs))
            }
            out.append(NSAttributedString(string: substring, attributes: attrs))
            if let blockID { lastBlock = blockID }
        }
        return out
    }

    /// Lossy reverse mapping: headings by font size, bold/italic by traits, paragraphs by newlines.
    static func markdown(from attr: NSAttributedString) -> String {
        var out = ""
        attr.enumerateAttributes(in: NSRange(location: 0, length: attr.length)) { attrs, range, _ in
            var s = (attr.string as NSString).substring(with: range)
            if let font = attrs[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if font.pointSize >= 20, !trimmed.isEmpty { s = "# " + trimmed + "\n\n"; out += s; return }
                if font.pointSize >= 16, !trimmed.isEmpty { s = "## " + trimmed + "\n\n"; out += s; return }
                if font.pointSize >= 14, traits.contains(.bold), !trimmed.isEmpty { s = "### " + trimmed + "\n\n"; out += s; return }
                if traits.contains(.bold), !trimmed.isEmpty { s = "**" + trimmed + "**" + (s.hasSuffix("\n") ? "\n" : " ") }
                else if traits.contains(.italic), !trimmed.isEmpty { s = "*" + trimmed + "*" + (s.hasSuffix("\n") ? "\n" : " ") }
                if traits.contains(.monoSpace), !trimmed.isEmpty { s = "`" + trimmed + "`" + (s.hasSuffix("\n") ? "\n" : "") }
            }
            if let link = attrs[.link] { s = "[\(s)](\(link))" }
            out += s
        }
        var lines = out.replacingOccurrences(of: "\n", with: "\n\n").replacingOccurrences(of: "\n\n\n\n", with: "\n\n")
        // TextKit lists come out as "\t•\titem"; turn them into markdown bullets.
        lines = lines.replacingOccurrences(of: "\t•\t", with: "- ").replacingOccurrences(of: "\t◦\t", with: "  - ")
        lines = lines.replacingOccurrences(of: "(?m)^\\t(\\d+)\\.\\t", with: "$1. ", options: .regularExpression)
        return lines
    }
}
