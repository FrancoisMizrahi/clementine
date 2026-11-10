import SwiftUI

extension Color {
    static let clementine = Color(red: 1.0, green: 0.55, blue: 0.15)
}

@MainActor
final class WheelModel: ObservableObject {
    @Published var kind: WheelKind = .convert
    @Published var items: [Operation] = []
    @Published var highlighted: Int? = nil
    private(set) var files: [FileItem] = []

    var subtitle: String {
        files.count == 1 ? files[0].name : "\(files.count) files"
    }

    func load(urls: [URL], kind: WheelKind) {
        files = urls.map(FileItem.init)
        self.kind = kind
        items = OperationCatalog.operations(for: files, kind: kind)
        highlighted = nil
    }

    func setKind(_ k: WheelKind) {
        guard k != kind else { return }
        kind = k
        items = OperationCatalog.operations(for: files, kind: k)
        highlighted = nil
    }

    func updateHighlight(point: CGPoint, in rect: CGRect) {
        let idx = WheelGeometry.index(forPoint: point, in: rect, count: items.count)
        guard idx != highlighted else { return }
        highlighted = idx
        if idx != nil { SoundPlayer.shared.play(.highlight) }
    }

    func reset() {
        highlighted = nil
    }

    func perform(urls: [URL]) -> Bool {
        guard let i = highlighted, items.indices.contains(i) else { return false }
        JobCenter.shared.run(items[i], urls: urls)
        return true
    }
}

struct PetalShape: Shape {
    let index: Int
    let count: Int
    func path(in rect: CGRect) -> Path {
        let (a, b) = WheelGeometry.angles(index: index, count: count)
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.addArc(center: c, radius: WheelGeometry.outer, startAngle: .degrees(a), endAngle: .degrees(b), clockwise: false)
        p.addArc(center: c, radius: WheelGeometry.inner, startAngle: .degrees(b), endAngle: .degrees(a), clockwise: true)
        p.closeSubpath()
        return p
    }
}

struct WheelView: View {
    @ObservedObject var model: WheelModel
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            ZStack {
                Circle()
                    .fill(.regularMaterial)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
                    .padding(4)
                ForEach(Array(model.items.enumerated()), id: \.offset) { i, op in
                    let on = i == model.highlighted
                    PetalShape(index: i, count: model.items.count)
                        .fill(on ? Color.clementine : Color.primary.opacity(0.045))
                    PetalShape(index: i, count: model.items.count)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                    VStack(spacing: 4) {
                        Image(systemName: op.symbol)
                            .font(.system(size: 19, weight: .medium))
                        Text(op.title)
                            .font(.system(size: 10.5, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(on ? Color.white : Color.primary)
                    .frame(width: 76)
                    .position(WheelGeometry.labelCenter(index: i, count: model.items.count, in: rect))
                    .allowsHitTesting(false)
                }
                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.9))
                    .frame(width: WheelGeometry.inner * 2 - 6, height: WheelGeometry.inner * 2 - 6)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
                VStack(spacing: 2) {
                    Image(systemName: model.kind.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.clementine)
                    Text(model.highlighted.flatMap { model.items.indices.contains($0) ? model.items[$0].title : nil } ?? model.kind.title)
                        .font(.system(size: 11.5, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(model.subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(settings.hintLine)
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .frame(width: WheelGeometry.inner * 2 - 18)
            }
        }
        .frame(width: WheelGeometry.size, height: WheelGeometry.size)
    }
}
