import AppKit
import SwiftUI

/// Fallback entry point: `open -a Clementine file`, double-clicking the app, or "Convert Files…" in the menu.
@MainActor
final class PickerWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PickerWindowController()
    let model = PickerModel()

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Clementine"
        w.isReleasedWhenClosed = false
        w.center()
        super.init(window: w)
        w.delegate = self
        w.contentView = NSHostingView(rootView: PickerView(model: model))
    }
    required init?(coder: NSCoder) { fatalError() }

    func present(urls: [URL]) {
        model.setFiles(urls)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose files to convert or act on"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { present(urls: panel.urls) }
    }
}

@MainActor
final class PickerModel: ObservableObject {
    @Published var files: [FileItem] = []
    @Published var kind: WheelKind = .convert
    var operations: [Operation] { OperationCatalog.allOperations(for: files, kind: kind) }
    func setFiles(_ urls: [URL]) { files = urls.map(FileItem.init) }
}

struct PickerView: View {
    @ObservedObject var model: PickerModel
    @State private var targeted = false

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Files").font(.headline)
                    Spacer()
                    Button("Choose…") { PickerWindowController.shared.chooseFiles() }.controlSize(.small)
                }
                .padding(10)
                Divider()
                if model.files.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.down").font(.system(size: 28)).foregroundStyle(.tertiary)
                        Text("Drop files here").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(model.files) { f in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: f.url.path)).resizable().frame(width: 22, height: 22)
                            Text(f.name).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .frame(minWidth: 200, idealWidth: 230)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(targeted ? Color.clementine : .clear, lineWidth: 2))
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                var urls: [URL] = []
                let group = DispatchGroup()
                for p in providers {
                    group.enter()
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url { urls.append(url) }
                        group.leave()
                    }
                }
                group.notify(queue: .main) { model.setFiles(urls) }
                return true
            }

            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: $model.kind) {
                    ForEach(WheelKind.allCases) { k in Label(k.title, systemImage: k.symbol).tag(k) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if model.files.isEmpty {
                    Text("Add files to see what Clementine can do with them.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                            ForEach(model.operations) { op in
                                Button {
                                    JobCenter.shared.run(op, urls: model.files.map(\.url))
                                } label: {
                                    VStack(spacing: 6) {
                                        Image(systemName: op.symbol).font(.system(size: 20))
                                        Text(op.title).font(.system(size: 11, weight: .medium)).multilineTextAlignment(.center)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 64)
                                    .padding(6)
                                }
                                .buttonStyle(.bordered)
                                .tint(Color.clementine)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                Text(Settings.shared.hintLine + "  while dragging files anywhere opens the same options as a wheel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(minWidth: 320)
        }
    }
}
