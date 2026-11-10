import Foundation

/// Removes metadata from JPEG and PNG files by rewriting the container, leaving the compressed pixels untouched.
/// Colour profiles stay; EXIF, XMP, IPTC, Photoshop blocks, comments and PNG text/time chunks go.
enum LosslessStrip {
    /// Only safe when the EXIF orientation is 1 (or absent), since the orientation tag is dropped too.
    static func jpeg(_ data: Data, orientation: Int) -> Data? {
        guard orientation <= 1, data.count > 4, data[0] == 0xFF, data[1] == 0xD8 else { return nil }
        var out = Data(capacity: data.count)
        out.append(contentsOf: [0xFF, 0xD8])
        var i = 2
        while i + 4 <= data.count {
            guard data[i] == 0xFF else { return nil }
            let marker = data[i + 1]
            if marker == 0xFF { i += 1; continue }                       // fill byte
            if marker == 0x01 || (0xD0...0xD8).contains(marker) { i += 2; continue } // standalone markers
            if marker == 0xDA {                                            // start of scan: copy the rest verbatim
                out.append(contentsOf: data[i...])
                return out
            }
            let length = Int(data[i + 2]) << 8 | Int(data[i + 3])
            guard length >= 2, i + 2 + length <= data.count else { return nil }
            let segment = data[i..<(i + 2 + length)]
            var drop = false
            switch marker {
            case 0xE1, 0xE3...0xEC, 0xED, 0xEF, 0xFE: drop = true          // Exif/XMP, misc APPn, Photoshop/IPTC, comments
            case 0xE2:                                                    // keep only ICC_PROFILE in APP2
                let tagEnd = min(i + 15, data.count)
                drop = String(bytes: data[(i + 4)..<tagEnd], encoding: .ascii) != "ICC_PROFILE"
            default: drop = false                                         // JFIF, Adobe APP14, tables, frames
            }
            if !drop { out.append(contentsOf: segment) }
            i += 2 + length
        }
        return nil
    }

    static func png(_ data: Data) -> Data? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count > 8, Array(data[0..<8]) == signature else { return nil }
        let dropTypes: Set<String> = ["tEXt", "iTXt", "zTXt", "eXIf", "tIME", "dSIG", "caNv"]
        var out = Data(signature)
        var i = 8
        while i + 8 <= data.count {
            let length = Int(data[i]) << 24 | Int(data[i + 1]) << 16 | Int(data[i + 2]) << 8 | Int(data[i + 3])
            let type = String(bytes: data[(i + 4)..<(i + 8)], encoding: .ascii) ?? ""
            let total = 12 + length
            guard i + total <= data.count else { return nil }
            if !dropTypes.contains(type) { out.append(contentsOf: data[i..<(i + total)]) }
            if type == "IEND" { return out }
            i += total
        }
        return nil
    }
}
