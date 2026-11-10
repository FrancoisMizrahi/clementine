import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let dragMonitor = DragMonitor()
    let wheel = WheelController()
    private let statusLine = NSMenuItem(title: "Clementine is ready", action: nil, keyEquivalent: "")
    private let hintLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-wheel"), args.count > i + 1 {
            let kind = args.count > i + 2 ? WheelKind(rawValue: args[i + 2]) ?? .convert : .convert
            let samples = args.count > i + 3 ? args[(i + 3)...].map { URL(fileURLWithPath: $0) } : [URL(fileURLWithPath: "/tmp/sample.png")]
            FFmpeg.shared.detectIfNeeded()
            let ok = WheelRenderer.render(to: args[i + 1], kind: kind, sampleURLs: samples)
            print(ok ? "wrote \(args[i + 1])" : "render failed")
            NSApp.terminate(nil)
            return
        }
        if let i = args.firstIndex(of: "--snapshot-editor"), args.count > i + 3 {
            // Debug: open one editor off-screen, wait for its preview, write the window contents to a PNG.
            let kind = EditorKind(rawValue: args[i + 1]) ?? .image
            let out = args[i + 3]
            EditorManager.shared.open(kind, urls: [URL(fileURLWithPath: args[i + 2])])
            for w in NSApp.windows where w.title.contains(kind.title) { w.setFrameOrigin(NSPoint(x: -20_000, y: -20_000)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if let w = NSApp.windows.first(where: { $0.title.contains(kind.title) }), let v = w.contentView,
                   let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    w.effectiveAppearance.performAsCurrentDrawingAppearance { v.cacheDisplay(in: v.bounds, to: rep) }
                    let composed = NSImage(size: v.bounds.size)
                    composed.lockFocus()
                    w.effectiveAppearance.performAsCurrentDrawingAppearance {
                        NSColor.windowBackgroundColor.setFill()
                        NSRect(origin: .zero, size: v.bounds.size).fill()
                    }
                    rep.draw(in: NSRect(origin: .zero, size: v.bounds.size))
                    composed.unlockFocus()
                    var rect = NSRect(origin: .zero, size: v.bounds.size)
                    if let cg = composed.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                        try? ImageConverter.write(cg, to: URL(fileURLWithPath: out), type: .png, quality: 1, properties: nil)
                    }
                    print("wrote \(out)")
                } else {
                    print("no editor window")
                }
                NSApp.terminate(nil)
            }
            return
        }
        NSApp.applicationIconImage = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
        setupStatusItem()
        DispatchQueue.global(qos: .utility).async { FFmpeg.shared.detectIfNeeded() }
        dragMonitor.onDrag = { [weak self] kind, urls, point in self?.wheel.show(kind: kind, urls: urls, at: point) }
        dragMonitor.onModifierReleased = { [weak self] point in self?.wheel.modifierReleased(at: point) }
        dragMonitor.onDragEnded = { [weak self] in self?.wheel.dragEnded() }
        dragMonitor.start()
        SoundPlayer.shared.prewarm()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.wheel.prewarm() }
        if !Settings.shared.hasCompletedWelcome {
            WelcomeWindowController.shared.present()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        PickerWindowController.shared.present(urls: urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { PickerWindowController.shared.present(urls: []) }
        return true
    }

    // MARK: Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = StatusIcon.image()
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "Clementine"
        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        hintLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(hintLine)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Convert Files…", action: #selector(convertFiles), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "New Float", action: #selector(newFloat), keyEquivalent: "n").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Welcome…", action: #selector(openWelcome), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Clementine", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let running = JobCenter.shared.jobs.filter { !$0.isFinished }.count
        statusLine.title = running > 0 ? "Working on \(running) job\(running == 1 ? "" : "s")…" : "Clementine is ready"
        hintLine.title = Settings.shared.hintLine + " while dragging"
    }

    @objc private func convertFiles() { PickerWindowController.shared.chooseFiles() }
    @objc private func newFloat() { FloatManager.shared.newFloat(with: []) }
    @objc private func openSettings() { SettingsWindowController.shared.present() }
    @objc private func openWelcome() { WelcomeWindowController.shared.present() }
}

/// Menu-bar glyph: a sliced citrus seen from above, drawn as a template image.
enum StatusIcon {
    static func image() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            let c = NSGraphicsContext.current!.cgContext
            let center = CGPoint(x: rect.midX, y: rect.midY - 0.5)
            let r: CGFloat = 7.2
            c.setStrokeColor(NSColor.black.cgColor)
            c.setLineWidth(1.6)
            c.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
            c.setLineWidth(1.1)
            for i in 0..<4 {
                let a = CGFloat(i) * .pi / 4
                c.move(to: CGPoint(x: center.x - cos(a) * (r - 1.4), y: center.y - sin(a) * (r - 1.4)))
                c.addLine(to: CGPoint(x: center.x + cos(a) * (r - 1.4), y: center.y + sin(a) * (r - 1.4)))
            }
            c.strokePath()
            c.setFillColor(NSColor.black.cgColor)
            c.fillEllipse(in: CGRect(x: center.x - 1.4, y: center.y - 1.4, width: 2.8, height: 2.8))
            // leaf
            c.move(to: CGPoint(x: center.x + 0.5, y: center.y + r))
            c.addQuadCurve(to: CGPoint(x: center.x + 4.5, y: center.y + r + 2.2), control: CGPoint(x: center.x + 0.5, y: center.y + r + 3))
            c.addQuadCurve(to: CGPoint(x: center.x + 0.5, y: center.y + r), control: CGPoint(x: center.x + 4, y: center.y + r))
            c.fillPath()
            return true
        }
        img.isTemplate = true
        return img
    }
}
