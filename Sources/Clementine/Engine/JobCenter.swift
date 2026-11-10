import AppKit
import SwiftUI

@MainActor
final class JobState: ObservableObject, Identifiable {
    enum Status { case running, done(OperationResult), failed(String) }
    let id = UUID()
    let title: String
    let detail: String
    @Published var progress: Double = 0
    @Published var status: Status = .running
    init(title: String, detail: String) { self.title = title; self.detail = detail }
    var isFinished: Bool { if case .running = status { return false }; return true }
}

/// Runs operations on a background queue and feeds the HUD.
@MainActor
final class JobCenter: ObservableObject {
    static let shared = JobCenter()
    @Published private(set) var jobs: [JobState] = []
    private let queue = DispatchQueue(label: "clementine.jobs", qos: .userInitiated, attributes: .concurrent)
    private lazy var hud = HUDController(center: self)

    func run(_ op: Operation, urls: [URL]) {
        if let editor = op.editor {
            EditorManager.shared.open(editor, urls: urls)
            return
        }
        let files = urls.map(FileItem.init)
        let job = JobState(title: op.title, detail: files.count == 1 ? files[0].name : "\(files.count) files")
        jobs.append(job)
        if jobs.count > 8 { jobs.removeFirst(jobs.count - 8) }
        hud.show()
        Settings.shared.usesCount += 1
        let ctx = JobContext { p in
            Task { @MainActor in job.progress = p }
        }
        queue.async {
            let outcome: Result<OperationResult, Error>
            do { outcome = .success(try op.run(OperationInput(files: files, ctx: ctx))) }
            catch { outcome = .failure(error) }
            Task { @MainActor in self.finish(job, outcome) }
        }
    }

    private func finish(_ job: JobState, _ outcome: Result<OperationResult, Error>) {
        switch outcome {
        case .success(let r):
            job.progress = 1
            job.status = .done(r)
            if !r.outputs.isEmpty { SoundPlayer.shared.play(.done) }
            if Settings.shared.revealOutputs, r.revealable, !r.outputs.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(r.outputs)
            }
            if r.outputs.isEmpty, r.message == nil { dismiss(job, after: 1.2) }
        case .failure(let e):
            job.status = .failed(e.localizedDescription)
            SoundPlayer.shared.play(.failed)
        }
        hud.scheduleAutoHide()
    }

    func dismiss(_ job: JobState, after delay: TimeInterval = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.jobs.removeAll { $0.id == job.id }
            if self?.jobs.isEmpty == true { self?.hud.hide() }
        }
    }

    func clearFinished() {
        jobs.removeAll(where: \.isFinished)
        if jobs.isEmpty { hud.hide() }
    }

    var hasRunning: Bool { jobs.contains { !$0.isFinished } }
}

// MARK: HUD

@MainActor
final class HUDController {
    private weak var center: JobCenter?
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    init(center: JobCenter) { self.center = center }

    func show() {
        hideWork?.cancel()
        let p = panel ?? makePanel()
        panel = p
        position(p)
        if !p.isVisible { p.alphaValue = 0; p.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.15; p.animator().alphaValue = 1 }
    }

    func scheduleAutoHide() {
        hideWork?.cancel()
        guard let center, !center.hasRunning else { return }
        let hasErrors = center.jobs.contains { if case .failed = $0.status { return true }; return false }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let center = self.center, !center.hasRunning else { return }
            self.hide()
            center.clearFinished()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (hasErrors ? 12 : 5), execute: work)
    }

    func hide() {
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.2; p.animator().alphaValue = 0 }) {
            Task { @MainActor in p.orderOut(nil) }
        }
    }

    private func position(_ p: NSPanel) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let f = screen?.visibleFrame else { return }
        p.setFrameOrigin(NSPoint(x: f.maxX - p.frame.width - 16, y: f.maxY - p.frame.height - 16))
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 10),
                        styleMask: [.borderless, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = true
        let host = NSHostingView(rootView: HUDView(center: center ?? JobCenter.shared))
        host.sizingOptions = [.preferredContentSize]
        p.contentView = host
        p.setContentSize(host.fittingSize)
        return p
    }
}

struct HUDView: View {
    @ObservedObject var center: JobCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(center.jobs) { job in
                JobRow(job: job, center: center)
                if job.id != center.jobs.last?.id { Divider() }
            }
        }
        .padding(12)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .padding(6)
    }
}

struct JobRow: View {
    @ObservedObject var job: JobState
    let center: JobCenter

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
                if case .running = job.status {
                    ProgressView(value: job.progress).progressViewStyle(.linear).controlSize(.small)
                }
            }
            Spacer(minLength: 0)
            if case .done(let r) = job.status, r.revealable, !r.outputs.isEmpty {
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting(r.outputs) }
                    .controlSize(.small)
            }
            Button { center.dismiss(job) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var icon: some View {
        switch job.status {
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.clementine).font(.system(size: 18))
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.system(size: 17))
        }
    }

    private var detail: String {
        switch job.status {
        case .running: return job.detail
        case .done(let r):
            if let m = r.message { return m }
            if r.outputs.count == 1 { return r.outputs[0].lastPathComponent }
            return r.outputs.isEmpty ? "Done" : "\(r.outputs.count) files written"
        case .failed(let msg): return msg
        }
    }
}
