import Foundation

/// Which models Friday may use and in what order. Persisted by the app; read per request.
public struct IntelligenceSettings: Codable, Sendable, Hashable {
    /// Use the signed-in ChatGPT account (plan sharing) when available.
    public var chatGPTEnabled = true
    /// Model slugs chosen by the user; `nil` means "pick automatically from what the account lists".
    public var chatGPTModel: String?
    public var chatGPTFastModel: String?

    /// An OpenAI API key is metered: it is used only when explicitly enabled.
    public var openAIKeyEnabled = false
    public var openAIModel: String?
    public var openAIFastModel: String?

    /// Any OpenAI-compatible server (Ollama, LM Studio, llama.cpp, a hosted gateway).
    public var compatibleEnabled = false
    public var compatibleEndpoint = "http://localhost:11434/v1"
    public var compatibleModel = ""
    public var compatibleSupportsTools = true

    /// Apple's on-device model as the free offline fallback (macOS 26+).
    public var appleOnDeviceEnabled = true

    /// Provider ids in the order they are tried. A provider that `mayIncurCharges` is skipped as a *fallback*
    /// unless `allowPaidFallback` is on (it is still used when it is the first enabled provider).
    public var fallbackOrder: [String] = ["chatgpt", "openai", "compatible", "apple"]
    public var allowPaidFallback = false

    /// Laya routing (through the sidecar) before the LLM.
    public var layaRoutingEnabled = true
    public var layaConfidenceThreshold = 0.6
    /// Deterministic fast path for obvious commands (no model call).
    public var fastPathEnabled = true

    /// Effort hint for reasoning models during planning (`low` keeps voice latency acceptable).
    public var planningReasoningEffort: String? = "low"
    public var maxToolRounds = 12
    /// Include screen context (frontmost app, selection) in prompts when a tool needs it.
    public var shareScreenContext = true

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case chatGPTEnabled, chatGPTModel, chatGPTFastModel, openAIKeyEnabled, openAIModel, openAIFastModel
        case compatibleEnabled, compatibleEndpoint, compatibleModel, compatibleSupportsTools, appleOnDeviceEnabled
        case fallbackOrder, allowPaidFallback, layaRoutingEnabled, layaConfidenceThreshold, fastPathEnabled
        case planningReasoningEffort, maxToolRounds, shareScreenContext
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = IntelligenceSettings()
        chatGPTEnabled = try c.decodeIfPresent(Bool.self, forKey: .chatGPTEnabled) ?? d.chatGPTEnabled
        chatGPTModel = try c.decodeIfPresent(String.self, forKey: .chatGPTModel)
        chatGPTFastModel = try c.decodeIfPresent(String.self, forKey: .chatGPTFastModel)
        openAIKeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .openAIKeyEnabled) ?? d.openAIKeyEnabled
        openAIModel = try c.decodeIfPresent(String.self, forKey: .openAIModel)
        openAIFastModel = try c.decodeIfPresent(String.self, forKey: .openAIFastModel)
        compatibleEnabled = try c.decodeIfPresent(Bool.self, forKey: .compatibleEnabled) ?? d.compatibleEnabled
        compatibleEndpoint = try c.decodeIfPresent(String.self, forKey: .compatibleEndpoint) ?? d.compatibleEndpoint
        compatibleModel = try c.decodeIfPresent(String.self, forKey: .compatibleModel) ?? d.compatibleModel
        compatibleSupportsTools = try c.decodeIfPresent(Bool.self, forKey: .compatibleSupportsTools) ?? d.compatibleSupportsTools
        appleOnDeviceEnabled = try c.decodeIfPresent(Bool.self, forKey: .appleOnDeviceEnabled) ?? d.appleOnDeviceEnabled
        fallbackOrder = try c.decodeIfPresent([String].self, forKey: .fallbackOrder) ?? d.fallbackOrder
        allowPaidFallback = try c.decodeIfPresent(Bool.self, forKey: .allowPaidFallback) ?? d.allowPaidFallback
        layaRoutingEnabled = try c.decodeIfPresent(Bool.self, forKey: .layaRoutingEnabled) ?? d.layaRoutingEnabled
        layaConfidenceThreshold = try c.decodeIfPresent(Double.self, forKey: .layaConfidenceThreshold) ?? d.layaConfidenceThreshold
        fastPathEnabled = try c.decodeIfPresent(Bool.self, forKey: .fastPathEnabled) ?? d.fastPathEnabled
        planningReasoningEffort = try c.decodeIfPresent(String.self, forKey: .planningReasoningEffort) ?? d.planningReasoningEffort
        maxToolRounds = try c.decodeIfPresent(Int.self, forKey: .maxToolRounds) ?? d.maxToolRounds
        shareScreenContext = try c.decodeIfPresent(Bool.self, forKey: .shareScreenContext) ?? d.shareScreenContext
    }
}
