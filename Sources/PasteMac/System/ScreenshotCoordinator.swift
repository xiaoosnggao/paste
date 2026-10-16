import AppKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

/// Coordinates one user-initiated selection. It never requests or modifies TCC permission.
@MainActor
final class ScreenshotCoordinator {
    enum Failure: LocalizedError {
        case permissionRequired, busy, cancelled, noDisplay, emptySelection, tooLarge, captureFailed, encodingFailed, timedOut, cannotExcludeSelf
        var errorDescription: String? {
            switch self {
            case .permissionRequired: return "请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中开启 Pasteboard，然后重试截图。"
            case .busy: return "正在截图，请完成框选或按 Esc 取消。"
            case .cancelled: return "已取消截图。"
            case .noDisplay: return "无法找到鼠标所在的显示器。"
            case .emptySelection: return "截图区域过小，请重新框选。"
            case .tooLarge: return "截图超过 1600 万像素或 32 MB，请选择更小的区域。"
            case .captureFailed: return "无法截取所选区域，请检查屏幕录制权限。"
            case .encodingFailed: return "无法生成截图，请重试。"
            case .timedOut: return "截图服务响应超时，请重试。"
            case .cannotExcludeSelf: return "无法隐藏 Pasteboard 窗口，请重试截图。"
            }
        }
    }
    struct Region: Equatable {
        let sourceRect: CGRect
        let pixelWidth: Int
        let pixelHeight: Int
    }
    /// AppKit local bottom-left coordinates -> display-local top-left ScreenCaptureKit coordinates.
    nonisolated static func region(selection: CGRect, screenSize: CGSize, scale: CGFloat) throws -> Region {
        guard screenSize.width.isFinite, screenSize.height.isFinite, screenSize.width > 0, screenSize.height > 0,
              scale.isFinite, scale > 0, scale <= 8,
              [selection.origin.x, selection.origin.y, selection.size.width, selection.size.height].allSatisfy(\.isFinite) else { throw Failure.emptySelection }
        let clipped = selection.standardized.intersection(CGRect(origin: .zero, size: screenSize))
        guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2 else { throw Failure.emptySelection }
        let left = max(0, floor(clipped.minX * scale))
        let right = min(floor(screenSize.width * scale), ceil(clipped.maxX * scale))
        let top = max(0, floor((screenSize.height - clipped.maxY) * scale))
        let bottom = min(floor(screenSize.height * scale), ceil((screenSize.height - clipped.minY) * scale))
        let width = right - left, height = bottom - top
        guard width >= 1, height >= 1, width <= 16_000_000, height <= 16_000_000, width <= 16_000_000 / height else { throw Failure.tooLarge }
        return Region(sourceRect: CGRect(x: left / scale, y: top / scale, width: width / scale, height: height / scale), pixelWidth: Int(width), pixelHeight: Int(height))
    }
    nonisolated static func localSelection(global: CGRect, screenFrame: CGRect) -> CGRect {
        global.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }
    static var isPermissionGranted: Bool { CGPreflightScreenCaptureAccess() }
    static func openPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
    private(set) var isCapturing = false
    private var token: UUID?
    private var cancelled = false
    private var overlay: RegionSelectionPanel?
    private let selectionGate = ScreenshotResultGate<CGRect>()
    private let contentGate = ScreenshotResultGate<SCShareableContent>()
    private let imageGate = ScreenshotResultGate<CGImage>()
    private var encoder: Task<Data, Error>?

    func captureRegion() async throws -> Data {
        guard !isCapturing else { throw Failure.busy }
        try Task.checkCancellation()
        guard Self.isPermissionGranted else { throw Failure.permissionRequired }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { throw Failure.noDisplay }
        let currentToken = UUID()
        token = currentToken; isCapturing = true; cancelled = false
        defer {
            finish(currentToken)
        }
        return try await withTaskCancellationHandler(operation: {
            let selection = try await select(on: screen, token: currentToken)
            try validate(currentToken)
            let content = try await contentGate.wait(token: currentToken, timeoutNanoseconds: 10_000_000_000) { complete in
                SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
                    Task { @MainActor in
                        if let error { complete(.failure(error)) }
                        else if let content { complete(.success(content)) }
                        else { complete(.failure(Failure.captureFailed)) }
                    }
                }
            }
            try validate(currentToken)
            guard let display = content.displays.first(where: { $0.displayID == displayID.uint32Value }) else { throw Failure.noDisplay }
            // Excluding the process also excludes windows created after content enumeration.
            guard let ownApplication = content.applications.first(where: { $0.processID == ProcessInfo.processInfo.processIdentifier }) else {
                throw Failure.cannotExcludeSelf
            }
            let filter = SCContentFilter(display: display, excludingApplications: [ownApplication], exceptingWindows: [])
            let scale = CGFloat(filter.pointPixelScale)
            let region = try Self.region(selection: selection, screenSize: screen.frame.size, scale: scale)
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = region.sourceRect
            configuration.width = region.pixelWidth; configuration.height = region.pixelHeight
            configuration.showsCursor = false
            configuration.captureResolution = .best
            configuration.scalesToFit = false
            closeOverlay()
            let image: CGImage = try await imageGate.wait(token: currentToken, timeoutNanoseconds: 15_000_000_000) { complete in
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                    Task { @MainActor in
                        if let error { complete(.failure(error)) }
                        else if let image { complete(.success(image)) }
                        else { complete(.failure(Failure.captureFailed)) }
                    }
                }
            }
            try validate(currentToken)
            guard image.width == region.pixelWidth, image.height == region.pixelHeight else { throw Failure.captureFailed }
            let work = Task.detached(priority: .utility) { try Self.encode(image) }
            encoder = work
            let data = try await work.value
            try validate(currentToken)
            return data
        }, onCancel: { [weak self] in Task { @MainActor in
            guard let self, self.token == currentToken else { return }
            self.cancel()
        } })
    }
    func cancel() {
        guard isCapturing else { return }
        cancelled = true
        guard let activeToken = token else { return }
        selectionGate.cancel(token: activeToken)
        contentGate.cancel(token: activeToken)
        imageGate.cancel(token: activeToken)
        encoder?.cancel()
        finish(activeToken)
    }
    private func finish(_ expected: UUID) {
        guard token == expected else { return }
        closeOverlay(); encoder = nil; token = nil; isCapturing = false
    }
    private func validate(_ expected: UUID) throws {
        try Task.checkCancellation()
        guard token == expected, !cancelled else { throw Failure.cancelled }
    }
    private func select(on screen: NSScreen, token expected: UUID) async throws -> CGRect {
        try await selectionGate.wait(token: expected, timeoutNanoseconds: nil) { complete in
            let panel = RegionSelectionPanel(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            panel.title = "截图框选 · 拖动选择区域 · Esc 取消"
            panel.level = .screenSaver
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .stationary]
            panel.isReleasedWhenClosed = false
            let view = RegionSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.finished = { [weak self] rect in
                guard let self, self.token == expected else { return }
                self.closeOverlay()
                complete(.success(rect))
            }
            view.cancelled = { [weak self] in
                guard let self, self.token == expected else { return }
                self.cancel()
            }
            panel.contentView = view; overlay = panel
            panel.setFrame(screen.frame, display: false)
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(view)
            NSCursor.crosshair.set()
        }
    }
    private func closeOverlay() { overlay?.orderOut(nil); overlay?.close(); overlay = nil }
    nonisolated private static func encode(_ image: CGImage) throws -> Data {
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw Failure.encodingFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encodingFailed }
        try Task.checkCancellation()
        guard data.length <= 32 * 1024 * 1024 else { throw Failure.tooLarge }
        return data as Data
    }
}


/// UI-independent continuation gate. A late callback cannot resolve a newer request.
@MainActor
final class ScreenshotResultGate<Value> {
    private var token: UUID?
    private var continuation: CheckedContinuation<Value, Error>?
    private var timeoutTask: Task<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait(token expected: UUID, timeoutNanoseconds: UInt64?, start: (@escaping @MainActor (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        guard continuation == nil else { throw ScreenshotCoordinator.Failure.busy }
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { waiter in
            token = expected; continuation = waiter
            if let duration = timeoutNanoseconds {
                timeoutTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: duration) }
                    catch { return }
                    self?.resolve(token: expected, result: .failure(ScreenshotCoordinator.Failure.timedOut))
                }
            }
            start { [weak self] result in self?.resolve(token: expected, result: result) }
        }
    }
    func cancel(token expected: UUID) { resolve(token: expected, result: .failure(ScreenshotCoordinator.Failure.cancelled)) }
    private func resolve(token expected: UUID, result: Result<Value, Error>) {
        guard token == expected, let waiter = continuation else { return }
        continuation = nil; token = nil
        timeoutTask?.cancel(); timeoutTask = nil
        waiter.resume(with: result)
    }
}

@MainActor
private final class RegionSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // AppKit must not relocate an upper/negative-origin screen overlay to another screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
private final class RegionSelectionView: NSView {
    var finished: ((CGRect) -> Void)?
    var cancelled: (() -> Void)?
    private var start: CGPoint?
    private var selected: CGRect?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("截图框选")
        setAccessibilityHelp("拖动选择截图区域，松开鼠标完成，按 Esc 取消。")
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil); selected = nil; needsDisplay = true }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        selected = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        guard let selected, selected.width >= 2, selected.height >= 2 else { start = nil; self.selected = nil; needsDisplay = true; return }
        finished?(selected)
    }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { cancelled?() } }
    override func cancelOperation(_ sender: Any?) { cancelled?() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 { cancelled?() }
        return true // Consume app menu shortcuts while selecting.
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.24).setFill(); bounds.fill()
        if let selected {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            selected.fill(); NSGraphicsContext.restoreGraphicsState()
            NSColor.white.setStroke(); let path = NSBezierPath(rect: selected); path.lineWidth = 1.5; path.stroke()
        }
        let message = "拖动选择截图区域"
        let hint = selected.map { "\(Int($0.width)) × \(Int($0.height)) 点 · 松开完成 · Esc 取消" } ?? "拖动框选，松开完成 · Esc 取消"
        let box = NSRect(x: max(12, (bounds.width - 360) / 2), y: max(12, bounds.height - 94), width: min(360, max(1, bounds.width - 24)), height: 68)
        NSColor(calibratedWhite: 0.08, alpha: 0.94).setFill()
        NSBezierPath(roundedRect: box, xRadius: 14, yRadius: 14).fill()
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: paragraph]
        let hintAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white.withAlphaComponent(0.8), .paragraphStyle: paragraph]
        (message as NSString).draw(in: NSRect(x: box.minX + 8, y: box.minY + 35, width: box.width - 16, height: 22), withAttributes: titleAttributes)
        (hint as NSString).draw(in: NSRect(x: box.minX + 8, y: box.minY + 13, width: box.width - 16, height: 18), withAttributes: hintAttributes)
    }
}
