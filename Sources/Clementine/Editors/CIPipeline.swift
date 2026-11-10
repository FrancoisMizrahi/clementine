import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

struct Adjustments: Equatable {
    var exposure: Double = 0      // EV, -2...2
    var brightness: Double = 0    // -0.5...0.5
    var contrast: Double = 1      // 0.5...1.5
    var saturation: Double = 1    // 0...2
    var vibrance: Double = 0      // -1...1
    var warmth: Double = 0        // -1...1
    var sharpness: Double = 0     // 0...2
    var isNeutral: Bool { self == Adjustments() }
}

/// Flips are stored before the rotation. A flip the user applies after a quarter turn therefore toggles the other axis.
struct EditOrientation: Equatable {
    var rotation = 0 // quarter turns clockwise, 0...3
    var flipH = false
    var flipV = false
    var isIdentity: Bool { rotation == 0 && !flipH && !flipV }
    mutating func rotateClockwise() { rotation = (rotation + 1) % 4 }
    mutating func rotateCounterclockwise() { rotation = (rotation + 3) % 4 }
    mutating func flipHorizontal() { if rotation % 2 == 0 { flipH.toggle() } else { flipV.toggle() } }
    mutating func flipVertical() { if rotation % 2 == 0 { flipV.toggle() } else { flipH.toggle() } }
}

enum RedactStyle: String, CaseIterable, Identifiable {
    case pixelate, blur, solid
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .pixelate: return "squareshape.split.3x3"
        case .blur: return "drop.halffull"
        case .solid: return "rectangle.fill"
        }
    }
}

enum CIPipeline {
    static let context = CIContext(options: [.cacheIntermediates: false])

    static func normalized(_ img: CIImage) -> CIImage {
        img.transformed(by: CGAffineTransform(translationX: -img.extent.origin.x, y: -img.extent.origin.y))
    }

    static func oriented(_ img: CIImage, _ o: EditOrientation) -> CIImage {
        var out = img
        if o.flipH { out = normalized(out.transformed(by: CGAffineTransform(scaleX: -1, y: 1))) }
        if o.flipV { out = normalized(out.transformed(by: CGAffineTransform(scaleX: 1, y: -1))) }
        if o.rotation != 0 { out = normalized(out.transformed(by: CGAffineTransform(rotationAngle: -.pi / 2 * CGFloat(o.rotation)))) }
        return out
    }

    static func adjusted(_ img: CIImage, _ a: Adjustments) -> CIImage {
        var out = img
        if a.exposure != 0 {
            let f = CIFilter.exposureAdjust(); f.inputImage = out; f.ev = Float(a.exposure); out = f.outputImage ?? out
        }
        if a.brightness != 0 || a.contrast != 1 || a.saturation != 1 {
            let f = CIFilter.colorControls(); f.inputImage = out
            f.brightness = Float(a.brightness); f.contrast = Float(a.contrast); f.saturation = Float(a.saturation)
            out = f.outputImage ?? out
        }
        if a.vibrance != 0 {
            let f = CIFilter.vibrance(); f.inputImage = out; f.amount = Float(a.vibrance); out = f.outputImage ?? out
        }
        if a.warmth != 0 {
            let f = CIFilter.temperatureAndTint(); f.inputImage = out
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 6500 - CGFloat(a.warmth) * 2500, y: 0)
            out = f.outputImage ?? out
        }
        if a.sharpness > 0 {
            let f = CIFilter.sharpenLuminance(); f.inputImage = out; f.sharpness = Float(a.sharpness); out = f.outputImage ?? out
        }
        return out.cropped(to: img.extent)
    }

    /// `crop` is in top-left pixel coordinates of `img`.
    static func cropped(_ img: CIImage, _ crop: CGRect?) -> CIImage {
        guard let crop else { return img }
        let h = img.extent.height
        let ci = CGRect(x: crop.minX, y: h - crop.maxY, width: crop.width, height: crop.height).integral.intersection(img.extent)
        guard !ci.isEmpty else { return img }
        return normalized(img.cropped(to: ci))
    }

    /// Burns redactions into the image. `rects` are top-left pixel coordinates at full size; `scale` maps them onto `base`.
    static func redacted(_ base: CIImage, rects: [(CGRect, RedactStyle)], scale: CGFloat) -> CIImage {
        var out = base
        let h = base.extent.height
        for (rect, style) in rects {
            let ci = CGRect(x: rect.minX * scale, y: h - rect.maxY * scale, width: rect.width * scale, height: rect.height * scale)
                .integral.intersection(base.extent)
            guard !ci.isEmpty else { continue }
            let patch: CIImage
            switch style {
            case .solid:
                patch = CIImage(color: CIColor.black).cropped(to: ci)
            case .pixelate:
                let f = CIFilter.pixellate()
                f.inputImage = base.clampedToExtent()
                f.scale = Float(max(6, min(ci.width, ci.height) / 8))
                f.center = CGPoint(x: ci.midX, y: ci.midY)
                patch = (f.outputImage ?? base).cropped(to: ci)
            case .blur:
                let f = CIFilter.gaussianBlur()
                f.inputImage = base.clampedToExtent()
                f.radius = Float(max(10, min(ci.width, ci.height) / 5))
                patch = (f.outputImage ?? base).cropped(to: ci)
            }
            out = patch.composited(over: out)
        }
        return out
    }

    static func render(_ img: CIImage, colorSpace: CGColorSpace?) -> CGImage? {
        context.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB))
    }
}

/// Tracks the newest render request so stale previews are dropped.
final class RenderCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var latest = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; latest += 1; return latest }
    func isCurrent(_ g: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return g == latest }
}

/// Full-size facts plus a bounded preview, loaded once per editor window.
struct EditablePicture: @unchecked Sendable {
    let fullSize: CGSize
    let properties: [String: Any]
    let preview: CIImage
    let previewScale: CGFloat
    let colorSpace: CGColorSpace?

    static func load(_ url: URL) throws -> EditablePicture {
        var fullSize = CGSize.zero
        var properties: [String: Any] = [:]
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
           let w = props[kCGImagePropertyPixelWidth as String] as? Double,
           let h = props[kCGImagePropertyPixelHeight as String] as? Double {
            let o = props[kCGImagePropertyOrientation as String] as? Int ?? 1
            fullSize = o >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
            properties = props
        }
        let loaded = try ImageConverter.load(url, maxPixel: 1600)
        if fullSize == .zero {
            let full = try ImageConverter.load(url)
            fullSize = CGSize(width: full.image.width, height: full.image.height)
            properties = full.properties
        }
        return EditablePicture(fullSize: fullSize, properties: properties, preview: CIImage(cgImage: loaded.image),
                               previewScale: CGFloat(loaded.image.width) / fullSize.width, colorSpace: loaded.image.colorSpace)
    }
}

extension ImageConverter {
    /// Only the metadata dictionaries, with stale pixel dimensions and orientation cleared.
    static func metadataOnly(_ props: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyGPSDictionary,
                    kCGImagePropertyIPTCDictionary, kCGImagePropertyExifAuxDictionary] as [CFString] {
            if let d = props[key as String] as? [String: Any] { out[key as String] = d }
        }
        if var exif = out[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension as String)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension as String)
            out[kCGImagePropertyExifDictionary as String] = exif
        }
        return out
    }
}
