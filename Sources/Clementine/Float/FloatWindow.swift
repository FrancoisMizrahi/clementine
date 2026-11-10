import AppKit
import SwiftUI
import Quartz

/// A Float is a small always-on-top shelf that holds files until you drag them somewhere else.
@MainActor
final class FloatManager {
    static let shared = FloatManager()
    private(set) var controllers: [FloatWindowController] = []
    nonisolated(unsafe) static var hasFloats = false

    func newFloat(with urls: [URL]) {
        let c = FloatWindowController(urls: urls, index: controllers.count)
        controllers.append(c)
        FloatManager.hasFloats = true
        c.showWindow(nil)
    }

    func addToLatest(_ urls: [URL]) {
        guard let last = controllers.last else { newFloat(with: urls); return }
        last.model.add(urls)
        last.window?.orderFrontRegardless()
    }

    func remove(_ c: FloatWindowController) {
        controllers.removeAll { $0 === c }
        FloatManager.hasFloats = !controllers.isEmpty
    }
}

@MainActor
final class FloatModel: ObservableObject {
    @Published var items: [URL] = []
    @Published var selection: Set<URL> = []
    func add(_ urls: [URL]) {
        for u in urls.map({ $0.standardizedFileURL }) where !items.contains(u) { items.append(u) }
    }
    func remove(_ urls: Set<URL>) {
        items.removeAll { urls.contains($0) }
        selection.subtract(urls)
    }
}

final class FloatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class FloatWindowController: NSWindowController, NSWindowDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let model = FloatModel()

    init(urls: [URL], index: Int) {
        let panel = FloatPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 300),
                               styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
                               backing: .buffered, defer: false)
        panel.title = "Float"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 200, height: 160)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        model.add(urls)
        panel.delegate = self
        let host = NSHostingView(rootView: FloatView(model: model, controller: self))
        panel.contentView = host
        if let screen = NSScreen.main?.visibleFrame {
            let offset = CGFloat(index % 5) * 28
            panel.setFrameOrigin(NSPoint(x: screen.maxX - 290 - offset, y: screen.minY + 60 + offset))
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        FloatManager.shared.remove(self)
    }

    func quickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { model.selection.isEmpty ? model.items.count : model.selection.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            let list = model.selection.isEmpty ? model.items : model.items.filter { model.selection.contains($0) }
            return list.indices.contains(index) ? list[index] as NSURL : nil
        }
    }
}

/// AppKit drag source so all files leave the Float in one drag.
struct DragAllHandle: NSViewRepresentable {
    let urls: [URL]
    func makeNSView(context: Context) -> DragSourceView { DragSourceView() }
    func updateNSView(_ v: DragSourceView, context: Context) { v.urls = urls }
}

final class DragSourceView: NSView, NSDraggingSource {
    var urls: [URL] = []
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {
        guard !urls.isEmpty else { return }
        let items = urls.map { url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 32, height: 32)
            item.setDraggingFrame(NSRect(x: 0, y: 0, width: 32, height: 32), contents: icon)
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

struct FloatView: View {
    @ObservedObject var model: FloatModel
    unowned let controller: FloatWindowController
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "paperclip").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text("Drop files here").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selection) {
                    ForEach(model.items, id: \.self) { url in
                        row(url).tag(url)
                            .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                            .contextMenu {
                                Button("Open") { NSWorkspace.shared.open(url) }
                                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                Button("Quick Look") { model.selection = [url]; controller.quickLook() }
                                Divider()
                                Button("Remove from Float") { model.remove([url]) }
                                Button("Move to Trash") {
                                    NSWorkspace.shared.recycle([url]) { _, _ in }
                                    model.remove([url])
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(minWidth: 200, minHeight: 160)
        .background(.regularMaterial)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(targeted ? Color.clementine : .clear, lineWidth: 2).padding(2))
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.add([url]) }
                }
            }
            return true
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "paperclip").foregroundStyle(Color.clementine)
            Text(model.items.count == 1 ? "1 file" : "\(model.items.count) files").font(.system(size: 12, weight: .semibold))
            Spacer()
            if !model.items.isEmpty {
                DragAllHandle(urls: model.selection.isEmpty ? model.items : model.items.filter { model.selection.contains($0) })
                    .frame(width: 70, height: 20)
                    .overlay(
                        Text(model.selection.isEmpty ? "Drag all" : "Drag \(model.selection.count)")
                            .font(.system(size: 10, weight: .medium))
                            .allowsHitTesting(false)
                    )
                    .background(Color.clementine.opacity(0.15), in: Capsule())
                    .help("Drag all files out at once")
                Button { controller.quickLook() } label: { Image(systemName: "eye") }
                    .buttonStyle(.plain).help("Quick Look")
                Button { model.remove(Set(model.items)) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.plain).help("Clear")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 26)
        .padding(.bottom, 8)
    }

    private func row(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle)
                Text(sizeString(url)).font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
    }

    private func sizeString(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true { return "Folder" }
        return ByteCountFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file)
    }
}
