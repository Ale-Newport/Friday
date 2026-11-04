import CryptoKit
import Foundation
import Network
import Security
import FridayCore
import os

// MARK: - Sign in with ChatGPT (token sharing for open-source / locally hosted apps)
//
// Implements the documented flow (developers.openai.com/siwc/token-sharing-open-source):
//   1. open https://auth.openai.com/api/accounts/authorize in the browser with client_id=dynamic_agent_client
//      (first time) or the issued client id (later), PKCE S256, a loopback redirect on 127.0.0.1 with the
//      path /auth/callback, the scopes below, resource=https://api.openai.com/v1, a stable ext_agent_host_id;
//   2. receive code/state/scope/client_id on the loopback listener;
//   3. exchange the code at https://auth.openai.com/api/accounts/oauth/token (form-encoded, no secret);
//   4. validate the ID token (issuer, audience, nonce, expiry; RS256/ES256 signature against the published JWKS);
//   5. store everything in the macOS Keychain; refresh (rotating refresh token) when the access token nears expiry;
//   6. revoke the refresh token at the revocation endpoint on sign-out.
// Nothing here touches ChatGPT's browser cookies or private endpoints; inference goes to api.openai.com/v1.

public struct ChatGPTCredentials: Codable, Sendable, Equatable {
    public var email: String?
    public var subject: String
    public var issuer: String
    public var clientID: String
    public var hostID: String
    public var idToken: String?
    public var idTokenSignatureVerified: Bool
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var scopes: [String]
    public var savedAt: Date

    public var planUsageGranted: Bool { scopes.contains("chatgpt.tokens.use.direct") }
    public var isAccessTokenFresh: Bool { expiresAt.timeIntervalSinceNow > 120 }
}

public enum ChatGPTAuthError: Error, Sendable, Equatable, LocalizedError {
    case stateMismatch
    case accessDenied
    case callbackMissingCode
    case clientIDMismatch
    case tokenExchangeFailed(String)
    case idTokenInvalid(String)
    case refreshFailed(code: String, message: String)
    case notSignedIn
    case listenerFailed(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .stateMismatch: return "The sign-in response did not match this request."
        case .accessDenied: return "Sign-in was cancelled."
        case .callbackMissingCode: return "The sign-in response had no authorization code."
        case .clientIDMismatch: return "The sign-in response came from a different client registration."
        case .tokenExchangeFailed(let m): return "Could not exchange the sign-in code: \(m)"
        case .idTokenInvalid(let m): return "The ID token was rejected: \(m)"
        case .refreshFailed(let code, let message): return "Could not refresh the ChatGPT session (\(code)): \(message)"
        case .notSignedIn: return "Not signed in with ChatGPT."
        case .listenerFailed(let m): return "Could not open the local sign-in listener: \(m)"
        case .timedOut: return "Sign-in timed out."
        }
    }

    /// Refresh errors after which the only fix is to sign in again.
    public static let reauthenticationCodes: Set<String> = [
        "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated",
        "refresh_token_reused",
    ]
}

public actor ChatGPTAuthService {
    public static let authorizeURL = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    public static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    public static let openIDConfigurationURL = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
    public static let issuer = "https://auth.openai.com"
    public static let resource = "https://api.openai.com/v1"
    public static let scopes = ["openid", "profile", "email", "offline_access", "resource.invoke", "chatgpt.tokens.use.direct"]
    public static let callbackPath = "/auth/callback"
    public static let dynamicClientID = "dynamic_agent_client"
    static let credentialsAccount = "chatgpt.credentials.v1"
    static let hostIDKey = "friday.chatgpt.hostID"
    static let clientIDKey = "friday.chatgpt.clientID"
    static let logger = Logger(subsystem: "com.alejandro.friday", category: "chatgpt-auth")

    private let secrets: any SecretStoring
    private let defaults: UserDefaults
    private let appName: String
    private let session: URLSession
    private var cached: ChatGPTCredentials?
    private var refreshTask: Task<ChatGPTCredentials, any Error>?

    public init(secrets: any SecretStoring, defaults: UserDefaults = .standard, appName: String = "Friday") {
        self.secrets = secrets
        self.defaults = defaults
        self.appName = appName
        self.session = ModelSessions.make(timeout: 30)
    }

    // MARK: Stored state

    /// A stable, opaque identifier of this Mac for OpenAI's host accounting (`urn:uuid:…`), created once.
    public func hostID() -> String {
        if let existing = defaults.string(forKey: Self.hostIDKey) { return existing }
        let created = "urn:uuid:" + UUID().uuidString.lowercased()
        defaults.set(created, forKey: Self.hostIDKey)
        return created
    }

    /// The client id issued at the first registration, kept across sign-outs (revocation does not delete it).
    public func savedClientID() -> String? { defaults.string(forKey: Self.clientIDKey) }

    public func credentials() -> ChatGPTCredentials? {
        if let cached { return cached }
        guard let json = try? secrets.secret(for: Self.credentialsAccount), let data = json.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(ChatGPTCredentials.self, from: data)
        else { return nil }
        cached = decoded
        return decoded
    }

    private func store(_ credentials: ChatGPTCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        try secrets.set(String(decoding: data, as: UTF8.self), for: Self.credentialsAccount)
        defaults.set(credentials.clientID, forKey: Self.clientIDKey)
        cached = credentials
    }

    public var isSignedIn: Bool { credentials() != nil }

    // MARK: Sign in

    /// Runs the whole browser flow. `openBrowser` is called once with the authorization URL; the method returns when
    /// the browser has redirected to the loopback listener and the code has been exchanged.
    public func signIn(openBrowser: @Sendable (URL) -> Void, timeout: Duration = .seconds(600)) async throws -> ChatGPTCredentials {
        let verifier = PKCE.verifier()
        let challenge = PKCE.challenge(for: verifier)
        let state = PKCE.random(32)
        let nonce = PKCE.random(32)
        let existingClientID = savedClientID()
        let previous = credentials()

        let listener = try LoopbackListener(path: Self.callbackPath)
        let port = try await listener.start()
        let redirectURI = "http://127.0.0.1:\(port)\(Self.callbackPath)"

        var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "client_id", value: existingClientID ?? Self.dynamicClientID),
            URLQueryItem(name: "ext_agent_host_id", value: hostID()),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "resource", value: Self.resource),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
        ]
        if existingClientID == nil {
            items.append(URLQueryItem(name: "agent_name_hint", value: appName))
        } else {
            if let idToken = previous?.idToken { items.append(URLQueryItem(name: "id_token_hint", value: idToken)) }
            if let email = previous?.email { items.append(URLQueryItem(name: "login_hint", value: email)) }
        }
        components.queryItems = items
        // `+` must not be used for spaces in OAuth query values; percent-encode explicitly.
        components.percentEncodedQuery = items.map { item in
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            let value = item.value?.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(item.name)=\(value)"
        }.joined(separator: "&")
        guard let url = components.url else { throw ChatGPTAuthError.listenerFailed("bad authorize URL") }
        Self.logger.info("Opening the ChatGPT sign-in page (client \(existingClientID == nil ? "new" : "saved", privacy: .public))")
        openBrowser(url)

        let callback: [String: String]
        do {
            callback = try await listener.waitForCallback(timeout: timeout)
        } catch {
            await listener.stop()
            throw error
        }
        await listener.stop()

        guard callback["state"] == state else { throw ChatGPTAuthError.stateMismatch }
        if callback["error"] == "access_denied" { throw ChatGPTAuthError.accessDenied }
        if let error = callback["error"] { throw ChatGPTAuthError.tokenExchangeFailed(error + ": " + (callback["error_description"] ?? "")) }
        guard let code = callback["code"] else { throw ChatGPTAuthError.callbackMissingCode }
        let clientID: String
        if let issued = callback["client_id"] {
            if let existingClientID, issued != existingClientID { throw ChatGPTAuthError.clientIDMismatch }
            clientID = issued
        } else if let existingClientID {
            clientID = existingClientID
        } else {
            throw ChatGPTAuthError.tokenExchangeFailed("the registration did not return a client id")
        }

        let token = try await exchange(
            form: [
                "grant_type": "authorization_code", "client_id": clientID, "code": code, "code_verifier": verifier,
                "redirect_uri": redirectURI, "resource": Self.resource,
            ])
        let claims = try await validateIDToken(token.idToken, clientID: clientID, nonce: nonce)
        let scopes = (token.scope ?? callback["scope"] ?? "").split(separator: " ").map(String.init)
        let credentials = ChatGPTCredentials(
            email: claims.email, subject: claims.subject, issuer: Self.issuer, clientID: clientID, hostID: hostID(),
            idToken: token.idToken, idTokenSignatureVerified: claims.signatureVerified, accessToken: token.accessToken,
            refreshToken: token.refreshToken, expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn ?? 3600)),
            scopes: scopes, savedAt: Date())
        try store(credentials)
        Self.logger.info("Signed in with ChatGPT (plan usage \(credentials.planUsageGranted ? "granted" : "not granted", privacy: .public))")
        return credentials
    }

    // MARK: Tokens

    /// A valid access token, refreshing first when the stored one is near expiry. Refreshes are serialised.
    public func validAccessToken() async throws -> String {
        guard let current = credentials() else { throw ChatGPTAuthError.notSignedIn }
        if current.isAccessTokenFresh { return current.accessToken }
        return try await refresh().accessToken
    }

    public func refresh() async throws -> ChatGPTCredentials {
        if let running = refreshTask { return try await running.value }
        let task = Task<ChatGPTCredentials, any Error> { [self] in
            guard let current = credentials() else { throw ChatGPTAuthError.notSignedIn }
            guard let refreshToken = current.refreshToken else {
                throw ChatGPTAuthError.refreshFailed(code: "no_refresh_token", message: "No refresh token was granted.")
            }
            let token: TokenResponse
            do {
                token = try await exchange(
                    form: [
                        "grant_type": "refresh_token", "client_id": current.clientID, "refresh_token": refreshToken,
                        "resource": Self.resource,
                    ])
            } catch ChatGPTAuthError.tokenExchangeFailed(let detail) {
                let code = detail.split(separator: ":").first.map(String.init) ?? "refresh_failed"
                if ChatGPTAuthError.reauthenticationCodes.contains(code) {
                    // Terminal: the tokens are unusable. Clear them (the client id survives).
                    var cleared = current
                    cleared.accessToken = ""
                    cleared.refreshToken = nil
                    cleared.expiresAt = .distantPast
                    try? secrets.removeSecret(for: Self.credentialsAccount)
                    cached = nil
                }
                throw ChatGPTAuthError.refreshFailed(code: code, message: detail)
            }
            var updated = current
            updated.accessToken = token.accessToken
            updated.refreshToken = token.refreshToken ?? refreshToken
            updated.expiresAt = Date().addingTimeInterval(TimeInterval(token.expiresIn ?? 3600))
            if let scope = token.scope { updated.scopes = scope.split(separator: " ").map(String.init) }
            if let idToken = token.idToken { updated.idToken = idToken }
            updated.savedAt = Date()
            try store(updated)
            return updated
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    /// Revokes the refresh token (best effort, with bounded retries) and clears local credentials.
    /// Returns `false` when the remote revocation could not be confirmed.
    @discardableResult
    public func signOut() async -> Bool {
        guard let current = credentials() else { return true }
        var confirmed = false
        if let refreshToken = current.refreshToken, let endpoint = await revocationEndpoint() {
            for attempt in 0..<3 {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = Self.formBody(["token": refreshToken, "token_type_hint": "refresh_token", "client_id": current.clientID])
                if let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse,
                    (200..<300).contains(http.statusCode)
                {
                    confirmed = true
                    break
                }
                try? await Task.sleep(for: .seconds(Double(attempt + 1)))
            }
        }
        try? secrets.removeSecret(for: Self.credentialsAccount)
        cached = nil
        Self.logger.info("Signed out of ChatGPT (revocation \(confirmed ? "confirmed" : "not confirmed", privacy: .public))")
        return confirmed
    }

    // MARK: HTTP

    struct TokenResponse: Decodable {
        var accessToken: String
        var refreshToken: String?
        var idToken: String?
        var tokenType: String?
        var expiresIn: Int?
        var scope: String?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token", idToken = "id_token", tokenType = "token_type"
            case expiresIn = "expires_in", scope
        }
    }

    private func exchange(form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formBody(form)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatGPTAuthError.tokenExchangeFailed("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            var code = "http_\(http.statusCode)"
            var message = String(data: data.prefix(500), encoding: .utf8) ?? ""
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                code = json["error"] as? String ?? (json["error"] as? [String: Any])?["code"] as? String ?? code
                message = json["error_description"] as? String ?? (json["error"] as? [String: Any])?["message"] as? String ?? message
            }
            throw ChatGPTAuthError.tokenExchangeFailed("\(code): \(message)")
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw ChatGPTAuthError.tokenExchangeFailed("unreadable token response")
        }
    }

    static func formBody(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(
            fields.sorted { $0.key < $1.key }.map { key, value in
                key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
            }.joined(separator: "&").utf8)
    }

    private var openIDConfiguration: [String: Any]?

    private func loadOpenIDConfiguration() async -> [String: Any]? {
        if let openIDConfiguration { return openIDConfiguration }
        guard let (data, _) = try? await session.data(from: Self.openIDConfigurationURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        openIDConfiguration = json
        return json
    }

    private func revocationEndpoint() async -> URL? {
        guard let configuration = await loadOpenIDConfiguration(), let raw = configuration["revocation_endpoint"] as? String,
            let url = URL(string: raw), url.scheme == "https", url.host?.hasSuffix("openai.com") == true
        else { return nil }
        return url
    }

    // MARK: ID token validation

    struct IDTokenClaims { var subject: String; var email: String?; var signatureVerified: Bool }

    private func validateIDToken(_ token: String?, clientID: String, nonce: String) async throws -> IDTokenClaims {
        guard let token else { throw ChatGPTAuthError.idTokenInvalid("missing") }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let headerData = PKCE.base64URLDecode(String(parts[0])),
            let payloadData = PKCE.base64URLDecode(String(parts[1])), let signature = PKCE.base64URLDecode(String(parts[2])),
            let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
            let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else { throw ChatGPTAuthError.idTokenInvalid("malformed") }
        guard claims["iss"] as? String == Self.issuer else { throw ChatGPTAuthError.idTokenInvalid("issuer") }
        let audience: [String] = (claims["aud"] as? [String]) ?? [(claims["aud"] as? String) ?? ""]
        guard audience.contains(clientID) else { throw ChatGPTAuthError.idTokenInvalid("audience") }
        guard claims["nonce"] as? String == nonce else { throw ChatGPTAuthError.idTokenInvalid("nonce") }
        if let exp = claims["exp"] as? Double, Date(timeIntervalSince1970: exp) < Date().addingTimeInterval(-300) {
            throw ChatGPTAuthError.idTokenInvalid("expired")
        }
        guard let subject = claims["sub"] as? String, !subject.isEmpty else { throw ChatGPTAuthError.idTokenInvalid("subject") }

        var verified = false
        if let configuration = await loadOpenIDConfiguration(), let jwksRaw = configuration["jwks_uri"] as? String,
            let jwksURL = URL(string: jwksRaw), jwksURL.scheme == "https", jwksURL.host?.hasSuffix("openai.com") == true,
            let (jwksData, _) = try? await session.data(from: jwksURL),
            let jwks = try? JSONSerialization.jsonObject(with: jwksData) as? [String: Any],
            let keys = jwks["keys"] as? [[String: Any]]
        {
            let kid = header["kid"] as? String
            let algorithm = header["alg"] as? String ?? ""
            let signedPart = Data((String(parts[0]) + "." + String(parts[1])).utf8)
            let candidates = keys.filter { kid == nil || $0["kid"] as? String == kid }
            for jwk in candidates {
                if JWTSignature.verify(jwk: jwk, algorithm: algorithm, message: signedPart, signature: signature) {
                    verified = true
                    break
                }
            }
            if !verified {
                // The keys were available and none matched: the token is not OpenAI's.
                throw ChatGPTAuthError.idTokenInvalid("signature")
            }
        } else {
            Self.logger.warning("Could not fetch OpenAI's JWKS; the ID token's claims were checked but not its signature")
        }
        return IDTokenClaims(subject: subject, email: claims["email"] as? String, signatureVerified: verified)
    }
}

// MARK: - PKCE and encoding helpers

enum PKCE {
    static func random(_ bytes: Int) -> String {
        var buffer = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buffer)
        return base64URL(Data(buffer))
    }
    static func verifier() -> String { random(64) }
    static func challenge(for verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    static func base64URLDecode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}

/// RS256 / ES256 verification with the Security framework, from a JWK.
enum JWTSignature {
    static func verify(jwk: [String: Any], algorithm: String, message: Data, signature: Data) -> Bool {
        switch (jwk["kty"] as? String, algorithm) {
        case ("RSA", "RS256"):
            guard let n = (jwk["n"] as? String).flatMap(PKCE.base64URLDecode), let e = (jwk["e"] as? String).flatMap(PKCE.base64URLDecode) else { return false }
            let der = DER.sequence([DER.integer(n), DER.integer(e)])
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            ]
            guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil) else { return false }
            return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, nil)
        case ("EC", "ES256"):
            guard let x = (jwk["x"] as? String).flatMap(PKCE.base64URLDecode), let y = (jwk["y"] as? String).flatMap(PKCE.base64URLDecode),
                signature.count == 64
            else { return false }
            var raw = Data([0x04])
            raw.append(x)
            raw.append(y)
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            ]
            guard let key = SecKeyCreateWithData(raw as CFData, attributes as CFDictionary, nil) else { return false }
            let der = DER.sequence([DER.integer(signature.prefix(32)), DER.integer(signature.suffix(32))])
            return SecKeyVerifySignature(key, .ecdsaSignatureMessageX962SHA256, message as CFData, der as CFData, nil)
        default:
            return false
        }
    }
}

enum DER {
    static func length(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 { bytes.insert(UInt8(value & 0xff), at: 0); value >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
    static func integer(_ raw: Data) -> Data {
        var body = Data(raw.drop(while: { $0 == 0 }))
        if body.isEmpty { body = Data([0]) }
        if body.first! & 0x80 != 0 { body.insert(0, at: 0) }
        return Data([0x02]) + length(body.count) + body
    }
    static func sequence(_ items: [Data]) -> Data {
        let body = items.reduce(Data(), +)
        return Data([0x30]) + length(body.count) + body
    }
}

// MARK: - Loopback HTTP listener for the OAuth redirect

/// A minimal HTTP/1.1 listener on 127.0.0.1 that accepts exactly one `GET <path>?…` request, answers with a small
/// page, and hands the query parameters back. The port is chosen by the system each time (the documented flow allows
/// the port to change between sign-ins as long as scheme, host and path stay the same).
actor LoopbackListener {
    private let path: String
    private var listener: NWListener?
    private var continuation: CheckedContinuation<[String: String], any Error>?
    private var connections: [NWConnection] = []

    init(path: String) throws {
        self.path = path
    }

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: .any)
        } catch {
            throw ChatGPTAuthError.listenerFailed(error.localizedDescription)
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.accept(connection) }
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            let box = ContinuationBox(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue { box.resume(.success(port)) } else { box.resume(.failure(ChatGPTAuthError.listenerFailed("no port"))) }
                case .failed(let error): box.resume(.failure(ChatGPTAuthError.listenerFailed(error.localizedDescription)))
                case .cancelled: box.resume(.failure(ChatGPTAuthError.listenerFailed("cancelled")))
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "friday.oauth.loopback"))
        }
    }

    func waitForCallback(timeout: Duration) async throws -> [String: String] {
        try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask { [self] in
                try await withCheckedThrowingContinuation { continuation in
                    Task { await self.setContinuation(continuation) }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ChatGPTAuthError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw ChatGPTAuthError.timedOut }
            return result
        }
    }

    private func setContinuation(_ continuation: CheckedContinuation<[String: String], any Error>) {
        self.continuation = continuation
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections { connection.cancel() }
        connections = []
        if let continuation {
            self.continuation = nil
            continuation.resume(throwing: ChatGPTAuthError.timedOut)
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: DispatchQueue(label: "friday.oauth.connection"))
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            Task { await self.handle(connection, buffer: accumulated, isComplete: isComplete, error: error) }
        }
    }

    private func handle(_ connection: NWConnection, buffer: Data, isComplete: Bool, error: NWError?) {
        guard error == nil else { connection.cancel(); return }
        if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) ?? (isComplete ? buffer.endIndex..<buffer.endIndex : nil) {
            let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
            let requestLine = head.split(separator: "\r\n").first.map(String.init) ?? ""
            let components = requestLine.split(separator: " ")
            guard components.count >= 2, components[0] == "GET" else {
                respond(connection, status: "405 Method Not Allowed", body: "Method not allowed.")
                return
            }
            let target = String(components[1])
            guard let url = URLComponents(string: "http://127.0.0.1" + target), url.path == path else {
                respond(connection, status: "404 Not Found", body: "Not found.")
                return
            }
            var query: [String: String] = [:]
            for item in url.queryItems ?? [] { query[item.name] = item.value ?? "" }
            let success = query["error"] == nil && query["code"] != nil
            respond(
                connection, status: "200 OK",
                body: success
                    ? "<h2>Friday is connected to ChatGPT.</h2><p>You can close this window and return to Friday.</p>"
                    : "<h2>Sign-in was not completed.</h2><p>You can close this window and try again from Friday.</p>")
            if let continuation {
                self.continuation = nil
                continuation.resume(returning: query)
            }
        } else if buffer.count > 65_536 {
            connection.cancel()
        } else {
            receive(connection, buffer: buffer)
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let html = "<!doctype html><html><head><meta charset=\"utf-8\"><title>Friday</title><style>body{font-family:-apple-system,system-ui;margin:48px;color:#222}</style></head><body>\(body)</body></html>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n" + html
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Lets a non-reentrant callback resume a continuation at most once.
final class ContinuationBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    init(_ continuation: CheckedContinuation<T, any Error>) { self.continuation = continuation }
    func resume(_ result: Result<T, any Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
