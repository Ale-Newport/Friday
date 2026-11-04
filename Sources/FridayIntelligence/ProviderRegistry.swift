import Foundation
import FridayCore
import os

public enum ModelPurpose: Sendable, Hashable { case planning, fast, conversation }

/// A provider together with the model to use on it.
public struct ResolvedModel: Sendable {
    public var provider: any LLMProvider
    public var model: String
    public var providerID: String { provider.id }
}

public struct ProviderStatus: Sendable, Hashable, Identifiable {
    public var id: String
    public var displayName: String
    public var enabled: Bool
    public var configured: Bool
    public var detail: String
    public var models: [LLMModel]
    public var selectedModel: String?
    public var isRemote: Bool
    public var mayIncurCharges: Bool
}

/// Builds the provider chain from the settings and keeps model lists cached. Never picks a provider that may incur
/// charges as a silent fallback.
public actor ProviderRegistry {
    static let logger = Logger(subsystem: "com.alejandro.friday", category: "providers")

    public let auth: ChatGPTAuthService
    private let secrets: any SecretStoring
    private let settingsSnapshot: @Sendable () -> IntelligenceSettings
    private let override: (@Sendable (String, IntelligenceSettings) -> (any LLMProvider)?)?
    private var modelCache: [String: (models: [LLMModel], fetched: Date)] = [:]
    private var lastErrors: [String: String] = [:]

    /// `providerOverride` lets tests (or a host) substitute providers by id; an override that returns a provider is
    /// considered configured.
    public init(
        auth: ChatGPTAuthService, secrets: any SecretStoring, settings: @escaping @Sendable () -> IntelligenceSettings,
        providerOverride: (@Sendable (String, IntelligenceSettings) -> (any LLMProvider)?)? = nil
    ) {
        self.auth = auth
        self.secrets = secrets
        self.settingsSnapshot = settings
        self.override = providerOverride
    }

    public var settings: IntelligenceSettings { settingsSnapshot() }

    // MARK: Providers

    func provider(id: String, settings: IntelligenceSettings) -> (any LLMProvider)? {
        if let override, let provider = override(id, settings) { return provider }
        switch id {
        case "chatgpt": return settings.chatGPTEnabled ? ChatGPTPlanProvider(auth: auth) : nil
        case "openai": return settings.openAIKeyEnabled ? OpenAIKeyProvider(secrets: secrets) : nil
        case "compatible":
            guard settings.compatibleEnabled, let url = URL(string: settings.compatibleEndpoint), url.host != nil else { return nil }
            let key = try? secrets.secret(for: CompatibleProviderKeyAccount.account(for: settings.compatibleEndpoint))
            return CompatibleProvider(baseURL: url, apiKey: key, supportsTools: settings.compatibleSupportsTools)
        case "apple": return settings.appleOnDeviceEnabled && AppleFoundationProvider.isAvailable ? AppleFoundationProvider() : nil
        default: return nil
        }
    }

    /// Whether the provider has what it needs (signed in, key present, server reachable is NOT checked here).
    func isConfigured(id: String, settings: IntelligenceSettings) async -> Bool {
        if let override, override(id, settings) != nil { return true }
        switch id {
        case "chatgpt": return await auth.credentials()?.planUsageGranted == true
        case "openai": return ((try? secrets.secret(for: OpenAIKeyProvider.keychainAccount)) ?? nil)?.isEmpty == false
        case "compatible": return !settings.compatibleModel.isEmpty || modelCache["compatible"]?.models.isEmpty == false
        case "apple": return AppleFoundationProvider.isAvailable
        default: return false
        }
    }

    // MARK: Models

    public func models(for providerID: String, forceRefresh: Bool = false) async throws -> [LLMModel] {
        if !forceRefresh, let cached = modelCache[providerID], Date().timeIntervalSince(cached.fetched) < 600 { return cached.models }
        let settings = settings
        guard let provider = provider(id: providerID, settings: settings) else { throw LLMProviderError.notConfigured("\(providerID) is disabled") }
        do {
            let models = try await provider.availableModels()
            modelCache[providerID] = (models, Date())
            lastErrors[providerID] = nil
            return models
        } catch {
            lastErrors[providerID] = error.localizedDescription
            throw error
        }
    }

    func chosenModel(for providerID: String, purpose: ModelPurpose, settings: IntelligenceSettings) async -> String? {
        let explicit: String?
        switch (providerID, purpose) {
        case ("chatgpt", .fast): explicit = settings.chatGPTFastModel ?? settings.chatGPTModel
        case ("chatgpt", _): explicit = settings.chatGPTModel
        case ("openai", .fast): explicit = settings.openAIFastModel ?? settings.openAIModel
        case ("openai", _): explicit = settings.openAIModel
        case ("compatible", _): explicit = settings.compatibleModel.isEmpty ? nil : settings.compatibleModel
        case ("apple", _): return "apple-on-device"
        default: explicit = nil
        }
        if let explicit, !explicit.isEmpty { return explicit }
        guard let models = try? await models(for: providerID), !models.isEmpty else { return nil }
        switch purpose {
        case .fast: return ModelTiering.defaultFast(from: models)?.id
        default: return ModelTiering.defaultCapable(from: models)?.id
        }
    }

    /// The providers to try, in order, for a purpose. The first enabled one is always allowed; later ones only if
    /// they are free or the user allowed paid fallbacks.
    public func candidates(for purpose: ModelPurpose) async -> [ResolvedModel] {
        let settings = settings
        var result: [ResolvedModel] = []
        for id in settings.fallbackOrder {
            guard let provider = provider(id: id, settings: settings) else { continue }
            guard await isConfigured(id: id, settings: settings) else { continue }
            if !result.isEmpty, provider.mayIncurCharges, !settings.allowPaidFallback { continue }
            guard let model = await chosenModel(for: id, purpose: purpose, settings: settings) else { continue }
            result.append(ResolvedModel(provider: provider, model: model))
        }
        return result
    }

    public func resolve(_ purpose: ModelPurpose) async -> ResolvedModel? { await candidates(for: purpose).first }

    /// Runs `operation` on the first candidate; on errors that justify another provider (not configured, auth,
    /// usage limit, 5xx) moves on to the next one. Other errors propagate.
    public func withFallback<T: Sendable>(
        _ purpose: ModelPurpose, _ operation: @Sendable (ResolvedModel) async throws -> T
    ) async throws -> T {
        let candidates = await candidates(for: purpose)
        guard !candidates.isEmpty else {
            throw LLMProviderError.notConfigured("No language model is available: sign in with ChatGPT or configure another provider in Settings ▸ Intelligence.")
        }
        var lastError: (any Error)?
        for candidate in candidates {
            do {
                return try await operation(candidate)
            } catch let error as LLMProviderError where error.isRetryableElsewhere {
                Self.logger.warning("provider \(candidate.providerID, privacy: .public) failed (\(error.localizedDescription, privacy: .public)); trying the next one")
                lastErrors[candidate.providerID] = error.localizedDescription
                lastError = error
                continue
            }
        }
        throw lastError ?? LLMProviderError.notConfigured("No language model answered.")
    }

    // MARK: Status for the UI

    public func statuses() async -> [ProviderStatus] {
        let settings = settings
        var result: [ProviderStatus] = []
        for id in ["chatgpt", "openai", "compatible", "apple"] {
            let provider = provider(id: id, settings: settings)
            let enabled = provider != nil
            let configured = await isConfigured(id: id, settings: settings)
            let models = modelCache[id]?.models ?? []
            let selected = enabled && configured ? await chosenModel(for: id, purpose: .planning, settings: settings) : nil
            let detail: String
            switch id {
            case "chatgpt":
                if let credentials = await auth.credentials() {
                    detail = credentials.planUsageGranted
                        ? "Signed in as \(credentials.email ?? credentials.subject)"
                        : "Signed in, but plan usage was not granted"
                } else { detail = "Not signed in" }
            case "openai": detail = configured ? "API key stored in the Keychain" : "No API key"
            case "compatible": detail = settings.compatibleEndpoint
            case "apple": detail = AppleFoundationProvider.isAvailable ? "Available on this Mac" : (AppleFoundationProvider.unavailabilityReason ?? "Unavailable")
            default: detail = ""
            }
            result.append(
                ProviderStatus(
                    id: id, displayName: provider?.displayName ?? Self.displayName(id), enabled: enabled, configured: configured,
                    detail: lastErrors[id].map { detail + " — " + $0 } ?? detail, models: models, selectedModel: selected,
                    isRemote: provider?.isRemote ?? (id != "apple"), mayIncurCharges: provider?.mayIncurCharges ?? (id == "openai")))
        }
        return result
    }

    static func displayName(_ id: String) -> String {
        switch id {
        case "chatgpt": return "ChatGPT"
        case "openai": return "OpenAI API key"
        case "compatible": return "OpenAI-compatible server"
        case "apple": return "Apple on-device model"
        default: return id
        }
    }

    public func clearCache() { modelCache = [:]; lastErrors = [:] }
}

public enum CompatibleProviderKeyAccount {
    public static func account(for endpoint: String) -> String { "compatible." + endpoint.trimmingCharacters(in: .whitespacesAndNewlines) }
}
