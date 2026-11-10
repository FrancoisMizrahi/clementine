import AppKit
import Foundation

/// Converts office documents by asking the installed office apps to do it over Apple Events:
/// Pages, Numbers and Keynote first (free, on every Mac), Microsoft Word, Excel and PowerPoint as fallback.
/// Scripts run through /usr/bin/osascript so the main thread stays free; macOS asks once per app for permission.
enum OfficeApp: String, CaseIterable {
    case pages = "Pages", numbers = "Numbers", keynote = "Keynote"
    case word = "Microsoft Word", excel = "Microsoft Excel", powerpoint = "Microsoft PowerPoint"

    var bundleID: String {
        switch self {
        case .pages: return "com.apple.iWork.Pages"
        case .numbers: return "com.apple.iWork.Numbers"
        case .keynote: return "com.apple.iWork.Keynote"
        case .word: return "com.microsoft.Word"
        case .excel: return "com.microsoft.Excel"
        case .powerpoint: return "com.microsoft.Powerpoint"
        }
    }
    var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }
}

enum OfficeFamily { case text, sheet, slides }

enum OfficeBridge {
    struct Target {
        let id: String
        let title: String
        let symbol: String
        let ext: String
        let format: String      // key understood by the script
        var producesFolder = false
    }

    static let textExtensions: Set<String> = ["pages", "docx", "doc", "rtf", "rtfd", "txt", "odt"]
    static let sheetExtensions: Set<String> = ["numbers", "xlsx", "xlsm", "xls", "csv", "tsv", "ods"]
    static let slideExtensions: Set<String> = ["key", "pptx", "ppt", "odp"]

    static func family(of file: FileItem) -> OfficeFamily? {
        if textExtensions.contains(file.ext) { return .text }
        if sheetExtensions.contains(file.ext) { return .sheet }
        if slideExtensions.contains(file.ext) { return .slides }
        return nil
    }

    static func app(for family: OfficeFamily, ext: String) -> OfficeApp? {
        // iWork cannot open OpenDocument files; Office can.
        let needsOffice = ["odt", "ods", "odp"].contains(ext)
        let order: [OfficeApp]
        switch family {
        case .text: order = needsOffice ? [.word] : [.pages, .word]
        case .sheet: order = needsOffice ? [.excel] : [.numbers, .excel]
        case .slides: order = needsOffice ? [.powerpoint] : [.keynote, .powerpoint]
        }
        return order.first { $0.isInstalled }
    }

    static func canConvert(_ file: FileItem) -> Bool {
        guard let f = family(of: file) else { return false }
        return app(for: f, ext: file.ext) != nil
    }

    static func targets(for file: FileItem) -> [Target] {
        guard let f = family(of: file), let app = app(for: f, ext: file.ext) else { return [] }
        var t: [Target] = []
        switch (f, app) {
        case (.text, .pages):
            t.append(Target(id: "pdf", title: "PDF", symbol: "doc.richtext", ext: "pdf", format: "PDF"))
            if file.ext != "docx" { t.append(Target(id: "docx", title: "Word", symbol: "doc.text", ext: "docx", format: "DOCX")) }
            t.append(Target(id: "epub", title: "EPUB", symbol: "book", ext: "epub", format: "EPUB"))
            if file.ext != "rtf" { t.append(Target(id: "rtf", title: "RTF", symbol: "doc.plaintext", ext: "rtf", format: "RTF")) }
            if file.ext != "txt" { t.append(Target(id: "txt", title: "Text", symbol: "text.alignleft", ext: "txt", format: "TXT")) }
        case (.text, _):
            t.append(Target(id: "pdf", title: "PDF", symbol: "doc.richtext", ext: "pdf", format: "PDF"))
        case (.sheet, .numbers):
            t.append(Target(id: "pdf", title: "PDF", symbol: "doc.richtext", ext: "pdf", format: "PDF"))
            if file.ext != "xlsx" { t.append(Target(id: "xlsx", title: "Excel", symbol: "tablecells", ext: "xlsx", format: "XLSX")) }
            if file.ext != "csv" { t.append(Target(id: "csv", title: "CSV", symbol: "list.bullet.rectangle", ext: "csv", format: "CSV", producesFolder: true)) }
        case (.sheet, _):
            t.append(Target(id: "pdf", title: "PDF", symbol: "doc.richtext", ext: "pdf", format: "PDF"))
        case (.slides, .keynote):
            t.append(Target(id: "pdf", title: "PDF", symbol: "doc.richtext", ext: "pdf", format: "PDF"))
            if file.ext != "pptx" { t.append(Target(id: "pptx", title: "PowerPoint", symbol: "rectangle.on.rectangle", ext: "pptx", format: "PPTX")) }
            t.append(Target(id: "png", title: "Slide Images", symbol: "photo.on.rectangle", ext: "", format: "PNG", producesFolder: true))
        case (.slides, _):
            t.append(Target(id: "pdf", title: "PDF", symbol: "doc.richtext", ext: "pdf", format: "PDF"))
        }
        return t
    }

    static func convert(_ file: FileItem, to target: Target, ctx: JobContext) throws -> URL {
        guard let f = family(of: file), let app = app(for: f, ext: file.ext) else {
            throw ClementineError.unsupported("No installed app can convert \(file.name).")
        }
        return try run(app: app, input: file.url, format: target.format, ext: target.ext, ctx: ctx)
    }

    /// Exports `input` into a private folder, then moves whatever the app produced next to the source.
    static func run(app: OfficeApp, input: URL, format: String, ext: String, ctx: JobContext) throws -> URL {
        let job = try Output.jobDirectory("office")
        defer { try? FileManager.default.removeItem(at: job) }
        let base = input.deletingPathExtension().lastPathComponent
        let outName = ext.isEmpty ? base + " Slides" : base + "." + ext
        let outURL = job.appendingPathComponent(outName)
        let scriptURL = job.appendingPathComponent("convert.applescript")
        try script(for: app).write(to: scriptURL, atomically: true, encoding: .utf8)
        ctx.report(0.1)
        let r = try Shell.run(URL(fileURLWithPath: "/usr/bin/osascript"), [scriptURL.path, input.path, outURL.path, format],
                              env: ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                                    "LANG": "en_US.UTF-8"], timeout: 300)
        ctx.report(0.9)
        guard r.status == 0 else { throw ClementineError.helperFailed(friendly(r.stderr, app: app)) }
        let produced = (try? FileManager.default.contentsOfDirectory(at: job, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent != "convert.applescript" } ?? []
        guard let item = produced.first else {
            throw ClementineError.helperFailed("\(app.rawValue) finished but produced no file.")
        }
        let dest = Output.unique(input.deletingLastPathComponent().appendingPathComponent(item.lastPathComponent))
        try FileManager.default.moveItem(at: item, to: dest)
        return dest
    }

    private static func friendly(_ stderr: String, app: OfficeApp) -> String {
        let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if msg.contains("-1743") || msg.localizedCaseInsensitiveContains("not authorized") {
            return "Clementine is not allowed to control \(app.rawValue). Allow it in System Settings → Privacy & Security → Automation, then try again."
        }
        if msg.contains("-1712") { return "\(app.rawValue) did not answer in time. Close any dialog it is showing and try again." }
        if msg.contains("-600") { return "\(app.rawValue) could not be launched." }
        return msg.isEmpty ? "\(app.rawValue) could not convert the file." : msg
    }

    // MARK: Scripts

    static func script(for app: OfficeApp) -> String {
        switch app {
        case .pages:
            return iWorkScript(app: "Pages", cases: [
                ("PDF", "PDF"), ("DOCX", "Microsoft Word"), ("EPUB", "EPUB"), ("RTF", "formatted text"), ("TXT", "unformatted text"),
            ])
        case .numbers:
            return iWorkScript(app: "Numbers", cases: [("PDF", "PDF"), ("XLSX", "Microsoft Excel"), ("CSV", "CSV")])
        case .keynote:
            return iWorkScript(app: "Keynote", cases: [("PDF", "PDF"), ("PPTX", "Microsoft PowerPoint")],
                               extra: "else if fmt is \"PNG\" then\n\t\t\texport theDoc to outFile as slide images with properties {image format:PNG}\n")
        case .word:
            return """
            on run argv
            \tset inPath to item 1 of argv
            \tset outPath to item 2 of argv
            \tset wasRunning to application "Microsoft Word" is running
            \ttell application "Microsoft Word"
            \t\topen (POSIX file inPath)
            \t\tset theDoc to active document
            \t\tsave as theDoc file name outPath file format format PDF
            \t\tclose theDoc saving no
            \tend tell
            \tif not wasRunning then tell application "Microsoft Word" to quit saving no
            end run
            """
        case .excel:
            return """
            on run argv
            \tset inPath to item 1 of argv
            \tset outPath to item 2 of argv
            \tset wasRunning to application "Microsoft Excel" is running
            \ttell application "Microsoft Excel"
            \t\topen (POSIX file inPath)
            \t\tset theBook to active workbook
            \t\tsave workbook as theBook filename outPath file format PDF file format
            \t\tclose theBook saving no
            \tend tell
            \tif not wasRunning then tell application "Microsoft Excel" to quit saving no
            end run
            """
        case .powerpoint:
            return """
            on run argv
            \tset inPath to item 1 of argv
            \tset outPath to item 2 of argv
            \tset wasRunning to application "Microsoft PowerPoint" is running
            \ttell application "Microsoft PowerPoint"
            \t\topen (POSIX file inPath)
            \t\tset thePres to active presentation
            \t\tsave thePres in outPath as save as PDF
            \t\tclose thePres saving no
            \tend tell
            \tif not wasRunning then tell application "Microsoft PowerPoint" to quit saving no
            end run
            """
        }
    }

    private static func iWorkScript(app: String, cases: [(String, String)], extra: String = "") -> String {
        var branches = ""
        for (i, c) in cases.enumerated() {
            branches += (i == 0 ? "\t\tif" : "\t\telse if") + " fmt is \"\(c.0)\" then\n\t\t\texport theDoc to outFile as \(c.1)\n"
        }
        return """
        on run argv
        \tset inPath to item 1 of argv
        \tset outPath to item 2 of argv
        \tset fmt to item 3 of argv
        \tset wasRunning to application "\(app)" is running
        \ttell application "\(app)"
        \t\tset theDoc to open (POSIX file inPath)
        \t\tset outFile to POSIX file outPath
        \(branches)\(extra)\t\tend if
        \t\tclose theDoc saving no
        \tend tell
        \tif not wasRunning then tell application "\(app)" to quit
        end run
        """
    }
}
