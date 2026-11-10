import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum ImageConverter {
    struct Loaded {
        let image: CGImage
        let properties: [String: Any]
    }

    static let avif = UTType("public.avif")

    /// Filename extension to use for a target type (`jpg`, not `jpeg`).
    static func ext(for type: UTType) -> String {
        if type == .jpeg { return "jpg" }
        return type.preferredFilenameExtension ?? "img"
    }

    /// Which image formats this Mac can write (ImageIO plus optional ffmpeg for WebP).
    static func writableTargets() -> [(title: String, type: UTType, symbol: String)] {
        let native = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        var out: [(String, UTType, String)] = []
        func add(_ title: String, _ type: UTType?, _ symbol: String) {
            guard let type, native.contains(type.identifier) else { return }
            out.append((title, type, symbol))
        }
        add("JPEG", .jpeg, "photo")
        add("PNG", .png, "photo.on.rectangle")
        add("HEIC", .heic, "photo.stack")
        if WebPEncoder.isAvailable || FFmpeg.shared.has("libwebp") { out.append(("WebP", .webP, "globe")) }
        add("AVIF", avif, "photo.badge.arrow.down")
        add("TIFF", .tiff, "doc.richtext")
        add("GIF", .gif, "film")
        add("BMP", .bmp, "square.grid.3x3")
        return out
    }

    /// Loads with orientation baked in; `maxPixel` additionally downsamples.
    static func load(_ url: URL, maxPixel: Int? = nil) throws -> Loaded {
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 {
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] ?? [:]
            let w = props[kCGImagePropertyPixelWidth as String] as? Int ?? 0
            let h = props[kCGImagePropertyPixelHeight as String] as? Int ?? 0
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel ?? max(w, h, 1),
            ]
            if let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                return Loaded(image: img, properties: props)
            }
            if let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                return Loaded(image: img, properties: props)
            }
        }
        // SVG and anything else ImageIO cannot decode goes through NSImage.
        guard let ns = NSImage(contentsOf: url), ns.isValid else { throw ClementineError.cannotRead(url) }
        let scale: CGFloat = {
            let longest = max(ns.size.width, ns.size.height, 1)
            if let maxPixel { return min(CGFloat(maxPixel) / longest, 4) }
            return longest < 1024 ? 2048 / longest : 1
        }()
        let size = CGSize(width: ns.size.width * scale, height: ns.size.height * scale)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ClementineError.cannotRead(url)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ns.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let img = ctx.makeImage() else { throw ClementineError.cannotRead(url) }
        return Loaded(image: img, properties: [:])
    }

    static func flattenedOnWhite(_ image: CGImage) -> CGImage {
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst else { return image }
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    /// Writes one image. `properties` carries EXIF/GPS/IPTC across; pass nil to strip everything.
    static func write(_ image: CGImage, to url: URL, type: UTType, quality: Double, properties: [String: Any]?) throws {
        if type == .webP {
            try WebPEncoder.encode(image, quality: quality).write(to: url)
            return
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ClementineError.unsupported("This Mac cannot write \(type.preferredFilenameExtension ?? type.identifier).")
        }
        var p = properties ?? [:]
        p[kCGImageDestinationLossyCompressionQuality as String] = quality
        p[kCGImagePropertyOrientation as String] = 1
        if var tiff = p[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            p[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        let img = (type == .jpeg || type == .bmp) ? flattenedOnWhite(image) : image
        CGImageDestinationAddImage(dest, img, p as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ClementineError.cannotWrite(url) }
    }

    // MARK: Operations

    static func convert(_ file: FileItem, to type: UTType, ctx: JobContext) throws -> URL {
        let dest = Output.sibling(of: file.url, ext: ext(for: type))
        if type == .webP, !WebPEncoder.isAvailable {
            return try Output.write(to: dest) { tmp in
                try FFmpeg.shared.convert(input: file.url, output: tmp,
                                          args: ["-frames:v", "1", "-map_metadata", "0", "-c:v", "libwebp",
                                                 "-quality", String(Int(Settings.shared.imageQuality * 100))], ctx: ctx)
            }
        }
        let loaded = try load(file.url)
        ctx.report(0.5)
        return try Output.write(to: dest) { tmp in
            try write(loaded.image, to: tmp, type: type, quality: Settings.shared.imageQuality, properties: loaded.properties)
        }
    }

    static func compress(_ file: FileItem, ctx: JobContext) throws -> URL {
        let loaded = try load(file.url)
        let type: UTType = (file.type == .png && loaded.image.alphaInfo != .none) ? .png : (file.type == .heic ? .heic : .jpeg)
        let dest = Output.sibling(of: file.url, ext: ext(for: type), suffix: "Compressed")
        return try Output.write(to: dest) { tmp in
            try write(loaded.image, to: tmp, type: type, quality: 0.6, properties: loaded.properties)
        }
    }

    static func resize(_ file: FileItem, maxPixel: Int, ctx: JobContext) throws -> URL {
        let loaded = try load(file.url, maxPixel: maxPixel)
        let type = writableType(for: file) ?? .jpeg
        let dest = Output.sibling(of: file.url, ext: ext(for: type), suffix: "\(maxPixel)px")
        return try Output.write(to: dest) { tmp in
            try write(loaded.image, to: tmp, type: type, quality: Settings.shared.imageQuality, properties: loaded.properties)
        }
    }

    static func stripMetadata(_ file: FileItem, ctx: JobContext) throws -> URL {
        // JPEG and PNG are rewritten losslessly; everything else is re-encoded without properties.
        let data = try Data(contentsOf: file.url)
        var orientation = 1
        if let src = CGImageSourceCreateWithData(data as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] {
            orientation = props[kCGImagePropertyOrientation as String] as? Int ?? 1
        }
        if file.type == .jpeg, let stripped = LosslessStrip.jpeg(data, orientation: orientation) {
            let dest = Output.sibling(of: file.url, ext: "jpg", suffix: "Metadata Removed")
            return try Output.write(to: dest) { try stripped.write(to: $0) }
        }
        if file.type == .png, let stripped = LosslessStrip.png(data) {
            let dest = Output.sibling(of: file.url, ext: "png", suffix: "Metadata Removed")
            return try Output.write(to: dest) { try stripped.write(to: $0) }
        }
        let loaded = try load(file.url)
        let type = writableType(for: file) ?? .jpeg
        let dest = Output.sibling(of: file.url, ext: ext(for: type), suffix: "Metadata Removed")
        return try Output.write(to: dest) { tmp in
            try write(loaded.image, to: tmp, type: type, quality: 0.95, properties: nil)
        }
    }

    static func rotate(_ file: FileItem, ctx: JobContext) throws -> URL {
        let loaded = try load(file.url)
        let src = loaded.image
        guard let c = CGContext(data: nil, width: src.height, height: src.width, bitsPerComponent: 8, bytesPerRow: 0,
                                space: src.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ClementineError.cannotRead(file.url) }
        // 90° clockwise
        c.translateBy(x: 0, y: CGFloat(src.width))
        c.rotate(by: -.pi / 2)
        c.draw(src, in: CGRect(x: 0, y: 0, width: src.width, height: src.height))
        guard let rotated = c.makeImage() else { throw ClementineError.cannotRead(file.url) }
        let type = writableType(for: file) ?? .jpeg
        let dest = Output.sibling(of: file.url, ext: ext(for: type), suffix: "Rotated")
        return try Output.write(to: dest) { tmp in
            try write(rotated, to: tmp, type: type, quality: Settings.shared.imageQuality, properties: loaded.properties)
        }
    }

    /// Keep the source format when ImageIO can write it, otherwise fall back to JPEG/PNG.
    static func writableType(for file: FileItem) -> UTType? {
        let native = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        if let t = file.type, native.contains(t.identifier), t != .gif { return t }
        if let t = file.type, t.conforms(to: .image), t.identifier.contains("png") || t.identifier.contains("svg") { return .png }
        return .jpeg
    }
}
