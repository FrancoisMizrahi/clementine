import Foundation
import UniformTypeIdentifiers

enum FileKind: String, CaseIterable {
    case image, audio, video, pdf, document, text, office, subtitle, archive, folder, other
}

/// A dropped file with its resolved type. Classification drives which petals the wheel shows.
struct FileItem: Hashable, Identifiable {
    let url: URL
    let type: UTType?
    let kind: FileKind
    let isDirectory: Bool

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var baseName: String { url.deletingPathExtension().lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }

    init(url rawURL: URL) {
        let url = rawURL.standardizedFileURL
        self.url = url
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let resolved = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        self.type = resolved
        self.isDirectory = isDir.boolValue
        let ext = url.pathExtension.lowercased()
        if FileItem.officeExtensions.contains(ext) {
            self.kind = .office
        } else if ["srt", "vtt"].contains(ext) {
            self.kind = .subtitle
        } else if ext == "epub" {
            self.kind = .document
        } else {
            self.kind = FileItem.classify(type: resolved, isDirectory: isDir.boolValue)
        }
    }

    /// iWork and Office formats that go through the installed apps rather than TextKit.
    static let officeExtensions: Set<String> = ["pages", "numbers", "key", "xlsx", "xlsm", "xls", "pptx", "ppt", "odt", "ods", "odp"]

    static let markdown = UTType("net.daringfireball.markdown")
    static let docx = UTType("org.openxmlformats.wordprocessingml.document")
    static let doc = UTType("com.microsoft.word.doc")
    static let odt = UTType("org.oasis-open.opendocument.text")
    static let tar = UTType("public.tar-archive")

    /// Types TextKit can open as rich documents.
    static var documentTypes: [UTType] {
        [.rtf, .rtfd, .flatRTFD, .html, .webArchive, docx, doc].compactMap { $0 }
    }

    static func classify(type: UTType?, isDirectory: Bool) -> FileKind {
        guard let t = type else { return isDirectory ? .folder : .other }
        if t.conforms(to: .pdf) { return .pdf }
        if t.conforms(to: .image) { return .image }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return .video }
        if t.conforms(to: .audio) { return .audio }
        if t.conforms(to: .zip) || t.conforms(to: .gzip) || t.conforms(to: .archive)
            || (tar.map { t.conforms(to: $0) } ?? false) || t.identifier == "org.gnu.gnu-zip-tar-archive" {
            return .archive
        }
        if documentTypes.contains(where: { t.conforms(to: $0) }) { return .document }
        if t.conforms(to: .text) || t.conforms(to: .sourceCode) || t.conforms(to: .json) || t.conforms(to: .xml)
            || (markdown.map { t.conforms(to: $0) } ?? false) {
            return .text
        }
        if isDirectory && !t.conforms(to: .package) { return .folder }
        if isDirectory { return .folder }
        return .other
    }
}

extension Array where Element == FileItem {
    var kinds: Set<FileKind> { Set(map(\.kind)) }
    var allImages: Bool { !isEmpty && kinds == [.image] }
    var allAudio: Bool { !isEmpty && kinds == [.audio] }
    var allVideo: Bool { !isEmpty && kinds == [.video] }
    var allPDF: Bool { !isEmpty && kinds == [.pdf] }
    var allArchives: Bool { !isEmpty && kinds == [.archive] }
    var allOffice: Bool { !isEmpty && kinds == [.office] }
    var allSubtitles: Bool { !isEmpty && kinds == [.subtitle] }
    /// rich documents and plain text together
    var allTextual: Bool { !isEmpty && kinds.isSubset(of: [.document, .text]) }
    var allPrintable: Bool { !isEmpty && kinds.isSubset(of: [.image, .pdf]) }
}
