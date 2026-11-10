import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()
    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Clementine Settings"
        w.isReleasedWhenClosed = false
        w.center()
        super.init(window: w)
        w.contentView = NSHostingView(rootView: SettingsView())
    }
    required init?(coder: NSCoder) { fatalError() }
    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = Settings.shared
    @State private var launchAtLogin = Settings.shared.launchAtLogin

    var body: some View {
        Form {
            Section("Wheels") {
                Text("Hold one of these while dragging files to open the matching wheel.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Convert wheel", selection: $settings.convertModifier) { modifierOptions }
                Picker("Tools wheel", selection: $settings.toolsModifier) { modifierOptions }
                Picker("Actions wheel", selection: $settings.actionsModifier) { modifierOptions }
                if Set([settings.convertModifier, settings.toolsModifier, settings.actionsModifier]).count < 3 {
                    Label("Two wheels share a modifier; the first one wins.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Output") {
                Toggle("Reveal results in Finder when done", isOn: $settings.revealOutputs)
                Toggle("Play sounds", isOn: $settings.playSounds)
                VStack(alignment: .leading) {
                    Slider(value: $settings.imageQuality, in: 0.4...1.0, step: 0.05) {
                        Text("Image quality \(Int(settings.imageQuality * 100))%")
                    }
                }
                Picker("Video export", selection: $settings.videoQuality) {
                    ForEach(VideoQuality.allCases) { q in Text(q.label).tag(q) }
                }
                Picker("Terminal app", selection: $settings.terminalApp) {
                    ForEach(TerminalApp.allCases.filter(\.isInstalled)) { t in Text(t.label).tag(t) }
                }
            }
            Section("Helpers") {
                Toggle("Use installed ffmpeg when available", isOn: $settings.useFFmpeg)
                LabeledContent("ffmpeg") {
                    Text(FFmpeg.shared.url == nil ? "Not found (brew install ffmpeg for WebP, MP3, FLAC, WebM)" : FFmpeg.shared.url!.path)
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in
                        settings.launchAtLogin = v
                        launchAtLogin = settings.launchAtLogin
                    }
                LabeledContent("Uses so far", value: "\(settings.usesCount)")
                Button("Show Welcome Again") { WelcomeWindowController.shared.present() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 520)
    }

    private var modifierOptions: some View {
        ForEach(ModifierChoice.allCases) { m in Text("\(m.symbol) \(m.label)").tag(m) }
    }
}
