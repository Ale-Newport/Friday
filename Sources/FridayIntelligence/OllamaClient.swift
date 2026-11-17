import Foundation
import FridayCore

/// Ollama's native chat API (`POST {root}/api/chat`). Friday prefers it over Ollama's OpenAI-compatible endpoint
/// because only the native API lets the client set the context window: through `/v1` the server silently
/// truncates prompts that exceed the model's default `num_ctx` (4–8k tokens), which turns a planning request with
/// tool definitions into an empty or garbled answer. Here every request carries an explicit `num_ctx`.
public struct OllamaClient: Sendable {
    /// The server root (scheme, host, port), without `/v1`.
    public var root: URL
    public var apiKey: String?
    /// Context window requested for every chat; the model's own maximum still applies.
    public var contextTokens: Int
    private let session: URLSession

    public init(root: URL, apiKey: String? = nil, contextTokens: Int = 16_384) {
        self.root = root
        self.apiKey = apiKey
        self.contextTokens = contextTokens
        self.session = ModelSessions.make()
    }

    /// The server root for an OpenAI-compatible base URL (`http://127.0.0.1:11434/v1` → `http://127.0.0.1:11434`).
    public static func root(forCompatibleBaseURL baseURL: URL) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = ""
        components?.query = nil
        return components?.url ?? baseURL
    }

    // MARK: Detection

    /// What answered at a server root.
    public enum Detection: Sendable, Equatable {
        /// An Ollama server (`GET /api/version` returned its version).
        case ollama
        /// Something answered over HTTP, but not with Ollama's version payload (LM Studio, llama.cpp, a gateway…).
        case other
        /// Nothing answered: connection refused, no route, timeout. Worth asking again later.
        case unreachable
    }

    private static let probeSession = ModelSessions.make(timeout: 3)

    /// Probes `GET {root}/api/version` with a short timeout (this runs before the first request).
    public static func detect(at root: URL) async -> Detection {
        var request = URLRequest(url: root.appendingPathComponent("api/version"))
        request.timeoutInterval = 3
        guard let (data, response) = try? await probeSession.data(for: request), let http = response as? HTTPURLResponse else {
            return .unreachable
        }
        guard http.statusCode == 200, (try? JSONDecoder().decode(JSONValue.self, from: data))?["version"]?.stringValue != nil else {
            return .other
        }
        return .ollama
    }

    /// Whether an Ollama server answers at `root` right now.
    public static func isOllama(at root: URL) async -> Bool { await detect(at: root) == .ollama }

    // MARK: Request body

    func body(for request: LLMRequest, stream: Bool, supportsTools: Bool) -> JSONObject {
        var messages: [JSONValue] = [["role": "system", "content": .string(request.instructions)]]
        for message in request.messages {
            switch message.role {
            case .system, .developer: messages.append(["role": "system", "content": .string(message.text)])
            case .user: messages.append(["role": "user", "content": .string(message.text)])
            case .assistant:
                var object: JSONObject = ["role": "assistant", "content": .string(message.text)]
                if !message.toolCalls.isEmpty {
                    object["tool_calls"] = .array(message.toolCalls.map { call in
                        ["function": ["name": .string(call.name), "arguments": .object(call.arguments ?? [:])]]
                    })
                }
                messages.append(.object(object))
            case .tool:
                messages.append(["role": "tool", "content": .string(message.text), "tool_call_id": .string(message.toolCallID ?? "")])
            }
        }
        var options: JSONObject = ["num_ctx": .int(contextTokens)]
        if let temperature = request.temperature { options["temperature"] = .double(temperature) }
        if let max = request.maxOutputTokens { options["num_predict"] = .int(max) }
        var fields: JSONObject = [
            "model": .string(request.model), "messages": .array(messages), "stream": .bool(stream), "options": .object(options),
            "keep_alive": "30m",
            // Reasoning models (qwen3, deepseek-r1) otherwise spend their tokens on a hidden "thinking" channel and
            // return an empty content; planning wants the answer or the tool call directly.
            "think": false,
        ]
        if supportsTools, !request.tools.isEmpty {
            fields["tools"] = .array(request.tools.map {
                ["type": "function", "function": ["name": .string($0.name), "description": .string($0.description), "parameters": $0.parameters]]
            })
        }
        if request.jsonSchema != nil { fields["format"] = "json" }
        return fields
    }

    func urlRequest(_ fields: JSONObject) throws -> URLRequest {
        var request = URLRequest(url: root.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(JSONValue.object(fields))
        return request
    }

    // MARK: Calls

    /// Loads `model` into memory (an empty chat: Ollama loads and answers at once) with the same context window the
    /// real requests use — a different `num_ctx` would make the server reload the model on the first real request.
    /// Called on the wake word, so the reload of an evicted model (seconds for a 30B model) overlaps the user speaking.
    public func prewarm(model: String) async {
        let fields: JSONObject = [
            "model": .string(model), "messages": .array([]), "stream": false, "keep_alive": "30m",
            "options": .object(["num_ctx": .int(contextTokens)]),
        ]
        guard let request = try? urlRequest(fields) else { return }
        _ = try? await session.data(for: request)
    }

    public func listModels() async throws -> [String] {
        var request = URLRequest(url: root.appendingPathComponent("api/tags"))
        request.timeoutInterval = 10
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw LLMProviderError.invalidResponse(LocalizedText(en: "No HTTP response.", es: "Sin respuesta HTTP."))
            }
            guard (200..<300).contains(http.statusCode) else { throw HTTPErrorMapper.error(status: http.statusCode, body: data) }
            let json = try JSONDecoder().decode(JSONValue.self, from: data)
            return (json["models"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue ?? $0["model"]?.stringValue }
        } catch {
            throw LLMProviderError.wrapping(error)
        }
    }

    public func complete(_ request: LLMRequest, supportsTools: Bool = true) async throws -> LLMCompletion {
        var text = ""
        var calls: [LLMToolCall] = []
        var completion: LLMCompletion?
        for try await event in stream(request, supportsTools: supportsTools) {
            switch event {
            case .textDelta(let delta): text += delta
            case .toolCall(let call): calls.append(call)
            case .toolCallStarted: break
            case .completed(let final): completion = final
            }
        }
        guard let completion else { return LLMCompletion(text: text, toolCalls: calls, finishReason: calls.isEmpty ? .stop : .toolCalls) }
        return completion
    }

    public func stream(_ request: LLMRequest, supportsTools: Bool = true) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let http = try urlRequest(body(for: request, stream: true, supportsTools: supportsTools))
                    let (bytes, response) = try await session.bytes(for: http)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw LLMProviderError.invalidResponse(LocalizedText(en: "Not an HTTP response.", es: "La respuesta no es HTTP."))
                    }
                    guard (200..<300).contains(httpResponse.statusCode) else {
                        var body = Data()
                        for try await byte in bytes { body.append(byte); if body.count > 65_536 { break } }
                        throw HTTPErrorMapper.error(status: httpResponse.statusCode, body: body)
                    }
                    var text = ""
                    var calls: [LLMToolCall] = []
                    var finish: LLMCompletion.FinishReason = .stop
                    var usage: LLMUsage?
                    var model: String?
                    var total = 0
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        total += line.utf8.count
                        guard total <= 16 * 1_048_576 else { throw LLMProviderError.responseTooLarge }
                        guard let data = line.data(using: .utf8), let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { continue }
                        if let error = json["error"]?.stringValue ?? json["error"]?["message"]?.stringValue {
                            throw HTTPErrorMapper.classify(status: 400, code: nil, message: HTTPErrorMapper.summary(error))
                        }
                        model = json["model"]?.stringValue ?? model
                        if let message = json["message"] {
                            if let content = message["content"]?.stringValue, !content.isEmpty {
                                text += content
                                continuation.yield(.textDelta(content))
                            }
                            for call in message["tool_calls"]?.arrayValue ?? [] {
                                guard let function = call["function"], let name = function["name"]?.stringValue, !name.isEmpty else { continue }
                                let id = call["id"]?.stringValue ?? "call_\(calls.count + 1)"
                                let arguments: String
                                if let object = function["arguments"]?.objectValue { arguments = JSONValue.object(object).canonicalString() }
                                else if let string = function["arguments"]?.stringValue { arguments = string }
                                else { arguments = "{}" }
                                let toolCall = LLMToolCall(id: id, name: name, argumentsJSON: arguments)
                                calls.append(toolCall)
                                continuation.yield(.toolCallStarted(id: id, name: name))
                                continuation.yield(.toolCall(toolCall))
                            }
                        }
                        if json["done"]?.boolValue == true {
                            switch json["done_reason"]?.stringValue {
                            case "length": finish = .length
                            default: finish = calls.isEmpty ? .stop : .toolCalls
                            }
                            if json["prompt_eval_count"] != nil || json["eval_count"] != nil {
                                usage = LLMUsage(inputTokens: json["prompt_eval_count"]?.intValue ?? 0, outputTokens: json["eval_count"]?.intValue ?? 0)
                            }
                            break
                        }
                    }
                    continuation.yield(.completed(LLMCompletion(text: text, toolCalls: calls, finishReason: finish, usage: usage, model: model)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: LLMProviderError.wrapping(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
