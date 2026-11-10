import AppKit

@main
enum ClementineMain {
    nonisolated(unsafe) static var delegate: AppDelegate?

    static func main() {
        let args = CommandLine.arguments
        if args.count > 1, ["--run", "--list", "--help", "--selftest-editors", "--target-size", "--office-scripts", "--selftest-phase4"].contains(args[1]) {
            exit(HeadlessRunner.main(Array(args.dropFirst())))
        }
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let d = AppDelegate()
            delegate = d
            app.delegate = d
            app.setActivationPolicy(.accessory)
            app.run()
        }
    }
}
