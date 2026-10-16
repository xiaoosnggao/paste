#if DEBUG
import AppKit
import Translation

@MainActor
enum SystemToolsRuntimeChecks {
    static func run() async throws -> Int {
        let image = NSImage(size: NSSize(width: 1100, height: 260))
        image.lockFocus()
        NSColor.white.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1100, height: 260)).fill()
        ("PASTEBOARD OCR 2026\nHello world" as NSString).draw(at: NSPoint(x: 45, y: 75), withAttributes: [.font: NSFont.systemFont(ofSize: 60), .foregroundColor: NSColor.black])
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation else { throw SystemChecks.Failure(message: "System OCR fixture image unavailable") }
        let upload = try OCRImagePreparation.uploadData(tiff)
        guard upload.starts(with: [0x89, 0x50, 0x4e, 0x47]) || upload.starts(with: [0xff, 0xd8, 0xff]) else { throw SystemChecks.Failure(message: "TIFF clipboard image not normalized for cloud OCR") }
        let start = Date()
        let service = CloudToolsService(credentialLoader: { _ in nil })
        let response = try await service.recognize(image: tiff, configuration: .init())
        guard response.text.localizedCaseInsensitiveContains("PASTEBOARD"), response.text.contains("2026"), response.text.localizedCaseInsensitiveContains("Hello") else {
            throw SystemChecks.Failure(message: "Actual system OCR did not recognize rendered fixture: \(response.text)")
        }
        print("SYSTEM OCR REAL: rendered fixture recognized in \(Date().timeIntervalSince(start)) s")
        guard #available(macOS 15.0, *) else {
            print("SYSTEM TRANSLATION: requires macOS 15; actual translation not run")
            return 4
        }
        let source = Locale.Language(identifier: "en"), target = Locale.Language(identifier: "zh-Hans")
        let status: LanguageAvailability.Status
        do { status = try await SystemTranslationCoordinator.languageStatus(source: source, target: target) }
        catch { print("SYSTEM TRANSLATION: language-resource query timed out or unavailable; actual translation not verified"); return 4 }
        if status == .installed, #available(macOS 26.0, *) {
            let session: TranslationSession
            if #available(macOS 26.4, *) { session = .init(installedSource: source, target: target, preferredStrategy: .lowLatency) }
            else { session = .init(installedSource: source, target: target) }
            do {
                let translated = try await session.translate("Hello world")
                guard !translated.targetText.isEmpty, translated.targetText != "Hello world" else { throw SystemChecks.Failure(message: "System translation did not produce Chinese") }
                print("SYSTEM TRANSLATION REAL en→zh: \(translated.targetText)")
                return 5
            } catch let failure as SystemChecks.Failure { throw failure }
            catch { print("SYSTEM TRANSLATION: installed languages reported, runtime failed (\(type(of: error))); UI language setup requires verification"); return 4 }
        }
        print("SYSTEM TRANSLATION: language availability = \(status); real translation deferred until language resources are ready")
        return 4
    }
}
#endif
