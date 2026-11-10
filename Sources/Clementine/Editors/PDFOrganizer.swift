import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct PageItem: Identifiable, Equatable {
    let id: UUID
    let sourceURL: URL
    let sourceIndex: Int
    var extraRotation: Int = 0
    var thumbnail: NSImage? = nil
    static func == (a: PageItem, b: PageItem) -> Bool { a.id == b.id && a.extraRotation == b.extraRotation && a.thumbnail === b.thumbnail }
}

struct PDFOrganizeSpec: @unchecked Sendable {
    let pages: [(url: URL, index: Int, rotation: Int)]
    let destination: URL
}

@MainActor
final class PDFOrganizerModel: ObservableObject {
    let files: [FileItem]
    @Published var pages: [PageItem] = []
    @Published var selection: Set<UUID> = []
    @Published var thumbWidth: CGFloat = 150
    @Published var dragging: UUID?
    @Published var error: String?
    @Published private(set) var pendingThumbnails = 0
    private var undoStack: [[PageItem]] = []
    private let thumbQueue = DispatchQueue(label: "clementine.pdf.thumbnails", qos: .userInitiated)
    private var sourceNames: [URL: String] = [:]

    var multipleSources: Bool { sourceNames.count > 1 }
    func sourceName(_ url: URL) -> String { sourceNames[url] ?? url.lastPathComponent }

    init(files: [FileItem]) {
        self.files = files
        for f in files { append(url: f.url) }
    }

    private func append(url: URL) {
        guard let doc = PDFDocument(url: url) else { error = "Could not open \(url.lastPathComponent)"; return }
        if doc.isLocked { error = "\(url.lastPathComponent) is password protected"; return }
        sourceNames[url] = url.deletingPathExtension().lastPathComponent
        let items = (0..<doc.pageCount).map { PageItem(id: UUID(), sourceURL: url, sourceIndex: $0) }
        pages.append(contentsOf: items)
        generateThumbnails(for: items)
    }

    /// Thumbnails come from a private PDFDocument on a background queue, so PDFKit objects never cross threads.
    private func generateThumbnails(for items: [PageItem]) {
        pendingThumbnails += items.count
        let jobs = items.map { ($0.id, $0.sourceURL, $0.sourceIndex) }
        thumbQueue.async {
            var docs: [URL: PDFDocument] = [:]
            for (id, url, index) in jobs {
                if docs[url] == nil { docs[url] = PDFDocument(url: url) }
                let image = docs[url]?.page(at: index)?.thumbnail(of: CGSize(width: 320, height: 320), for: .cropBox)
                Task { @MainActor in
                    if let i = self.pages.firstIndex(where: { $0.id == id }) { self.pages[i].thumbnail = image }
                    self.pendingThumbnails = max(0, self.pendingThumbnails - 1)
                }
            }
        }
    }

    private func pushUndo() {
        undoStack.append(pages)
        if undoStack.count > 50 { undoStack.removeFirst() }
    }

    func move(_ id: UUID, onto target: UUID) {
        guard let from = pages.firstIndex(where: { $0.id == id }), let to = pages.firstIndex(where: { $0.id == target }), from != to else { return }
        if undoStack.last.map({ $0.map(\.id) }) != pages.map(\.id) { pushUndo() }
        let item = pages.remove(at: from)
        pages.insert(item, at: to)
    }

    private var targets: [Int] {
        let ids = selection.isEmpty ? Set(pages.map(\.id)) : selection
        return pages.indices.filter { ids.contains(pages[$0].id) }
    }

    func rotate(by degrees: Int) {
        pushUndo()
        for i in targets { pages[i].extraRotation = (pages[i].extraRotation + degrees + 360) % 360 }
    }

    func deleteSelected() {
        guard !selection.isEmpty else { return }
        pushUndo()
        pages.removeAll { selection.contains($0.id) }
        selection.removeAll()
    }

    func reverse() {
        pushUndo()
        pages.reverse()
    }

    func selectAll() { selection = Set(pages.map(\.id)) }
    func deselectAll() { selection.removeAll() }

    func toggle(_ id: UUID, extend: Bool) {
        if extend {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = selection == [id] ? [] : [id]
        }
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        pages = last
        selection = selection.filter { id in pages.contains { $0.id == id } }
    }

    func insertPDFs() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = "Choose PDFs to append"
        if panel.runModal() == .OK {
            pushUndo()
            for url in panel.urls { append(url: url) }
        }
    }

    func spec() -> PDFOrganizeSpec {
        let destination: URL
        if files.count == 1 {
            destination = Output.sibling(of: files[0].url, ext: "pdf", suffix: "Organized")
        } else {
            destination = Output.unique(files[0].url.deletingLastPathComponent().appendingPathComponent("Merged.pdf"))
        }
        return PDFOrganizeSpec(pages: pages.map { ($0.sourceURL, $0.sourceIndex, $0.extraRotation) }, destination: destination)
    }

    nonisolated static func export(_ s: PDFOrganizeSpec) throws -> URL {
        var docs: [URL: PDFDocument] = [:]
        let out = PDFDocument()
        for p in s.pages {
            if docs[p.url] == nil { docs[p.url] = try PDFConverter.open(p.url) }
            guard let page = docs[p.url]?.page(at: p.index)?.copy() as? PDFPage else { continue }
            page.rotation = (page.rotation + p.rotation) % 360
            out.insert(page, at: out.pageCount)
        }
        guard out.pageCount > 0 else { throw ClementineError.noOutput }
        return try Output.write(to: s.destination) { tmp in
            guard out.write(to: tmp) else { throw ClementineError.cannotWrite(tmp) }
        }
    }
}

struct PageDropDelegate: DropDelegate {
    let target: UUID
    let model: PDFOrganizerModel

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            guard let d = model.dragging, d != target else { return }
            model.move(d, onto: target)
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { model.dragging = nil }
        return true
    }
}

struct PDFOrganizerView: View {
    @ObservedObject var model: PDFOrganizerModel
    unowned let controller: EditorWindowController

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            grid
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { model.rotate(by: -90) } label: { Image(systemName: "rotate.left") }.help("Rotate left (selection, or all pages)")
            Button { model.rotate(by: 90) } label: { Image(systemName: "rotate.right") }.help("Rotate right (selection, or all pages)")
            Button { model.deleteSelected() } label: { Image(systemName: "trash") }
                .keyboardShortcut(.delete, modifiers: []).disabled(model.selection.isEmpty).help("Delete selected pages")
            Button { model.reverse() } label: { Image(systemName: "arrow.left.arrow.right") }.help("Reverse page order")
            Button { model.insertPDFs() } label: { Label("Append PDF…", systemImage: "plus.rectangle.on.rectangle") }
            Button("Undo") { model.undo() }.keyboardShortcut("z", modifiers: .command)
            Button(model.selection.count == model.pages.count && !model.pages.isEmpty ? "Deselect All" : "Select All") {
                if model.selection.count == model.pages.count { model.deselectAll() } else { model.selectAll() }
            }
            .keyboardShortcut("a", modifiers: .command)
            Spacer()
            if model.pendingThumbnails > 0 { ProgressView().controlSize(.small) }
            Text(model.selection.isEmpty ? "\(model.pages.count) pages" : "\(model.selection.count) of \(model.pages.count) selected")
                .font(.caption).foregroundStyle(.secondary)
            Image(systemName: "square.grid.3x3").foregroundStyle(.secondary)
            Slider(value: $model.thumbWidth, in: 90...300).frame(width: 120)
        }
        .padding(10)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: model.thumbWidth, maximum: model.thumbWidth), spacing: 14)], spacing: 14) {
                ForEach(model.pages) { page in
                    PageCell(page: page, number: (model.pages.firstIndex(where: { $0.id == page.id }) ?? 0) + 1,
                             selected: model.selection.contains(page.id), width: model.thumbWidth,
                             source: model.multipleSources ? model.sourceName(page.sourceURL) : nil)
                        .onTapGesture {
                            model.toggle(page.id, extend: NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift))
                        }
                        .onDrag {
                            model.dragging = page.id
                            if !model.selection.contains(page.id) { model.selection = [page.id] }
                            return NSItemProvider(object: page.id.uuidString as NSString)
                        }
                        .onDrop(of: [UTType.plainText], delegate: PageDropDelegate(target: page.id, model: model))
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .onTapGesture { model.deselectAll() }
        .overlay {
            if let e = model.error { Text(e).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)) }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("Drag pages to reorder. Click to select, ⌘-click for several. Rotation and deletion apply to the selection, or to every page when nothing is selected.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("Saves as “\(model.spec().destination.lastPathComponent)”").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Button("Cancel") { controller.dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save PDF") {
                let spec = model.spec()
                EditorManager.shared.save(title: "Organize PDF", source: model.files[0].url) { try PDFOrganizerModel.export(spec) }
                controller.dismiss()
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .tint(Color.clementine)
            .disabled(model.pages.isEmpty)
        }
        .padding(12)
    }
}

struct PageCell: View {
    let page: PageItem
    let number: Int
    let selected: Bool
    let width: CGFloat
    let source: String?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.white).shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                if let t = page.thumbnail {
                    Image(nsImage: t)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .rotationEffect(.degrees(Double(page.extraRotation)))
                        .padding(4)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: width, height: width * 1.3)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Color.clementine : Color.clear, lineWidth: 3))
            .contentShape(Rectangle())
            VStack(spacing: 1) {
                Text("\(number)").font(.caption.monospacedDigit())
                if let source { Text(source).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            .frame(width: width)
        }
    }
}
