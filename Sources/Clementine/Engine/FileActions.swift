import AppKit

/// The Actions wheel: nothing is converted, files are moved around or handed to other apps.
enum FileActions {
    static func copyPaths(_ files: [FileItem]) -> OperationResult {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(files.map(\.url.path).joined(separator: "\n"), forType: .string)
        return OperationResult(outputs: [], message: "Copied \(files.count) path\(files.count == 1 ? "" : "s")", revealable: false)
    }

    static func copyFiles(_ files: [FileItem]) -> OperationResult {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(files.map { $0.url as NSURL })
        return OperationResult(outputs: [], message: "Copied \(files.count) file\(files.count == 1 ? "" : "s")", revealable: false)
    }

    static func trash(_ files: [FileItem]) -> OperationResult {
        let sem = DispatchSemaphore(value: 0)
        var failure: Error?
        DispatchQueue.main.async {
            NSWorkspace.shared.recycle(files.map(\.url)) { _, error in
                failure = error
                sem.signal()
            }
        }
        sem.wait()
        if let failure { return OperationResult(outputs: [], message: failure.localizedDescription, revealable: false) }
        return OperationResult(outputs: [], message: "Moved \(files.count) to Trash", revealable: false)
    }

    static func reveal(_ files: [FileItem]) -> OperationResult {
        DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting(files.map(\.url)) }
        return .none
    }

    static func openTerminal(_ files: [FileItem]) -> OperationResult {
        guard let first = files.first else { return .none }
        let folder = first.isDirectory ? first.url : first.url.deletingLastPathComponent()
        let bundle = Settings.shared.terminalApp.rawValue
        DispatchQueue.main.async {
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: TerminalApp.terminal.rawValue) else { return }
            NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
        return .none
    }

    static func airdrop(_ files: [FileItem]) -> OperationResult {
        DispatchQueue.main.async {
            guard let service = NSSharingService(named: .sendViaAirDrop) else { return }
            NSApp.activate(ignoringOtherApps: true)
            if service.canPerform(withItems: files.map(\.url)) { service.perform(withItems: files.map(\.url)) }
        }
        return .none
    }

    static func duplicate(_ files: [FileItem]) throws -> OperationResult {
        var outs: [URL] = []
        for f in files {
            let dest = Output.sibling(of: f.url, ext: f.url.pathExtension, suffix: "copy")
            try FileManager.default.copyItem(at: f.url, to: dest)
            outs.append(dest)
        }
        return OperationResult(outputs: outs)
    }
}
