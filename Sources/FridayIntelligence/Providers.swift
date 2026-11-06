import Foundation
import FridayCore

// MARK: - ChatGPT plan (Sign in with ChatGPT)

/// Uses the signed-in ChatGPT account's plan through the Responses API, within the documented constraints.
public struct ChatGPTPlanProvider: LLMProvider {
    public let id = "chatgpt"
    public let displayName = "ChatGPT"
    public let isRemote = true
    /// Plan usage counts against the user's ChatGPT subscription limits; it is not a metered charge.
    public let mayIncurCharges = false
    public let capabilities: Set<LLMCapability> = [.nativeTools, .streaming, .jsonSchema]

    private let auth: ChatGPTAuthService
    private let client = ResponsesAPIClient()

    public init(auth: ChatGPTAuthService) { self.auth = auth }

    /// A plan token for one call. Sign-in errors come back in the planner's vocabulary (`LLMProviderError`), so a
    /// refresh that failed because the Mac is offline reads as "temporarily unavailable", not as "sign in again".
    private func credentials() async throws -> ResponsesAPIClient.Credentials {
        guard let stored = await auth.credentials() else {
            throw LLMProviderError.notConfigured(LocalizedText(en: "Not signed in with ChatGPT.", es: "No has iniciado sesión con ChatGPT."))
        }
        guard stored.planUsageGranted else {
            // Documented: keep the sign-in, mark plan usage disabled, do not run inference.
            throw LLMProviderError.notConfigured(
                LocalizedText(
                    en: "ChatGPT plan usage was not granted. Sign in again and allow plan usage.",
                    es: "No se concedió el uso del plan de ChatGPT. Vuelve a iniciar sesión y permite el uso del plan."))
        }
        do {
            return ResponsesAPIClient.Credentials(bearer: try await auth.validAccessToken(), planToken: true)
        } catch {
            throw LLMProviderError.wrapping(error)
        }
    }

    public func availableModels() async throws -> [LLMModel] {
        let credentials = try await credentials()
        return try await client.listModels(credentials: credentials).filter(\.listed).map {
            LLMModel(id: $0.id, displayName: $0.displayName, tier: ModelTiering.tier(for: $0.id))
        }
    }

    public func complete(_ request: LLMRequest) async throws -> LLMCompletion { try await completeByStreaming(request) }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let initial = try await credentials()
                    var delivered = 0
                    do {
                        for try await event in client.stream(request, credentials: initial) {
                            delivered += 1
                            continuation.yield(event)
                        }
                    } catch LLMProviderError.authenticationRequired where delivered == 0 {
                        // The access token was rejected (HTTP 401, invalid_token, subscription_sharing_invalid_user) although it
                        // looked fresh: it can be revoked or expire between the check and the call. One refresh, one retry.
                        // A terminal refresh error is the documented moment to ask for a new sign-in; an ineligible account
                        // (`notEligible`) or a usage limit never gets here.
                        do {
                            _ = try await auth.refresh()
                        } catch {
                            throw LLMProviderError.wrapping(error)
                        }
                        let refreshed = try await credentials()
                        for try await event in client.stream(request, credentials: refreshed) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: LLMProviderError.wrapping(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - OpenAI API key

public struct OpenAIKeyProvider: LLMProvider {
    public static let keychainAccount = "openai.api_key"

    public let id = "openai"
    public let displayName = "OpenAI API key"
    public let isRemote = true
    public let mayIncurCharges = true
    public let capabilities: Set<LLMCapability> = [.nativeTools, .streaming, .jsonSchema]

    private let secrets: any SecretStoring
    private let client: ResponsesAPIClient

    public init(secrets: any SecretStoring, baseURL: URL = URL(string: "https://api.openai.com/v1")!) {
        self.secrets = secrets
        self.client = ResponsesAPIClient(baseURL: baseURL)
    }

    private func credentials() throws -> ResponsesAPIClient.Credentials {
        guard let key = try secrets.secret(for: Self.keychainAccount), !key.isEmpty else {
            throw LLMProviderError.notConfigured(
                LocalizedText(en: "No OpenAI API key is configured.", es: "No hay ninguna clave de API de OpenAI configurada."))
        }
        return ResponsesAPIClient.Credentials(bearer: key, planToken: false)
    }

    /// The chat-capable models the key can use, in the server's order. The default for planning is chosen by
    /// `ModelTiering.defaultCapable`, which ranks the ids itself, so the order here only matters for display.
    public func availableModels() async throws -> [LLMModel] {
        let credentials = try credentials()
        let chatLike = try await client.listModels(credentials: credentials).filter { entry in
            let name = entry.id.lowercased()
            let excluded = ["embedding", "tts", "whisper", "transcribe", "dall-e", "image", "moderation", "realtime", "audio", "search", "davinci", "babbage"]
            return (name.hasPrefix("gpt-") || name.hasPrefix("o") && name.dropFirst().first?.isNumber == true
                || name.hasPrefix("chatgpt")) && !excluded.contains { name.contains($0) }
        }
        return chatLike.map { LLMModel(id: $0.id, displayName: $0.displayName, tier: ModelTiering.tier(for: $0.id)) }
    }

    public func complete(_ request: LLMRequest) async throws -> LLMCompletion { try await completeByStreaming(request) }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
        do {
            return client.stream(request, credentials: try credentials())
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: LLMProviderError.wrapping(error)) }
        }
    }
}

// MARK: - OpenAI-compatible local or hosted server

public struct CompatibleProvider: LLMProvider {
    public let id = "compatible"
    public var displayName: String
    public var isRemote: Bool
    public var mayIncurCharges: Bool
    public let capabilities: Set<LLMCapability>
    public var baseURL: URL
    private let client: ChatCompletionsClient
    private let ollama: OllamaClient
    private let supportsTools: Bool

    public init(baseURL: URL, apiKey: String? = nil, displayName: String? = nil, supportsTools: Bool = true) {
        self.baseURL = baseURL
        let host = baseURL.host?.lowercased() ?? ""
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        self.isRemote = !local
        self.mayIncurCharges = !local
        self.displayName = displayName ?? (local ? "Local model (\(host):\(baseURL.port ?? 80))" : host)
        self.client = ChatCompletionsClient(baseURL: baseURL, apiKey: apiKey)
        self.ollama = OllamaClient(root: OllamaClient.root(forCompatibleBaseURL: baseURL), apiKey: apiKey)
        self.supportsTools = supportsTools
        self.capabilities = supportsTools ? [.nativeTools, .streaming] : [.streaming]
    }

    /// Ollama servers are driven through their native API (explicit context window). Detection is cached per root: a
    /// positive answer for the process lifetime, "answers but is not Ollama" for ten minutes, and "unreachable" only
    /// briefly, so an Ollama started after Friday is picked up on the next request without probing on every one.
    private static let detected = DetectionCache()

    private func usesOllama() async -> Bool {
        let key = ollama.root.absoluteString
        if let known = Self.detected.outcome(for: key) { return known == .ollama }
        let outcome = await OllamaClient.detect(at: ollama.root)
        Self.detected.record(outcome, for: key)
        return outcome == .ollama
    }

    /// Forgets every cached detection (settings changed, the user asked to detect again).
    public static func resetDetection() { detected.removeAll() }

    public func availableModels() async throws -> [LLMModel] {
        let ids = await usesOllama() ? try await ollama.listModels() : try await client.listModels()
        return ids.filter { id in
            let name = id.lowercased()
            return !["embed", "nomic", "bge-", "minilm", "rerank", "whisper", "tts", "moderation", "clip"].contains { name.contains($0) }
        }.map { LLMModel(id: $0, tier: ModelTiering.tier(for: $0)) }
    }

    public func complete(_ request: LLMRequest) async throws -> LLMCompletion {
        if await usesOllama() { return try await ollama.complete(request, supportsTools: supportsTools) }
        return try await client.complete(request, supportsTools: supportsTools)
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
        let client = client
        let ollama = ollama
        let supportsTools = supportsTools
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let inner = await usesOllama() ? ollama.stream(request, supportsTools: supportsTools) : client.stream(request, supportsTools: supportsTools)
                    for try await event in inner { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: LLMProviderError.wrapping(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Remembers what answered at each server root. A positive Ollama detection lasts for the process; the two negative
/// outcomes expire, so a server started (or swapped) after Friday is re-probed.
final class DetectionCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (outcome: OllamaClient.Detection, at: Date)] = [:]
    let unreachableTTL: TimeInterval
    let otherTTL: TimeInterval

    init(unreachableTTL: TimeInterval = 60, otherTTL: TimeInterval = 600) {
        self.unreachableTTL = unreachableTTL
        self.otherTTL = otherTTL
    }

    func outcome(for key: String, now: Date = Date()) -> OllamaClient.Detection? {
        lock.withLock {
            guard let entry = entries[key] else { return nil }
            switch entry.outcome {
            case .ollama: return .ollama
            case .other: return now.timeIntervalSince(entry.at) < otherTTL ? .other : nil
            case .unreachable: return now.timeIntervalSince(entry.at) < unreachableTTL ? .unreachable : nil
            }
        }
    }

    func record(_ outcome: OllamaClient.Detection, for key: String, at date: Date = Date()) {
        lock.withLock { entries[key] = (outcome, date) }
    }

    func removeAll() { lock.withLock { entries.removeAll() } }
}
