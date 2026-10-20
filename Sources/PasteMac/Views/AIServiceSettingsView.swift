import AppKit
import SwiftUI

struct AIServiceSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var editingService: AIServiceConfig?
    @State private var isAdding = false
    @State private var testingID: UUID?
    @State private var testResult: [UUID: String] = [:]
    @State private var testSuccess: [UUID: Bool] = [:]
    @State private var testTask: Task<Void, Never>?
    @State private var testGeneration = UUID()
    @State private var operationError: String?

    var body: some View {
        Group {
            Section("场景建议") {
                Toggle("选中卡片时生成建议", isOn: $model.toolConfiguration.contextSuggestionsEnabled)
                Text("将所选文本、来源应用和粘贴目标发送至当前 AI 翻译服务；未指定时使用列表中首个已启用的文本服务。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("AI 服务") {
                if model.toolConfiguration.aiServices.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("暂未添加任何 AI 服务")
                            .font(.headline)
                        Text("添加服务后，可在「识别与翻译」中直接选用。支持 DeepSeek、OpenAI、Kimi、Ollama 等。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                } else {
                    ForEach(model.toolConfiguration.aiServices) { service in
                        serviceCard(item: service)
                    }
                }

                if let operationError {
                    Text(operationError).font(.caption).foregroundStyle(.red)
                }
                Button {
                    isAdding = true
                } label: {
                    Label("添加 AI 服务…", systemImage: "plus.circle.fill")
                }
            }
        }
        .sheet(isPresented: $isAdding) {
            AIServiceEditorSheet(
                service: AIServiceConfig(),
                isNew: true,
                onSave: { newService, keyChange in
                    if let keyChange { try CloudToolCredentials.saveAIServiceKey(keyChange, id: newService.id) }
                    model.toolConfiguration.aiServices.append(newService)
                }
            )
        }
        .sheet(item: $editingService) { target in
            AIServiceEditorSheet(
                service: target,
                isNew: false,
                onSave: { updated, keyChange in
                    guard let index = model.toolConfiguration.aiServices.firstIndex(where: { $0.id == updated.id }) else {
                        throw CloudToolsError.invalidConfiguration
                    }
                    let previous = model.toolConfiguration
                    if let keyChange { try CloudToolCredentials.saveAIServiceKey(keyChange, id: updated.id) }
                    var configuration = previous
                    configuration.aiServices[index] = updated
                    if configuration.ocrAIServiceID == updated.id,
                       !updated.isEnabled || updated.ocrModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        configuration.ocrAIServiceID = nil
                        configuration.ocrProvider = .system
                    }
                    if configuration.translationAIServiceID == updated.id,
                       !updated.isEnabled || updated.translationModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        configuration.translationAIServiceID = nil
                        configuration.translationProvider = .system
                    }
                    model.toolConfiguration = configuration
                    if keyChange != nil { model.invalidateContextSuggestionCache() }
                    let selectedForOCR = configuration.ocrAIServiceID == updated.id
                    let selectedForTranslation = configuration.translationAIServiceID == updated.id
                    if keyChange != nil, selectedForOCR || selectedForTranslation,
                       configuration.hasSameToolSettings(as: previous) {
                        model.refreshToolAfterConfigurationChange(recognizeImage: selectedForOCR)
                    }
                }
            )
        }
        .onChange(of: model.toolConfiguration.aiServices) { _, _ in
            testResult.removeAll(); testSuccess.removeAll()
        }
        .onDisappear { testGeneration = UUID(); testTask?.cancel(); testTask = nil; testingID = nil }
    }

    @ViewBuilder
    private func serviceCard(item: AIServiceConfig) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(item.name).font(.system(size: 14, weight: .bold))
                Text(item.vendor.title)
                    .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Toggle("启用服务", isOn: Binding(get: { item.isEnabled }, set: { setEnabled($0, service: item) }))
                    .labelsHidden().disabled(testingID != nil)
            }

            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Text("翻译:").font(.caption).foregroundStyle(.secondary)
                    Text(item.translationModel.isEmpty ? "未配置" : item.translationModel)
                        .font(.caption.monospaced())
                        .foregroundStyle(item.translationModel.isEmpty ? .secondary : .primary)
                }
                HStack(spacing: 4) {
                    Text("OCR:").font(.caption).foregroundStyle(.secondary)
                    Text(item.ocrModel.isEmpty ? "未配置" : item.ocrModel)
                        .font(.caption.monospaced())
                        .foregroundStyle(item.ocrModel.isEmpty ? .secondary : .primary)
                }
            }

            if let result = testResult[item.id] {
                HStack(spacing: 4) {
                    Image(systemName: (testSuccess[item.id] == true) ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle((testSuccess[item.id] == true) ? .green : .red)
                    Text(result).font(.caption).foregroundStyle((testSuccess[item.id] == true) ? .green : .red)
                }
            }

            HStack(spacing: 8) {
                if testingID == item.id {
                    ProgressView().controlSize(.small)
                } else {
                    Button("测试连接") {
                        testService(item)
                    }.controlSize(.small).disabled(testingID != nil)
                }
                Button("编辑") {
                    editingService = item
                }.controlSize(.small).disabled(testingID != nil)
                Button("删除", role: .destructive) {
                    deleteService(item)
                }.controlSize(.small).disabled(testingID != nil)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1))
    }

    private func testService(_ service: AIServiceConfig) {
        guard testingID == nil else { return }
        testingID = service.id
        testResult[service.id] = nil
        let generation = UUID(); testGeneration = generation
        testTask = Task { @MainActor in
            defer { if testGeneration == generation { testingID = nil; testTask = nil } }
            do {
                let key = try CloudToolCredentials.readAIServiceKeyChecked(service.id) ?? ""
                try await CloudToolsService().testAIService(config: service, key: key)
                try Task.checkCancellation()
                guard testGeneration == generation, model.toolConfiguration.aiServices.contains(service) else { return }
                testSuccess[service.id] = true
                testResult[service.id] = "连接正常"
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, testGeneration == generation, model.toolConfiguration.aiServices.contains(service) else { return }
                testSuccess[service.id] = false
                testResult[service.id] = error.localizedDescription
            }
        }
    }

    private func clearSelection(of id: UUID, in configuration: inout CloudToolConfiguration) {
        if configuration.translationAIServiceID == id {
            configuration.translationAIServiceID = nil
            configuration.translationProvider = .system
        }
        if configuration.ocrAIServiceID == id {
            configuration.ocrAIServiceID = nil
            configuration.ocrProvider = .system
        }
    }

    private func setEnabled(_ enabled: Bool, service: AIServiceConfig) {
        var configuration = model.toolConfiguration
        guard let index = configuration.aiServices.firstIndex(where: { $0.id == service.id }) else { return }
        configuration.aiServices[index].isEnabled = enabled
        if !enabled { clearSelection(of: service.id, in: &configuration) }
        model.toolConfiguration = configuration
    }

    private func deleteService(_ service: AIServiceConfig) {
        do {
            try CloudToolCredentials.deleteAIServiceKey(service.id)
            var configuration = model.toolConfiguration
            clearSelection(of: service.id, in: &configuration)
            configuration.aiServices.removeAll { $0.id == service.id }
            model.toolConfiguration = configuration
            operationError = nil
        } catch { operationError = error.localizedDescription }
    }
}

struct AIServiceEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var service: AIServiceConfig
    var isNew: Bool
    @State var apiKey: String = ""
    var onSave: (AIServiceConfig, String?) throws -> Void
    @State private var clearSavedKey = false
    @State private var testTask: Task<Void, Never>?
    @State private var testGeneration = UUID()

    @State private var isTesting = false
    @State private var testMessage: String?
    @State private var testPassed = false

    init(service: AIServiceConfig, isNew: Bool, onSave: @escaping (AIServiceConfig, String?) throws -> Void) {
        self._service = State(initialValue: service)
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "添加 AI 服务" : "编辑 AI 服务")
                    .font(.headline)
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)

            Divider()

            Form {
                Section("服务商与基础信息") {
                    Picker("服务厂商", selection: $service.vendor) {
                        ForEach(AIVendor.allCases) { vendor in
                            Text(vendor.title).tag(vendor)
                        }
                    }
                    .onChange(of: service.vendor) { _, newVendor in
                        service.name = newVendor.title
                        service.endpoint = newVendor.defaultEndpoint
                        service.translationModel = newVendor.defaultTranslationModel
                        service.ocrModel = newVendor.defaultOCRModel
                    }

                    TextField("服务名称", text: $service.name)

                    HStack(spacing: 6) {
                        SecureField(isNew ? "API Key" : "API Key（留空保留）", text: $apiKey).disabled(clearSavedKey)
                        Button("粘贴") {
                            if let pasteboard = NSPasteboard.general.string(forType: .string) {
                                apiKey = pasteboard.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }.controlSize(.small).disabled(clearSavedKey)
                        if let url = service.vendor.apiKeyHelpURL {
                            Link("获取 ↗", destination: url)
                                .font(.caption)
                                .padding(.leading, 2)
                        }
                    }

                    if !isNew {
                        Toggle("清除已保存的密钥", isOn: $clearSavedKey)
                            .onChange(of: clearSavedKey) { _, clear in if clear { apiKey = "" } }
                    }

                    if service.vendor == .custom || service.vendor == .ollama || service.vendor == .claude {
                        TextField("接口地址 (Endpoint)", text: $service.endpoint)
                    }
                }

                Section("场景模型配置") {
                    HStack {
                        TextField("文本翻译模型", text: $service.translationModel)
                        Text("例如 \(service.vendor.defaultTranslationModel)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        TextField("OCR 视觉模型", text: $service.ocrModel)
                        Text(service.vendor.defaultOCRModel.isEmpty ? "不支持图片可留空" : "例如 \(service.vendor.defaultOCRModel)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let message = testMessage {
                    Section {
                        HStack(spacing: 6) {
                            Image(systemName: testPassed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(testPassed ? .green : .red)
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(testPassed ? .green : .red)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .textFieldStyle(PasteboardTextFieldStyle())
            .disabled(isTesting)

            Divider()

            HStack {
                if isTesting {
                    ProgressView().controlSize(.small).padding(.trailing, 8)
                }
                Button("测试连接") {
                    testCurrent()
                }
                .disabled(isTesting)

                Spacer()

                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("保存") {
                    saveAndDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isTesting)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(minWidth: 460, minHeight: 400)
        .onDisappear { testGeneration = UUID(); testTask?.cancel(); testTask = nil }
        .onChange(of: service) { _, _ in testMessage = nil }
        .onChange(of: apiKey) { _, _ in testMessage = nil }
        .onChange(of: clearSavedKey) { _, _ in testMessage = nil }
    }

    static func validatedService(_ input: AIServiceConfig) throws -> AIServiceConfig {
        var value = input
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.endpoint = value.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        value.translationModel = value.translationModel.trimmingCharacters(in: .whitespacesAndNewlines)
        value.ocrModel = value.ocrModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty, value.name.count <= 120,
              !value.translationModel.isEmpty || !value.ocrModel.isEmpty,
              value.translationModel.isEmpty || CloudToolsService.validModel(value.translationModel),
              value.ocrModel.isEmpty || CloudToolsService.validModel(value.ocrModel) else {
            throw AIServiceEditorError.invalidFields
        }
        _ = try CloudToolsService.baseRequest(value.endpoint)
        return value
    }

    private func testCurrent() {
        guard !isTesting else { return }
        do {
            let snapshot = try Self.validatedService(service)
            let enteredKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let key: String
            if !enteredKey.isEmpty { key = enteredKey }
            else if clearSavedKey || isNew { key = "" }
            else { key = try CloudToolCredentials.readAIServiceKeyChecked(snapshot.id) ?? "" }
            isTesting = true; testMessage = nil
            let generation = UUID(); testGeneration = generation
            testTask = Task { @MainActor in
                defer { if testGeneration == generation { isTesting = false; testTask = nil } }
                do {
                    try await CloudToolsService().testAIService(config: snapshot, key: key)
                    try Task.checkCancellation()
                    guard testGeneration == generation else { return }
                    testPassed = true; testMessage = "连接正常"
                } catch is CancellationError { }
                catch {
                    guard !Task.isCancelled, testGeneration == generation else { return }
                    testPassed = false; testMessage = error.localizedDescription
                }
            }
        } catch { testPassed = false; testMessage = error.localizedDescription }
    }

    private func saveAndDismiss() {
        do {
            let value = try Self.validatedService(service)
            let cleaned = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let keyChange: String? = clearSavedKey ? "" : (cleaned.isEmpty ? nil : cleaned)
            try onSave(value, keyChange)
            dismiss()
        } catch { testPassed = false; testMessage = error.localizedDescription }
    }
}

private enum AIServiceEditorError: LocalizedError {
    case invalidFields
    var errorDescription: String? { "请输入服务名称和至少一个有效模型名称。" }
}
