#if DEBUG
import AppKit
import ApplicationServices
import PasteCore
import SwiftUI

@MainActor
enum SystemChecks {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static func run() async throws {
        var count = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw Failure(message: message) }
            count += 1
        }
        var trustQueries = 0
        let privacyEnvironment = NativePasteEnvironment(trustCheck: { trustQueries += 1; return true })
        try check(!privacyEnvironment.accessibilityGranted && trustQueries == 0, "startup queried Accessibility without an explicit user action")
        privacyEnvironment.enableAccessibilityChecks()
        try check(privacyEnvironment.accessibilityGranted && trustQueries == 1, "explicit paste action did not allow permission checking")
        var probes = 0
        let recoveredFocus = PasteAccessibilityTransport.verifySystemFocus(probe: {
            probes += 1
            return probes < 3 ? .unavailable : .matched
        }, wait: {})
        try check(recoveredFocus == nil && probes == 3, "transient AX query failure was treated as permanent dispatch failure")
        probes = 0
        let changedFocus = PasteAccessibilityTransport.verifySystemFocus(probe: { probes += 1; return .mismatched }, wait: {})
        try check(changedFocus == .focusNotRestored && probes == 1, "actual wrong focus was retried")
        probes = 0
        let unavailableFocus = PasteAccessibilityTransport.verifySystemFocus(probe: { probes += 1; return .unavailable }, wait: {})
        try check(unavailableFocus == .focusQueryUnavailable && probes == 3, "unavailable AX query did not terminate with specific failure")
        probes = 0
        let compatibleFocus = PasteAccessibilityTransport.verifySystemFocus(probe: { probes += 1; return .unavailable }, wait: {}, foregroundMatches: { true })
        try check(compatibleFocus == nil && probes == 3, "AX-unavailable foreground target was blocked")
        probes = 0
        let incompatibleFocus = PasteAccessibilityTransport.verifySystemFocus(probe: { probes += 1; return .unavailable }, wait: {}, foregroundMatches: { false })
        try check(incompatibleFocus == .focusNotRestored && probes == 0, "different foreground application permitted AX fallback")
        let contradictoryFocus = PasteAccessibilityTransport.verifySystemFocus(probe: { .mismatched }, wait: {}, foregroundMatches: { true })
        try check(contradictoryFocus == .focusNotRestored, "explicit AX focus mismatch was ignored")
        var foregroundReads = 0
        let switchedFocus = PasteAccessibilityTransport.verifySystemFocus(probe: { .unavailable }, wait: {}, foregroundMatches: { foregroundReads += 1; return foregroundReads < 4 })
        try check(switchedFocus == .focusNotRestored && foregroundReads == 4, "foreground switch before fallback was missed")
        foregroundReads = 0
        let switchedMatchedFocus = PasteAccessibilityTransport.verifySystemFocus(probe: { .matched }, wait: {}, foregroundMatches: { foregroundReads += 1; return foregroundReads == 1 })
        try check(switchedMatchedFocus == .focusNotRestored, "foreground switch during successful AX read was missed")
        var capturedReads = 0
        let recoveredCaptured = PasteAccessibilityTransport.verifyCapturedFocus(probe: {
            capturedReads += 1
            return capturedReads == 1 ? .unavailable : .matched
        }, wait: {})
        try check(recoveredCaptured == nil && capturedReads == 2, "transient captured-focus read failure blocked paste")
        capturedReads = 0
        let unavailableCaptured = PasteAccessibilityTransport.verifyCapturedFocus(probe: { capturedReads += 1; return .unavailable }, wait: {})
        try check(unavailableCaptured == .capturedFocusQueryUnavailable && capturedReads == 3, "captured-focus read failure was mislabeled as focus loss")
        capturedReads = 0
        let mismatchedCaptured = PasteAccessibilityTransport.verifyCapturedFocus(probe: { capturedReads += 1; return .mismatched }, wait: {})
        try check(mismatchedCaptured == .focusNotRestored && capturedReads == 1, "known different captured input was retried or allowed")
        var restoreActions = 0
        let unchangedRestore = PasteAccessibilityTransport.restoreFocusSafely(preflight: { nil }, captured: { nil }, raise: { restoreActions += 1 }, focus: { restoreActions += 1 })
        try check(unchangedRestore == nil && restoreActions == 0, "matching input was unnecessarily raised or refocused")
        let unreadableFocusRestore = PasteAccessibilityTransport.restoreFocusSafely(preflight: { nil }, captured: { .capturedFocusQueryUnavailable }, raise: { restoreActions += 1 }, focus: { restoreActions += 1 })
        try check(unreadableFocusRestore == .capturedFocusQueryUnavailable && restoreActions == 0, "unreadable input was blindly restored")
        let switchedRestore = PasteAccessibilityTransport.restoreFocusSafely(preflight: { .focusNotRestored }, captured: { .focusNotRestored }, raise: { restoreActions += 1 }, focus: { restoreActions += 1 })
        try check(switchedRestore == .focusNotRestored && restoreActions == 0, "background target was raised after foreground switch")
        var foregroundStillMatches = true
        let switchedDuringRaise = PasteAccessibilityTransport.restoreFocusSafely(preflight: { foregroundStillMatches ? nil : .focusNotRestored }, captured: { .focusNotRestored }, raise: { restoreActions += 1; foregroundStillMatches = false }, focus: { restoreActions += 10 })
        try check(switchedDuringRaise == .focusNotRestored && restoreActions == 1, "focus setter ran after foreground switch during AXRaise")
        var inputRestored = false
        restoreActions = 0
        let normalRestore = PasteAccessibilityTransport.restoreFocusSafely(preflight: { nil }, captured: { inputRestored ? nil : .focusNotRestored }, raise: { restoreActions += 1 }, focus: { restoreActions += 1; inputRestored = true })
        try check(normalRestore == nil && inputRestored && restoreActions == 2, "normal restoration did not run each action exactly once")
        var restorePermission = true
        restoreActions = 0
        let revokedRestore = PasteAccessibilityTransport.restoreFocusSafely(preflight: { restorePermission ? nil : .accessibilityPermissionRequired }, captured: { .focusNotRestored }, raise: { restoreActions += 1; restorePermission = false }, focus: { restoreActions += 10 })
        try check(revokedRestore == .accessibilityPermissionRequired && restoreActions == 1, "permission revoked during raise still allowed focus setter")
        capturedReads = 0
        restoreActions = 0
        let finalUnreadableRestore = PasteAccessibilityTransport.restoreFocusSafely(preflight: { nil }, captured: { capturedReads += 1; return capturedReads == 1 ? .focusNotRestored : .capturedFocusQueryUnavailable }, raise: { restoreActions += 1 }, focus: { restoreActions += 1 })
        try check(finalUnreadableRestore == .capturedFocusQueryUnavailable && restoreActions == 2, "unconfirmed restore was retried or mislabeled")
        try check(PasteAccessibilityTransport.isEditableTextRole(kAXTextAreaRole, settable: true, enabled: true), "writable text area did not use keyboard path")
        try check(!PasteAccessibilityTransport.isEditableTextRole(kAXTextAreaRole, settable: false, enabled: true), "read-only text area used keyboard path")
        try check(!PasteAccessibilityTransport.isEditableTextRole(kAXTextFieldRole, settable: true, enabled: false), "disabled text field used keyboard path")
        try check(!PasteAccessibilityTransport.isEditableTextRole(kAXButtonRole, settable: true, enabled: true), "noneditor bypassed paste menu")
        let secondaryScreen = NSRect(x: -1920, y: -200, width: 1920, height: 1080)
        let visible = PanelPresentation.visibleFrame(on: secondaryScreen)
        try check(visible.minY == secondaryScreen.minY + 8 && visible.minX == secondaryScreen.minX + 8, "panel does not anchor to full monitor bounds")
        let expanded = PanelPresentation.visibleFrame(on: secondaryScreen, suggestionsVisible: true)
        try check(expanded.minY == visible.minY && expanded.height == visible.height + PanelPresentation.suggestionExpansionHeight, "suggestions expansion shifted bottom anchor")
        let summaryFrame = PanelPresentation.visibleFrame(on: secondaryScreen, suggestionsVisible: true, additionalHeight: 250)
        for step in 0...10 {
            let progress = CGFloat(step) / 10
            let shrinking = PanelPresentation.interpolatedFrame(from: summaryFrame, to: visible, progress: progress)
            try check(shrinking.minY == visible.minY && shrinking.minX == visible.minX && shrinking.width == visible.width,
                      "summary collapse moved the monitor anchor")
            try check(shrinking.height >= visible.height && shrinking.height <= summaryFrame.height,
                      "summary collapse overshot its content bounds")
        }
        try check(PanelPresentation.interpolatedFrame(from: summaryFrame, to: visible, progress: 1) == visible,
                  "summary collapse did not finish at its destination")
        let animatedPanel = ClipboardPanel(contentRect: visible, styleMask: [.borderless], backing: .buffered, defer: false)
        animatedPanel.isReleasedWhenClosed = false
        let frameAnimator = PanelFrameAnimator()
        frameAnimator.animate(animatedPanel, to: summaryFrame)
        await Task.yield()
        frameAnimator.cancel()
        animatedPanel.setFrame(visible, display: false)
        try await Task.sleep(nanoseconds: 35_000_000)
        try check(animatedPanel.frame == visible, "cancelled suggestion resize overwrote a later panel frame")
        frameAnimator.animate(animatedPanel, to: summaryFrame, reduceMotion: true)
        try check(animatedPanel.frame == summaryFrame, "reduce motion did not resize immediately")
        animatedPanel.close()
        let shortScreen = NSRect(x: 0, y: 900, width: 600, height: 300)
        try check(PanelPresentation.visibleFrame(on: shortScreen, suggestionsVisible: true).height <= shortScreen.height - 16, "suggestions expand outside monitor")
        let clipped = PanelGlassContainer.make(content: EmptyView(), frame: NSRect(origin: .zero, size: visible.size))
        try check(clipped.layer?.masksToBounds == true, "panel content can draw outside its animation window")
        let solidContainer = PanelGlassContainer.make(content: EmptyView(), frame: NSRect(origin: .zero, size: visible.size), reduceTransparency: true) as! PanelAnimationContainer
        let solidSurface = solidContainer.surface as! PanelGlassSurface
        try check(solidSurface.material == .solid, "reduce transparency did not use an opaque surface")
        let nativeContainer = PanelGlassContainer.make(content: EmptyView(), frame: NSRect(origin: .zero, size: visible.size), reduceTransparency: false) as! PanelAnimationContainer
        let nativeSurface = nativeContainer.surface as! PanelGlassSurface
        if #available(macOS 26.0, *) {
            try check(nativeSurface.material == .liquidGlass, "native Liquid Glass surface missing")
            let glass = nativeSurface.subviews.first as? NSGlassEffectView
            try check(glass?.contentView != nil && glass?.tintColor != nil, "glass lost its hosted content or graphite tint")
            #if compiler(>=6.4)
            if #available(macOS 27.0, *) { try check(glass?.effectIsInteractive == false, "window glass must not flash when clicking empty space") }
            #endif
        } else {
            try check(nativeSurface.material == .visualEffect, "older macOS blur fallback missing")
        }
        let nativeBackground = nativeSurface.subviews.first
        let solidBackground = solidSurface.subviews.first
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
            nativeContainer.appearance = NSAppearance(named: appearanceName)
            solidContainer.appearance = NSAppearance(named: appearanceName)
            nativeSurface.viewDidChangeEffectiveAppearance()
            solidSurface.viewDidChangeEffectiveAppearance()
            let dark = appearanceName == .darkAqua
            let solidColor = solidBackground?.layer?.backgroundColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }
            try check(abs((solidColor?.redComponent ?? -1) - (dark ? 32.0 / 255 : 236.0 / 255)) < 0.001,
                      "solid fallback did not track the current appearance")
            try check(nativeSurface.subviews.first === nativeBackground && solidSurface.subviews.first === solidBackground,
                      "appearance change rebuilt the animated material surface")
            if #available(macOS 26.0, *), let glass = nativeBackground as? NSGlassEffectView {
                let tint = glass.tintColor?.usingColorSpace(.sRGB)
                try check(abs((tint?.redComponent ?? -1) - (dark ? 0.10 : 188.0 / 255)) < 0.001,
                          "Liquid Glass tint did not track the current appearance")
                try check(dark ? (tint?.alphaComponent ?? 0) >= 0.75 : (tint?.alphaComponent ?? 1) < 0.4,
                          "glass tint lost dark contrast protection or light translucency")
            }
            let tintAlpha = nativeSurface.tintLayerColor?.alphaComponent ?? 0
            try check(tintAlpha >= (dark ? PanelGlassSurface.tintAlpha.dark : PanelGlassSurface.tintAlpha.light) - 0.001,
                      "panel background lets the windows behind it show through")
        }
        // Traffic-light center line: window base coords (bottom-left origin) → distance from top.
        try check(TrafficLightGeometry.centerFromTop(buttonRect: NSRect(x: 20, y: 452, width: 16, height: 16), contentHeight: 480) == 20,
                  "traffic-light center conversion is wrong")
        let lightsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                                    styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        lightsWindow.isReleasedWhenClosed = false
        lightsWindow.titlebarAppearsTransparent = true
        if let measured = TrafficLightGeometry.measure(lightsWindow) {
            try check(measured > 4 && measured < 40, "measured traffic-light center \(measured) is implausible")
        }
        try check(TrafficLightGeometry.titlebarDrop(containerHeight: 28, target: 23) == 9, "titlebar drop math is wrong")
        try check(TrafficLightGeometry.buttonOrigins(sizes: [NSSize(width: 14, height: 14), NSSize(width: 14, height: 14)], step: 20,
                                                     stripHeight: 28, leading: 16) == [NSPoint(x: 16, y: 7), NSPoint(x: 36, y: 7)],
                  "traffic-light origins are wrong")
        TrafficLightGeometry.applyLayout(to: lightsWindow)
        if let moved = TrafficLightGeometry.measure(lightsWindow) {
            try check(abs(moved - TrafficLightGeometry.targetCenterFromTop) <= 1, "traffic lights did not move to \(TrafficLightGeometry.targetCenterFromTop), got \(moved)")
        }
        lightsWindow.close()
        let upper = NSRect(x: 0, y: 1080, width: 1920, height: 1080)
        let lower = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let upperWindow = PanelPresentation.visibleFrame(on: upper)
        let localBounds = NSRect(origin: .zero, size: upperWindow.size)
        let hiddenContent = PanelPresentation.hiddenContentFrame(size: upperWindow.size)
        for step in 0...10 {
            let content = localBounds.offsetBy(dx: 0, dy: hiddenContent.minY * (1 - CGFloat(step) / 10))
            let displayed = content.intersection(localBounds)
            try check(displayed.isEmpty || !displayed.offsetBy(dx: upperWindow.minX, dy: upperWindow.minY).intersects(lower), "upper-screen animation entered lower screen")
        }
        for error: AXError in [.cannotComplete, .failure, .notImplemented, .apiDisabled] {
            try check(!PasteAccessibilityTransport.MenuResult(actionResult: error).allowsKeyboardFallback, "uncertain AX paste action retried with keyboard")
        }
        try check(PasteAccessibilityTransport.MenuResult(actionResult: .success) == .pressed, "successful AX paste not classified as dispatched")
        try check(PasteAccessibilityTransport.MenuResult.timedOut.allowsKeyboardFallback, "menu search timeout without AXPress prevented keyboard fallback")
        try check(PasteAccessibilityTransport.MenuResult.unavailable.allowsKeyboardFallback, "missing paste menu prevented keyboard fallback")
        try check(!PasteAccessibilityTransport.MenuResult.focusChanged.allowsKeyboardFallback, "changed AX focus permitted keyboard fallback")
        try check(!PasteAccessibilityTransport.MenuResult.rejected(.capturedFocusQueryUnavailable).allowsKeyboardFallback, "unconfirmed known input permitted menu keyboard fallback")
        try check(!PasteAccessibilityTransport.MenuResult.rejected(.accessibilityPermissionRequired).allowsKeyboardFallback, "revoked permission permitted menu keyboard fallback")
        try check(!PasteAccessibilityTransport.MenuResult.disabled.allowsKeyboardFallback, "disabled paste action permitted keyboard fallback")
        let pasteboard = NSPasteboard(name: .init("com.gaoxs.pasteboard.tests.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let appURL = Bundle.main.bundleURL
        try check(appURL.pathExtension == "app", "authorization guide does not refer to an application bundle")
        try check(pasteboard.writeObjects([appURL as NSURL]), "application drag URL could not be written")
        try check(pasteboard.string(forType: .fileURL).flatMap(URL.init(string:)) == appURL, "application drag did not carry the exact running bundle URL")
        let bridge = ClipboardBridge(pasteboard: pasteboard, sourceProvider: { .init(bundleID: "test.clipboard.source", name: "Synthetic") })
        var preferences = AppPreferences()
        preferences.ignoredBundleIDs = []
        func put(_ items: [NSPasteboardItem]) {
            pasteboard.clearContents()
            pasteboard.writeObjects(items)
        }
        func textItem(_ text: String, marker: String? = nil) -> NSPasteboardItem {
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            if let marker { item.setData(Data(), forType: .init(marker)) }
            return item
        }
        let rich = textItem("测试 rich text")
        let rtf = try NSAttributedString(string: "测试 rich text", attributes: [.font: NSFont.boldSystemFont(ofSize: 16)]).data(from: NSRange(location: 0, length: 12), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        rich.setData(rtf, forType: .rtf)
        rich.setData(Data("<b>测试 rich text</b>".utf8), forType: .html)
        put([rich, textItem("second item")])
        guard let captured = try bridge.capture(preferences: preferences, paused: false) else { throw Failure(message: "rich capture failed") }
        try check(captured.representations.contains { $0.type == NSPasteboard.PasteboardType.rtf.rawValue && $0.data == rtf }, "RTF bytes were lost")
        try check(Set(captured.representations.map(\.itemIndex)) == [0, 1], "multi-item boundaries were lost")
        try bridge.write([captured], plainText: false)
        try check(pasteboard.pasteboardItems?.count == 2, "multi-item writeback failed")
        try check(pasteboard.pasteboardItems?.first?.data(forType: .rtf) == rtf, "RTF writeback changed bytes")
        try check(try bridge.capture(preferences: preferences, paused: false) == nil, "internal write was recaptured")
        try bridge.write([captured], plainText: true)
        try check(pasteboard.pasteboardItems?.first?.types == [.string], "plain text transformation retained rich formats")
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"] {
            put([textItem("must not save", marker: marker)])
            try check(try bridge.capture(preferences: preferences, paused: false) == nil, "privacy marker not respected: \(marker)")
        }
        put([textItem("paused")])
        try check(try bridge.capture(preferences: preferences, paused: true) == nil, "pause not respected")
        preferences.monitoringEnabled = false
        put([textItem("disabled")])
        try check(try bridge.capture(preferences: preferences, paused: false) == nil, "disabled monitor not respected")
        preferences.monitoringEnabled = true
        preferences.ignoredBundleIDs = ["test.clipboard.source"]
        put([textItem("ignored")])
        try check(try bridge.capture(preferences: preferences, paused: false) == nil, "ignored source not respected")
        preferences.ignoredBundleIDs = []
        let file = NSPasteboardItem()
        file.setString("file:///private/tmp/clipboard-test-reference.txt", forType: .fileURL)
        put([file])
        let capturedFile = try bridge.capture(preferences: preferences, paused: false)
        try check(capturedFile?.kind == .file && capturedFile?.filePaths == ["/private/tmp/clipboard-test-reference.txt"], "file reference not captured")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("pasteboard-integration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let repo = SnapshotRepository(directory: temporary)
        try repo.save(.init(items: [captured]))
        let restored = try repo.load()
        try bridge.write(restored.items, plainText: false)
        try check(pasteboard.pasteboardItems?.first?.data(forType: .rtf) == rtf, "rich restart roundtrip failed")
        let model = AppModel(isDemo: true, storageDirectory: temporary, bridge: bridge)
        model.pause(minutes: nil)
        try check(model.isPaused, "indefinite pause failed")
        model.resume()
        try check(!model.isPaused, "resume failed")
        model.pause(minutes: 0)
        try check(!model.isPaused, "expired timed pause failed")
        let original = model.snapshot
        model.createPinboard(name: "Test")
        model.undo()
        try check(model.snapshot == original, "pinboard undo failed")
        model.redo()
        try check(model.snapshot.pinboards.contains { $0.name == "Test" }, "pinboard redo failed")
        model.selectedPinboardID = model.snapshot.pinboards.first(where: { $0.name == "Test" })?.id
        try check(model.saveText("board-local text", title: "board-local", item: nil) && model.visibleItems.contains(where: { $0.title == "board-local" }), "new text was not pinned to current board")
        model.selectedPinboardID = nil
        model.queryString = "设计"
        model.selectFirstIfNeeded()
        try check(model.selectedItems.count == 1 && model.selectedItems[0].text.contains("设计"), "filtered ordering selection failed")
        model.selectedIDs = [original.items[0].id]
        let hiddenID = original.items[0].id
        model.deleteSelected()
        try check(model.snapshot.items.contains { $0.id == hiddenID }, "filtered deletion removed a hidden selection")
        let removed = model.snapshot.items[0]
        model.commit(SnapshotOperations.deleteItems(ids: [removed.id], in: model.snapshot), action: "test")
        try check(!model.saveText("edited", title: "", item: removed), "editing missing item reported success")
        let giant = String(repeating: "x", count: 2 * 1024 * 1024 + 1)
        put([textItem(giant)])
        do {
            _ = try bridge.capture(preferences: preferences, paused: false)
            throw Failure(message: "oversized text accepted")
        } catch ClipboardError.textTooLarge { count += 1 }
        let damagedDirectory = temporary.appendingPathComponent("damaged")
        try FileManager.default.createDirectory(at: damagedDirectory, withIntermediateDirectories: true)
        try Data("broken snapshot".utf8).write(to: damagedDirectory.appendingPathComponent("clipboard.json"))
        let recovering = AppModel(storageDirectory: damagedDirectory, bridge: bridge)
        try check(recovering.storageError != nil, "corrupt data not reported")
        try recovering.recoverStorageForImport(restored)
        let recoverySnapshot = try SnapshotRepository(directory: damagedDirectory).load()
        try check(recoverySnapshot == restored, "valid backup did not recover corrupt persistence")
        try check(try Data(contentsOf: damagedDirectory.appendingPathComponent("clipboard.json")) == Data("broken snapshot".utf8) && FileManager.default.fileExists(atPath: damagedDirectory.appendingPathComponent("Damaged Store Recovery").path), "damaged source was not preserved")
        model.queryString = ""
        let attributed = NSAttributedString(string: "rich saved", attributes: [.font: NSFont.boldSystemFont(ofSize: 17), .underlineStyle: NSUnderlineStyle.single.rawValue])
        try check(model.saveRichText(attributed, title: "Formatted", item: nil), "formatted editor save failed")
        guard let saved = model.snapshot.items.first(where: { $0.title == "Formatted" }),
              let rtf = saved.representations.first(where: { $0.type == NSPasteboard.PasteboardType.rtf.rawValue })?.data,
              let decoded = NSAttributedString(rtf: rtf, documentAttributes: nil) else { throw Failure(message: "edited RTF was not retained") }
        try check(decoded.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue, "editor underline was lost")
        if let image = model.snapshot.items.first(where: { $0.kind == .image }),
           let original = image.previewImage?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            model.rotateImage(image, clockwise: true)
            let deadline = Date().addingTimeInterval(5)
            while model.processingImageIDs.contains(image.id) && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            try check(!model.processingImageIDs.contains(image.id), "background rotation did not finish")
            let rotated = model.snapshot.items.first(where: { $0.id == image.id })?.previewImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            try check(rotated?.width == original.height && rotated?.height == original.width, "rotation dimensions are wrong")
            model.undo()
            try check(model.snapshot.items.first(where: { $0.id == image.id })?.fingerprint == image.fingerprint, "image rotation undo failed")
        }
        let full = ClipItem(text: "", kind: .image, representations: [.init(type: "public.png", data: Data(repeating: 0, count: 60 * 1024 * 1024))])
        model.snapshot = .init(items: [full], pinboards: [Pinboard(name: "Full", itemIDs: [full.id])])
        try check(model.saveText("keep my input", title: "", item: nil) && model.snapshot.items.contains(where: { $0.id == full.id }), "permanent history dropped existing content or rejected editor input")
        let engine = PasteEngine(trackApplications: false)
        let dispatched = await engine.dispatchPaste(closePanel: {})
        try check(!dispatched, "paste dispatched without a valid target")
        count += try await PasteDispatchChecks.run()
        count += try await ImagePreviewChecks.run()
        count += try await AIFeatureChecks.run()
        count += try await SessionStateChecks.run()
        count += try await PersistenceChecks.run()
        count += try await IntelligenceChecks.run()
        count += try await MCPChecks.run()
        count += try await AppDelegate.checkCapturePanelHandoff()
        count += try await AppDelegate.checkColdStartPreview()
        count += try ScreenshotChecks.run()
        count += try await ScreenshotChecks.runLifecycle()
        count += try MenuShortcut.checkPresentation()
        count += try ToolShortcutChecks.run()
        count += try await CloudToolsChecks.run()
        count += try await LocalKnowledgeChecks.run()
        count += try await LocalKnowledgeAcceptanceChecks.run()
        count += try await AppModelHistoryChecks.run()
        count += try await KnowledgeRegressionChecks.run()
        count += try HorizontalScrollRoutingChecks.run()
        count += try PanelPaletteChecks.run()
        count += try PanelMetricsChecks.run()
        count += try PanelKeyboardChecks.run()
        count += try PanelDetailChecks.run()
        count += try StackCapsuleChecks.run()
        count += try await PanelNoticeChecks.run()
        count += try await ContextSuggestionsChecks.run()
        count += try await ContextSuggestionModelChecks.run()
        count += try await ToolWorkflowChecks.run()
        count += try ToolSourceEditor.runEditorChecks()
        count += try await AutoTranslationChecks.run()
        count += try await SelectedTextChecks.run()
        count += try PermissionGuideChecks.run()
        count += try await PermissionRepairChecks.run()
        count += try ToolWindowPlacementChecks.run()
        count += try AuxiliaryWindowPlacementChecks.run()
        count += try WindowLayoutChecks.run()
        count += try await ProviderChecks.run()
        count += try await SystemToolsRuntimeChecks.run()
        if ProcessInfo.processInfo.environment["PASTE_PERFORMANCE_CHECKS"] == "1" {
            count += try await RuntimePerformanceChecks.run()
        }
        print("PASS: \(count) native integration checks (rich formats, file refs, privacy, self-write suppression, pause, selection, undo/redo, safe paste fallback).")
    }
}
#endif
