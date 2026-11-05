import Foundation
import Testing
import FridayCore
@testable import FridayIntelligence

// Live checks against a local Ollama server (skipped when none answers on 127.0.0.1:11434). They cover the two
// things that broke with the first local model: the planner offering the whole catalogue (prompt silently truncated
// by the server's context window) and the OpenAI-compatible route having no way to set that window.

private let ollamaBase = URL(string: "http://127.0.0.1:11434/v1")!

private func ollamaModel() async -> String? {
    guard await OllamaClient.isOllama(at: OllamaClient.root(forCompatibleBaseURL: ollamaBase)) else { return nil }
    let ids = (try? await OllamaClient(root: OllamaClient.root(forCompatibleBaseURL: ollamaBase)).listModels()) ?? []
    return ids.first { !$0.contains("embed") }
}

@Suite(.serialized) struct LocalModelTests {
    @Test func compatibleProviderUsesTheNativeOllamaAPI() async throws {
        guard let model = await ollamaModel() else { return }
        let provider = CompatibleProvider(baseURL: ollamaBase)
        let request = LLMRequest(
            model: model, instructions: "Answer in one short sentence.", messages: [.user("What is the capital of Australia?")], maxOutputTokens: 60)
        var text = ""
        var completion: LLMCompletion?
        for try await event in provider.stream(request) {
            if case .textDelta(let delta) = event { text += delta }
            if case .completed(let final) = event { completion = final }
        }
        #expect(text.localizedCaseInsensitiveContains("Canberra"))
        #expect(completion?.usage?.inputTokens ?? 0 > 0, "the native API reports token usage")
    }

    @Test func toolCallsStreamThroughTheNativeAPI() async throws {
        guard let model = await ollamaModel() else { return }
        let provider = CompatibleProvider(baseURL: ollamaBase)
        let tool = LLMToolDefinition(
            name: "reminders__create", description: "Create a reminder",
            parameters: ["type": "object", "properties": ["title": ["type": "string"]], "required": ["title"]])
        let request = LLMRequest(
            model: model, instructions: "You act only through tools. Create reminders with reminders__create.",
            messages: [.user("Remind me to buy oat milk")], tools: [tool], toolChoice: .auto, maxOutputTokens: 200)
        var calls: [LLMToolCall] = []
        for try await event in provider.stream(request) {
            if case .toolCall(let call) = event { calls.append(call) }
        }
        #expect(calls.first?.name == "reminders__create")
        #expect(calls.first?.arguments?["title"]?.stringValue?.localizedCaseInsensitiveContains("milk") == true)
    }

    @Test func plannerAnswersAndPlansWithALocalModel() async throws {
        guard let model = await ollamaModel() else { return }
        let settings: IntelligenceSettings = {
            var settings = IntelligenceSettings()
            settings.fallbackOrder = ["compatible"]
            settings.compatibleEnabled = true
            settings.compatibleEndpoint = ollamaBase.absoluteString
            settings.compatibleModel = model
            settings.layaRoutingEnabled = false
            settings.fastPathEnabled = false
            settings.chatGPTEnabled = false
            settings.appleOnDeviceEnabled = false
            return settings
        }()
        let secrets = InMemorySecretStore()
        let auth = ChatGPTAuthService(secrets: secrets, defaults: UserDefaults(suiteName: "friday.tests.\(UUID().uuidString)")!)
        let registry = ProviderRegistry(auth: auth, secrets: secrets, settings: { settings })
        let planner = FridayPlanner(providers: registry, router: IntentRouter(), settings: { settings })
        let reminders = FakeReminders(created: .init())
        let meta = FridayMetaIntegration()
        let tools = ToolRegistry(integrations: [reminders, meta])
        meta.setCatalog(tools.descriptors)
        let engine = ActionEngine(registry: tools, interpreter: planner, settings: InMemorySettings())

        let question = await engine.process(CommandRequest(text: "What is the capital of Australia?", language: .en, source: .test, session: "q"))
        #expect(question.message.localizedCaseInsensitiveContains("Canberra"), Comment(rawValue: question.message))
        #expect(reminders.created.lock.withLock { reminders.created.titles }.isEmpty)

        let command = await engine.process(CommandRequest(text: "remind me to buy oat milk", language: .en, source: .test, session: "c"))
        #expect(command.status == .completed, Comment(rawValue: "\(command.status): \(command.message)"))
        #expect(reminders.created.lock.withLock { reminders.created.titles }.first?.localizedCaseInsensitiveContains("milk") == true)
    }
}
