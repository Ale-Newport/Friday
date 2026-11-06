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

/// Errors a provider can throw. Messages are spoken aloud inside the user's reply, so every case carries both
/// languages; the `String` overloads below keep call sites that only have one text (server messages, diagnostics)
/// short, and they produce the same text in both languages.
public enum LLMProviderError: Error, Sendable, Equatable, LocalizedError {
    case notConfigured(LocalizedText)
    case authenticationRequired(LocalizedText)
    case usageLimitExceeded(LocalizedText)
    case temporarilyUnavailable(LocalizedText)
    /// The account cannot use this provider at all (ChatGPT plan sharing is not available for the user, workspace or
    /// policy). Explained once, never retried on the same provider and never answered with a new sign-in; another
    /// provider may still take over.
    case notEligible(LocalizedText)
    case unsupportedCapability(LocalizedText)
    case http(status: Int, code: String?, message: String)
    case invalidResponse(LocalizedText)
    case responseTooLarge
    case cancelled

    public static func notConfigured(_ message: String) -> LLMProviderError { .notConfigured(LocalizedText(message)) }
    public static func authenticationRequired(_ message: String) -> LLMProviderError { .authenticationRequired(LocalizedText(message)) }
    public static func usageLimitExceeded(_ message: String) -> LLMProviderError { .usageLimitExceeded(LocalizedText(message)) }
    public static func temporarilyUnavailable(_ message: String) -> LLMProviderError { .temporarilyUnavailable(LocalizedText(message)) }
    public static func notEligible(_ message: String) -> LLMProviderError { .notEligible(LocalizedText(message)) }
    public static func unsupportedCapability(_ message: String) -> LLMProviderError { .unsupportedCapability(LocalizedText(message)) }
    public static func invalidResponse(_ message: String) -> LLMProviderError { .invalidResponse(LocalizedText(message)) }

    public var errorDescription: String? { message(for: .en) }

    /// The user-facing text in the given language.
    public func message(for language: Language) -> String {
        switch self {
        case .notConfigured(let m), .authenticationRequired(let m), .usageLimitExceeded(let m),
            .temporarilyUnavailable(let m), .notEligible(let m), .unsupportedCapability(let m), .invalidResponse(let m):
            return m.resolved(language)
        case .http(let status, let code, let message):
            let prefix = "HTTP \(status)\(code.map { " (\($0))" } ?? "")"
            return message.isEmpty ? language.pick("\(prefix) from the model service.", "\(prefix) del servicio del modelo.") : "\(prefix): \(message)"
        case .responseTooLarge: return language.pick("The model's response was too large.", "La respuesta del modelo era demasiado grande.")
        case .cancelled: return language.pick("Cancelled.", "Cancelado.")
        }
    }

    public var localizedText: LocalizedText { LocalizedText(en: message(for: .en), es: message(for: .es)) }

    /// Errors after which another provider may reasonably be tried.
    public var isRetryableElsewhere: Bool {
        switch self {
        case .notConfigured, .authenticationRequired, .usageLimitExceeded, .temporarilyUnavailable, .notEligible: return true
        case .http(let status, _, _): return status >= 500 || status == 429
        default: return false
        }
    }

    // MARK: Mapping other errors

    /// Maps anything a provider can throw to the planner's vocabulary: cancellation stays a `CancellationError`
    /// (a `URLError.cancelled` included), transport failures (offline, refused, DNS, timeout) become
    /// `temporarilyUnavailable` so the fallback chain and the offline path run, sign-in errors become
    /// `authenticationRequired` / `temporarilyUnavailable`, and anything unknown becomes `invalidResponse`.
    public static func wrapping(_ error: any Error) -> any Error {
        switch error {
        case is CancellationError: return error
        case let typed as LLMProviderError: return typed
        case let url as URLError: return url.code == .cancelled ? CancellationError() : LLMProviderError.transport(url)
        case let auth as ChatGPTAuthError: return auth.providerError
        default:
            return LLMProviderError.invalidResponse(
                LocalizedText(en: "Unexpected error: \(error.localizedDescription)", es: "Error inesperado: \(error.localizedDescription)"))
        }
    }

    /// A `URLError` as a provider error (always `temporarilyUnavailable`: the service may be back for the next request).
    public static func transport(_ error: URLError) -> LLMProviderError {
        let host = error.failingURL?.host ?? ""
        let service = host.isEmpty ? LocalizedText(en: "the model service", es: "el servicio del modelo") : LocalizedText(host)
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .internationalRoamingOff, .dataNotAllowed, .callIsActive:
            return .temporarilyUnavailable(LocalizedText(en: "No internet connection.", es: "No hay conexión a internet."))
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .badURL, .unsupportedURL:
            return .temporarilyUnavailable(LocalizedText(en: "Could not reach \(service.en).", es: "No se pudo conectar con \(service.es)."))
        case .timedOut:
            return .temporarilyUnavailable(LocalizedText(en: "\(service.en) did not answer in time.", es: "\(service.es) no respondió a tiempo."))
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
            .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired:
            return .temporarilyUnavailable(LocalizedText(en: "The secure connection to \(service.en) failed.", es: "Falló la conexión segura con \(service.es)."))
        default:
            return .temporarilyUnavailable(
                LocalizedText(
                    en: "No connection to \(service.en) (\(error.localizedDescription)).",
                    es: "Sin conexión con \(service.es) (\(error.localizedDescription))."))
        }
    }
}

/// User-facing text for any error the intelligence layer can surface, in the user's language. The planner and the
/// app use this instead of `localizedDescription`, which is English-only.
public enum ProviderErrorText {
    public static func message(for error: any Error, language: Language) -> String {
        switch error {
        case let typed as LLMProviderError: return typed.message(for: language)
        case let auth as ChatGPTAuthError: return auth.message(for: language)
        case is CancellationError: return language.pick("Cancelled.", "Cancelado.")
        case let url as URLError: return LLMProviderError.transport(url).message(for: language)
        default: return error.localizedDescription
        }
    }

    public static func localizedText(for error: any Error) -> LocalizedText {
        LocalizedText(en: message(for: error, language: .en), es: message(for: error, language: .es))
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

    /// The everyday default for planning: the best-ranked `capable` model, independent of the order the provider
    /// lists them in (a string sort once made the automatic OpenAI choice land on `o3-pro`). Mainline `gpt-N[.x]`
    /// aliases rank ahead of reasoning-only `oN`, "pro", preview, codex and dated-snapshot variants, which are slower
    /// and dearer; ties keep the provider's order, so a provider that lists its preferred model first still wins.
    /// Falls back to the first model of any tier.
    public static func defaultCapable(from models: [LLMModel]) -> LLMModel? {
        best(models.filter { $0.tier == .capable }) ?? models.first
    }

    public static func defaultFast(from models: [LLMModel]) -> LLMModel? {
        best(models.filter { $0.tier == .fast }) ?? models.first
    }

    static func best(_ models: [LLMModel]) -> LLMModel? {
        var choice: (rank: Int, model: LLMModel)?
        for model in models {
            let rank = defaultRank(model.id)
            if let current = choice, current.rank <= rank { continue }
            choice = (rank, model)
        }
        return choice?.model
    }

    /// Lower ranks are better defaults. Penalties are additive so a dated "pro" snapshot stays behind a dated mainline
    /// one; newer `gpt-N.x` families get a small bonus so `gpt-5.1` beats `gpt-4.1` whatever the listing order.
    public static func defaultRank(_ id: String) -> Int {
        let name = id.lowercased()
        var rank = 0
        if name.contains("pro") { rank += 1000 }
        if name.hasPrefix("o"), name.dropFirst().first?.isNumber == true { rank += 500 }
        if name.contains("preview") || name.contains("research") || name.contains("codex") { rank += 300 }
        if name.range(of: #"-\d{4}(-\d{2}-\d{2})?$"#, options: .regularExpression) != nil { rank += 100 }
        if let version = gptVersion(name) { rank -= min(Int(version * 10), 99) }
        return rank
    }

    static func gptVersion(_ name: String) -> Double? {
        guard name.hasPrefix("gpt-") else { return nil }
        let digits = name.dropFirst(4).prefix { $0.isNumber || $0 == "." }
        return Double(digits)
    }
}
