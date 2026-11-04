import Foundation

/// Server-sent events over `URLSession.bytes`, with bounded buffering and cooperative cancellation.
/// Yields `(event, data)` pairs; a `data` of `[DONE]` is passed through for the caller to recognise.
enum SSEStream {
    struct Event: Sendable { var event: String?; var data: String }

    static func events(for request: URLRequest, session: URLSession, maxBytes: Int = 16 * 1_048_576)
        -> AsyncThrowingStream<Event, any Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw LLMProviderError.invalidResponse("Not an HTTP response.")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count > 262_144 { break }
                        }
                        throw HTTPErrorMapper.error(status: http.statusCode, body: body)
                    }
                    var total = 0
                    var eventName: String?
                    var dataLines: [String] = []
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        total += line.utf8.count
                        guard total <= maxBytes else { throw LLMProviderError.responseTooLarge }
                        if line.isEmpty {
                            if !dataLines.isEmpty {
                                continuation.yield(Event(event: eventName, data: dataLines.joined(separator: "\n")))
                            }
                            eventName = nil
                            dataLines = []
                            continue
                        }
                        if line.hasPrefix(":") { continue }
                        if line.hasPrefix("event:") {
                            eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            dataLines.append(String(line.dropFirst(5).drop(while: { $0 == " " })))
                        }
                    }
                    if !dataLines.isEmpty {
                        continuation.yield(Event(event: eventName, data: dataLines.joined(separator: "\n")))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Maps HTTP failures from OpenAI-style APIs to typed provider errors, recognising the documented
/// ChatGPT-plan error codes so the app can react correctly (re-authenticate, pause, back off).
enum HTTPErrorMapper {
    static func error(status: Int, body: Data) -> LLMProviderError {
        var code: String?
        var message = String(data: body.prefix(2000), encoding: .utf8) ?? ""
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let error = json["error"] as? [String: Any] {
                code = error["code"] as? String ?? error["type"] as? String
                message = error["message"] as? String ?? message
            } else if let detail = json["detail"] as? String {
                message = detail
            }
        }
        return classify(status: status, code: code, message: message)
    }

    static func classify(status: Int, code: String?, message: String) -> LLMProviderError {
        switch code {
        case "subscription_sharing_usage_limit_exceeded":
            return .usageLimitExceeded("Your ChatGPT plan's usage limit was reached. Check ChatGPT Settings ▸ Usage.")
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
            return .temporarilyUnavailable("ChatGPT plan usage is temporarily unavailable. Try again shortly.")
        case "subscription_sharing_user_not_eligible":
            return .authenticationRequired("This ChatGPT account is not eligible for plan sharing with Friday.")
        case "subscription_sharing_invalid_user", "invalid_api_key", "invalid_token":
            return .authenticationRequired("The ChatGPT credentials were rejected. Sign in again.")
        case "subscription_sharing_unsupported_capability":
            return .unsupportedCapability(message)
        case "subscription_sharing_route_not_supported", "chatpass_v2_scope_not_authorized",
            "chatpass_v2_invalid_authorization_context":
            return .http(status: status, code: code, message: message)
        default: break
        }
        switch status {
        case 401: return .authenticationRequired(message.isEmpty ? "Authentication required." : message)
        case 429: return .usageLimitExceeded(message.isEmpty ? "Rate limit reached." : message)
        case 500...599: return .temporarilyUnavailable(message.isEmpty ? "The model service is unavailable." : message)
        default: return .http(status: status, code: code, message: message)
        }
    }
}

/// Ephemeral, redirect-free session for model traffic: no cookies, cache or credentials on disk.
enum ModelSessions {
    static func make(timeout: TimeInterval = 120) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 4
        configuration.httpAdditionalHeaders = ["User-Agent": "Friday/0.1 (macOS)"]
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
