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
    /// What the provider is doing right now, in both languages (with the last error, if any).
    public var detail: LocalizedText
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
    private var lastErrors: [String: LocalizedText] = [:]
    /// When a model list could not be fetched, so a server that is down is not probed on every request.
    private var lastModelFailures: [String: Date] = [:]
    static let modelFailureBackoff: TimeInterval = 30

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

    /// Whether the provider has what it needs: signed in, key present, or (compatible server with the model left on
    /// "Automatic") a model list from the server, fetched here on first use and cached.
    func isConfigured(id: String, settings: IntelligenceSettings) async -> Bool {
        if let override, override(id, settings) != nil { return true }
        switch id {
        case "chatgpt": return await auth.credentials()?.planUsageGranted == true
        case "openai": return ((try? secrets.secret(for: OpenAIKeyProvider.keychainAccount)) ?? nil)?.isEmpty == false
        case "compatible":
            if !settings.compatibleModel.isEmpty { return true }
            if modelCache["compatible"]?.models.isEmpty == false { return true }
            // Automatic model: the server's list decides. A failed fetch lands in `lastErrors` (so statuses() can show
            // "endpoint — <error>" instead of a silent grey circle) and is not repeated for a short while.
            if let failed = lastModelFailures["compatible"], Date().timeIntervalSince(failed) < Self.modelFailureBackoff { return false }
            return ((try? await models(for: "compatible")) ?? []).isEmpty == false
        case "apple": return AppleFoundationProvider.isAvailable
        default: return false
        }
    }

    // MARK: Models

    public func models(for providerID: String, forceRefresh: Bool = false) async throws -> [LLMModel] {
        if !forceRefresh, let cached = modelCache[providerID], Date().timeIntervalSince(cached.fetched) < 600 { return cached.models }
        let settings = settings
        guard let provider = provider(id: providerID, settings: settings) else {
            throw LLMProviderError.notConfigured(LocalizedText(en: "\(providerID) is disabled", es: "\(providerID) está desactivado"))
        }
        do {
            let models = try await provider.availableModels()
            modelCache[providerID] = (models, Date())
            lastErrors[providerID] = nil
            lastModelFailures[providerID] = nil
            return models
        } catch {
            let mapped = LLMProviderError.wrapping(error)
            lastErrors[providerID] = ProviderErrorText.localizedText(for: mapped)
            lastModelFailures[providerID] = Date()
            throw mapped
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
        if let explicit, !explicit.isEmpty {
            // A local server's models come and go (pulled, removed, renamed): a chosen model the server no longer
            // lists is replaced by one it has, and the diagnostics say so, instead of every request failing with 404.
            if providerID == "compatible", let models = try? await models(for: providerID), !models.isEmpty,
                !models.contains(where: { $0.id == explicit })
            {
                let replacement = ModelTiering.defaultCapable(from: models)?.id ?? models[0].id
                if lastErrors[providerID]?.en.contains(explicit) != true {
                    Self.logger.warning("model \(explicit, privacy: .public) is not on the compatible server; using \(replacement, privacy: .public)")
                    lastErrors[providerID] = LocalizedText(
                        en: "Model \(explicit) is not available on the server; using \(replacement).",
                        es: "El modelo \(explicit) no está disponible en el servidor; se usa \(replacement).")
                }
                return replacement
            }
            return explicit
        }
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

    private var lastPrewarm: Date = .distantPast
    /// Makes the first planning model ready (a local server loads it into memory). At most once every 20 seconds.
    public func prewarm() async {
        guard Date().timeIntervalSince(lastPrewarm) > 20 else { return }
        lastPrewarm = Date()
        guard let resolved = await resolve(.planning), let compatible = resolved.provider as? CompatibleProvider else { return }
        await compatible.prewarm(model: resolved.model)
    }

    /// Runs `operation` on the first candidate and moves on to the next one after any failure that another provider
    /// could get past: transport errors (offline, refused, DNS, timeout), sign-in and refresh failures, usage limits,
    /// 5xx, "not configured". Cancellation (including a `URLError.cancelled`) propagates as `CancellationError`; a
    /// typed error that no other provider would fix (bad response, unsupported capability, 4xx) propagates at once.
    /// Whatever is left when the chain is exhausted is an `LLMProviderError`, so the planner's offline path can run.
    public func withFallback<T: Sendable>(
        _ purpose: ModelPurpose, _ operation: @Sendable (ResolvedModel) async throws -> T
    ) async throws -> T {
        let candidates = await candidates(for: purpose)
        guard !candidates.isEmpty else {
            throw LLMProviderError.notConfigured(
                LocalizedText(
                    en: "No language model is available: sign in with ChatGPT or configure another provider in Settings ▸ Intelligence.",
                    es: "No hay ningún modelo de lenguaje disponible: inicia sesión con ChatGPT o configura otro proveedor en Ajustes ▸ Inteligencia."))
        }
        var lastError: LLMProviderError?
        for candidate in candidates {
            do {
                return try await operation(candidate)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as LLMProviderError where !error.isRetryableElsewhere {
                throw error
            } catch {
                let mapped = LLMProviderError.wrapping(error)
                guard let typed = mapped as? LLMProviderError else { throw CancellationError() }
                Self.logger.warning("provider \(candidate.providerID, privacy: .public) failed (\(typed.message(for: .en), privacy: .public)); trying the next one")
                lastErrors[candidate.providerID] = typed.localizedText
                lastError = typed
            }
        }
        throw lastError ?? LLMProviderError.notConfigured(LocalizedText(en: "No language model answered.", es: "Ningún modelo de lenguaje respondió."))
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
            var detail: LocalizedText
            switch id {
            case "chatgpt":
                if let credentials = await auth.credentials() {
                    let account = credentials.email ?? credentials.subject
                    detail = credentials.planUsageGranted
                        ? LocalizedText(en: "Signed in as \(account)", es: "Sesión iniciada como \(account)")
                        : LocalizedText(en: "Signed in, but plan usage was not granted", es: "Sesión iniciada, pero no se concedió el uso del plan")
                } else {
                    detail = LocalizedText(en: "Not signed in", es: "Sin sesión iniciada")
                }
            case "openai":
                detail = configured
                    ? LocalizedText(en: "API key stored in the Keychain", es: "Clave de API guardada en el llavero")
                    : LocalizedText(en: "No API key", es: "Sin clave de API")
            case "compatible": detail = LocalizedText(settings.compatibleEndpoint)
            case "apple":
                detail = AppleFoundationProvider.unavailability ?? LocalizedText(en: "Available on this Mac", es: "Disponible en este Mac")
            default: detail = LocalizedText("")
            }
            if let error = lastErrors[id] {
                detail = LocalizedText(en: detail.en + " — " + error.en, es: detail.es + " — " + error.es)
            }
            result.append(
                ProviderStatus(
                    id: id, displayName: provider?.displayName ?? Self.displayName(id), enabled: enabled, configured: configured,
                    detail: detail, models: models, selectedModel: selected,
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

    /// Forgets cached model lists, errors and the Ollama detection (settings changed, sign-in state changed).
    public func clearCache() {
        modelCache = [:]
        lastErrors = [:]
        lastModelFailures = [:]
        CompatibleProvider.resetDetection()
    }
}

public enum CompatibleProviderKeyAccount {
    public static func account(for endpoint: String) -> String { "compatible." + endpoint.trimmingCharacters(in: .whitespacesAndNewlines) }
}
