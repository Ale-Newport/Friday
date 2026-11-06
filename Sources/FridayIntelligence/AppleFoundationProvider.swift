import Foundation
import FridayCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device foundation model (macOS 26+, Apple Intelligence). Free, private and always available
/// offline, but small: Friday uses it as the last resort for interpretation and for short replies, through the
/// JSON text protocol (no native tool calling here, by design: the planner validates the JSON like any other
/// model output).
public struct AppleFoundationProvider: LLMProvider {
    public let id = "apple"
    public let displayName = "Apple on-device model"
    public let isRemote = false
    public let mayIncurCharges = false
    public let capabilities: Set<LLMCapability> = [.streaming]

    public init() {}

    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Why the model cannot be used on this Mac right now, in both languages; `nil` when it is available.
    public static var unavailability: LocalizedText? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return LocalizedText(en: "This Mac does not support Apple Intelligence.", es: "Este Mac no es compatible con Apple Intelligence.")
                case .appleIntelligenceNotEnabled:
                    return LocalizedText(
                        en: "Apple Intelligence is turned off in System Settings.", es: "Apple Intelligence está desactivado en Ajustes del Sistema.")
                case .modelNotReady:
                    return LocalizedText(
                        en: "The on-device model is still downloading or preparing.",
                        es: "El modelo del dispositivo todavía se está descargando o preparando.")
                @unknown default:
                    return LocalizedText(
                        en: "The on-device model is unavailable (\(reason)).", es: "El modelo del dispositivo no está disponible (\(reason)).")
                }
            }
        }
        #endif
        return LocalizedText(en: "FoundationModels needs macOS 26 or newer.", es: "FoundationModels necesita macOS 26 o posterior.")
    }

    public static var unavailabilityReason: String? { unavailability?.en }

    static var notAvailableError: LLMProviderError {
        .notConfigured(unavailability ?? LocalizedText(en: "Unavailable", es: "No disponible"))
    }

    public func availableModels() async throws -> [LLMModel] {
        guard Self.isAvailable else { throw Self.notAvailableError }
        return [LLMModel(id: "apple-on-device", displayName: "Apple on-device model", tier: .fast)]
    }

    public func complete(_ request: LLMRequest) async throws -> LLMCompletion {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *), Self.isAvailable else { throw Self.notAvailableError }
        let session = LanguageModelSession(instructions: request.instructions)
        let prompt = Self.flatten(request)
        do {
            let response = try await session.respond(to: prompt)
            return LLMCompletion(text: response.content, finishReason: .stop, model: "apple-on-device")
        } catch {
            throw Self.mapped(error)
        }
        #else
        throw LLMProviderError.notConfigured(
            LocalizedText(en: "FoundationModels is not available in this build.", es: "FoundationModels no está disponible en esta compilación."))
        #endif
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                #if canImport(FoundationModels)
                guard #available(macOS 26, *), Self.isAvailable else {
                    continuation.finish(throwing: Self.notAvailableError)
                    return
                }
                let session = LanguageModelSession(instructions: request.instructions)
                let prompt = Self.flatten(request)
                do {
                    var previous = ""
                    for try await partial in session.streamResponse(to: prompt) {
                        let text = partial.content
                        if text.hasPrefix(previous) {
                            let delta = String(text.dropFirst(previous.count))
                            if !delta.isEmpty { continuation.yield(.textDelta(delta)) }
                        } else {
                            continuation.yield(.textDelta(text))
                        }
                        previous = text
                    }
                    continuation.yield(.completed(LLMCompletion(text: previous, finishReason: .stop, model: "apple-on-device")))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapped(error))
                }
                #else
                continuation.finish(
                    throwing: LLMProviderError.notConfigured(
                        LocalizedText(en: "FoundationModels is not available in this build.", es: "FoundationModels no está disponible en esta compilación.")))
                #endif
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Errors

    #if canImport(FoundationModels)
    /// Turns the framework's generation errors into something the planner can act on: a guardrail refusal or an
    /// overlong request becomes a user-facing reply, a busy model is retryable elsewhere, missing assets mean
    /// "not configured", and only real failures are reported as such.
    @available(macOS 26, *)
    static func mapped(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        guard let generation = error as? LanguageModelSession.GenerationError else { return failure(error.localizedDescription) }
        switch generation {
        case .guardrailViolation, .refusal:
            return LLMProviderError.unsupportedCapability(
                LocalizedText(
                    en: "I can't help with that using the on-device model.", es: "No puedo ayudarte con eso usando el modelo del dispositivo."))
        case .exceededContextWindowSize:
            return LLMProviderError.unsupportedCapability(
                LocalizedText(
                    en: "That is too long for the on-device model. Try a shorter request.",
                    es: "Eso es demasiado largo para el modelo del dispositivo. Prueba con una petición más corta."))
        case .rateLimited, .concurrentRequests:
            return LLMProviderError.temporarilyUnavailable(
                LocalizedText(
                    en: "The on-device model is busy. Try again in a moment.", es: "El modelo del dispositivo está ocupado. Inténtalo de nuevo en un momento."))
        case .assetsUnavailable:
            return LLMProviderError.notConfigured(
                LocalizedText(en: "The on-device model is not ready on this Mac.", es: "El modelo del dispositivo no está listo en este Mac."))
        case .unsupportedLanguageOrLocale:
            return LLMProviderError.unsupportedCapability(
                LocalizedText(
                    en: "The on-device model does not support this language.", es: "El modelo del dispositivo no admite este idioma."))
        case .unsupportedGuide, .decodingFailure:
            return failure(generation.localizedDescription)
        @unknown default:
            return failure(generation.localizedDescription)
        }
    }
    #endif

    static func failure(_ detail: String) -> LLMProviderError {
        .invalidResponse(LocalizedText(en: "The on-device model failed: \(detail)", es: "El modelo del dispositivo falló: \(detail)"))
    }

    /// The model takes one prompt; the conversation and tool results are rendered as labelled text.
    static func flatten(_ request: LLMRequest) -> String {
        var lines: [String] = []
        for message in request.messages {
            switch message.role {
            case .system, .developer: lines.append("[Instructions] " + message.text)
            case .user: lines.append("[User] " + message.text)
            case .assistant:
                if !message.text.isEmpty { lines.append("[Assistant] " + message.text) }
                for call in message.toolCalls { lines.append("[Assistant called \(call.name)] " + call.argumentsJSON) }
            case .tool: lines.append("[Tool result \(message.toolCallID ?? "")] " + String(message.text.prefix(4000)))
            }
        }
        if !request.tools.isEmpty {
            let catalog = request.tools.map { "- \($0.name): \($0.description)\n  parameters: \($0.parameters.canonicalString())" }
            lines.append(
                "[Available tools]\n" + catalog.joined(separator: "\n")
                    + "\nAnswer with ONE JSON object only: {\"calls\":[{\"tool\":\"name\",\"arguments\":{…}}],\"reply\":\"…\"} — calls empty when no tool is needed.")
        }
        return lines.joined(separator: "\n\n")
    }
}
