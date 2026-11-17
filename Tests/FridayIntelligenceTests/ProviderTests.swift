import Foundation
import Testing
import FridayCore
@testable import FridayIntelligence

// MARK: - Fakes

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URL?
    func set(_ url: URL) { lock.withLock { value = url } }
    var url: URL? { lock.withLock { value } }
}

/// A provider whose every call runs `outcome`.
private struct OutcomeProvider: LLMProvider {
    let id: String
    var displayName: String { id }
    let isRemote = true
    let mayIncurCharges = false
    let capabilities: Set<LLMCapability> = [.nativeTools, .streaming]
    let calls = Counter()
    let outcome: @Sendable () throws -> LLMCompletion

    func availableModels() async throws -> [LLMModel] { [LLMModel(id: "\(id)-model", tier: .capable)] }

    func complete(_ request: LLMRequest) async throws -> LLMCompletion {
        calls.increment()
        return try outcome()
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            calls.increment()
            do {
                continuation.yield(.completed(try outcome()))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "friday.tests.\(UUID().uuidString)")! }

private func registry(order: [String], providers: [String: any LLMProvider], configure: (inout IntelligenceSettings) -> Void = { _ in })
    -> ProviderRegistry
{
    var settings = IntelligenceSettings()
    settings.fallbackOrder = order
    settings.allowPaidFallback = true
    configure(&settings)
    let frozen = settings
    let secrets = InMemorySecretStore()
    let auth = ChatGPTAuthService(secrets: secrets, defaults: freshDefaults())
    return ProviderRegistry(auth: auth, secrets: secrets, settings: { frozen }, providerOverride: { id, _ in providers[id] })
}

private func ask(_ registry: ProviderRegistry) async throws -> LLMCompletion {
    try await registry.withFallback(.planning) { resolved in
        try await resolved.provider.complete(LLMRequest(model: resolved.model, instructions: "", messages: [.user("hi")]))
    }
}

private func queryItems(of url: URL) -> [String: String] {
    var items: [String: String] = [:]
    for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { items[item.name] = item.value ?? "" }
    return items
}

private func get(_ url: URL) async throws -> (status: Int, body: String) {
    let session = URLSession(configuration: .ephemeral)
    defer { session.finishTasksAndInvalidate() }
    let (data, response) = try await session.data(from: url)
    return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
}

/// Polls until the sign-in flow has handed the authorization URL to the "browser".
private func authorizationURL(_ box: URLBox) async throws -> URL {
    for _ in 0..<100 {
        if let url = box.url { return url }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw ChatGPTAuthError.listenerFailed("the browser was never opened")
}

// MARK: - Fallback chain (finding 20)

@Suite struct ProviderFallbackTests {
    @Test func transportFailureMovesToTheNextProviderAndShowsInTheStatus() async throws {
        let first = OutcomeProvider(id: "compatible") { throw URLError(.cannotConnectToHost) }
        let second = OutcomeProvider(id: "apple") { LLMCompletion(text: "ok") }
        let registry = registry(order: ["compatible", "apple"], providers: ["compatible": first, "apple": second])
        let result = try await ask(registry)
        #expect(result.text == "ok")
        #expect(first.calls.count == 1)
        #expect(second.calls.count == 1)
        let status = await registry.statuses().first { $0.id == "compatible" }
        #expect(status?.detail.en.contains(" — ") == true)
        #expect(status?.detail.en.contains("Could not reach") == true)
        #expect(status?.detail.es.contains("No se pudo conectar") == true)
    }

    @Test func exhaustedChainThrowsATypedBilingualError() async {
        let first = OutcomeProvider(id: "compatible") { throw URLError(.notConnectedToInternet) }
        let second = OutcomeProvider(id: "apple") { throw URLError(.timedOut) }
        let registry = registry(order: ["compatible", "apple"], providers: ["compatible": first, "apple": second])
        do {
            _ = try await ask(registry)
            Issue.record("expected a failure")
        } catch let error as LLMProviderError {
            guard case .temporarilyUnavailable(let text) = error else { Issue.record("expected temporarilyUnavailable, got \(error)"); return }
            #expect(text.en.contains("did not answer in time"))
            #expect(text.es.contains("no respondió a tiempo"))
            #expect(error.isRetryableElsewhere)
        } catch {
            Issue.record("expected an LLMProviderError, got \(error)")
        }
    }

    @Test func cancellationIsNeverRetriedElsewhere() async {
        let first = OutcomeProvider(id: "compatible") { throw URLError(.cancelled) }
        let second = OutcomeProvider(id: "apple") { LLMCompletion(text: "late") }
        let registry = registry(order: ["compatible", "apple"], providers: ["compatible": first, "apple": second])
        await #expect(throws: CancellationError.self) { try await ask(registry) }
        #expect(second.calls.count == 0)
    }

    @Test func nonRetryableTypedErrorsPropagateAtOnce() async {
        let first = OutcomeProvider(id: "compatible") { throw LLMProviderError.invalidResponse("garbled") }
        let second = OutcomeProvider(id: "apple") { LLMCompletion(text: "late") }
        let registry = registry(order: ["compatible", "apple"], providers: ["compatible": first, "apple": second])
        do {
            _ = try await ask(registry)
            Issue.record("expected a failure")
        } catch let error as LLMProviderError {
            #expect(error == .invalidResponse("garbled"))
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(second.calls.count == 0)
    }

    @Test func signInFailuresMoveOnLikeAnyOtherRetryableError() async throws {
        let first = OutcomeProvider(id: "chatgpt") { throw ChatGPTAuthError.refreshFailed(code: "invalid_grant", message: "invalid_grant: expired") }
        let second = OutcomeProvider(id: "apple") { LLMCompletion(text: "local") }
        let registry = registry(order: ["chatgpt", "apple"], providers: ["chatgpt": first, "apple": second])
        #expect(try await ask(registry).text == "local")
    }

    @Test func unreachableAutomaticCompatibleServerIsReportedNotSilentlySkipped() async {
        // No override: the real CompatibleProvider against a port nothing listens on, with the model left on "Automatic".
        let registry = registry(order: ["compatible"], providers: [:]) { settings in
            settings.compatibleEnabled = true
            settings.compatibleEndpoint = "http://127.0.0.1:1/v1"
            settings.compatibleModel = ""
            settings.chatGPTEnabled = false
            settings.appleOnDeviceEnabled = false
        }
        #expect(await registry.candidates(for: .planning).isEmpty)
        let status = await registry.statuses().first { $0.id == "compatible" }
        #expect(status?.enabled == true)
        #expect(status?.configured == false)
        #expect(status?.detail.en.hasPrefix("http://127.0.0.1:1/v1 — ") == true)
        #expect(status?.detail.es != status?.detail.en)
    }
}

// MARK: - Error vocabulary

@Suite struct ProviderErrorMappingTests {
    @Test func transportErrorsBecomeTemporarilyUnavailable() {
        for code in [URLError.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .timedOut, .secureConnectionFailed, .unknown] {
            let mapped = LLMProviderError.wrapping(URLError(code))
            guard let typed = mapped as? LLMProviderError, case .temporarilyUnavailable = typed else {
                Issue.record("\(code) mapped to \(mapped)")
                continue
            }
            #expect(typed.isRetryableElsewhere)
        }
        #expect(LLMProviderError.wrapping(URLError(.cancelled)) is CancellationError)
        #expect(LLMProviderError.wrapping(CancellationError()) is CancellationError)
        let passthrough = LLMProviderError.wrapping(LLMProviderError.responseTooLarge) as? LLMProviderError
        #expect(passthrough == .responseTooLarge)
        if case .invalidResponse = LLMProviderError.wrapping(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x"))) as? LLMProviderError {} else {
            Issue.record("unknown errors become invalidResponse")
        }
    }

    @Test func authErrorsMapByDocumentedCode() {
        if case .authenticationRequired = ChatGPTAuthError.refreshFailed(code: "invalid_grant", message: "").providerError {} else { Issue.record("invalid_grant") }
        if case .authenticationRequired = ChatGPTAuthError.refreshFailed(code: "refresh_token_reused", message: "").providerError {} else { Issue.record("reused") }
        if case .notConfigured = ChatGPTAuthError.refreshFailed(code: "invalid_client", message: "").providerError {} else { Issue.record("invalid_client") }
        if case .temporarilyUnavailable = ChatGPTAuthError.refreshFailed(code: "http_503", message: "").providerError {} else { Issue.record("http_503") }
        if case .temporarilyUnavailable = ChatGPTAuthError.network("offline").providerError {} else { Issue.record("network") }
        if case .notConfigured = ChatGPTAuthError.notSignedIn.providerError {} else { Issue.record("notSignedIn") }
        #expect(ChatGPTAuthError.refreshFailed(code: "invalid_grant", message: "").requiresSignIn)
        #expect(!ChatGPTAuthError.network("x").requiresSignIn)
        #expect(!ChatGPTAuthError.refreshFailed(code: "http_503", message: "").requiresSignIn)
    }

    @Test func everyFixedMessageExistsInBothLanguages() {
        let provider: [LLMProviderError] = [
            .responseTooLarge, .cancelled, .http(status: 418, code: nil, message: ""),
            LLMProviderError.transport(URLError(.notConnectedToInternet)), LLMProviderError.transport(URLError(.timedOut)),
            HTTPErrorMapper.classify(status: 403, code: "subscription_sharing_user_not_eligible", message: ""),
            HTTPErrorMapper.classify(status: 429, code: "subscription_sharing_usage_limit_exceeded", message: ""),
            HTTPErrorMapper.classify(status: 503, code: "subscription_sharing_usage_unavailable", message: ""),
            HTTPErrorMapper.classify(status: 401, code: nil, message: ""),
            HTTPErrorMapper.classify(status: 503, code: nil, message: ""),
            ChatGPTAuthError.notSignedIn.providerError,
        ]
        for error in provider {
            #expect(!error.message(for: .en).isEmpty)
            #expect(error.message(for: .en) != error.message(for: .es), "\(error)")
            #expect(error.errorDescription == error.message(for: .en))
        }
        let auth: [ChatGPTAuthError] = [
            .stateMismatch, .accessDenied, .callbackMissingCode, .clientIDMismatch, .identityMismatch, .tokenExchangeFailed("x"),
            .idTokenInvalid("nonce"), .refreshFailed(code: "c", message: "m"), .notSignedIn, .listenerFailed("x"), .timedOut, .network("x"),
        ]
        for error in auth {
            #expect(error.message(for: .en) != error.message(for: .es), "\(error)")
            #expect(ProviderErrorText.message(for: error, language: .es) == error.message(for: .es))
        }
        #expect(ProviderErrorText.message(for: CancellationError(), language: .es) == "Cancelado.")
        #expect(ProviderErrorText.message(for: URLError(.notConnectedToInternet), language: .es) == "No hay conexión a internet.")
    }
}

// MARK: - HTTP error bodies

@Suite struct HTTPErrorMapperTests {
    @Test func ollamaNativeErrorShapeIsParsed() {
        let body = #"{"error":"model 'nope' not found, try pulling it first"}"#.data(using: .utf8)!
        #expect(HTTPErrorMapper.error(status: 404, body: body) == .http(status: 404, code: nil, message: "model 'nope' not found, try pulling it first"))
    }

    @Test func htmlBodiesAreNotRepeatedToTheUser() {
        let body = "<html><head><title>502</title></head><body><h1>502 Bad Gateway</h1><p>nginx</p></body></html>".data(using: .utf8)!
        let error = HTTPErrorMapper.error(status: 502, body: body)
        #expect(error == HTTPErrorMapper.classify(status: 502, code: nil, message: ""))
        #expect(error.message(for: .en) == "The model service is unavailable.")
        #expect(!error.message(for: .es).contains("<"))
    }

    @Test func longMessagesAreCutToOneShortLine() {
        let long = String(repeating: "word ", count: 100) + "<b>tag</b>\nsecond line"
        let body = try! JSONSerialization.data(withJSONObject: ["error": ["message": long, "code": "x"]])
        guard case .http(_, _, let message) = HTTPErrorMapper.error(status: 400, body: body) else { Issue.record("expected http"); return }
        #expect(message.count <= HTTPErrorMapper.summaryLimit)
        #expect(!message.contains("\n"))
        #expect(!message.contains("<"))
        #expect(message.hasSuffix("…"))
        #expect(HTTPErrorMapper.summary("  a\n\n b   c ") == "a b c")
    }

    @Test func directAdmissionDetailIsUsed() {
        let body = #"{"detail":"Direct routing unavailable"}"#.data(using: .utf8)!
        #expect(HTTPErrorMapper.error(status: 503, body: body) == .temporarilyUnavailable("Direct routing unavailable"))
    }

    @Test func notEligibleIsExplainedNotTreatedAsAuthentication() {
        let body = #"{"error":{"code":"subscription_sharing_user_not_eligible","message":"not eligible"}}"#.data(using: .utf8)!
        let error = HTTPErrorMapper.error(status: 403, body: body)
        guard case .notEligible(let text) = error else { Issue.record("expected notEligible, got \(error)"); return }
        #expect(error.isRetryableElsewhere, "another provider may still answer")
        #expect(text.es.contains("no puede compartir"))
    }

    @Test func rejectedCredentialsAreAnAuthenticationFailure() {
        let body = #"{"error":{"code":"subscription_sharing_invalid_user","message":"x"}}"#.data(using: .utf8)!
        if case .authenticationRequired = HTTPErrorMapper.error(status: 401, body: body) {} else { Issue.record("expected auth") }
        if case .http(403, "chatpass_v2_scope_not_authorized", _) = HTTPErrorMapper.classify(status: 403, code: "chatpass_v2_scope_not_authorized", message: "m") {} else {
            Issue.record("chatpass errors are not retried anywhere")
        }
    }
}

// MARK: - Default model (finding 67)

@Suite struct DefaultModelRankingTests {
    private func models(_ ids: [String]) -> [LLMModel] { ids.map { LLMModel(id: $0, tier: ModelTiering.tier(for: $0)) } }

    @Test func automaticOpenAIChoiceIsAnEverydayModelWhateverTheOrder() {
        let listed = ["o4-mini-2025-04-16", "o4-mini", "o3-pro-2025-06-10", "o3-pro", "o3", "gpt-5.1", "gpt-4o", "gpt-4.1", "gpt-4.1-2025-04-14", "chatgpt-4o-latest", "gpt-5-pro"]
        #expect(ModelTiering.defaultCapable(from: models(listed))?.id == "gpt-5.1")
        #expect(ModelTiering.defaultCapable(from: models(listed.reversed()))?.id == "gpt-5.1")
        #expect(ModelTiering.defaultCapable(from: models(listed.sorted { $0 > $1 }))?.id == "gpt-5.1")
        #expect(ModelTiering.defaultFast(from: models(["o4-mini", "gpt-5.1-mini"]))?.id == "gpt-5.1-mini")
    }

    @Test func aliasBeatsDatedSnapshotAndProBeatsNothing() {
        #expect(ModelTiering.defaultCapable(from: models(["gpt-4.1-2025-04-14", "gpt-4.1"]))?.id == "gpt-4.1")
        #expect(ModelTiering.defaultCapable(from: models(["gpt-4.1", "gpt-4.1-2025-04-14"]))?.id == "gpt-4.1")
        #expect(ModelTiering.defaultCapable(from: models(["o3-pro", "o3"]))?.id == "o3")
        #expect(ModelTiering.defaultCapable(from: models(["o3-pro"]))?.id == "o3-pro", "the only option is still used")
    }

    @Test func tiesKeepTheProviderOrder() {
        #expect(ModelTiering.defaultCapable(from: [LLMModel(id: "b", tier: .capable), LLMModel(id: "c", tier: .capable)])?.id == "b")
        #expect(ModelTiering.defaultCapable(from: [LLMModel(id: "unknown-1"), LLMModel(id: "unknown-2")])?.id == "unknown-1")
        #expect(ModelTiering.defaultCapable(from: models(["gpt-6.1-sol", "gpt-6.1-sol-2026-01-01"]))?.id == "gpt-6.1-sol")
    }
}

// MARK: - Ollama detection (finding 68)

@Suite struct OllamaDetectionTests {
    @Test func negativeOutcomesExpireAndPositiveOnesSurvive() {
        let cache = DetectionCache(unreachableTTL: 60, otherTTL: 600)
        let t0 = Date()
        cache.record(.unreachable, for: "a", at: t0)
        #expect(cache.outcome(for: "a", now: t0.addingTimeInterval(30)) == .unreachable)
        #expect(cache.outcome(for: "a", now: t0.addingTimeInterval(61)) == nil)
        cache.record(.ollama, for: "b", at: t0)
        #expect(cache.outcome(for: "b", now: t0.addingTimeInterval(86_400 * 30)) == .ollama)
        cache.record(.other, for: "c", at: t0)
        #expect(cache.outcome(for: "c", now: t0.addingTimeInterval(599)) == .other)
        #expect(cache.outcome(for: "c", now: t0.addingTimeInterval(601)) == nil)
        cache.removeAll()
        #expect(cache.outcome(for: "b") == nil)
    }

    @Test func nothingListeningIsUnreachableNotOther() async {
        #expect(await OllamaClient.detect(at: URL(string: "http://127.0.0.1:1")!) == .unreachable)
        #expect(await OllamaClient.isOllama(at: URL(string: "http://127.0.0.1:1")!) == false)
    }
}

// MARK: - Loopback listener (finding 65)

@Suite(.serialized) struct LoopbackListenerTests {
    @Test func timeoutEndsTheWait() async throws {
        let listener = try LoopbackListener(path: "/auth/callback")
        _ = try await listener.start()
        let started = ContinuousClock.now
        await #expect(throws: ChatGPTAuthError.timedOut) { try await listener.waitForCallback(timeout: .milliseconds(200)) }
        #expect(started.duration(to: .now) < .seconds(5))
        await listener.stop()
    }

    @Test func cancellationEndsTheWait() async throws {
        let listener = try LoopbackListener(path: "/auth/callback")
        _ = try await listener.start()
        let waiting = Task { try await listener.waitForCallback(timeout: .seconds(60)) }
        try await Task.sleep(for: .milliseconds(100))
        let started = ContinuousClock.now
        waiting.cancel()
        let result = await waiting.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(started.duration(to: .now) < .seconds(5))
        await listener.stop()
    }

    @Test func stopEndsTheWait() async throws {
        let listener = try LoopbackListener(path: "/auth/callback")
        _ = try await listener.start()
        let waiting = Task { try await listener.waitForCallback(timeout: .seconds(60)) }
        try await Task.sleep(for: .milliseconds(100))
        await listener.stop()
        let result = await waiting.result
        #expect(throws: ChatGPTAuthError.timedOut) { try result.get() }
    }

    @Test func redirectIsDeliveredAndAnsweredInBothLanguages() async throws {
        let listener = try LoopbackListener(path: "/auth/callback")
        let port = try await listener.start()
        let waiting = Task { try await listener.waitForCallback(timeout: .seconds(10)) }
        let (status, body) = try await get(URL(string: "http://127.0.0.1:\(port)/auth/callback?code=abc&state=xyz&client_id=cid&scope=openid%20email")!)
        #expect(status == 200)
        #expect(body.contains("connected to ChatGPT") && body.contains("conectado a ChatGPT"))
        let query = try await waiting.value
        #expect(query == ["code": "abc", "state": "xyz", "client_id": "cid", "scope": "openid email"])
        await listener.stop()
    }

    @Test func redirectThatArrivesBeforeTheWaitIsKept() async throws {
        let listener = try LoopbackListener(path: "/auth/callback", language: .es)
        let port = try await listener.start()
        let (status, body) = try await get(URL(string: "http://127.0.0.1:\(port)/auth/callback?error=access_denied&state=s")!)
        #expect(status == 200)
        #expect(body.contains("no se completó") && !body.contains("not completed"))
        let query = try await listener.waitForCallback(timeout: .seconds(1))
        #expect(query["error"] == "access_denied")
        await listener.stop()
    }

    @Test func otherPathsAreRejectedAndDoNotEndTheWait() async throws {
        let listener = try LoopbackListener(path: "/auth/callback")
        let port = try await listener.start()
        let waiting = Task { try await listener.waitForCallback(timeout: .milliseconds(400)) }
        let (status, _) = try await get(URL(string: "http://127.0.0.1:\(port)/favicon.ico")!)
        #expect(status == 404)
        let result = await waiting.result
        #expect(throws: ChatGPTAuthError.timedOut) { try result.get() }
        await listener.stop()
    }
}

// MARK: - Sign in with ChatGPT (documented parameters and every failure path short of a real account)

@Suite(.serialized) struct SignInFlowTests {
    @Test func firstSignInRegistersWithTheDocumentedParameters() async throws {
        let auth = ChatGPTAuthService(secrets: InMemorySecretStore(), defaults: freshDefaults(), appName: "Friday")
        let request = await auth.authorizationRequest(port: 1455)
        #expect(request.isRegistration)
        #expect(request.url.host == "auth.openai.com")
        #expect(request.url.path == "/api/accounts/authorize")
        let query = queryItems(of: request.url)
        #expect(query["client_id"] == "dynamic_agent_client")
        #expect(query["ext_agent_host_id"]?.hasPrefix("urn:uuid:") == true)
        #expect(query["ext_agent_host_id"] == (await auth.hostID()), "the host id is stable")
        #expect(query["agent_name_hint"] == "Friday")
        #expect(query["response_type"] == "code")
        #expect(query["redirect_uri"] == "http://127.0.0.1:1455/auth/callback")
        #expect(query["scope"] == "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
        #expect(query["resource"] == "https://api.openai.com/v1")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["code_challenge"] == PKCE.challenge(for: request.codeVerifier))
        #expect(query["state"] == request.state && query["nonce"] == request.nonce)
        #expect(query["id_token_hint"] == nil && query["login_hint"] == nil)
        #expect(!request.url.absoluteString.contains("+"), "spaces are percent-encoded, never '+'")
    }

    @Test func returningSignInReusesTheIssuedClientIDAndHintsTheAccount() async throws {
        let defaults = freshDefaults()
        defaults.set("client_abc", forKey: ChatGPTAuthService.clientIDKey)
        let secrets = InMemorySecretStore()
        let stored = ChatGPTCredentials(
            email: "ana@example.com", subject: "user_1", issuer: ChatGPTAuthService.issuer, clientID: "client_abc", hostID: "urn:uuid:x",
            idToken: "eyJ.id.token", idTokenSignatureVerified: true, accessToken: "a", refreshToken: "r", expiresAt: .distantFuture,
            scopes: ChatGPTAuthService.scopes, savedAt: Date())
        try secrets.set(String(decoding: JSONEncoder().encode(stored), as: UTF8.self), for: ChatGPTAuthService.credentialsAccount)
        let auth = ChatGPTAuthService(secrets: secrets, defaults: defaults, appName: "Friday")
        let request = await auth.authorizationRequest(port: 2000)
        #expect(!request.isRegistration)
        let query = queryItems(of: request.url)
        #expect(query["client_id"] == "client_abc")
        #expect(query["agent_name_hint"] == nil, "only the initial registration names the app")
        #expect(query["id_token_hint"] == "eyJ.id.token")
        #expect(query["login_hint"] == "ana@example.com")
    }

    @Test func deniedConsentEndsTheFlowWithAClearBilingualError() async throws {
        let auth = ChatGPTAuthService(secrets: InMemorySecretStore(), defaults: freshDefaults())
        let browser = URLBox()
        let flow = Task { try await auth.signIn(openBrowser: { browser.set($0) }, timeout: .seconds(10)) }
        let query = queryItems(of: try await authorizationURL(browser))
        let redirect = try #require(query["redirect_uri"])
        let state = try #require(query["state"])
        let (status, _) = try await get(URL(string: "\(redirect)?error=access_denied&state=\(state)")!)
        #expect(status == 200)
        let result = await flow.result
        #expect(throws: ChatGPTAuthError.accessDenied) { try result.get() }
        #expect(ChatGPTAuthError.accessDenied.message(for: .es).contains("canceló"))
    }

    @Test func serverSideErrorsAreReportedWithTheirDescription() async throws {
        let auth = ChatGPTAuthService(secrets: InMemorySecretStore(), defaults: freshDefaults())
        let browser = URLBox()
        let flow = Task { try await auth.signIn(openBrowser: { browser.set($0) }, timeout: .seconds(10)) }
        let query = queryItems(of: try await authorizationURL(browser))
        _ = try await get(URL(string: "\(query["redirect_uri"]!)?error=server_error&error_description=boom&state=\(query["state"]!)")!)
        let result = await flow.result
        #expect(throws: ChatGPTAuthError.tokenExchangeFailed("server_error: boom")) { try result.get() }
    }

    @Test func mismatchedStateIsRejectedBeforeAnyExchange() async throws {
        let auth = ChatGPTAuthService(secrets: InMemorySecretStore(), defaults: freshDefaults())
        let browser = URLBox()
        let flow = Task { try await auth.signIn(openBrowser: { browser.set($0) }, timeout: .seconds(10)) }
        let query = queryItems(of: try await authorizationURL(browser))
        _ = try await get(URL(string: "\(query["redirect_uri"]!)?code=abc&state=not-the-one&client_id=cid")!)
        let result = await flow.result
        #expect(throws: ChatGPTAuthError.stateMismatch) { try result.get() }
        #expect(await auth.credentials() == nil)
    }

    @Test func timeoutEndsTheFlow() async throws {
        let auth = ChatGPTAuthService(secrets: InMemorySecretStore(), defaults: freshDefaults())
        let started = ContinuousClock.now
        await #expect(throws: ChatGPTAuthError.timedOut) { try await auth.signIn(openBrowser: { _ in }, timeout: .milliseconds(300)) }
        #expect(started.duration(to: .now) < .seconds(5))
    }

    @Test func cancellationEndsTheFlowAndClosesTheListener() async throws {
        let auth = ChatGPTAuthService(secrets: InMemorySecretStore(), defaults: freshDefaults())
        let browser = URLBox()
        let flow = Task { try await auth.signIn(openBrowser: { browser.set($0) }, timeout: .seconds(60)) }
        let query = queryItems(of: try await authorizationURL(browser))
        flow.cancel()
        let result = await flow.result
        #expect(throws: CancellationError.self) { try result.get() }
        // The listener is gone: nothing answers on the redirect port any more.
        await #expect(throws: URLError.self) { _ = try await get(URL(string: query["redirect_uri"]!)!) }
    }
}

@Suite struct SSELineSplittingTests {
    /// `URLSession.AsyncBytes.lines` drops empty lines, which in SSE end each event: every event of a Responses stream
    /// used to be glued into one unparseable blob ("The stream ended before the response completed").
    @Test func emptyLinesSurviveSoEventsStaySeparate() async throws {
        let raw = "event: a\r\ndata: {\"type\":\"one\"}\r\n\r\nevent: b\ndata: {\"type\":\"two\"}\n\n"
        let bytes = AsyncStream<UInt8> { continuation in
            for byte in Array(raw.utf8) { continuation.yield(byte) }
            continuation.finish()
        }
        var lines: [String] = []
        for try await line in SSEStream.lines(bytes) { lines.append(line) }
        #expect(lines == ["event: a", "data: {\"type\":\"one\"}", "", "event: b", "data: {\"type\":\"two\"}", ""])
    }
}
