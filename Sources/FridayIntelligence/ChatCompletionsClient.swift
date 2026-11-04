import Foundation
import FridayCore

/// OpenAI-compatible Chat Completions client (`POST {base}/chat/completions`): Ollama, LM Studio, llama.cpp,
/// OpenRouter and any other compatible server. Supports streaming and function tools when the server does.
public struct ChatCompletionsClient: Sendable {
    public var baseURL: URL
    public var apiKey: String?
    private let session: URLSession

    public init(baseURL: URL, apiKey: String? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = ModelSessions.make()
    }

    public func listModels() async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.timeoutInterval = 10
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMProviderError.invalidResponse("No HTTP response.") }
        guard (200..<300).contains(http.statusCode) else { throw HTTPErrorMapper.error(status: http.statusCode, body: data) }
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        return (json["data"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
    }

    func body(for request: LLMRequest, stream: Bool, supportsTools: Bool) -> JSONObject {
        var messages: [JSONValue] = [["role": "system", "content": .string(request.instructions)]]
        for message in request.messages {
            switch message.role {
            case .system, .developer: messages.append(["role": "system", "content": .string(message.text)])
            case .user: messages.append(["role": "user", "content": .string(message.text)])
            case .assistant:
                var object: JSONObject = ["role": "assistant", "content": message.text.isEmpty ? .null : .string(message.text)]
                if !message.toolCalls.isEmpty {
                    object["tool_calls"] = .array(
                        message.toolCalls.map {
                            [
                                "id": .string($0.id), "type": "function",
                                "function": ["name": .string($0.name), "arguments": .string($0.argumentsJSON)],
                            ]
                        })
                }
                messages.append(.object(object))
            case .tool:
                messages.append(["role": "tool", "tool_call_id": .string(message.toolCallID ?? ""), "content": .string(message.text)])
            }
        }
        var fields: JSONObject = ["model": .string(request.model), "messages": .array(messages), "stream": .bool(stream)]
        if let temperature = request.temperature { fields["temperature"] = .double(temperature) }
        if let max = request.maxOutputTokens { fields["max_tokens"] = .int(max) }
        if supportsTools, !request.tools.isEmpty {
            fields["tools"] = .array(
                request.tools.map {
                    [
                        "type": "function",
                        "function": ["name": .string($0.name), "description": .string($0.description), "parameters": $0.parameters],
                    ]
                })
            switch request.toolChoice {
            case .auto: fields["tool_choice"] = "auto"
            case .none: fields["tool_choice"] = "none"
            case .required: fields["tool_choice"] = "required"
            case .tool(let name): fields["tool_choice"] = ["type": "function", "function": ["name": .string(name)]]
            }
            fields["parallel_tool_calls"] = .bool(request.parallelToolCalls)
        }
        if request.jsonSchema != nil { fields["response_format"] = ["type": "json_object"] }
        return fields
    }

    func urlRequest(_ fields: JSONObject) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(JSONValue.object(fields))
        return request
    }

    public func complete(_ request: LLMRequest, supportsTools: Bool = true) async throws -> LLMCompletion {
        let http = try urlRequest(body(for: request, stream: false, supportsTools: supportsTools))
        let (data, response) = try await session.data(for: http)
        guard let httpResponse = response as? HTTPURLResponse else { throw LLMProviderError.invalidResponse("No HTTP response.") }
        guard (200..<300).contains(httpResponse.statusCode) else { throw HTTPErrorMapper.error(status: httpResponse.statusCode, body: data) }
        guard data.count <= 16 * 1_048_576 else { throw LLMProviderError.responseTooLarge }
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let choice = json["choices"]?[0] else { throw LLMProviderError.invalidResponse("No choices in the reply.") }
        let message = choice["message"]
        let calls: [LLMToolCall] = (message?["tool_calls"]?.arrayValue ?? []).compactMap { call in
            guard let function = call["function"], let name = function["name"]?.stringValue else { return nil }
            let arguments: String
            if let text = function["arguments"]?.stringValue { arguments = text } else { arguments = function["arguments"]?.canonicalString() ?? "{}" }
            return LLMToolCall(id: call["id"]?.stringValue ?? UUID().uuidString, name: name, argumentsJSON: arguments)
        }
        let finish: LLMCompletion.FinishReason = {
            switch choice["finish_reason"]?.stringValue {
            case "length": return .length
            case "tool_calls": return .toolCalls
            case "content_filter": return .contentFilter
            default: return calls.isEmpty ? .stop : .toolCalls
            }
        }()
        let usage = json["usage"].map {
            LLMUsage(inputTokens: $0["prompt_tokens"]?.intValue ?? 0, outputTokens: $0["completion_tokens"]?.intValue ?? 0)
        }
        return LLMCompletion(
            text: message?["content"]?.stringValue ?? "", toolCalls: calls, finishReason: finish, usage: usage,
            model: json["model"]?.stringValue, responseID: json["id"]?.stringValue)
    }

    public func stream(_ request: LLMRequest, supportsTools: Bool = true) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let http = try urlRequest(body(for: request, stream: true, supportsTools: supportsTools))
                    var text = ""
                    var partial: [Int: (id: String, name: String, arguments: String)] = [:]
                    var finish: LLMCompletion.FinishReason = .stop
                    var model: String?
                    for try await event in SSEStream.events(for: http, session: session) {
                        if event.data == "[DONE]" { break }
                        guard let data = event.data.data(using: .utf8),
                            let json = try? JSONDecoder().decode(JSONValue.self, from: data)
                        else { continue }
                        if let error = json["error"] {
                            throw HTTPErrorMapper.classify(status: 400, code: error["code"]?.stringValue, message: error["message"]?.stringValue ?? "error")
                        }
                        model = json["model"]?.stringValue ?? model
                        guard let choice = json["choices"]?[0] else { continue }
                        if let delta = choice["delta"] {
                            if let content = delta["content"]?.stringValue, !content.isEmpty {
                                text += content
                                continuation.yield(.textDelta(content))
                            }
                            for call in delta["tool_calls"]?.arrayValue ?? [] {
                                let index = call["index"]?.intValue ?? 0
                                var entry = partial[index] ?? (call["id"]?.stringValue ?? "call_\(index)", "", "")
                                if let id = call["id"]?.stringValue { entry.id = id }
                                if let name = call["function"]?["name"]?.stringValue, !name.isEmpty {
                                    if entry.name.isEmpty { continuation.yield(.toolCallStarted(id: entry.id, name: name)) }
                                    entry.name = name
                                }
                                if let arguments = call["function"]?["arguments"]?.stringValue { entry.arguments += arguments }
                                partial[index] = entry
                            }
                        }
                        if let reason = choice["finish_reason"]?.stringValue {
                            switch reason {
                            case "length": finish = .length
                            case "tool_calls": finish = .toolCalls
                            case "content_filter": finish = .contentFilter
                            default: break
                            }
                        }
                    }
                    let calls = partial.keys.sorted().map { key -> LLMToolCall in
                        let entry = partial[key]!
                        return LLMToolCall(id: entry.id, name: entry.name, argumentsJSON: entry.arguments.isEmpty ? "{}" : entry.arguments)
                    }
                    for call in calls { continuation.yield(.toolCall(call)) }
                    if !calls.isEmpty, finish == .stop { finish = .toolCalls }
                    continuation.yield(.completed(LLMCompletion(text: text, toolCalls: calls, finishReason: finish, model: model)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
