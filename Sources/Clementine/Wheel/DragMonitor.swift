import AppKit

/// Detects a file drag anywhere on the system plus a held modifier, without Accessibility permission:
/// global mouse monitors see the button go down and up, a short-lived timer watches the drag pasteboard,
/// `NSEvent.modifierFlags` reports the held modifiers.
@MainActor
final class DragMonitor {
    var onDrag: ((WheelKind, [URL], NSPoint) -> Void)?
    var onModifierReleased: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    private var monitors: [Any] = []
    private var timer: Timer?
    private var changeCountAtDown = -1
    private var cachedChangeCount = -1
    private var cachedURLs: [URL] = []
    private var sawDrag = false

    func start() {
        let down: (NSEvent) -> Void = { [weak self] _ in self?.mouseDown() }
        let up: (NSEvent) -> Void = { [weak self] _ in self?.mouseUp() }
        let dragged: (NSEvent) -> Void = { [weak self] _ in self?.tick() }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: down) as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: up) as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: dragged) as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { e in down(e); return e } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { e in up(e); return e } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { e in dragged(e); return e } as Any)
    }

    private func mouseDown() {
        changeCountAtDown = NSPasteboard(name: .drag).changeCount
        sawDrag = false
        timer?.invalidate()
        let t = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func mouseUp() {
        timer?.invalidate()
        timer = nil
        if sawDrag { onDragEnded?() }
        sawDrag = false
    }

    private func tick() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else { mouseUp(); return }
        let pb = NSPasteboard(name: .drag)
        let count = pb.changeCount
        guard count != changeCountAtDown else { return } // no new drag session yet
        if count != cachedChangeCount {
            cachedChangeCount = count
            let objs = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            cachedURLs = objs
        }
        guard !cachedURLs.isEmpty else { return }
        sawDrag = true
        let location = NSEvent.mouseLocation
        if let kind = Settings.shared.kind(for: NSEvent.modifierFlags) {
            onDrag?(kind, cachedURLs, location)
        } else {
            onModifierReleased?(location)
        }
    }
}
