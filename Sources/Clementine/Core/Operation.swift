import Foundation

enum WheelKind: String, CaseIterable, Identifiable {
    case convert, tools, actions
    var id: String { rawValue }
    var title: String {
        switch self {
        case .convert: return "Convert"
        case .tools: return "Tools"
        case .actions: return "Actions"
        }
    }
    var symbol: String {
        switch self {
        case .convert: return "arrow.triangle.2.circlepath"
        case .tools: return "wrench.and.screwdriver"
        case .actions: return "bolt"
        }
    }
}

/// Per-job plumbing handed to converters: progress reporting and a cancellation flag.
final class JobContext {
    var progress: (Double) -> Void
    private let lock = NSLock()
    private var cancelled = false
    init(progress: @escaping (Double) -> Void = { _ in }) { self.progress = progress }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func report(_ value: Double) { progress(min(max(value, 0), 1)) }
    /// Scales a sub-task's 0...1 progress into the slot `index` of `count`.
    func sub(_ index: Int, of count: Int) -> JobContext {
        let child = JobContext { [weak self] p in
            self?.report((Double(index) + p) / Double(max(count, 1)))
        }
        return child
    }
}

struct OperationInput {
    let files: [FileItem]
    let ctx: JobContext
    var urls: [URL] { files.map(\.url) }
}

struct OperationResult {
    var outputs: [URL] = []
    var message: String? = nil
    /// Some outputs (e.g. a clipboard copy) have nothing to reveal.
    var revealable: Bool = true
    static let none = OperationResult(outputs: [], message: nil, revealable: false)
}

/// Editors open a window instead of running straight away; saving then goes through the normal job pipeline.
enum EditorKind: String {
    case image, redact, annotate, pdfOrganizer, targetSize, videoTrim, audioTrim, collage, visualizer, metadata
    var title: String {
        switch self {
        case .image: return "Crop & Adjust"
        case .redact: return "Redact"
        case .annotate: return "Annotate"
        case .pdfOrganizer: return "Organize PDF"
        case .targetSize: return "Target Size"
        case .videoTrim: return "Trim & Crop"
        case .audioTrim: return "Trim & Bleep"
        case .collage: return "Collage"
        case .visualizer: return "Visualizer"
        case .metadata: return "Metadata"
        }
    }
}

/// One petal on the wheel.
struct Operation: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let kind: WheelKind
    let editor: EditorKind?
    let run: (OperationInput) throws -> OperationResult

    init(_ id: String, _ title: String, _ symbol: String, _ kind: WheelKind,
         run: @escaping (OperationInput) throws -> OperationResult) {
        self.id = id; self.title = title; self.symbol = symbol; self.kind = kind; self.editor = nil; self.run = run
    }

    init(_ id: String, _ title: String, _ symbol: String, _ kind: WheelKind, editor: EditorKind) {
        self.id = id; self.title = title; self.symbol = symbol; self.kind = kind; self.editor = editor
        self.run = { _ in throw ClementineError.unsupported("\(title) opens an editor window and cannot run headless.") }
    }
    static func == (a: Operation, b: Operation) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// Runs `body` for each file, collecting outputs and continuing past per-file failures.
func perFile(_ input: OperationInput, _ body: (FileItem, JobContext) throws -> [URL]) throws -> OperationResult {
    var outputs: [URL] = []
    var errors: [String] = []
    for (i, f) in input.files.enumerated() {
        if input.ctx.isCancelled { break }
        do {
            outputs += try body(f, input.ctx.sub(i, of: input.files.count))
        } catch {
            errors.append("\(f.name): \(error.localizedDescription)")
        }
    }
    input.ctx.report(1)
    if outputs.isEmpty, !errors.isEmpty { throw ClementineError.partial(errors) }
    var result = OperationResult(outputs: outputs)
    if !errors.isEmpty { result.message = "\(errors.count) failed: " + errors.joined(separator: "; ") }
    return result
}
