import AppKit
import Combine
import ServiceManagement

enum ModifierChoice: String, CaseIterable, Identifiable {
    case shift, command, control, option
    var id: String { rawValue }
    var flags: NSEvent.ModifierFlags {
        switch self {
        case .shift: return .shift
        case .command: return .command
        case .control: return .control
        case .option: return .option
        }
    }
    var symbol: String {
        switch self {
        case .shift: return "⇧"
        case .command: return "⌘"
        case .control: return "⌃"
        case .option: return "⌥"
        }
    }
    var label: String { rawValue.capitalized }
}

enum TerminalApp: String, CaseIterable, Identifiable {
    case terminal = "com.apple.Terminal"
    case iterm = "com.googlecode.iterm2"
    case ghostty = "com.mitchellh.ghostty"
    case warp = "dev.warp.Warp-Stable"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .terminal: return "Terminal"
        case .iterm: return "iTerm2"
        case .ghostty: return "Ghostty"
        case .warp: return "Warp"
        }
    }
    var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue) != nil }
}

enum VideoQuality: String, CaseIterable, Identifiable {
    case highest, p1080, p720
    var id: String { rawValue }
    var label: String {
        switch self {
        case .highest: return "Source resolution"
        case .p1080: return "1080p"
        case .p720: return "720p"
        }
    }
}

/// UserDefaults-backed preferences: one modifier per wheel, output options and quality defaults.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var convertModifier: ModifierChoice { didSet { d.set(convertModifier.rawValue, forKey: "convertModifier") } }
    @Published var toolsModifier: ModifierChoice { didSet { d.set(toolsModifier.rawValue, forKey: "toolsModifier") } }
    @Published var actionsModifier: ModifierChoice { didSet { d.set(actionsModifier.rawValue, forKey: "actionsModifier") } }
    @Published var revealOutputs: Bool { didSet { d.set(revealOutputs, forKey: "revealOutputs") } }
    @Published var playSounds: Bool { didSet { d.set(playSounds, forKey: "playSounds") } }
    @Published var imageQuality: Double { didSet { d.set(imageQuality, forKey: "imageQuality") } }
    @Published var videoQuality: VideoQuality { didSet { d.set(videoQuality.rawValue, forKey: "videoQuality") } }
    @Published var terminalApp: TerminalApp { didSet { d.set(terminalApp.rawValue, forKey: "terminalApp") } }
    @Published var hasCompletedWelcome: Bool { didSet { d.set(hasCompletedWelcome, forKey: "hasCompletedWelcome") } }
    @Published var useFFmpeg: Bool { didSet { d.set(useFFmpeg, forKey: "useFFmpeg") } }
    @Published var usesCount: Int { didSet { d.set(usesCount, forKey: "usesCount") } }

    private init() {
        convertModifier = ModifierChoice(rawValue: d.string(forKey: "convertModifier") ?? "") ?? .shift
        toolsModifier = ModifierChoice(rawValue: d.string(forKey: "toolsModifier") ?? "") ?? .command
        actionsModifier = ModifierChoice(rawValue: d.string(forKey: "actionsModifier") ?? "") ?? .control
        revealOutputs = d.object(forKey: "revealOutputs") as? Bool ?? false
        playSounds = d.object(forKey: "playSounds") as? Bool ?? true
        imageQuality = d.object(forKey: "imageQuality") as? Double ?? 0.85
        videoQuality = VideoQuality(rawValue: d.string(forKey: "videoQuality") ?? "") ?? .highest
        terminalApp = TerminalApp(rawValue: d.string(forKey: "terminalApp") ?? "") ?? .terminal
        hasCompletedWelcome = d.bool(forKey: "hasCompletedWelcome")
        useFFmpeg = d.object(forKey: "useFFmpeg") as? Bool ?? true
        usesCount = d.integer(forKey: "usesCount")
    }

    func modifier(for kind: WheelKind) -> ModifierChoice {
        switch kind {
        case .convert: return convertModifier
        case .tools: return toolsModifier
        case .actions: return actionsModifier
        }
    }

    /// Which wheel a modifier combination opens. Exactly one configured modifier must be held.
    func kind(for flags: NSEvent.ModifierFlags) -> WheelKind? {
        let f = flags.intersection([.shift, .command, .control, .option])
        guard !f.isEmpty else { return nil }
        for kind in WheelKind.allCases where modifier(for: kind).flags == f { return kind }
        return nil
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Launch at login change failed: \(error)")
            }
        }
    }

    var hintLine: String {
        "\(convertModifier.symbol) Convert · \(toolsModifier.symbol) Tools · \(actionsModifier.symbol) Actions"
    }
}
