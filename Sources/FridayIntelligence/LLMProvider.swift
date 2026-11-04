import Foundation
import FridayCore

// MARK: - Provider-independent chat and tool-calling types
//
// Every language-model provider Friday can use (ChatGPT plan via Sign in with ChatGPT, an OpenAI API key, an
// OpenAI-compatible local server such as Ollama or LM Studio, Apple's on-device Foundation model) is driven
// through these types, so the planner never knows which one is answering and providers can be swapped or
// added without touching the planner.

/// One message in a model conversation.
public struct LLMMessage: Sendable, Hashable {
    public enum Role: String, Sendable, Hashable { case system, developer, user, assistant, tool }

    public var role: Role
    public var text: String
    /// For `.assistant`: the tool calls the model issued in this turn (replayed verbatim to the model).
    public var toolCalls: [LLMToolCall]
    /// For `.tool`: which call this message answers.
    public var toolCallID: String?

    public init(role: Role, text: String, toolCalls: [LLMToolCall] = [], toolCallID: String? = nil) {
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    public static func user(_ text: String) -> LLMMessage { LLMMessage(role: .user, text: text) }
    public static func assistant(_ text: String, toolCalls: [LLMToolCall] = []) -> LLMMessage {
        LLMMessage(role: .assistant, text: text, toolCalls: toolCalls)
    }
    public static func toolResult(callID: String, _ text: String) -> LLMMessage {
        LLMMessage(role: .tool, text: text, toolCallID: callID)
    }
}

/// A function the model may call. `parameters` is a JSON Schema object.
public struct LLMToolDefinition: Sendable, Hashable {
    public var name: String
    public var description: String
    public var parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// A call the model asked for. Arguments are kept as the model's JSON text and parsed by the caller: the model is
/// untrusted, and whatever it produced is validated against the tool schemas like any other request.
public struct LLMToolCall: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }

    public var arguments: JSONObject? {
        guard let data = argumentsJSON.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue
    }
}

public enum LLMToolChoice: Sendable, Hashable {
    case auto, none, required
    case tool(String)
}

/// Everything one model call needs. `instructions` is the system prompt (providers map it to whatever their API
/// calls it); `messages` is the conversation so far, including earlier tool calls and their results.
public struct LLMRequest: Sendable {
    public var model: String
    public var instructions: String
    public var messages: [LLMMessage]
    public var tools: [LLMToolDefinition]
    public var toolChoice: LLMToolChoice
    public var parallelToolCalls: Bool
    /// When set, the provider asks for a JSON object (schema-constrained when it can, plain JSON mode otherwise).
    public var jsonSchema: JSONValue?
    public var maxOutputTokens: Int?
    public var temperature: Double?
    /// Hint for providers that expose effort levels (reasoning models); ignored elsewhere.
    public var reasoningEffort: String?

    public init(
        model: String, instructions: String, messages: [LLMMessage], tools: [LLMToolDefinition] = [],
        toolChoice: LLMToolChoice = .auto, parallelToolCalls: Bool = true, jsonSchema: JSONValue? = nil,
        maxOutputTokens: Int? = nil, temperature: Double? = nil, reasoningEffort: String? = nil
    ) {
        self.model = model
        self.instructions = instructions
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.parallelToolCalls = parallelToolCalls
        self.jsonSchema = jsonSchema
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.reasoningEffort = reasoningEffort
    }
}

public struct LLMUsage: Sendable, Hashable {
    public var inputTokens: Int
    public var outputTokens: Int
    public init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// The model's complete answer: text and/or tool calls.
public struct LLMCompletion: Sendable, Hashable {
    public enum FinishReason: String, Sendable, Hashable { case stop, toolCalls = "tool_calls", length, contentFilter = "content_filter", incomplete, unknown }

    public var text: String
    public var toolCalls: [LLMToolCall]
    public var finishReason: FinishReason
    public var usage: LLMUsage?
    public var model: String?
    public var responseID: String?

    public init(
        text: String, toolCalls: [LLMToolCall] = [], finishReason: FinishReason = .stop, usage: LLMUsage? = nil,
        model: String? = nil, responseID: String? = nil
    ) {
        self.text = text
        self.toolCalls = toolCalls
        self.finishReason = finishReason
        self.usage = usage
        self.model = model
        self.responseID = responseID
    }
}

/// Streamed progress of one model call.
public enum LLMStreamEvent: Sendable {
    /// A fragment of the answer text, in order.
    case textDelta(String)
    /// The model started a tool call (arguments may still be streaming).
    case toolCallStarted(id: String, name: String)
    /// A complete tool call.
    case toolCall(LLMToolCall)
    /// The call finished; this is always the last event of a successful stream.
    case completed(LLMCompletion)
}

/// A model the provider offers, as discovered from the provider itself (never hardcoded).
public struct LLMModel: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var displayName: String
    /// Rough capability class derived from the name; used to pick a default, never to exclude a user's choice.
    public var tier: Tier

    public enum Tier: String, Sendable, Hashable, Codable { case capable, fast, unknown }

    public init(id: String, displayName: String? = nil, tier: Tier = .unknown) {
        self.id = id
        self.displayName = displayName ?? id
        self.tier = tier
    }
}

public enum LLMProviderError: Error, Sendable, Equatable, LocalizedError {
    case notConfigured(String)
    case authenticationRequired(String)
    case usageLimitExceeded(String)
    case temporarilyUnavailable(String)
    case unsupportedCapability(String)
    case http(status: Int, code: String?, message: String)
    case invalidResponse(String)
    case responseTooLarge
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let m), .authenticationRequired(let m), .usageLimitExceeded(let m),
            .temporarilyUnavailable(let m), .unsupportedCapability(let m), .invalidResponse(let m):
            return m
        case .http(let status, let code, let message): return "HTTP \(status)\(code.map { " (\($0))" } ?? ""): \(message)"
        case .responseTooLarge: return "The model's response was too large."
        case .cancelled: return "Cancelled."
        }
    }

    /// Errors after which another provider may reasonably be tried.
    public var isRetryableElsewhere: Bool {
        switch self {
        case .notConfigured, .authenticationRequired, .usageLimitExceeded, .temporarilyUnavailable: return true
        case .http(let status, _, _): return status >= 500 || status == 429
        default: return false
        }
    }
}

/// What a provider can do, so the planner can choose between native function calling and a JSON text protocol.
public enum LLMCapability: String, Sendable, Hashable { case nativeTools, streaming, jsonSchema }

/// A language-model backend.
public protocol LLMProvider: Sendable {
    /// Stable identifier (`chatgpt`, `openai`, `compatible`, `apple`).
    var id: String { get }
    var capabilities: Set<LLMCapability> { get }
    var displayName: String { get }
    /// Whether data leaves this Mac when the provider is used.
    var isRemote: Bool { get }
    /// Whether the provider may incur charges for the user (so it is never selected silently).
    var mayIncurCharges: Bool { get }
    /// The models this provider offers right now (from the provider itself).
    func availableModels() async throws -> [LLMModel]
    /// One complete call.
    func complete(_ request: LLMRequest) async throws -> LLMCompletion
    /// The same call, streamed. The stream always ends with `.completed` unless it throws.
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error>
}

extension LLMProvider {
    /// Default `complete` on top of `stream`, for providers that only implement streaming.
    public func completeByStreaming(_ request: LLMRequest) async throws -> LLMCompletion {
        var text = ""
        var calls: [LLMToolCall] = []
        for try await event in stream(request) {
            switch event {
            case .textDelta(let delta): text += delta
            case .toolCall(let call): calls.append(call)
            case .completed(var completion):
                if completion.text.isEmpty { completion.text = text }
                if completion.toolCalls.isEmpty { completion.toolCalls = calls }
                return completion
            case .toolCallStarted: break
            }
        }
        throw LLMProviderError.invalidResponse("The stream ended without a completion.")
    }
}

// MARK: - Model tiers

public enum ModelTiering {
    /// Heuristic only: names change, so this only ranks what a provider actually lists.
    public static func tier(for id: String) -> LLMModel.Tier {
        let name = id.lowercased()
        if name.contains("nano") || name.contains("mini") || name.contains("flash") || name.contains("small")
            || name.contains("lite") || name.contains("turbo") || name.contains("haiku")
        {
            return .fast
        }
        if name.hasPrefix("gpt-") || name.hasPrefix("o") && name.dropFirst().first?.isNumber == true
            || name.contains("sol") || name.contains("pro") || name.contains("opus") || name.contains("sonnet")
            || name.contains("qwen3") || name.contains("llama") || name.contains("gemma") || name.contains("mistral")
            || name.contains("deepseek") || name.contains("gpt-oss")
        {
            return .capable
        }
        return .unknown
    }

    /// Chooses a default from a provider's list: the first `capable` model in the provider's own order, else the first.
    public static func defaultCapable(from models: [LLMModel]) -> LLMModel? {
        models.first { $0.tier == .capable } ?? models.first
    }

    public static func defaultFast(from models: [LLMModel]) -> LLMModel? {
        models.first { $0.tier == .fast } ?? models.first
    }
}
