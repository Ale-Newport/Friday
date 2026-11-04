import Foundation
import FridayCore

/// OpenAI Responses API client (`POST {base}/responses`), used both with a ChatGPT-plan access token obtained
/// through Sign in with ChatGPT and with a regular OpenAI API key.
///
/// With a plan token the documented constraints apply and are honoured here: `store: false`, `stream: true`,
/// no `system` message items (the system prompt travels in `instructions`), no `previous_response_id`
/// (the whole history is sent as `input`), no `temperature`/`top_p`/`max_output_tokens`/`user`, and only
/// function tools.
public struct ResponsesAPIClient: Sendable {
    public struct Credentials: Sendable {
        public var bearer: String
        /// `true` for ChatGPT-plan tokens: enforces the plan-sharing request constraints.
        public var planToken: Bool
        public init(bearer: String, planToken: Bool) {
            self.bearer = bearer
            self.planToken = planToken
        }
    }

    public var baseURL: URL
    private let session: URLSession

    public init(baseURL: URL = URL(string: "https://api.openai.com/v1")!) {
        self.baseURL = baseURL
        self.session = ModelSessions.make()
    }

    // MARK: Models

    public struct ModelEntry: Sendable { public var id: String; public var displayName: String; public var listed: Bool }

    /// `GET /models`. For plan tokens the response carries `visibility`/`slug`/`display_name`; for API keys it is
    /// the classic `{data:[{id}]}` list. Both are handled.
    public func listModels(credentials: Credentials) async throws -> [ModelEntry] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.setValue("Bearer " + credentials.bearer, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMProviderError.invalidResponse("No HTTP response.") }
        guard (200..<300).contains(http.statusCode) else { throw HTTPErrorMapper.error(status: http.statusCode, body: data) }
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        let items = json["models"]?.arrayValue ?? json["data"]?.arrayValue ?? []
        return items.compactMap { item in
            let id = item["slug"]?.stringValue ?? item["id"]?.stringValue
            guard let id else { return nil }
            let visibility = item["visibility"]?.stringValue
            return ModelEntry(
                id: id, displayName: item["display_name"]?.stringValue ?? id,
                listed: visibility == nil || visibility == "list")
        }
    }

    // MARK: Requests

    func body(for request: LLMRequest, credentials: Credentials, stream: Bool) -> JSONObject {
        var input: [JSONValue] = []
        for message in request.messages {
            switch message.role {
            case .system, .developer:
                // Plan tokens reject explicit system items; everyone gets the same shape: a developer message.
                input.append(["role": "developer", "content": .string(message.text)])
            case .user:
                input.append(["role": "user", "content": .string(message.text)])
            case .assistant:
                if !message.text.isEmpty {
                    input.append([
                        "role": "assistant",
                        "content": [["type": "output_text", "text": .string(message.text)]],
                    ])
                }
                for call in message.toolCalls {
                    input.append([
                        "type": "function_call", "call_id": .string(call.id), "name": .string(call.name),
                        "arguments": .string(call.argumentsJSON),
                    ])
                }
            case .tool:
                input.append([
                    "type": "function_call_output", "call_id": .string(message.toolCallID ?? ""),
                    "output": .string(message.text),
                ])
            }
        }
        var fields: JSONObject = [
            "model": .string(request.model),
            "instructions": .string(request.instructions),
            "input": .array(input),
            "store": false,
            "stream": .bool(stream),
        ]
        if !request.tools.isEmpty {
            fields["tools"] = .array(
                request.tools.map {
                    [
                        "type": "function", "name": .string($0.name), "description": .string($0.description),
                        "parameters": $0.parameters, "strict": false,
                    ]
                })
            switch request.toolChoice {
            case .auto: fields["tool_choice"] = "auto"
            case .none: fields["tool_choice"] = "none"
            case .required: fields["tool_choice"] = "required"
            case .tool(let name): fields["tool_choice"] = ["type": "function", "name": .string(name)]
            }
            fields["parallel_tool_calls"] = .bool(request.parallelToolCalls)
        }
        if let schema = request.jsonSchema {
            fields["text"] = [
                "format": ["type": "json_schema", "name": "answer", "schema": schema, "strict": false],
            ]
        }
        if let effort = request.reasoningEffort, request.model.lowercased().hasPrefix("o") || request.model.contains("gpt-5") || request.model.contains("gpt-6") {
            fields["reasoning"] = ["effort": .string(effort)]
        }
        if !credentials.planToken {
            if let max = request.maxOutputTokens { fields["max_output_tokens"] = .int(max) }
            if let temperature = request.temperature, !Self.isReasoningModel(request.model) {
                fields["temperature"] = .double(temperature)
            }
        }
        return fields
    }

    static func isReasoningModel(_ model: String) -> Bool {
        let m = model.lowercased()
        return (m.hasPrefix("o") && m.dropFirst().first?.isNumber == true) || m.hasPrefix("gpt-5") || m.hasPrefix("gpt-6")
    }

    func urlRequest(_ fields: JSONObject, credentials: Credentials) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + credentials.bearer, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(JSONValue.object(fields))
        return request
    }

    /// Streams a response. Always streams on the wire (required for plan tokens); the caller may ignore deltas.
    public func stream(_ request: LLMRequest, credentials: Credentials) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let http = try urlRequest(body(for: request, credentials: credentials, stream: true), credentials: credentials)
                    var text = ""
                    var calls: [LLMToolCall] = []
                    var pendingCalls: [String: (callID: String, name: String, arguments: String)] = [:]  // keyed by item_id
                    var completed = false
                    for try await event in SSEStream.events(for: http, session: session) {
                        guard event.data != "[DONE]", let data = event.data.data(using: .utf8),
                            let json = try? JSONDecoder().decode(JSONValue.self, from: data)
                        else { continue }
                        let type = json["type"]?.stringValue ?? event.event ?? ""
                        switch type {
                        case "response.output_text.delta":
                            if let delta = json["delta"]?.stringValue, !delta.isEmpty {
                                text += delta
                                continuation.yield(.textDelta(delta))
                            }
                        case "response.output_item.added":
                            if let item = json["item"], item["type"]?.stringValue == "function_call" {
                                let itemID = item["id"]?.stringValue ?? UUID().uuidString
                                let callID = item["call_id"]?.stringValue ?? itemID
                                let name = item["name"]?.stringValue ?? ""
                                pendingCalls[itemID] = (callID, name, item["arguments"]?.stringValue ?? "")
                                continuation.yield(.toolCallStarted(id: callID, name: name))
                            }
                        case "response.function_call_arguments.delta":
                            if let itemID = json["item_id"]?.stringValue, let delta = json["delta"]?.stringValue {
                                pendingCalls[itemID]?.arguments += delta
                            }
                        case "response.function_call_arguments.done":
                            if let itemID = json["item_id"]?.stringValue, let arguments = json["arguments"]?.stringValue {
                                pendingCalls[itemID]?.arguments = arguments
                            }
                        case "response.output_item.done":
                            if let item = json["item"], item["type"]?.stringValue == "function_call" {
                                let itemID = item["id"]?.stringValue ?? ""
                                let pending = pendingCalls.removeValue(forKey: itemID)
                                let call = LLMToolCall(
                                    id: item["call_id"]?.stringValue ?? pending?.callID ?? itemID,
                                    name: item["name"]?.stringValue ?? pending?.name ?? "",
                                    argumentsJSON: item["arguments"]?.stringValue ?? pending?.arguments ?? "{}")
                                calls.append(call)
                                continuation.yield(.toolCall(call))
                            }
                        case "response.completed", "response.incomplete":
                            completed = true
                            let response = json["response"]
                            // Any function calls that were never reported as done (shouldn't happen) are flushed.
                            for (_, pending) in pendingCalls where !calls.contains(where: { $0.id == pending.callID }) {
                                let call = LLMToolCall(id: pending.callID, name: pending.name, argumentsJSON: pending.arguments.isEmpty ? "{}" : pending.arguments)
                                calls.append(call)
                                continuation.yield(.toolCall(call))
                            }
                            if text.isEmpty, let output = response?["output"]?.arrayValue {
                                // Non-streamed text (rare): collect from the final output items.
                                for item in output where item["type"]?.stringValue == "message" {
                                    for part in item["content"]?.arrayValue ?? [] where part["type"]?.stringValue == "output_text" {
                                        text += part["text"]?.stringValue ?? ""
                                    }
                                }
                            }
                            let usage = response?["usage"].map {
                                LLMUsage(inputTokens: $0["input_tokens"]?.intValue ?? 0, outputTokens: $0["output_tokens"]?.intValue ?? 0)
                            }
                            let incomplete = type == "response.incomplete"
                            let reason: LLMCompletion.FinishReason =
                                incomplete
                                ? (response?["incomplete_details"]?["reason"]?.stringValue == "max_output_tokens" ? .length : .incomplete)
                                : (calls.isEmpty ? .stop : .toolCalls)
                            continuation.yield(
                                .completed(
                                    LLMCompletion(
                                        text: text, toolCalls: calls, finishReason: reason, usage: usage,
                                        model: response?["model"]?.stringValue, responseID: response?["id"]?.stringValue)))
                        case "response.failed":
                            let error = json["response"]?["error"]
                            throw HTTPErrorMapper.classify(
                                status: 400, code: error?["code"]?.stringValue,
                                message: error?["message"]?.stringValue ?? "The response failed.")
                        case "error":
                            throw HTTPErrorMapper.classify(
                                status: 400, code: json["code"]?.stringValue,
                                message: json["message"]?.stringValue ?? "The model returned an error.")
                        default:
                            break
                        }
                    }
                    guard completed else {
                        throw LLMProviderError.invalidResponse("The stream ended before the response completed.")
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
