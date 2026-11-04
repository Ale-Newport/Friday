import Foundation
import FridayCore

/// Typed HTTP client for the sidecar's local API (bearer-authenticated, loopback only).
public struct SidecarClient: Sendable {
    public let endpoint: SidecarEndpoint
    private let session: URLSession

    public init(endpoint: SidecarEndpoint) {
        self.endpoint = endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: configuration)
    }

    // MARK: Generic

    public func request(_ method: String, _ path: String, body: JSONValue? = nil, timeout: TimeInterval = 120) async throws -> JSONValue {
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer " + endpoint.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SidecarError.invalidResponse("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            var code: String?
            var message = String(data: data.prefix(1000), encoding: .utf8) ?? ""
            if let json = try? JSONDecoder().decode(JSONValue.self, from: data), let error = json["error"] {
                code = error["code"]?.stringValue
                message = error["message"]?.stringValue ?? message
            }
            throw SidecarError.http(status: http.statusCode, code: code, message: message)
        }
        if data.isEmpty { return .null }
        do { return try JSONDecoder().decode(JSONValue.self, from: data) } catch { throw SidecarError.invalidResponse("not JSON") }
    }

    public func get(_ path: String, timeout: TimeInterval = 30) async throws -> JSONValue { try await request("GET", path, timeout: timeout) }
    public func post(_ path: String, _ body: JSONValue? = nil, timeout: TimeInterval = 120) async throws -> JSONValue {
        try await request("POST", path, body: body, timeout: timeout)
    }
    public func put(_ path: String, _ body: JSONValue, timeout: TimeInterval = 30) async throws -> JSONValue {
        try await request("PUT", path, body: body, timeout: timeout)
    }
    public func delete(_ path: String) async throws -> JSONValue { try await request("DELETE", path) }

    /// Raw bytes upload (used by the optional speech-to-text endpoint).
    public func postBytes(_ path: String, data: Data, contentType: String = "application/octet-stream", query: [String: String] = [:], timeout: TimeInterval = 120) async throws -> JSONValue {
        var components = URLComponents(url: endpoint.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer " + endpoint.token, forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (bytes, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SidecarError.invalidResponse("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let json = try? JSONDecoder().decode(JSONValue.self, from: bytes)
            throw SidecarError.http(status: http.statusCode, code: json?["error"]?["code"]?.stringValue, message: json?["error"]?["message"]?.stringValue ?? "")
        }
        return try JSONDecoder().decode(JSONValue.self, from: bytes)
    }

    // MARK: Health and status

    public func health() async throws -> Bool {
        let value = try await get("health", timeout: 5)
        return value["status"]?.stringValue == "ready"
    }

    public func status() async throws -> JSONValue { try await get("api/status") }
    public func layaStatus() async throws -> JSONValue { try await get("api/laya/status") }
    public func loadLaya() async throws -> JSONValue { try await post("api/laya/load", timeout: 180) }
    public func chromeStatus() async throws -> JSONValue { try await get("api/chrome/status") }

    // MARK: Events (WebSocket)

    /// The sidecar's event stream (`/api/events`), decoded as JSON envelopes. Ends when the socket closes.
    public func events() -> AsyncThrowingStream<JSONValue, any Error> {
        AsyncThrowingStream { continuation in
            var components = URLComponents(url: endpoint.baseURL.appendingPathComponent("api/events"), resolvingAgainstBaseURL: false)!
            components.scheme = "ws"
            var request = URLRequest(url: components.url!)
            request.setValue("jarvis.v1, bearer.\(endpoint.token)", forHTTPHeaderField: "Sec-WebSocket-Protocol")
            let task = session.webSocketTask(with: request)
            task.resume()
            let reader = Task {
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        let data: Data
                        switch message {
                        case .string(let text): data = Data(text.utf8)
                        case .data(let bytes): data = bytes
                        @unknown default: continue
                        }
                        if let value = try? JSONDecoder().decode(JSONValue.self, from: data) { continuation.yield(value) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                reader.cancel()
                task.cancel(with: .normalClosure, reason: nil)
            }
        }
    }
}
