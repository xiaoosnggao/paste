import AppKit
import SwiftUI

/// Supplies the actual app bundle to the system's file drop destination.
@MainActor
final class ApplicationDragIcon: NSImageView, NSDraggingSource {
    let applicationURL: URL

    init(applicationURL: URL, destination: String = "辅助功能") {
        self.applicationURL = applicationURL
        super.init(frame: NSRect(x: 0, y: 0, width: 88, height: 88))
        let iconURL = Bundle(url: applicationURL)?.url(forResource: "Pasteboard", withExtension: "icns")
        image = iconURL.flatMap { NSImage(contentsOf: $0) } ?? NSWorkspace.shared.icon(forFile: applicationURL.path)
        imageScaling = .scaleProportionallyUpOrDown
        toolTip = "拖到系统设置的\(destination)应用列表"
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Pasteboard 应用图标，可拖入权限列表")
        setAccessibilityHelp(toolTip)
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: 88, height: 88) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {
        guard let image else { return }
        let item = NSDraggingItem(pasteboardWriter: applicationURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

private struct DraggableApplicationIcon: NSViewRepresentable {
    let applicationURL: URL
    let destination: String
    func makeNSView(context: Context) -> ApplicationDragIcon { ApplicationDragIcon(applicationURL: applicationURL, destination: destination) }
    func updateNSView(_ nsView: ApplicationDragIcon, context: Context) { nsView.toolTip = "拖到系统设置的\(destination)应用列表" }
}

private struct AccessibilityGuideView: View {
    @ObservedObject var state: PermissionGuideState
    let applicationURL: URL
    let openSettings: () -> Void
    let dismiss: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Text(state.kind.title).font(.system(size: 18, weight: .semibold))
            DraggableApplicationIcon(applicationURL: applicationURL, destination: state.kind.destination)
                .frame(width: 88, height: 88)
            Text("将图标拖入\(state.kind.destination)列表")
                .font(.system(size: 13, weight: .medium)).multilineTextAlignment(.center)
            Text(state.kind.instructions)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Label(state.granted ? "权限已开启" : "请在系统设置中开启权限",
                  systemImage: state.granted ? "checkmark.circle.fill" : "hand.point.up.left")
                .font(.system(size: 12)).foregroundStyle(state.granted ? Color.green : Color.secondary)
            Button(state.kind.settingsTitle, action: openSettings)
            if state.kind == .screenCapture {
                Text("如系统要求重新打开应用，请重新打开后重试截图。")
                    .font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack {
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([applicationURL]) }
                Spacer()
                Button("稍后", action: dismiss)
                Button(state.granted ? state.kind.continueTitle : "检查权限") {
                    if state.granted { state.proceed() } else { state.refresh() }
                }.keyboardShortcut(.defaultAction)
            }.controlSize(.small)
        }
        .padding(.horizontal, 24).padding(.top, 40).padding(.bottom, 22)
        .frame(width: 340)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor
final class AccessibilityGuide: NSObject, NSWindowDelegate {
    private let state: PermissionGuideState
    private var panel: NSPanel?
    private var permissionTimer: Timer?
    init(model: AppModel) {
        state = PermissionGuideState { [weak model] kind in
            if kind == .screenCapture { return ScreenshotCoordinator.isPermissionGranted }
            guard let model else { return false }
            model.pasteEngine.enableAccessibilityChecks()
            model.refreshDirectPastePermission()
            return model.directPastePermissionGranted
        }
    }
    func show(kind: PermissionGuideKind = .directPaste, onAuthorized: (() -> Void)? = nil) {
        state.present(kind) { [weak self] in self?.panel?.close(); onAuthorized?() }
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 410),
                                styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
            panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
            panel.isReleasedWhenClosed = false; panel.isMovableByWindowBackground = true
            panel.hidesOnDeactivate = false; panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .ignoresCycle]
            panel.delegate = self
            panel.contentView = NSHostingView(rootView: AccessibilityGuideView(state: state, applicationURL: Bundle.main.bundleURL,
                openSettings: { [weak self] in
                    guard let self else { return }
                    if self.state.kind == .screenCapture { ScreenshotCoordinator.openPermissionSettings() }
                    else { PasteEngine.openAccessibilitySettings() }
                }, dismiss: { [weak self] in self?.panel?.close() }))
            self.panel = panel
        }
        guard let panel else { return }
        panel.title = "Pasteboard · \(kind.destination)授权"
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(NSPoint(x: max(frame.minX, frame.midX - panel.frame.width / 2), y: max(frame.minY, frame.midY - panel.frame.height / 2)))
        panel.orderFrontRegardless()
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.state.refresh() }
        }
    }
    func dismiss() {
        permissionTimer?.invalidate(); permissionTimer = nil
        state.dismiss(); panel?.orderOut(nil)
    }
    func windowWillClose(_ notification: Notification) {
        permissionTimer?.invalidate(); permissionTimer = nil
        state.dismiss()
    }
}
