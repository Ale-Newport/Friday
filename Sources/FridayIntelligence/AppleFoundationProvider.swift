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

    public static var unavailabilityReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(let reason): return "\(reason)"
            }
        }
        #endif
        return "FoundationModels needs macOS 26 or newer."
    }

    public func availableModels() async throws -> [LLMModel] {
        guard Self.isAvailable else { throw LLMProviderError.notConfigured(Self.unavailabilityReason ?? "Unavailable") }
        return [LLMModel(id: "apple-on-device", displayName: "Apple on-device model", tier: .fast)]
    }

    public func complete(_ request: LLMRequest) async throws -> LLMCompletion {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *), Self.isAvailable else {
            throw LLMProviderError.notConfigured(Self.unavailabilityReason ?? "Unavailable")
        }
        let session = LanguageModelSession(instructions: request.instructions)
        let prompt = Self.flatten(request)
        do {
            let response = try await session.respond(to: prompt)
            return LLMCompletion(text: response.content, finishReason: .stop, model: "apple-on-device")
        } catch {
            throw LLMProviderError.invalidResponse("The on-device model failed: \(error.localizedDescription)")
        }
        #else
        throw LLMProviderError.notConfigured("FoundationModels is not available in this build.")
        #endif
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                #if canImport(FoundationModels)
                guard #available(macOS 26, *), Self.isAvailable else {
                    continuation.finish(throwing: LLMProviderError.notConfigured(Self.unavailabilityReason ?? "Unavailable"))
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
                    continuation.finish(throwing: LLMProviderError.invalidResponse("The on-device model failed: \(error.localizedDescription)"))
                }
                #else
                continuation.finish(throwing: LLMProviderError.notConfigured("FoundationModels is not available in this build."))
                #endif
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
