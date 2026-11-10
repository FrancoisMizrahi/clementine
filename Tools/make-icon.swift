// Draws the Clementine app icon (an orange seen from above, sliced like the wheel) and builds AppIcon.icns.
// Usage: swift Tools/make-icon.swift <outputDir>
import AppKit
import ImageIO

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build"
let iconset = outDir + "/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func draw(size: CGFloat) -> CGImage {
    let px = Int(size)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let r = size * 0.40
    let c = CGPoint(x: size / 2, y: size / 2 - size * 0.03)
    // Shadow + body
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.02), blur: size * 0.05, color: CGColor(gray: 0, alpha: 0.35))
    ctx.setFillColor(CGColor(red: 0.98, green: 0.52, blue: 0.12, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    ctx.restoreGState()
    // Radial gradient for volume
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    ctx.clip()
    let grad = CGGradient(colorsSpace: cs,
                          colors: [CGColor(red: 1.0, green: 0.72, blue: 0.28, alpha: 1),
                                   CGColor(red: 0.98, green: 0.52, blue: 0.12, alpha: 1),
                                   CGColor(red: 0.85, green: 0.36, blue: 0.06, alpha: 1)] as CFArray,
                          locations: [0, 0.6, 1])!
    ctx.drawRadialGradient(grad, startCenter: CGPoint(x: c.x - r * 0.35, y: c.y + r * 0.4), startRadius: 0,
                           endCenter: c, endRadius: r * 1.15, options: [.drawsAfterEndLocation])
    // Segment lines, like the wheel
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.38))
    ctx.setLineWidth(max(1, size * 0.014))
    ctx.setLineCap(.round)
    for i in 0..<8 {
        let a = CGFloat(i) * .pi / 4 + .pi / 8
        ctx.move(to: CGPoint(x: c.x + cos(a) * r * 0.22, y: c.y + sin(a) * r * 0.22))
        ctx.addLine(to: CGPoint(x: c.x + cos(a) * r * 0.92, y: c.y + sin(a) * r * 0.92))
    }
    ctx.strokePath()
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.45))
    ctx.fillEllipse(in: CGRect(x: c.x - r * 0.1, y: c.y - r * 0.1, width: r * 0.2, height: r * 0.2))
    ctx.restoreGState()
    // Leaf
    ctx.setFillColor(CGColor(red: 0.33, green: 0.66, blue: 0.30, alpha: 1))
    let lx = c.x + r * 0.02, ly = c.y + r * 0.92
    let leaf = CGMutablePath()
    leaf.move(to: CGPoint(x: lx, y: ly))
    leaf.addQuadCurve(to: CGPoint(x: lx + r * 0.62, y: ly + r * 0.42), control: CGPoint(x: lx + r * 0.05, y: ly + r * 0.55))
    leaf.addQuadCurve(to: CGPoint(x: lx, y: ly), control: CGPoint(x: lx + r * 0.6, y: ly - r * 0.02))
    ctx.addPath(leaf)
    ctx.fillPath()
    return ctx.makeImage()!
}

let sizes: [(String, Int)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
                              ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
                              ("512x512", 512), ("512x512@2x", 1024)]
for (name, px) in sizes {
    let img = draw(size: CGFloat(px))
    let url = URL(fileURLWithPath: "\(iconset)/icon_\(name).png") as CFURL
    let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", outDir + "/AppIcon.icns"]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "AppIcon.icns written" : "iconutil failed")
