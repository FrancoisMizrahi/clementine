import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// One editable tag: which ImageIO dictionary and key it lives in, and whether it is a list.
struct MetadataField: Identifiable {
    let id: String
    let label: String
    let dictionary: CFString
    let key: CFString
    var isList = false
    var isDate = false
}

struct MetadataEditSpec: @unchecked Sendable {
    let url: URL
    let values: [String: String]     // field id -> new text ("" removes)
    let originals: [String: String]
    let latitude: Double?
    let longitude: Double?
    let removeGPS: Bool
    let stripAll: Bool
}

@MainActor
final class MetadataModel: ObservableObject {
    let file: FileItem
    @Published var values: [String: String] = [:]
    @Published var originals: [String: String] = [:]
    @Published var latitude = ""
    @Published var longitude = ""
    @Published var removeGPS = false
    @Published var allProperties: [(String, String)] = []
    @Published var showAll = false
    @Published var error: String?

    static let fields: [MetadataField] = [
        MetadataField(id: "title", label: "Title", dictionary: kCGImagePropertyIPTCDictionary, key: kCGImagePropertyIPTCObjectName),
        MetadataField(id: "description", label: "Description", dictionary: kCGImagePropertyTIFFDictionary, key: kCGImagePropertyTIFFImageDescription),
        MetadataField(id: "caption", label: "Caption", dictionary: kCGImagePropertyIPTCDictionary, key: kCGImagePropertyIPTCCaptionAbstract),
        MetadataField(id: "keywords", label: "Keywords (comma separated)", dictionary: kCGImagePropertyIPTCDictionary, key: kCGImagePropertyIPTCKeywords, isList: true),
        MetadataField(id: "artist", label: "Artist / creator", dictionary: kCGImagePropertyTIFFDictionary, key: kCGImagePropertyTIFFArtist, isList: true),
        MetadataField(id: "copyright", label: "Copyright", dictionary: kCGImagePropertyTIFFDictionary, key: kCGImagePropertyTIFFCopyright),
        MetadataField(id: "credit", label: "Credit", dictionary: kCGImagePropertyIPTCDictionary, key: kCGImagePropertyIPTCCredit),
        MetadataField(id: "make", label: "Camera make", dictionary: kCGImagePropertyTIFFDictionary, key: kCGImagePropertyTIFFMake),
        MetadataField(id: "model", label: "Camera model", dictionary: kCGImagePropertyTIFFDictionary, key: kCGImagePropertyTIFFModel),
        MetadataField(id: "lens", label: "Lens", dictionary: kCGImagePropertyExifDictionary, key: kCGImagePropertyExifLensModel),
        MetadataField(id: "software", label: "Software", dictionary: kCGImagePropertyTIFFDictionary, key: kCGImagePropertyTIFFSoftware),
        MetadataField(id: "dateOriginal", label: "Date taken (YYYY:MM:DD HH:MM:SS)", dictionary: kCGImagePropertyExifDictionary, key: kCGImagePropertyExifDateTimeOriginal, isDate: true),
        MetadataField(id: "dateDigitized", label: "Date digitized", dictionary: kCGImagePropertyExifDictionary, key: kCGImagePropertyExifDateTimeDigitized, isDate: true),
        MetadataField(id: "city", label: "City", dictionary: kCGImagePropertyIPTCDictionary, key: kCGImagePropertyIPTCCity),
        MetadataField(id: "country", label: "Country", dictionary: kCGImagePropertyIPTCDictionary, key: kCGImagePropertyIPTCCountryPrimaryLocationName),
        MetadataField(id: "comment", label: "User comment", dictionary: kCGImagePropertyExifDictionary, key: kCGImagePropertyExifUserComment),
    ]

    /// JPEG, PNG and TIFF are rewritten losslessly; everything else is re-encoded with the new properties.
    var isLossless: Bool { [UTType.jpeg, .png, .tiff].contains(file.type ?? .data) }

    init(file: FileItem) {
        self.file = file
        guard let src = CGImageSourceCreateWithURL(file.url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else {
            error = "Could not read the image metadata."
            return
        }
        for f in MetadataModel.fields {
            let dict = props[f.dictionary as String] as? [String: Any]
            let raw = dict?[f.key as String]
            let text: String
            if let arr = raw as? [Any] { text = arr.map { "\($0)" }.joined(separator: ", ") }
            else if let v = raw { text = "\(v)" } else { text = "" }
            values[f.id] = text
            originals[f.id] = text
        }
        if let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any],
           let lat = gps[kCGImagePropertyGPSLatitude as String] as? Double, let lon = gps[kCGImagePropertyGPSLongitude as String] as? Double {
            let latRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String ?? "N"
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String ?? "E"
            latitude = String(format: "%.6f", latRef == "S" ? -lat : lat)
            longitude = String(format: "%.6f", lonRef == "W" ? -lon : lon)
        }
        var all: [(String, String)] = []
        for (k, v) in props.sorted(by: { $0.key < $1.key }) {
            if let d = v as? [String: Any] {
                for (dk, dv) in d.sorted(by: { $0.key < $1.key }) { all.append(("\(k.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))).\(dk)", "\(dv)")) }
            } else {
                all.append((k, "\(v)"))
            }
        }
        allProperties = all
    }

    var hasChanges: Bool {
        values != originals || removeGPS || latitude != originalLatitude || longitude != originalLongitude
    }
    private var originalLatitude: String { Self.format(latitude) }
    private var originalLongitude: String { Self.format(longitude) }
    private static func format(_ s: String) -> String { s }

    func binding(_ id: String) -> Binding<String> {
        Binding(get: { self.values[id] ?? "" }, set: { self.values[id] = $0 })
    }

    func spec(stripAll: Bool = false) -> MetadataEditSpec {
        MetadataEditSpec(url: file.url, values: values, originals: originals,
                         latitude: Double(latitude.replacingOccurrences(of: ",", with: ".")),
                         longitude: Double(longitude.replacingOccurrences(of: ",", with: ".")),
                         removeGPS: removeGPS, stripAll: stripAll)
    }

    nonisolated static func export(_ s: MetadataEditSpec) throws -> URL {
        let file = FileItem(url: s.url)
        if s.stripAll { return try ImageConverter.stripMetadata(file, ctx: JobContext()) }
        guard let src = CGImageSourceCreateWithURL(s.url as CFURL, nil) else { throw ClementineError.cannotRead(s.url) }
        let lossless = [UTType.jpeg, .png, .tiff].contains(file.type ?? .data)
        let ext = file.ext.isEmpty ? "jpg" : file.ext
        let dest = Output.sibling(of: s.url, ext: ext, suffix: "Metadata")
        if lossless {
            let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil).flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()
            for f in MetadataModel.fields {
                let new = s.values[f.id] ?? "", old = s.originals[f.id] ?? ""
                guard new != old else { continue }
                if new.isEmpty {
                    // Remove: write an empty value in EXIF/IPTC space and drop the XMP twin if it has a known path.
                    CGImageMetadataSetValueMatchingImageProperty(meta, f.dictionary, f.key, (f.isList ? [] as CFArray : "" as CFString) as CFTypeRef)
                } else if f.isList {
                    let parts = new.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    CGImageMetadataSetValueMatchingImageProperty(meta, f.dictionary, f.key, parts as CFArray)
                } else {
                    CGImageMetadataSetValueMatchingImageProperty(meta, f.dictionary, f.key, new as CFString)
                }
            }
            if s.removeGPS {
                for tag in ["exif:GPSLatitude", "exif:GPSLongitude", "exif:GPSLatitudeRef", "exif:GPSLongitudeRef", "exif:GPSAltitude", "exif:GPSTimeStamp", "exif:GPSDateStamp"] {
                    CGImageMetadataRemoveTagWithPath(meta, nil, tag as CFString)
                }
            } else if let lat = s.latitude, let lon = s.longitude {
                CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitude, abs(lat) as CFNumber)
                CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitudeRef, (lat < 0 ? "S" : "N") as CFString)
                CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitude, abs(lon) as CFNumber)
                CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitudeRef, (lon < 0 ? "W" : "E") as CFString)
            }
            return try Output.write(to: dest) { tmp in
                guard let type = file.type, let d = CGImageDestinationCreateWithURL(tmp as CFURL, type.identifier as CFString, 1, nil) else { throw ClementineError.cannotWrite(tmp) }
                var err: Unmanaged<CFError>?
                let ok = CGImageDestinationCopyImageSource(d, src, [kCGImageDestinationMetadata: meta, kCGImageDestinationMergeMetadata: false] as CFDictionary, &err)
                guard ok else { throw ClementineError.helperFailed((err?.takeRetainedValue()).map { String(describing: $0) } ?? "Metadata rewrite failed.") }
            }
        }
        // Re-encode path (HEIC and others): merge edits into the property dictionaries.
        let loaded = try ImageConverter.load(s.url)
        var props = ImageConverter.metadataOnly(loaded.properties)
        for f in MetadataModel.fields {
            let new = s.values[f.id] ?? "", old = s.originals[f.id] ?? ""
            guard new != old else { continue }
            var dict = props[f.dictionary as String] as? [String: Any] ?? [:]
            if new.isEmpty { dict.removeValue(forKey: f.key as String) }
            else if f.isList { dict[f.key as String] = new.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            else { dict[f.key as String] = new }
            props[f.dictionary as String] = dict
        }
        if s.removeGPS { props.removeValue(forKey: kCGImagePropertyGPSDictionary as String) }
        else if let lat = s.latitude, let lon = s.longitude {
            props[kCGImagePropertyGPSDictionary as String] = [
                kCGImagePropertyGPSLatitude as String: abs(lat), kCGImagePropertyGPSLatitudeRef as String: lat < 0 ? "S" : "N",
                kCGImagePropertyGPSLongitude as String: abs(lon), kCGImagePropertyGPSLongitudeRef as String: lon < 0 ? "W" : "E",
            ]
        }
        let type = ImageConverter.writableType(for: file) ?? .jpeg
        return try Output.write(to: Output.sibling(of: s.url, ext: ImageConverter.ext(for: type), suffix: "Metadata")) { tmp in
            try ImageConverter.write(loaded.image, to: tmp, type: type, quality: 0.95, properties: props)
        }
    }
}

struct MetadataEditorView: View {
    @ObservedObject var model: MetadataModel
    unowned let controller: EditorWindowController

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Description") {
                    ForEach(MetadataModel.fields.filter { ["title", "description", "caption", "keywords"].contains($0.id) }) { f in
                        TextField(f.label, text: model.binding(f.id))
                    }
                }
                Section("Rights") {
                    ForEach(MetadataModel.fields.filter { ["artist", "copyright", "credit"].contains($0.id) }) { f in TextField(f.label, text: model.binding(f.id)) }
                }
                Section("Camera and dates") {
                    ForEach(MetadataModel.fields.filter { ["make", "model", "lens", "software", "dateOriginal", "dateDigitized", "comment"].contains($0.id) }) { f in
                        TextField(f.label, text: model.binding(f.id))
                    }
                }
                Section("Location") {
                    TextField("Latitude (decimal, south negative)", text: $model.latitude).disabled(model.removeGPS)
                    TextField("Longitude (decimal, west negative)", text: $model.longitude).disabled(model.removeGPS)
                    ForEach(MetadataModel.fields.filter { ["city", "country"].contains($0.id) }) { f in TextField(f.label, text: model.binding(f.id)) }
                    Toggle("Remove GPS coordinates", isOn: $model.removeGPS)
                }
                Section {
                    DisclosureGroup("All properties (\(model.allProperties.count))", isExpanded: $model.showAll) {
                        ForEach(Array(model.allProperties.enumerated()), id: \.offset) { _, pair in
                            LabeledContent(pair.0) { Text(pair.1).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack(spacing: 12) {
                Text(model.isLossless ? "Writes a copy with the pixels untouched (lossless)." : "This format is re-encoded at high quality to carry the new tags.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Remove all metadata") {
                    let spec = model.spec(stripAll: true)
                    EditorManager.shared.save(title: "Remove Metadata", source: model.file.url) { try MetadataModel.export(spec) }
                    controller.dismiss()
                }
                Button("Cancel") { controller.dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save copy") {
                    let spec = model.spec()
                    EditorManager.shared.save(title: "Metadata", source: model.file.url) { try MetadataModel.export(spec) }
                    controller.dismiss()
                }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .tint(Color.clementine)
                .disabled(!model.hasChanges)
            }
            .padding(12)
        }
        .frame(minWidth: 620, minHeight: 520)
    }
}
