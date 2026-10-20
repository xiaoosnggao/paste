import AppKit

@main
struct PasteboardMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        #if DEBUG
        if CommandLine.arguments.contains("--knowledge-preview") || Bundle.main.bundleIdentifier?.hasSuffix(".knowledge-preview") == true {
            KnowledgeInteractionPreview.show()
            application.run()
            return
        }
        if CommandLine.arguments.contains("--context-suggestions-preview") || Bundle.main.bundleIdentifier?.hasSuffix(".context-preview") == true {
            ContextSuggestionPreview.show()
            application.run()
            return
        }
        if CommandLine.arguments.contains("--self-test") {
            setbuf(stdout, nil)
            Task { @MainActor in
                do {
                    if ProcessInfo.processInfo.environment["PASTE_DEEPSEEK_LIVE_CHECKS"] == "1" {
                        let count = try await DeepSeekLiveChecks.run()
                        print("PASS: \(count) DeepSeek Flash live integration checks")
                    } else if ProcessInfo.processInfo.environment["PASTE_PERFORMANCE_ONLY"] == "1" {
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
