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
        // Two invalid batches in a row (missing title; then "Done." as a bare claim): one repair round, then an
        // honest stop with nothing executed.
        let provider = ScriptedProvider(script: [
            LLMCompletion(text: "", toolCalls: [LLMToolCall(id: "c1", name: "reminders__create", argumentsJSON: #"{"list":"x"}"#)], finishReason: .toolCalls),  // missing title
            LLMCompletion(text: "Done.", finishReason: .stop),
        ])
        let registry = ScriptedRegistryFactory.make(provider: provider)
        let planner = FridayPlanner(providers: registry, router: IntentRouter(), settings: { ScriptedRegistryFactory.settings })
        let reminders = FakeReminders(created: .init())
        let tools = ToolRegistry(integrations: [reminders])
        let engine = ActionEngine(registry: tools, interpreter: planner, settings: InMemorySettings())
        let response = await engine.process(CommandRequest(text: "remind me", language: .en, source: .test, session: "t"))
        #expect(response.status == .unrecognized, Comment(rawValue: "\(response.status): \(response.message)"))
        #expect(response.message.contains("Nothing ran"))
        #expect(!response.message.contains("Done."))
        #expect(reminders.created.lock.withLock { reminders.created.titles }.isEmpty)
        #expect(provider.requests.count == 2)
        #expect(provider.requests.last?.messages.contains { $0.role == .user && $0.text.contains("REJECTED") && $0.text.contains("title") } == true)
    }

    @Test func rejectedBatchIsRepairedOnce() async throws {
        let provider = ScriptedProvider(script: [
            LLMCompletion(text: "", toolCalls: [LLMToolCall(id: "c1", name: "reminders__create", argumentsJSON: #"{"list":"Groceries"}"#)], finishReason: .toolCalls),  // missing title
            LLMCompletion(text: "", toolCalls: [LLMToolCall(id: "c2", name: "reminders__create", argumentsJSON: #"{"title":"Eggs","list":"Groceries"}"#)], finishReason: .toolCalls),
            LLMCompletion(text: "Added eggs.", finishReason: .stop),
        ])
        let registry = ScriptedRegistryFactory.make(provider: provider)
        let planner = FridayPlanner(providers: registry, router: IntentRouter(), settings: { ScriptedRegistryFactory.settings })
        let reminders = FakeReminders(created: .init())
        let tools = ToolRegistry(integrations: [reminders])
        let engine = ActionEngine(registry: tools, interpreter: planner, settings: InMemorySettings())
        let response = await engine.process(CommandRequest(text: "remind me to buy eggs", language: .en, source: .test, session: "t"))
        #expect(response.status == .completed, Comment(rawValue: "\(response.status): \(response.message)"))
        #expect(reminders.created.lock.withLock { reminders.created.titles } == ["Eggs"])
        #expect(provider.requests.count == 3)
    }

    @Test func unknownToolNamesAreRepairedToo() async throws {
        let provider = ScriptedProvider(script: [
            LLMCompletion(text: "", toolCalls: [LLMToolCall(id: "c1", name: "reminders__add", argumentsJSON: #"{"title":"Eggs"}"#)], finishReason: .toolCalls),
            LLMCompletion(text: "", toolCalls: [LLMToolCall(id: "c2", name: "reminders__create", argumentsJSON: #"{"title":"Eggs"}"#)], finishReason: .toolCalls),
            LLMCompletion(text: "Done, eggs added.", finishReason: .stop),
        ])
        let registry = ScriptedRegistryFactory.make(provider: provider)
        let planner = FridayPlanner(providers: registry, router: IntentRouter(), settings: { ScriptedRegistryFactory.settings })
        let reminders = FakeReminders(created: .init())
        let engine = ActionEngine(registry: ToolRegistry(integrations: [reminders]), interpreter: planner, settings: InMemorySettings())
        let response = await engine.process(CommandRequest(text: "remind me to buy eggs", language: .en, source: .test, session: "t"))
        #expect(response.status == .completed, Comment(rawValue: "\(response.status): \(response.message)"))
        #expect(provider.requests[1].messages.contains { $0.role == .user && $0.text.contains("Unknown tool") })
    }
}

/// A provider whose transport fails the way URLSession does offline.
final class OfflineProvider: LLMProvider, @unchecked Sendable {
    let id = "scripted"
    let displayName = "Offline"
    let isRemote = true
    let mayIncurCharges = false
    let capabilities: Set<LLMCapability> = [.nativeTools, .streaming]
    func availableModels() async throws -> [LLMModel] { [LLMModel(id: "offline-1", tier: .capable)] }
    func complete(_ request: LLMRequest) async throws -> LLMCompletion { throw URLError(.notConnectedToInternet) }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
        AsyncThrowingStream { continuation in continuation.finish(throwing: URLError(.notConnectedToInternet)) }
    }
}

@Suite struct ModelFailureTests {
    @Test func networkErrorsGiveTheHonestOfflineReply() async throws {
        // The registry factory hands out whichever provider carries the "scripted" id; here it is the offline one.
        let offline = OfflineProvider()
        let secrets = InMemorySecretStore()
        let auth = ChatGPTAuthService(secrets: secrets, defaults: UserDefaults(suiteName: "friday.tests.\(UUID().uuidString)")!)
        let settings = ScriptedRegistryFactory.settings
        let registry = ProviderRegistry(auth: auth, secrets: secrets, settings: { settings }) { id, _ in id == "scripted" ? offline : nil }
        let planner = FridayPlanner(providers: registry, router: IntentRouter(), settings: { settings })
        let engine = ActionEngine(registry: ToolRegistry(integrations: [FakeReminders(created: .init()), FridayMetaIntegration()]), interpreter: planner, settings: InMemorySettings())
        let english = await engine.process(CommandRequest(text: "explain the theory of relativity", language: .en, source: .test, session: "t"))
        #expect(english.status == .reply, Comment(rawValue: "\(english.status): \(english.message)"))
        #expect(english.message.contains("can't reach a language model"), Comment(rawValue: english.message))
        #expect(!english.message.contains("rephras"))
        let spanish = await engine.process(CommandRequest(text: "explícame la teoría de la relatividad", language: .es, source: .test, session: "s"))
        #expect(spanish.message.contains("no puedo usar un modelo de lenguaje"), Comment(rawValue: spanish.message))
    }

    @Test func networkErrorsMidWorkflowStopItHonestly() async throws {
        // First round answers, then the transport dies: the workflow stops with the real reason, not "rephrase".
        final class FlakyProvider: LLMProvider, @unchecked Sendable {
            let id = "scripted"
            let displayName = "Flaky"
            let isRemote = true
            let mayIncurCharges = false
            let capabilities: Set<LLMCapability> = [.nativeTools, .streaming]
            let lock = NSLock()
            var calls = 0
            func availableModels() async throws -> [LLMModel] { [LLMModel(id: "flaky-1", tier: .capable)] }
            func complete(_ request: LLMRequest) async throws -> LLMCompletion { throw URLError(.timedOut) }
            func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
                let index = lock.withLock { calls += 1; return calls }
                return AsyncThrowingStream { continuation in
                    if index == 1 {
                        let call = LLMToolCall(id: "c1", name: "reminders__list", argumentsJSON: "{}")
                        continuation.yield(.toolCall(call))
                        continuation.yield(.completed(LLMCompletion(text: "", toolCalls: [call], finishReason: .toolCalls)))
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: URLError(.timedOut))
                    }
                }
            }
        }
        let flaky = FlakyProvider()
        let secrets = InMemorySecretStore()
        let auth = ChatGPTAuthService(secrets: secrets, defaults: UserDefaults(suiteName: "friday.tests.\(UUID().uuidString)")!)
        let settings = ScriptedRegistryFactory.settings
        let registry = ProviderRegistry(auth: auth, secrets: secrets, settings: { settings }) { id, _ in id == "scripted" ? flaky : nil }
        let planner = FridayPlanner(providers: registry, router: IntentRouter(), settings: { settings })
        let engine = ActionEngine(registry: ToolRegistry(integrations: [FakeReminders(created: .init())]), interpreter: planner, settings: InMemorySettings())
        let response = await engine.process(CommandRequest(text: "what's on my list", language: .en, source: .test, session: "t"))
        #expect(response.message.contains("The model stopped responding"), Comment(rawValue: response.message))
        #expect(!response.message.contains("rephras"))
        #expect(response.results.contains { $0.tool.rawValue == "reminders.list" && $0.success })
    }
}

@Suite struct AskUserRoundTripTests {
    private func make(_ script: [LLMCompletion]) -> (ScriptedProvider, FakeReminders, ActionEngine) {
        let provider = ScriptedProvider(script: script)
        let registry = ScriptedRegistryFactory.make(provider: provider)
        let planner = FridayPlanner(providers: registry, router: IntentRouter(), settings: { ScriptedRegistryFactory.settings })
        let reminders = FakeReminders(created: .init())
        let meta = FridayMetaIntegration()
        let tools = ToolRegistry(integrations: [reminders, meta])
        meta.setCatalog(tools.descriptors)
        return (provider, reminders, ActionEngine(registry: tools, interpreter: planner, settings: InMemorySettings()))
    }

    @Test func anOptionPickedByOrdinalResumesTheWorkflowWithTheAnswer() async throws {
        let (provider, reminders, engine) = make([
            LLMCompletion(text: "", toolCalls: [LLMToolCall(id: "c1", name: "friday__ask_user", argumentsJSON: #"{"question":"Which list?","options":["Groceries","Work"]}"#)], finishReason: .toolCalls),
            LLMCompletion(text: "", toolCalls: [LLMToolCall(id: "c2", name: "reminders__create", argumentsJSON: #"{"title":"Eggs","list":"Work"}"#)], finishReason: .toolCalls),
            LLMCompletion(text: "Added eggs to Work.", finishReason: .stop),
        ])
        let asked = await engine.process(CommandRequest(text: "add eggs to my list", language: .en, source: .test, session: "t"))
        #expect(asked.status == .needsClarification, Comment(rawValue: "\(asked.status): \(asked.message)"))
        let clarification = asked.results.first?.clarification
        #expect(clarification?.options.map(\.label) == ["Groceries", "Work"])
        #expect(clarification?.token != nil)
        #expect(clarification?.acceptsFreeText == true)
        #expect(asked.message.contains("1. Groceries"))

        let answered = await engine.process(CommandRequest(text: "la segunda", language: .es, source: .test, session: "t"))
        #expect(answered.status == .completed, Comment(rawValue: "\(answered.status): \(answered.message)"))
        #expect(answered.message.contains("Added eggs to Work."))
        #expect(reminders.created.lock.withLock { reminders.created.titles } == ["Eggs"])
        // The model saw its own question answered as a tool result.
        let replan = provider.requests[1]
        #expect(replan.messages.contains { $0.role == .tool && $0.text.contains("\"answer\":\"Work\"") }, Comment(rawValue: replan.messages.map(\.text).joined(separator: "\n")))
        #expect(replan.messages.contains { $0.role == .assistant && $0.toolCalls.contains { $0.name == "friday__ask_user" } })
        #expect(provider.requests.count == 3)
    }

    @Test func aFreeTextAnswerAndAPlainNoReachTheModel() async throws {
        let (provider, _, engine) = make([
            LLMCompletion(text: "", toolCalls: [LLMToolCall(id: "c1", name: "friday__ask_user", argumentsJSON: #"{"question":"Should I add eggs too?"}"#)], finishReason: .toolCalls),
            LLMCompletion(text: "Okay, only milk then.", finishReason: .stop),
        ])
        let asked = await engine.process(CommandRequest(text: "add milk to my list", language: .en, source: .test, session: "t"))
        #expect(asked.status == .needsClarification, Comment(rawValue: "\(asked.status): \(asked.message)"))
        #expect(asked.results.first?.clarification?.options.isEmpty == true)
        let answered = await engine.process(CommandRequest(text: "no", language: .en, source: .test, session: "t"))
        #expect(answered.message.contains("only milk"), Comment(rawValue: "\(answered.status): \(answered.message)"))
        #expect(provider.requests.count == 2)
        #expect(provider.requests[1].messages.contains { $0.role == .tool && $0.text.contains("\"answer\":\"no\"") })
        let pending = await engine.pendingCount
        #expect(pending == 0)
    }

    @Test func yesAndLongerRepliesAreAnswersAndCancelAbandonsTheTask() async throws {
        let (provider, reminders, engine) = make([
            LLMCompletion(text: "", toolCalls: [LLMToolCall(id: "c1", name: "friday__ask_user", argumentsJSON: #"{"question":"What should the reminder say?"}"#)], finishReason: .toolCalls),
            LLMCompletion(text: "", toolCalls: [LLMToolCall(id: "c2", name: "reminders__create", argumentsJSON: #"{"title":"Call the dentist at nine"}"#)], finishReason: .toolCalls),
            LLMCompletion(text: "Reminder created.", finishReason: .stop),
            LLMCompletion(text: "", toolCalls: [LLMToolCall(id: "c3", name: "friday__ask_user", argumentsJSON: #"{"question":"Which day?"}"#)], finishReason: .toolCalls),
        ])
        _ = await engine.process(CommandRequest(text: "remind me", language: .en, source: .test, session: "t"))
        let done = await engine.process(CommandRequest(text: "call the dentist at nine", language: .en, source: .test, session: "t"))
        #expect(done.status == .completed, Comment(rawValue: "\(done.status): \(done.message)"))
        #expect(reminders.created.lock.withLock { reminders.created.titles } == ["Call the dentist at nine"])
        #expect(provider.requests[1].messages.contains { $0.role == .tool && $0.text.contains("call the dentist at nine") })

        let asked = await engine.process(CommandRequest(text: "remind me again", language: .en, source: .test, session: "t"))
        #expect(asked.status == .needsClarification)
        let cancelled = await engine.process(CommandRequest(text: "olvídalo", language: .es, source: .test, session: "t"))
        #expect(cancelled.status == .cancelled, Comment(rawValue: "\(cancelled.status): \(cancelled.message)"))
        #expect(provider.requests.count == 4)
    }

    @Test func theModelNeverSeesOrSetsTheReservedAnswerParameter() async throws {
        let (provider, _, engine) = make([
            LLMCompletion(text: "", toolCalls: [LLMToolCall(id: "c1", name: "friday__ask_user", argumentsJSON: #"{"question":"Which one?","answer":"the first"}"#)], finishReason: .toolCalls),
        ])
        let asked = await engine.process(CommandRequest(text: "move the meeting", language: .en, source: .test, session: "t"))
        // A pre-filled answer is dropped: the user is really asked.
        #expect(asked.status == .needsClarification, Comment(rawValue: "\(asked.status): \(asked.message)"))
        let ask = provider.requests[0].tools.first { $0.name == "friday__ask_user" }
        #expect(ask?.parameters["properties"]?["answer"] == nil)
    }
}

@Suite struct RoundLimitTests {
    @Test func theRoundLimitEndsWithAnAnswerInsteadOfMoreTools() async throws {
        let settings: IntelligenceSettings = { var s = ScriptedRegistryFactory.settings; s.maxToolRounds = 1; return s }()
        let provider = ScriptedProvider(script: [
            LLMCompletion(text: "", toolCalls: [LLMToolCall(id: "c1", name: "reminders__list", argumentsJSON: "{}")], finishReason: .toolCalls),
            LLMCompletion(text: "", toolCalls: [LLMToolCall(id: "c2", name: "reminders__list", argumentsJSON: "{}")], finishReason: .toolCalls),  // ignored: no tools allowed
        ])
        let registry = ScriptedRegistryFactory.make(provider: provider)
        let planner = FridayPlanner(providers: registry, router: IntentRouter(), settings: { settings })
        let engine = ActionEngine(registry: ToolRegistry(integrations: [FakeReminders(created: .init())]), interpreter: planner, settings: InMemorySettings())
        let response = await engine.process(CommandRequest(text: "check my list twice", language: .en, source: .test, session: "t"))
        #expect(provider.requests.count == 2)
        #expect(provider.requests.last?.toolChoice == LLMToolChoice.none)
        #expect(response.message.contains("limit of tool rounds"), Comment(rawValue: "\(response.status): \(response.message)"))
        #expect(response.message.contains("2 reminders"))
        #expect(response.results.filter { $0.tool.rawValue == "reminders.list" }.count == 1)
    }

    @Test func aModelThatAnswersAtTheLimitIsQuoted() async throws {
        let settings: IntelligenceSettings = { var s = ScriptedRegistryFactory.settings; s.maxToolRounds = 1; return s }()
        let provider = ScriptedProvider(script: [
            LLMCompletion(text: "", toolCalls: [LLMToolCall(id: "c1", name: "reminders__list", argumentsJSON: "{}")], finishReason: .toolCalls),
            LLMCompletion(text: "You have milk and eggs on the list.", finishReason: .stop),
        ])
        let registry = ScriptedRegistryFactory.make(provider: provider)
        let planner = FridayPlanner(providers: registry, router: IntentRouter(), settings: { settings })
        let engine = ActionEngine(registry: ToolRegistry(integrations: [FakeReminders(created: .init())]), interpreter: planner, settings: InMemorySettings())
        let response = await engine.process(CommandRequest(text: "what's on my list", language: .en, source: .test, session: "t"))
        #expect(response.message == "You have milk and eggs on the list.", Comment(rawValue: response.message))
    }
}

struct FailingSearch: AppIntegration {
    let id: IntegrationID = "notes"
    let displayName = LocalizedText("Notes")
    let summary = LocalizedText("fake")
    let symbolName = "note"
    let permissionRequirements: [PermissionRequirement] = []
    var tools: [ToolDescriptor] {
        [ToolDescriptor(name: "notes.search", integration: id, title: "Search notes", summary: "Search", parameters: [.string("query", "q", required: true)], safety: .readOnly)]
    }
    func status() async -> IntegrationStatus { IntegrationStatus(state: .ready) }
    func authorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }
    func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }
    func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
        throw JarvisError.failed("notes_down", en: "Notes did not answer.", es: "Notas no respondió.")
    }
}

@Suite struct RecoverableReadFailureTests {
    @Test func aFailedReadIsFedBackToTheModelInsteadOfEndingTheWorkflow() async throws {
        let provider = ScriptedProvider(script: [
            LLMCompletion(text: "", toolCalls: [LLMToolCall(id: "c1", name: "notes__search", argumentsJSON: #"{"query":"dentist"}"#)], finishReason: .toolCalls),
            LLMCompletion(text: "I couldn't search your notes: Notes did not answer.", finishReason: .stop),
        ])
        let registry = ScriptedRegistryFactory.make(provider: provider)
        let planner = FridayPlanner(providers: registry, router: IntentRouter(), settings: { ScriptedRegistryFactory.settings })
        let engine = ActionEngine(registry: ToolRegistry(integrations: [FailingSearch(), FakeReminders(created: .init())]), interpreter: planner, settings: InMemorySettings())
        let response = await engine.process(CommandRequest(text: "find my note about the dentist", language: .en, source: .test, session: "t"))
        #expect(provider.requests.count == 2)
        #expect(provider.requests[1].messages.contains { $0.role == .user && $0.text.contains("Notes did not answer.") })
        #expect(response.message.contains("couldn't search"), Comment(rawValue: "\(response.status): \(response.message)"))
    }
}

@Suite struct WorkflowRoutingTests {
    @Test func continuationRoundsKeepTheirOwnWorkflowRouting() async throws {
        let provider = ScriptedProvider(script: [])
        let registry = ScriptedRegistryFactory.make(provider: provider)
        let planner = FridayPlanner(providers: registry, router: IntentRouter(), settings: { ScriptedRegistryFactory.settings })
        let tools = [
            ToolDescriptor(name: "music.play", integration: "music", title: "Play", summary: "Play music", parameters: [.string("query", "q", required: true)], safety: .modifying),
            ToolDescriptor(name: "reminders.create", integration: "reminders", title: "Create", summary: "Create", parameters: [.string("title", "t", required: true)], safety: .modifying),
        ]
        func request(_ text: String) -> InterpretationRequest {
            InterpretationRequest(text: text, language: .en, now: Date(), calendar: .current, settings: JarvisSettings(), tools: tools)
        }
        let music = request("play some jazz")
        _ = try await planner.interpret(music)
        #expect(planner.lastDiagnostics?.routing?.category == .music)
        // Another session routes in between.
        _ = try await planner.interpret(request("remind me to buy milk"))
        #expect(planner.lastDiagnostics?.routing?.category == .reminders)
        // Round 2 of the music workflow is still narrowed for music, not for the reminder that routed last.
        var second = music
        second.round = 1
        second.observations = [ToolResult(callID: UUID(), tool: "music.play", status: .completed, message: "Playing jazz")]
        _ = try await planner.interpret(second)
        #expect(planner.lastDiagnostics?.routing?.category == .music)
        #expect(planner.workflowRouting(for: second)?.category == .music)
    }
}

struct FakeCalendar: AppIntegration {
    let id: IntegrationID = "calendar"
    let displayName = LocalizedText("Calendar")
    let summary = LocalizedText("fake")
    let symbolName = "calendar"
    let permissionRequirements: [PermissionRequirement] = []
    var tools: [ToolDescriptor] {
        [ToolDescriptor(name: "calendar.list_events", integration: id, title: "List events", summary: "List events in a range", parameters: [.string("start", "start"), .string("end", "end"), .string("day", "day"), .string("calendar", "calendar")], safety: .readOnly)]
    }
    func status() async -> IntegrationStatus { IntegrationStatus(state: .ready) }
    func authorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }
    func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }
    func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
        .done(ToolOutput(message: "1 event: Dentist 10:00", data: ["items": [["title": "Dentist", "start": "10:00"]]], verification: .notApplicable))
    }
}

@Suite struct PersonalDataGuardTests {
    @Test func inventedCalendarAnswersAreNeverShown() async throws {
        // The model answers twice in prose without reading the calendar: Friday must not repeat the invented events.
        let provider = ScriptedProvider(script: [
            LLMCompletion(text: "You have a meeting with the team at 10 and an interview at 2.", finishReason: .stop),
            LLMCompletion(text: "Tomorrow: team meeting at 10.", finishReason: .stop),
        ])
        let registry = ScriptedRegistryFactory.make(provider: provider)
        let planner = FridayPlanner(providers: registry, router: IntentRouter(), settings: { ScriptedRegistryFactory.settings })
        let tools = ToolRegistry(integrations: [FakeCalendar(), FridayMetaIntegration()])
        let engine = ActionEngine(registry: tools, interpreter: planner, settings: InMemorySettings())
        let response = await engine.process(CommandRequest(text: "what do I have on my calendar tomorrow?", language: .en, source: .test, session: "t"))
        #expect(!response.message.contains("interview"))
        #expect(!response.message.contains("team meeting"))
        // Either the honest refusal, or the deterministic parser's real read of the calendar: never the invention.
        let honest = response.message.contains("without reading your data") || response.message.contains("could not")
        let real = response.results.contains { $0.tool.rawValue == "calendar.list_events" } && response.message.contains("Dentist")
        #expect(honest || real, Comment(rawValue: response.message))
        #expect(provider.requests.count == 2)
        #expect(provider.requests.last?.toolChoice == .required)
    }

    @Test func theRetryWithARequiredToolCallSucceeds() async throws {
        let provider = ScriptedProvider(script: [
            LLMCompletion(text: "You have a meeting at 10.", finishReason: .stop),
            LLMCompletion(text: "", toolCalls: [LLMToolCall(id: "c1", name: "calendar__list_events", argumentsJSON: #"{"day":"tomorrow"}"#)], finishReason: .toolCalls),
            LLMCompletion(text: "Tomorrow you have the dentist at 10:00.", finishReason: .stop),
        ])
        let registry = ScriptedRegistryFactory.make(provider: provider)
        let planner = FridayPlanner(providers: registry, router: IntentRouter(), settings: { ScriptedRegistryFactory.settings })
        let tools = ToolRegistry(integrations: [FakeCalendar(), FridayMetaIntegration()])
        let engine = ActionEngine(registry: tools, interpreter: planner, settings: InMemorySettings())
        let response = await engine.process(CommandRequest(text: "qué tengo en el calendario mañana", language: .es, source: .test, session: "t"))
        #expect(response.status == .completed, Comment(rawValue: response.message))
        #expect(response.message.contains("dentist"))
        #expect(response.results.contains { $0.tool.rawValue == "calendar.list_events" })
    }
}
