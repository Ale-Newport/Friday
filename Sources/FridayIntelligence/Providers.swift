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

    private func credentials() async throws -> ResponsesAPIClient.Credentials {
        guard let stored = await auth.credentials() else { throw LLMProviderError.notConfigured("Not signed in with ChatGPT.") }
        guard stored.planUsageGranted else {
            throw LLMProviderError.authenticationRequired("ChatGPT plan usage was not granted. Sign in again and allow plan usage.")
        }
        let token = try await auth.validAccessToken()
        return ResponsesAPIClient.Credentials(bearer: token, planToken: true)
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
                    let credentials = try await credentials()
                    for try await event in client.stream(request, credentials: credentials) { continuation.yield(event) }
                    continuation.finish()
                } catch LLMProviderError.authenticationRequired(let message) {
                    // One refresh-and-retry: an access token can be revoked or expire between the check and the call.
                    do {
                        _ = try await auth.refresh()
                        let credentials = try await credentials()
                        for try await event in client.stream(request, credentials: credentials) { continuation.yield(event) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: LLMProviderError.authenticationRequired(message))
                    }
                } catch {
                    continuation.finish(throwing: error)
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
            throw LLMProviderError.notConfigured("No OpenAI API key is configured.")
        }
        return ResponsesAPIClient.Credentials(bearer: key, planToken: false)
    }

    public func availableModels() async throws -> [LLMModel] {
        let credentials = try credentials()
        let chatLike = try await client.listModels(credentials: credentials).filter { entry in
            let name = entry.id.lowercased()
            let excluded = ["embedding", "tts", "whisper", "transcribe", "dall-e", "image", "moderation", "realtime", "audio", "search", "davinci", "babbage"]
            return (name.hasPrefix("gpt-") || name.hasPrefix("o") && name.dropFirst().first?.isNumber == true
                || name.hasPrefix("chatgpt")) && !excluded.contains { name.contains($0) }
        }
        return chatLike.map { LLMModel(id: $0.id, displayName: $0.displayName, tier: ModelTiering.tier(for: $0.id)) }
            .sorted { $0.id > $1.id }
    }

    public func complete(_ request: LLMRequest) async throws -> LLMCompletion { try await completeByStreaming(request) }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
        do {
            return client.stream(request, credentials: try credentials())
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
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
    private let supportsTools: Bool

    public init(baseURL: URL, apiKey: String? = nil, displayName: String? = nil, supportsTools: Bool = true) {
        self.baseURL = baseURL
        let host = baseURL.host?.lowercased() ?? ""
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        self.isRemote = !local
        self.mayIncurCharges = !local
        self.displayName = displayName ?? (local ? "Local model (\(host):\(baseURL.port ?? 80))" : host)
        self.client = ChatCompletionsClient(baseURL: baseURL, apiKey: apiKey)
        self.supportsTools = supportsTools
        self.capabilities = supportsTools ? [.nativeTools, .streaming] : [.streaming]
    }

    public func availableModels() async throws -> [LLMModel] {
        try await client.listModels().filter { id in
            let name = id.lowercased()
            return !["embed", "nomic", "bge-", "minilm", "rerank", "whisper", "tts", "moderation", "clip"].contains { name.contains($0) }
        }.map { LLMModel(id: $0, tier: ModelTiering.tier(for: $0)) }
    }

    public func complete(_ request: LLMRequest) async throws -> LLMCompletion {
        try await client.complete(request, supportsTools: supportsTools)
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
        client.stream(request, supportsTools: supportsTools)
    }
}
