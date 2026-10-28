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
    @State private var confirmRepair = false
    private var permissionTitle: String { state.kind == .screenCapture ? "屏幕录制" : "辅助功能" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("权限设置").font(.scaled(.display, weight: .semibold))
                    Spacer()
                    Text("Pasteboard").font(.scaled(.label, weight: .medium)).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    step("辅助功能", number: 1)
                    stepConnector(completed: state.stepNumber > 1)
                    step("屏幕录制", number: 2)
                    stepConnector(completed: state.stepNumber > 2)
                    step("完成", number: 3)
                }
            }
            .padding(.bottom, 16)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if state.isReview {
                        VStack(spacing: 14) {
                            Image(systemName: state.granted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                                .font(.scaled(.hero, weight: .light))
                                .foregroundStyle(state.granted ? Color.green : Color.orange)
                            Text(state.granted ? "一切就绪" : "请重新检查权限")
                                .font(.scaled(.heading, weight: .semibold))
                            Text(state.granted ? "现在可以直接粘贴、截图和选中文字翻译。" : "部分权限已变更，点击完成后重新设置。")
                                .font(.scaled(.label)).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 34)
                        .frame(minHeight: 220)
                    } else {
                        permissionCard
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: state.granted ? "checkmark.circle.fill" : "circle.dashed")
                                    .foregroundStyle(state.granted ? Color.green : Color.secondary)
                                Text(state.granted ? "已授权" : "尚未生效")
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                if !state.granted {
                                    Button(state.repairing ? "正在修复…" : "已开启但不可用？") { confirmRepair = true }
                                        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                                        .disabled(state.repairing)
                                        .help("仅重置 Pasteboard 的\(permissionTitle)授权，随后需要重新开启。")
                                }
                            }
                            Text(statusHint)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .lineLimit(2)
                        }
                        .font(.scaled(.caption))
                        .padding(.top, 12)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
                    }
                }.frame(maxWidth: .infinity, alignment: .topLeading)
            }.scrollIndicators(.hidden)

            Divider().padding(.bottom, 12)
            HStack {
                Button("稍后", action: dismiss).buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button(state.isReview ? "完成" : (state.granted ? "下一步" : "检查权限")) {
                    if state.isReview || state.granted { state.proceed() } else { state.refresh() }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                .controlSize(.large).disabled(state.repairing)
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 20).padding(.top, 40)
        .frame(width: 480, height: 440)
        .alert("修复旧授权？", isPresented: $confirmRepair) {
            Button("取消", role: .cancel) {}
            Button("修复旧授权", role: .destructive) {
                state.repair(using: { try await PermissionRepair.reset($0) }, onRepaired: openSettings)
            }
        } message: {
            Text("仅重置 Pasteboard 的\(permissionTitle)授权，随后需要重新开启。")
        }
    }

    private var statusHint: String {
        if let message = state.repairMessage { return message }
        if state.granted { return "" }
        if state.kind == .screenCapture { return "首次开启后，请退出并重新打开 Pasteboard。" }
        return "开启后返回此窗口检查权限。"
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                DraggableApplicationIcon(applicationURL: applicationURL, destination: state.kind.destination)
                    .frame(width: 64, height: 64).id(state.kind.destination)
                VStack(alignment: .leading, spacing: 6) {
                    Text(permissionTitle).font(.scaled(.heading, weight: .semibold))
                    Text(state.kind == .screenCapture ? "截图识别 · 截图翻译" : "直接粘贴 · 选中文字翻译")
                        .font(.scaled(.label)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if !state.granted {
                    Label("在系统设置中添加并开启 Pasteboard。", systemImage: "hand.draw")
                        .font(.scaled(.label)).foregroundStyle(.secondary)
                }
                Button {
                    if state.kind == .screenCapture { ScreenshotCoordinator.openPermissionSettings(requestAccess: true) }
                    else { openSettings() }
                } label: {
                    HStack {
                        Text(state.kind.settingsTitle)
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.scaled(.micro, weight: .semibold))
                    }
                    .font(.scaled(.label, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
                    .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .accessibilityLabel(state.kind.settingsTitle)
            }
        }
        .padding(16)
        .background(.background.opacity(0.52), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg).strokeBorder(.primary.opacity(0.07), lineWidth: 0.5))
    }

    private func step(_ title: String, number: Int) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().fill(number <= state.stepNumber ? Color.accentColor : Color.secondary.opacity(0.12))
                if number < state.stepNumber {
                    Image(systemName: "checkmark").font(.scaled(.micro, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.scaled(.micro, weight: .semibold))
                        .foregroundStyle(number == state.stepNumber ? Color.white : Color.secondary)
                }
            }.frame(width: 20, height: 20)
            Text(title).font(.scaled(.caption, weight: number == state.stepNumber ? .semibold : .regular))
                .foregroundStyle(number == state.stepNumber ? Color.primary : Color.secondary)
                .fixedSize()
        }
    }

    private func stepConnector(completed: Bool) -> some View {
        Capsule().fill(completed ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.15))
            .frame(height: 1).frame(maxWidth: .infinity)
    }

}

@MainActor
final class AccessibilityGuide: NSObject, NSWindowDelegate {
    private let state: PermissionGuideState
    private var panel: NSPanel?
    private var permissionTimer: Timer?
    init(model: AppModel) {
        state = PermissionGuideState { [weak model] kind in
            guard let model, !model.isDemo else { return false }
            if kind == .screenCapture { return ScreenshotCoordinator.isPermissionGranted }
            model.pasteEngine.enableAccessibilityChecks()
            model.refreshDirectPastePermission()
            return model.directPastePermissionGranted
        }
    }
    func show(kind: PermissionGuideKind = .directPaste, onAuthorized: (() -> Void)? = nil) {
        state.present(kind) { [weak self] in self?.panel?.close(); onAuthorized?() }
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
                                styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
            panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
            panel.isReleasedWhenClosed = false; panel.isMovableByWindowBackground = true
            panel.isOpaque = false; panel.backgroundColor = .clear
            panel.hidesOnDeactivate = false; panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .ignoresCycle]
            panel.delegate = self
            panel.contentView = PanelGlassContainer.make(content: AccessibilityGuideView(state: state, applicationURL: Bundle.main.bundleURL,
                openSettings: { [weak self] in
                    guard let self else { return }
                    if self.state.kind == .screenCapture { ScreenshotCoordinator.openPermissionSettings() }
                    else { PasteEngine.openAccessibilitySettings() }
                }, dismiss: { [weak self] in self?.panel?.close() }),
                frame: NSRect(x: 0, y: 0, width: 480, height: 440), cornerRadius: DesignTokens.Radius.window)
            self.panel = panel
        }
        guard let panel else { return }
        panel.title = "Pasteboard · 权限设置"
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(NSPoint(x: max(frame.minX, frame.midX - panel.frame.width / 2), y: max(frame.minY, frame.midY - panel.frame.height / 2)))
        panel.makeKeyAndOrderFront(nil)
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
