import Foundation
import SwiftUI
import NaturalLanguage
import Translation

@available(macOS 15.0, *)
@MainActor
final class SystemTranslationCoordinator: ObservableObject {
    static let shared = SystemTranslationCoordinator()
    @Published var configuration: TranslationSession.Configuration?
    private var pending: Request?
    @Published private(set) var sessionID = UUID()
    private var timeout: Task<Void, Never>?
    private struct Request {
        let id: UUID
        let text: String
        let continuation: CheckedContinuation<CloudTranslationResponse, Error>
    }
    enum Failure: LocalizedError {
        case unavailable, unsupported, failed
        var errorDescription: String? {
            switch self {
            case .unavailable: return "系统翻译需要 macOS 15 或更新版本。请升级系统，或在设置中选择其他翻译服务。"
            case .unsupported: return "系统翻译不支持所选语言，请更改语言或翻译服务。"
            case .failed: return "系统翻译失败，请检查网络和语言包。首次使用时，请按系统提示下载语言包。"
            }
        }
    }
    func translate(text: String, configuration settings: CloudToolConfiguration) async throws -> CloudTranslationResponse {
        try Task.checkCancellation()
        let sourceID = settings.sourceLanguage == "auto" ? NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue : settings.sourceLanguage
        let source = sourceID.map { Locale.Language(identifier: $0) }
        let target = Locale.Language(identifier: settings.targetLanguage)
        func normalized(_ language: String) -> String {
            let value = language.lowercased().replacingOccurrences(of: "_", with: "-")
            return ["zh": "zh-hans", "zh-cn": "zh-hans", "zh-tw": "zh-hant", "en-us": "en", "en-gb": "en"][value] ?? value
        }
        if let sourceID, normalized(sourceID) == normalized(settings.targetLanguage) {
            return .init(text: text, model: "Apple Translation", provider: TranslationProvider.system.title)
        }
        if let source, try await Self.languageStatus(source: source, target: target) == .unsupported { throw Failure.unsupported }
        try Task.checkCancellation()
        cancel()
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pending = Request(id: id, text: text, continuation: continuation)
                self.sessionID = id
                self.configuration = Self.sessionConfiguration(source: source, target: target)
                timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: 180_000_000_000) } catch { return }
                    self?.finish(id, result: .failure(CloudToolsError.timedOut))
                }
                if Task.isCancelled { finish(id, result: .failure(CancellationError())) }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancel(id) } })
    }
    static func languageStatus(source: Locale.Language, target: Locale.Language) async throws -> LanguageAvailability.Status {
        let gate = TranslationStatusGate()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                gate.continuation = continuation
                let operation = Task { @MainActor in
                    let value = await availability().status(from: source, to: target)
                    gate.finish(.success(value))
                }
                let deadline = Task { @MainActor in
                    do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
                    gate.finish(.failure(CloudToolsError.timedOut))
                }
                gate.tasks = [operation, deadline]
                if Task.isCancelled { gate.finish(.failure(CancellationError())) }
            }
        }, onCancel: { Task { @MainActor in gate.finish(.failure(CancellationError())) } })
    }
    @available(macOS 15.0, *)
    static func availability() -> LanguageAvailability {
        if #available(macOS 26.4, *) { return LanguageAvailability(preferredStrategy: .lowLatency) }
        return LanguageAvailability()
    }
    @available(macOS 15.0, *)
    private static func sessionConfiguration(source: Locale.Language?, target: Locale.Language) -> TranslationSession.Configuration {
        if #available(macOS 26.4, *) { return .init(source: source, target: target, preferredStrategy: .lowLatency) }
        return .init(source: source, target: target)
    }
    @available(macOS 15.0, *)
    func process(_ session: TranslationSession, id: UUID) async {
        guard let request = pending, request.id == id else { return }
        do {
            try Task.checkCancellation()
            let response = try await session.translate(request.text)
            try Task.checkCancellation()
            guard !response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudToolsError.emptyResult }
            finish(request.id, result: .success(.init(text: response.targetText, model: "Apple Translation", provider: TranslationProvider.system.title)))
        } catch is CancellationError { finish(request.id, result: .failure(CancellationError())) }
        catch { finish(request.id, result: .failure(Failure.failed)) }
    }
    func cancel(_ id: UUID? = nil) {
        guard let request = pending, id == nil || id == request.id else { return }
        finish(request.id, result: .failure(CancellationError()))
    }
    private func finish(_ id: UUID, result: Result<CloudTranslationResponse, Error>) {
        guard let request = pending, request.id == id else { return }
        pending = nil; timeout?.cancel(); timeout = nil
        configuration = nil
        request.continuation.resume(with: result)
    }
}

@available(macOS 15.0, *)
struct SystemTranslationHost: View {
    @ObservedObject private var service = SystemTranslationCoordinator.shared
    var body: some View {
        let id = service.sessionID
        Color.clear.frame(width: 1, height: 1)
            .translationTask(service.configuration) { session in await service.process(session, id: id) }
            .id(id)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

@available(macOS 15.0, *)
@MainActor
private final class TranslationStatusGate {
    var continuation: CheckedContinuation<LanguageAvailability.Status, Error>?
    var tasks: [Task<Void, Never>] = []
    func finish(_ value: Result<LanguageAvailability.Status, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        tasks.forEach { $0.cancel() }; tasks = []
        continuation.resume(with: value)
    }
}
