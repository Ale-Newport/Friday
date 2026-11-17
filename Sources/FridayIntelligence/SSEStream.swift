import Foundation
import FridayCore
import os

/// Server-sent events over `URLSession.bytes`, with bounded buffering and cooperative cancellation.
/// Yields `(event, data)` pairs; a `data` of `[DONE]` is passed through for the caller to recognise.
/// Transport failures surface as `LLMProviderError` (see `LLMProviderError.wrapping`), never as raw `URLError`s.
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
                        throw LLMProviderError.invalidResponse(LocalizedText(en: "Not an HTTP response.", es: "La respuesta no es HTTP."))
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
                    // Lines are split here, not with `bytes.lines`: that sequence drops empty lines, and in SSE the
                    // empty line is what ends an event (every event of a stream used to arrive glued into one).
                    for try await line in Self.lines(bytes) {
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
                    continuation.finish(throwing: LLMProviderError.wrapping(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension SSEStream {
    /// The lines of a byte stream, empty ones included, without their "\n" or "\r\n".
    static func lines<Bytes: AsyncSequence & Sendable>(_ bytes: Bytes) -> AsyncThrowingStream<String, any Error> where Bytes.Element == UInt8 {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var buffer: [UInt8] = []
                    buffer.reserveCapacity(4_096)
                    for try await byte in bytes {
                        if byte == 0x0A {
                            if buffer.last == 0x0D { buffer.removeLast() }
                            continuation.yield(String(decoding: buffer, as: UTF8.self))
                            buffer.removeAll(keepingCapacity: true)
                        } else {
                            buffer.append(byte)
                        }
                    }
                    if !buffer.isEmpty {
                        if buffer.last == 0x0D { buffer.removeLast() }
                        continuation.yield(String(decoding: buffer, as: UTF8.self))
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

/// Maps HTTP failures from OpenAI-style APIs (and Ollama's native API) to typed provider errors, recognising the
/// documented ChatGPT-plan error codes so the app can react correctly (re-authenticate, pause, back off, explain).
/// Only a short, tag-free summary of the server's message reaches the user; the body itself goes to the debug log.
enum HTTPErrorMapper {
    static let logger = Logger(subsystem: "com.alejandro.friday", category: "providers")

    /// Longest server message that is repeated to the user (these are spoken aloud).
    static let summaryLimit = 160

    static func error(status: Int, body: Data) -> LLMProviderError {
        var code: String?
        var message: String?
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let error = json["error"] as? [String: Any] {
                // OpenAI: {"error":{"code":…,"type":…,"message":…}}
                code = error["code"] as? String ?? error["type"] as? String
                message = error["message"] as? String
            } else if let text = json["error"] as? String {
                // Ollama's native API: {"error":"model 'x' not found"}
                message = text
            } else if let detail = json["detail"] as? String {
                // Direct-admission failures on the plan route: {"detail":"…"} with no stable code.
                message = detail
            } else if let text = json["message"] as? String {
                message = text
            }
        } else if !body.isEmpty {
            let text = String(decoding: body.prefix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            // An HTML error page says nothing useful aloud; a plain-text body may (nginx "upstream timed out", etc.).
            message = text.hasPrefix("<") ? nil : text
        }
        if !body.isEmpty {
            logger.debug("HTTP \(status, privacy: .public) body: \(String(decoding: body.prefix(2000), as: UTF8.self), privacy: .private)")
        }
        return classify(status: status, code: code, message: summary(message))
    }

    /// One short line without markup, for the spoken message.
    static func summary(_ text: String?) -> String {
        guard let text else { return "" }
        var line = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        line = line.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        if line.count > summaryLimit {
            line = String(line.prefix(summaryLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return line
    }

    static func classify(status: Int, code: String?, message: String) -> LLMProviderError {
        switch code {
        case "subscription_sharing_usage_limit_exceeded":
            return .usageLimitExceeded(
                LocalizedText(
                    en: "Your ChatGPT plan's usage limit was reached. Check ChatGPT Settings ▸ Usage.",
                    es: "Se alcanzó el límite de uso de tu plan de ChatGPT. Revisa Ajustes de ChatGPT ▸ Uso."))
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
            return .temporarilyUnavailable(
                LocalizedText(
                    en: "ChatGPT plan usage is temporarily unavailable. Try again shortly.",
                    es: "El uso del plan de ChatGPT no está disponible temporalmente. Inténtalo de nuevo en un momento."))
        case "subscription_sharing_user_not_eligible":
            // Documented as 403, not an authentication problem: explain it, never retry here, never loop through sign-in.
            return .notEligible(
                LocalizedText(
                    en: "This ChatGPT account, workspace or plan cannot share its usage with Friday.",
                    es: "Esta cuenta, espacio de trabajo o plan de ChatGPT no puede compartir su uso con Friday."))
        case "subscription_sharing_invalid_user", "invalid_api_key", "invalid_token":
            return .authenticationRequired(
                LocalizedText(
                    en: "The model service rejected the credentials. Check the API key or sign in again.",
                    es: "El servicio del modelo rechazó las credenciales. Revisa la clave de API o vuelve a iniciar sesión."))
        case "subscription_sharing_unsupported_capability":
            let detail = message.isEmpty ? "" : ": " + message
            return .unsupportedCapability(
                LocalizedText(
                    en: "ChatGPT plan usage does not support this request" + detail + ".",
                    es: "El uso del plan de ChatGPT no admite esta petición" + detail + "."))
        case "subscription_sharing_route_not_supported", "chatpass_v2_scope_not_authorized",
            "chatpass_v2_invalid_authorization_context":
            return .http(status: status, code: code, message: message)
        default: break
        }
        switch status {
        case 401:
            return .authenticationRequired(
                message.isEmpty ? LocalizedText(en: "Authentication required.", es: "Se requiere autenticación.") : LocalizedText(message))
        case 429:
            return .usageLimitExceeded(
                message.isEmpty ? LocalizedText(en: "Rate limit reached.", es: "Se alcanzó el límite de peticiones.") : LocalizedText(message))
        case 500...599:
            return .temporarilyUnavailable(
                message.isEmpty
                    ? LocalizedText(en: "The model service is unavailable.", es: "El servicio del modelo no está disponible.")
                    : LocalizedText(message))
        default:
            return .http(status: status, code: code, message: message)
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
