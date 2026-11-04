import Foundation
import Testing
import FridayCore
@testable import FridayIntelligence

// End-to-end through the real Action Engine with a scripted model: the planner proposes a tool call, the engine
// validates and executes it, the planner is called again with the result and answers in prose.

final class ScriptedProvider: LLMProvider, @unchecked Sendable {
    let id = "scripted"
    let displayName = "Scripted"
    let isRemote = false
    let mayIncurCharges = false
    let capabilities: Set<LLMCapability> = [.nativeTools, .streaming]
    private let lock = NSLock()
    private(set) var requests: [LLMRequest] = []
    var script: [LLMCompletion]

    init(script: [LLMCompletion]) { self.script = script }

    func availableModels() async throws -> [LLMModel] { [LLMModel(id: "scripted-1", tier: .capable)] }
    func complete(_ request: LLMRequest) async throws -> LLMCompletion { try await completeByStreaming(request) }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
        let next: LLMCompletion = lock.withLock {
            requests.append(request)
            return script.isEmpty ? LLMCompletion(text: "Done.") : script.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            if !next.text.isEmpty { continuation.yield(.textDelta(next.text)) }
            for call in next.toolCalls { continuation.yield(.toolCall(call)) }
            continuation.yield(.completed(next))
            continuation.finish()
        }
    }
}

/// A registry whose only provider is the scripted one.
enum ScriptedRegistryFactory {
    static let settings: IntelligenceSettings = {
        var settings = IntelligenceSettings()
        settings.fallbackOrder = ["scripted"]
        settings.layaRoutingEnabled = false
        settings.fastPathEnabled = false
        settings.chatGPTEnabled = false
        settings.appleOnDeviceEnabled = false
        return settings
    }()

    static func make(provider: ScriptedProvider) -> ProviderRegistry {
        let secrets = InMemorySecretStore()
        let auth = ChatGPTAuthService(secrets: secrets, defaults: UserDefaults(suiteName: "friday.tests.\(UUID().uuidString)")!)
        let settings = Self.settings
        return ProviderRegistry(auth: auth, secrets: secrets, settings: { settings }) { id, _ in id == "scripted" ? provider : nil }
    }
}

struct FakeReminders: AppIntegration {
    let id: IntegrationID = "reminders"
    let displayName = LocalizedText("Reminders")
    let summary = LocalizedText("fake")
    let symbolName = "list.bullet"
    let permissionRequirements: [PermissionRequirement] = []
    let created: Created
    final class Created: @unchecked Sendable { let lock = NSLock(); var titles: [String] = [] }
    var tools: [ToolDescriptor] {
        [
            ToolDescriptor(name: "reminders.create", integration: id, title: "Create reminder", summary: "Create a reminder", parameters: [.string("title", "title", required: true), .string("list", "list")], safety: .modifying, deduplicate: true),
            ToolDescriptor(name: "reminders.list", integration: id, title: "List reminders", summary: "List", safety: .readOnly),
        ]
    }
    func status() async -> IntegrationStatus { IntegrationStatus(state: .ready) }
    func authorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }
    func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }
    func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
        switch call.descriptor.name.rawValue {
        case "reminders.create":
            let title = call.string("title") ?? ""
            created.lock.withLock { created.titles.append(title) }
            return .done(ToolOutput(message: "Created “\(title)”.", data: ["id": "r1", "title": .string(title)], verification: .verified("re-read")))
        default:
            return .done(ToolOutput(message: "2 reminders", data: ["items": [["id": "r1", "title": "Milk"], ["id": "r2", "title": "Eggs"]]], verification: .notApplicable))
        }
    }
}

@Suite struct EnginePipelineTests {
    @Test func plannerDrivesTheEngineThroughToolCallsAndAFinalReply() async throws {
        let provider = ScriptedProvider(script: [
            LLMCompletion(text: "", toolCalls: [LLMToolCall(id: "c1", name: "reminders__create", argumentsJSON: #"{"title":"Almond milk","list":"Groceries"}"#)], finishReason: .toolCalls),
            LLMCompletion(text: "Added almond milk to Groceries.", finishReason: .stop),
        ])
        let registry = ScriptedRegistryFactory.make(provider: provider)
        let planner = FridayPlanner(providers: registry, router: IntentRouter(), settings: { ScriptedRegistryFactory.settings })
        let reminders = FakeReminders(created: .init())
        let meta = FridayMetaIntegration()
        let tools = ToolRegistry(integrations: [reminders, meta])
        meta.setCatalog(tools.descriptors)
        let engine = ActionEngine(registry: tools, interpreter: planner, settings: InMemorySettings())
        let response = await engine.process(CommandRequest(text: "add milk, no wait, almond milk, to my groceries list", language: .en, source: .test, session: "t"))
        #expect(response.status == .completed, Comment(rawValue: "got \(response.status): \(response.message)"))
        #expect(reminders.created.lock.withLock { reminders.created.titles } == ["Almond milk"])
        #expect(response.message.contains("Added almond milk"))
        // The second model call replayed the tool call and its result.
        let second = provider.requests.last
        #expect(second?.messages.contains { $0.role == .tool && $0.text.contains("Almond milk") } == true)
        #expect(second?.messages.first { $0.role == .user }?.text.contains("almond milk") == true)
    }

    @Test func discoveryToolExpandsTheOfferedTools() async throws {
        let provider = ScriptedProvider(script: [
            LLMCompletion(text: "", toolCalls: [LLMToolCall(id: "c1", name: "friday__find_tools", argumentsJSON: #"{"query":"create reminder"}"#)], finishReason: .toolCalls),
            LLMCompletion(text: "", toolCalls: [LLMToolCall(id: "c2", name: "reminders__create", argumentsJSON: #"{"title":"Eggs"}"#)], finishReason: .toolCalls),
            LLMCompletion(text: "Done.", finishReason: .stop),
        ])
        let registry = ScriptedRegistryFactory.make(provider: provider)
        // Route confidently to "music" so reminders tools are NOT offered at first; find_tools must bring them in.
        let router = IntentRouter()
        let planner = FridayPlanner(providers: registry, router: router, settings: { ScriptedRegistryFactory.settings })
        let reminders = FakeReminders(created: .init())
        let meta = FridayMetaIntegration()
        let tools = ToolRegistry(integrations: [reminders, meta])
        meta.setCatalog(tools.descriptors)
        let engine = ActionEngine(registry: tools, interpreter: planner, settings: InMemorySettings())
        let response = await engine.process(CommandRequest(text: "play something and note eggs", language: .en, source: .test, session: "t"))
        #expect(response.status == .completed, Comment(rawValue: response.message))
        #expect(reminders.created.lock.withLock { reminders.created.titles } == ["Eggs"])
        let offered = provider.requests.map { $0.tools.map(\.name) }
        #expect(offered.count == 3)
        #expect(offered[1].contains("reminders__create"))
    }

    @Test func invalidModelOutputStopsWithoutExecutingAnything() async throws {
        let provider = ScriptedProvider(script: [
            LLMCompletion(text: "", toolCalls: [LLMToolCall(id: "c1", name: "reminders__create", argumentsJSON: #"{"list":"x"}"#)], finishReason: .toolCalls),  // missing title
        ])
        let registry = ScriptedRegistryFactory.make(provider: provider)
        let planner = FridayPlanner(providers: registry, router: IntentRouter(), settings: { ScriptedRegistryFactory.settings })
        let reminders = FakeReminders(created: .init())
        let tools = ToolRegistry(integrations: [reminders])
        let engine = ActionEngine(registry: tools, interpreter: planner, settings: InMemorySettings())
        let response = await engine.process(CommandRequest(text: "remind me", language: .en, source: .test, session: "t"))
        #expect(response.status == .failed)
        #expect(reminders.created.lock.withLock { reminders.created.titles }.isEmpty)
    }
}
