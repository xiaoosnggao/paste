import AppKit

@main
struct PasteboardMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        #if DEBUG
        if CommandLine.arguments.contains("--self-test") {
            setbuf(stdout, nil)
            Task { @MainActor in
                do {
                    if ProcessInfo.processInfo.environment["PASTE_PERFORMANCE_ONLY"] == "1" {
                        let count = try await RuntimePerformanceChecks.run()
                        print("PASS: \(count) isolated runtime performance checks")
                    } else { try await SystemChecks.run() }
                    exit(0)
                }
                catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            }
            application.run()
            return
        }
        #endif
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}
