import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class WelcomeWindowController: NSWindowController {
    static let shared = WelcomeWindowController()
    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Welcome to Clementine"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.center()
        super.init(window: w)
        w.contentView = NSHostingView(rootView: WelcomeView())
    }
    required init?(coder: NSCoder) { fatalError() }
    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct WelcomeView: View {
    @ObservedObject private var settings = Settings.shared
    @State private var sample: URL = WelcomeView.makeSample()
    @State private var launchAtLogin = Settings.shared.launchAtLogin

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
            Text("Clementine").font(.system(size: 26, weight: .bold))
            Text("Drag any file. Hold a modifier. Drop it on a petal.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                step(settings.convertModifier.symbol, "Convert", "Images, audio, video, PDF and documents to other formats.")
                step(settings.toolsModifier.symbol, "Tools", "Compress, resize, strip metadata, OCR, merge or split PDFs, mute video.")
                step(settings.actionsModifier.symbol, "Actions", "Copy path, reveal, open a terminal, AirDrop, trash, or park files in a Float.")
            }
            .padding(14)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: sample.path)).resizable().frame(width: 40, height: 40)
                    .onDrag { NSItemProvider(contentsOf: sample) ?? NSItemProvider() }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Try it now").font(.system(size: 12, weight: .semibold))
                    Text("Drag this sample image anywhere while holding \(settings.convertModifier.symbol).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 6)
            HStack {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in
                        settings.launchAtLogin = v
                        launchAtLogin = settings.launchAtLogin
                    }
                Spacer()
                Button("Settings…") { SettingsWindowController.shared.present() }
                Button("Got it") {
                    settings.hasCompletedWelcome = true
                    WelcomeWindowController.shared.window?.close()
                }
                .keyboardShortcut(.defaultAction)
                .tint(Color.clementine)
            }
        }
        .padding(28)
        .frame(width: 520)
    }

    private func step(_ key: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key).font(.system(size: 18, weight: .bold)).frame(width: 30, height: 30)
                .background(Color.clementine.opacity(0.18), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }

    /// A small PNG in the temp folder, so the welcome screen has something real to drag.
    static func makeSample() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Clementine Sample.png")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let size = 400
        guard let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return url }
        c.setFillColor(CGColor(red: 1.0, green: 0.55, blue: 0.15, alpha: 1))
        c.fillEllipse(in: CGRect(x: 20, y: 20, width: size - 40, height: size - 40))
        c.setFillColor(CGColor(gray: 1, alpha: 0.8))
        c.fillEllipse(in: CGRect(x: 110, y: 230, width: 60, height: 60))
        if let img = c.makeImage() {
            try? ImageConverter.write(img, to: url, type: .png, quality: 1, properties: nil)
        }
        return url
    }
}
