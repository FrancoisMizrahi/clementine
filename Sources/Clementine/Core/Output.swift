import Foundation

/// Output placement rules: results land next to the source,
/// are written to a hidden temporary sibling first, then renamed into a unique final name.
enum Output {
    static func unique(_ proposed: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: proposed.path) else { return proposed }
        let dir = proposed.deletingLastPathComponent()
        let base = proposed.deletingPathExtension().lastPathComponent
        let ext = proposed.pathExtension
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// `photo.heic` converted to jpeg becomes `photo.jpg`; with a suffix, `photo Compressed.jpg`.
    static func sibling(of source: URL, ext: String, suffix: String? = nil) -> URL {
        var base = source.deletingPathExtension().lastPathComponent
        if let suffix, !suffix.isEmpty { base += " " + suffix }
        var candidate = source.deletingLastPathComponent().appendingPathComponent(base)
        if !ext.isEmpty { candidate = candidate.appendingPathExtension(ext) }
        if candidate.path.compare(source.path, options: .caseInsensitive) == .orderedSame {
            candidate = source.deletingLastPathComponent().appendingPathComponent(base + " Converted")
            if !ext.isEmpty { candidate = candidate.appendingPathExtension(ext) }
        }
        return unique(candidate)
    }

    /// A new folder next to the source, e.g. `report Pages/`.
    static func siblingFolder(of source: URL, suffix: String) throws -> URL {
        let folder = unique(source.deletingLastPathComponent()
            .appendingPathComponent(source.deletingPathExtension().lastPathComponent + " " + suffix))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Runs `body` against a hidden temp file beside `final`, then moves it into place.
    @discardableResult
    static func write(to final: URL, _ body: (URL) throws -> Void) throws -> URL {
        let fm = FileManager.default
        var temp = final.deletingLastPathComponent().appendingPathComponent(".clementine-" + UUID().uuidString)
        if !final.pathExtension.isEmpty { temp = temp.appendingPathExtension(final.pathExtension) }
        try? fm.removeItem(at: temp)
        do {
            try body(temp)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        guard fm.fileExists(atPath: temp.path) else { throw ClementineError.noOutput }
        let dest = unique(final)
        try fm.moveItem(at: temp, to: dest)
        return dest
    }

    /// Scratch directory for a job, removed by the caller.
    static func jobDirectory(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Clementine-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
