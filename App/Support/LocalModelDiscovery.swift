import Foundation

/// Finds language-model servers running on this Mac so a person who installed Ollama or LM Studio gets a working
/// local model without typing an endpoint: Ollama answers `GET /api/version` and lists models at `/api/tags`;
/// LM Studio (and anything OpenAI-compatible on its port) lists them at `/v1/models`. Plain `URLSession`, two-second
/// timeouts, no retries: this runs at launch and behind a button, and a server that is not there must cost nothing.
struct LocalModelDiscovery: Sendable {
    /// A server that answered, with the endpoint Friday's compatible provider should use.
    struct Server: Sendable, Equatable, Identifiable {
        enum Kind: String, Sendable { case ollama, lmStudio }
        let kind: Kind
        /// The OpenAI-compatible base URL (`…/v1`).
        let endpoint: String
        let version: String?
        /// Chat-capable model ids, as the server names them (embedding, speech and reranking models are left out).
        let models: [String]
        var id: String { endpoint }
        var displayName: String { kind == .ollama ? "Ollama" : "LM Studio" }
    }

    static let ollamaRoot = "http://127.0.0.1:11434"
    static let lmStudioRoot = "http://127.0.0.1:1234"

    var timeout: TimeInterval = 2
    var ollamaRoot = LocalModelDiscovery.ollamaRoot
    var lmStudioRoot = LocalModelDiscovery.lmStudioRoot

    /// Probes both servers concurrently. Servers that answer come back in a stable order (Ollama first).
    func probe() async -> [Server] {
        async let ollama = probeOllama()
        async let lmStudio = probeLMStudio()
        return [await ollama, await lmStudio].compactMap { $0 }
    }

    func probeOllama() async -> Server? {
        guard let version = await json(ollamaRoot + "/api/version"), let number = version["version"] as? String else { return nil }
        let tags = await json(ollamaRoot + "/api/tags")
        let names = ((tags?["models"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String ?? $0["model"] as? String }
        return Server(kind: .ollama, endpoint: ollamaRoot + "/v1", version: number, models: Self.chatCapable(names))
    }

    func probeLMStudio() async -> Server? {
        guard let listing = await json(lmStudioRoot + "/v1/models") else { return nil }
        let ids = ((listing["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        return Server(kind: .lmStudio, endpoint: lmStudioRoot + "/v1", version: nil, models: Self.chatCapable(ids))
    }

    /// The same exclusions Friday's compatible provider applies when it lists models.
    static func chatCapable(_ ids: [String]) -> [String] {
        let excluded = ["embed", "nomic", "bge-", "minilm", "rerank", "whisper", "tts", "moderation", "clip"]
        return ids.filter { id in
            let name = id.lowercased()
            return !excluded.contains { name.contains($0) }
        }
    }

    private func json(_ url: String) async -> [String: Any]? {
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await Self.session.data(for: request), let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 4
        return URLSession(configuration: configuration)
    }()
}
