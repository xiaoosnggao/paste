import SwiftUI

struct CloudToolSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var credentials: [String: String] = [:]
    @State private var loadedCredentials: Set<String> = []
    @State private var ocrMessage: String?
    @State private var translationMessage: String?

    var body: some View {
        Group {
            Section("文字识别") {
                Picker("服务", selection: $model.toolConfiguration.ocrProvider) {
                    ForEach(OCRProvider.allCases) { Text($0.title).tag($0) }
                }
                ocrOptions
                credentialFields(model.toolConfiguration.ocrProvider.credentialKinds, scope: .ocr)
                Text(model.toolConfiguration.ocrProvider == .system
                     ? "使用 macOS 文字识别，无需密钥，图片在本机处理。"
                     : "识别时将图片发送至所选服务，费用由服务商收取。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("文本翻译") {
                Picker("服务", selection: $model.toolConfiguration.translationProvider) {
                    ForEach(TranslationProvider.allCases) { Text($0.title).tag($0) }
                }
                translationOptions
                Picker("默认目标语言", selection: $model.toolConfiguration.targetLanguage) {
                    Text("简体中文").tag("zh"); Text("英语").tag("en"); Text("日语").tag("ja")
                    Text("韩语").tag("ko"); Text("繁体中文").tag("zh-Hant"); Text("法语").tag("fr")
                }
                credentialFields(model.toolConfiguration.translationProvider.credentialKinds, scope: .translation)
                Text(model.toolConfiguration.translationProvider == .system
                     ? "使用 macOS 翻译，首次使用可能需要下载语言资源。"
                     : "翻译时将原文发送至所选服务，费用由服务商收取。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("结果与隐私") {
                Text("原图、识别文字、原文和译文分别保存为卡片。密钥保存在 Pasteboard 的钥匙串中，不包含在历史记录、备份或日志中。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("截图与快捷操作") {
                Text("截图需要屏幕录制权限，选中文字翻译需要辅助功能权限。首次使用时将显示授权指引。各项快捷键可在“快捷键”中设置。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("屏幕录制权限…") { ScreenshotCoordinator.openPermissionSettings() }
                Button("输入翻译") { model.performTool(.inputTranslate) }
            }
        }
        .onAppear(perform: loadSelectedCredentials)
        .onChange(of: model.toolConfiguration.ocrProvider) { _, _ in
            ocrMessage = nil; loadSelectedCredentials()
        }
        .onChange(of: model.toolConfiguration.translationProvider) { _, _ in
            translationMessage = nil; loadSelectedCredentials()
        }
    }

    @ViewBuilder private var ocrOptions: some View {
        switch model.toolConfiguration.ocrProvider {
        case .system:
            EmptyView()
        case .volcengine:
            Picker("识别模式", selection: $model.toolConfiguration.ocrMode) {
                Text("通用文字识别").tag("normal"); Text("多语种文字识别").tag("multilingual")
            }
            help("需在火山引擎视觉智能中开通对应服务。")
        case .tencent:
            TextField("地域", text: $model.toolConfiguration.tencentRegion)
            Picker("识别接口", selection: $model.toolConfiguration.tencentAction) {
                Text("通用印刷体 · 高精度").tag("GeneralAccurateOCR")
                Text("通用印刷体 · 通用").tag("GeneralBasicOCR")
            }
        case .baidu:
            Picker("识别接口", selection: $model.toolConfiguration.baiduOCRMode) {
                Text("通用文字识别 · 标准版").tag("general_basic")
                Text("通用文字识别 · 高精度版").tag("accurate_basic")
            }
            help("填写百度智能云 OCR 应用的 API Key 与 Secret Key。")
        case .google:
            help("需要在 Google Cloud 项目中启用 Cloud Vision API。")
        case .openAICompatible:
            TextField("完整接口地址", text: $model.toolConfiguration.openAIOCREndpoint)
            TextField("视觉模型", text: $model.toolConfiguration.openAIOCRModel)
            help("填写兼容 Chat Completions 的完整 HTTPS 接口地址，模型需支持图片输入。文字识别与翻译的配置分别保存。")
        }
    }

    @ViewBuilder private var translationOptions: some View {
        switch model.toolConfiguration.translationProvider {
        case .system:
            help("需要 macOS 15 或更高版本。系统将在首次使用时引导下载所需语言。")
        case .zhipu:
            TextField("模型", text: $model.toolConfiguration.zhipuModel)
            help("例如 glm-4-flash-250414；可用模型与额度以智谱账户为准。")
        case .openAICompatible:
            TextField("完整接口地址", text: $model.toolConfiguration.openAITranslationEndpoint)
            TextField("模型", text: $model.toolConfiguration.openAITranslationModel)
            help("填写兼容 Chat Completions 的完整 HTTPS 地址，例如以 /v1/chat/completions 结尾的接口。")
        case .youdao:
            help("使用有道智云文本翻译应用的应用 ID 与应用密钥。")
        case .google:
            help("需要在 Google Cloud 项目中启用 Cloud Translation API。")
        case .microsoft:
            TextField("资源区域", text: $model.toolConfiguration.microsoftRegion)
            help("区域需与 Azure Translator 资源一致。全局资源按服务要求填写或留空。")
        }
    }

    private enum CredentialScope { case ocr, translation }

    @ViewBuilder private func credentialFields(_ kinds: [CloudCredentialKind], scope: CredentialScope) -> some View {
        if !kinds.isEmpty {
            ForEach(kinds, id: \.rawValue) { kind in
                SecureField(kind.title, text: Binding(
                    get: { credentials[kind.rawValue] ?? "" },
                    set: { credentials[kind.rawValue] = $0 }
                ))
            }
            HStack {
                Button("保存凭证") { save(kinds, scope: scope) }
                Button("删除凭证", role: .destructive) { remove(kinds, scope: scope) }
            }
            if let message = scope == .ocr ? ocrMessage : translationMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func help(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func loadSelectedCredentials() {
        let kinds = model.toolConfiguration.ocrProvider.credentialKinds + model.toolConfiguration.translationProvider.credentialKinds
        for kind in kinds where !loadedCredentials.contains(kind.rawValue) {
            credentials[kind.rawValue] = CloudToolCredentials.read(kind) ?? ""
            loadedCredentials.insert(kind.rawValue)
        }
    }

    private func setMessage(_ text: String, scope: CredentialScope) {
        if scope == .ocr { ocrMessage = text } else { translationMessage = text }
    }

    private func save(_ kinds: [CloudCredentialKind], scope: CredentialScope) {
        do {
            guard kinds.allSatisfy({ !(credentials[$0.rawValue] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                setMessage("请填写全部凭证。", scope: scope); return
            }
            var saved = false
            for kind in kinds {
                let value = (credentials[kind.rawValue] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                try CloudToolCredentials.save(value, kind: kind); saved = true
            }
            setMessage(saved ? "凭证已保存。" : "请填写凭证。", scope: scope)
        } catch { setMessage("部分凭证未能保存：\(error.localizedDescription)", scope: scope) }
    }

    private func remove(_ kinds: [CloudCredentialKind], scope: CredentialScope) {
        do {
            for kind in kinds {
                try CloudToolCredentials.delete(kind)
                credentials[kind.rawValue] = ""
            }
            setMessage("凭证已删除。", scope: scope)
        } catch { setMessage("部分凭证未能删除：\(error.localizedDescription)", scope: scope) }
    }
}
