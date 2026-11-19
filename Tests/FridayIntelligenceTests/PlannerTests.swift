import Foundation
import Testing
import FridayCore
@testable import FridayIntelligence

/// A tool catalogue of three integrations, enough to exercise selection, validation and planning.
private func catalogue() -> [ToolDescriptor] {
    [
        ToolDescriptor(name: "music.play", integration: "music", title: "Play", summary: "Play music", parameters: [.string("query", "what", required: true)], safety: .modifying),
        ToolDescriptor(name: "music.pause", integration: "music", title: "Pause", summary: "Pause", safety: .modifying),
        ToolDescriptor(name: "reminders.create", integration: "reminders", title: "Create reminder", summary: "Create", parameters: [.string("title", "title", required: true), .string("list", "list")], safety: .modifying),
        ToolDescriptor(name: "reminders.list", integration: "reminders", title: "List reminders", summary: "List", safety: .readOnly),
        ToolDescriptor(name: "files.trash", integration: "files", title: "Trash", summary: "Trash a file", parameters: [.string("path", "path", required: true)], safety: .destructive),
        ToolDescriptor(name: "friday.find_tools", integration: "friday", title: "Find tools", summary: "Find", parameters: [.string("query", "q", required: true)], safety: .readOnly),
        ToolDescriptor(name: "system.open_app", integration: "system", title: "Open app", summary: "Open", parameters: [.string("name", "n", required: true)], safety: .modifying),
    ]
}

@Suite struct ToolSelectionTests {
    @Test func confidentCategoryNarrowsToItsIntegrationsPlusCore() {
        let routing = RoutingDecision(category: .music, confidence: 0.9, multistepProbability: 0.1, dangerProbability: 0, questionProbability: 0, source: "rules", latencyMs: 0)
        let chosen = FridayPlanner.selectTools(all: catalogue(), routing: routing, threshold: 0.6, discovered: [], observations: [])
        let names = Set(chosen.map(\.name.rawValue))
        #expect(names.contains("music.play"))
        #expect(names.contains("friday.find_tools"))
        #expect(names.contains("system.open_app"))
        #expect(!names.contains("reminders.create"))
    }

    @Test func lowConfidenceOrMultistepOffersEverything() {
        let low = RoutingDecision(category: .music, confidence: 0.3, multistepProbability: 0.1, dangerProbability: 0, questionProbability: 0, source: "laya", latencyMs: 0)
        #expect(FridayPlanner.selectTools(all: catalogue(), routing: low, threshold: 0.6, discovered: [], observations: []).count == catalogue().count)
        let multi = RoutingDecision(category: .music, confidence: 0.9, multistepProbability: 0.9, dangerProbability: 0, questionProbability: 0, source: "laya", latencyMs: 0)
        #expect(FridayPlanner.selectTools(all: catalogue(), routing: multi, threshold: 0.6, discovered: [], observations: []).count == catalogue().count)
    }

    @Test func discoveredToolsAreAdded() {
        let routing = RoutingDecision(category: .music, confidence: 0.9, multistepProbability: 0.1, dangerProbability: 0, questionProbability: 0, source: "rules", latencyMs: 0)
        let chosen = FridayPlanner.selectTools(all: catalogue(), routing: routing, threshold: 0.6, discovered: ["reminders.create"], observations: [])
        #expect(chosen.contains { $0.name.rawValue == "reminders.create" })
    }
}

@Suite struct ProposalToPlanTests {
    private func request() -> InterpretationRequest {
        InterpretationRequest(text: "x", language: .en, now: Date(), calendar: .current, settings: JarvisSettings(), tools: catalogue())
    }

    @Test func validCallsBecomeAContinuingPlan() throws {
        let proposal = AIProposal(calls: [ProposedToolCall(tool: "reminders.list", arguments: [:])])
        guard case .plan(let plan) = try FridayPlanner.plan(from: proposal, request: request(), offered: catalogue(), routing: .unknown) else { Issue.record("expected plan"); return }
        #expect(plan.continues)
        #expect(plan.steps.count == 1)
    }

    @Test func unknownToolIsRejected() {
        let proposal = AIProposal(calls: [ProposedToolCall(tool: "nope.tool", arguments: [:])])
        #expect(throws: (any Error).self) { try FridayPlanner.plan(from: proposal, request: request(), offered: catalogue(), routing: .unknown) }
    }

    @Test func invalidArgumentsAreRejected() {
        let proposal = AIProposal(calls: [ProposedToolCall(tool: "music.play", arguments: [:])])  // missing required query
        #expect(throws: (any Error).self) { try FridayPlanner.plan(from: proposal, request: request(), offered: catalogue(), routing: .unknown) }
    }

    @Test func mixedBatchKeepsLeadingReadsOnly() throws {
        let proposal = AIProposal(calls: [
            ProposedToolCall(tool: "reminders.list", arguments: [:]),
            ProposedToolCall(tool: "reminders.create", arguments: ["title": "milk"]),
        ])
        guard case .plan(let plan) = try FridayPlanner.plan(from: proposal, request: request(), offered: catalogue(), routing: .unknown) else { Issue.record("expected plan"); return }
        #expect(plan.steps.map(\.tool.rawValue) == ["reminders.list"])
    }

    @Test func replyAndQuestionMap() throws {
        if case .reply(let text) = try FridayPlanner.plan(from: AIProposal(reply: "Done."), request: request(), offered: [], routing: .unknown) { #expect(text == "Done.") } else { Issue.record("expected reply") }
        if case .clarification(let c) = try FridayPlanner.plan(from: AIProposal(clarifyingQuestion: "Which one?"), request: request(), offered: [], routing: .unknown) { #expect(c.question == "Which one?") } else { Issue.record("expected clarification") }
    }
}

@Suite struct FastPathTests {
    @Test func structuredConversionsAreSafeInBothLanguagesButWordyArithmeticIsNot() {
        let tools = [
            ToolDescriptor(name: "utilities.convert", integration: "utilities", title: "Convert", summary: "Convert", parameters: [.number("value", "v", required: true), .string("from", "f", required: true), .string("to", "t", required: true)], safety: .readOnly),
            ToolDescriptor(name: "utilities.calculate", integration: "utilities", title: "Calculate", summary: "Calculate", parameters: [.string("expression", "e", required: true)], safety: .readOnly),
        ]
        for text in ["convierte 3 tazas en mililitros", "pasa 2 hectáreas a metros cuadrados", "convert 26.2 miles to kilometers"] {
            let plan = ToolPlan(steps: [ToolCall(tool: "utilities.convert", arguments: ["value": 1, "from": "a", "to": "b"], sourceText: text)], language: .es, interpreter: "deterministic")
            #expect(FridayPlanner.isFastPathSafe(plan, tools: tools), "\(text)")
        }
        let wordy = ToolPlan(steps: [ToolCall(tool: "utilities.calculate", arguments: ["expression": "17*24"], sourceText: "seventeen times twenty four")], language: .en, interpreter: "deterministic")
        #expect(!FridayPlanner.isFastPathSafe(wordy, tools: tools), "spoken arithmetic still goes to the model")
    }

    @Test func onlyLowRiskKnownToolsWithoutAssumptions() {
        let tools = catalogue()
        let safe = ToolPlan(steps: [ToolCall(tool: "music.pause")], language: .en, interpreter: "deterministic")
        #expect(FridayPlanner.isFastPathSafe(safe, tools: tools))
        let destructive = ToolPlan(steps: [ToolCall(tool: "files.trash", arguments: ["path": "/x"])], language: .en, interpreter: "deterministic")
        #expect(!FridayPlanner.isFastPathSafe(destructive, tools: tools))
        let assumed = ToolPlan(steps: [ToolCall(tool: "music.pause", assumptions: ["guessed"])], language: .en, interpreter: "deterministic")
        #expect(!FridayPlanner.isFastPathSafe(assumed, tools: tools))
        var noted = safe
        noted.notes = ["part not understood"]
        #expect(!FridayPlanner.isFastPathSafe(noted, tools: tools))
    }
}

@Suite struct MetaIntegrationTests {
    @Test func findToolsRanksByNameAndSummary() {
        let found = FridayMetaIntegration.search("create reminder", in: catalogue(), limit: 3)
        #expect(found.first?.name.rawValue == "reminders.create")
    }

    @Test func askUserBecomesClarification() async throws {
        let meta = FridayMetaIntegration()
        let registry = ToolRegistry(integrations: [meta])
        let call = try registry.validate(ToolCall(tool: "friday.ask_user", arguments: ["question": "Which?", "options": ["A", "B"]]))
        let context = ExecutionContext(language: .en, now: Date(), calendar: .current, settings: JarvisSettings(), source: .test)
        guard case .clarify(let clarification) = try await meta.execute(call, context: context) else { Issue.record("expected clarify"); return }
        #expect(clarification.question.contains("1. A"))
    }
}

@Suite struct RefusalRecoveryTests {
    @Test func refusalsAreRecognisedInBothLanguages() {
        for reply in ["Lo siento, pero no puedo acceder a internet.", "No tengo acceso a información en tiempo real.", "Como modelo de lenguaje, no puedo abrir aplicaciones.",
                      "I'm sorry, but I can't browse the web.", "As an AI, I don't have access to your calendar.", "I don't have real-time data about prices."] {
            #expect(FridayPlanner.looksLikeRefusal(reply), "\(reply)")
        }
        for reply in ["La capital de Australia es Canberra.", "Mañana tienes dos reuniones.", "Here's a joke: why did the scarecrow win an award?"] {
            #expect(!FridayPlanner.looksLikeRefusal(reply), "\(reply)")
        }
    }

    private func tools(withWeb: Bool) -> [ToolDescriptor] {
        var list = [ToolDescriptor(name: "reminders.list", integration: "reminders", title: "List reminders", summary: "List", safety: .readOnly)]
        if withWeb {
            list.append(ToolDescriptor(name: "web.task", integration: "web", title: "Browse", summary: "Browse", parameters: [.string("goal", "goal", required: true)], safety: .modifying))
        }
        return list
    }

    @Test func webShapedRequestsFallBackToTheBrowserAgent() throws {
        let request = InterpretationRequest(text: "¿Cuál es el precio del bitcoin hoy?", language: .es, now: Date(), calendar: .current, settings: JarvisSettings(), tools: tools(withWeb: true))
        let proposal = try #require(FridayPlanner.browserFallback(for: request, routing: .unknown))
        #expect(proposal.calls.first?.tool == "web.task")
        guard case .plan(let plan) = try FridayPlanner.plan(from: proposal, request: request, offered: [], routing: .unknown) else { Issue.record("expected plan"); return }
        #expect(plan.steps.first?.tool.rawValue == "web.task")
    }

    @Test func personalDataAndDangerNeverGoToTheBrowser() {
        let personal = InterpretationRequest(text: "¿Qué recordatorios tengo?", language: .es, now: Date(), calendar: .current, settings: JarvisSettings(), tools: tools(withWeb: true))
        #expect(FridayPlanner.browserFallback(for: personal, routing: .unknown) == nil)
        let noWeb = InterpretationRequest(text: "precio del bitcoin", language: .es, now: Date(), calendar: .current, settings: JarvisSettings(), tools: tools(withWeb: false))
        #expect(FridayPlanner.browserFallback(for: noWeb, routing: .unknown) == nil)
        let danger = RoutingDecision(category: .browser, confidence: 0.9, multistepProbability: 0.1, dangerProbability: 0.9, questionProbability: 0, source: "rules", latencyMs: 0)
        let buy = InterpretationRequest(text: "compra un iPhone en Amazon", language: .es, now: Date(), calendar: .current, settings: JarvisSettings(), tools: tools(withWeb: true))
        #expect(FridayPlanner.browserFallback(for: buy, routing: danger) == nil)
    }

    @Test func refusalsAndShortClaimsAreNotStreamed() {
        final class Box: @unchecked Sendable { let lock = NSLock(); var items: [String] = []; func withLock<T>(_ body: (inout [String]) -> T) -> T { lock.withLock { body(&items) } } }
        let seen = Box()
        var gate = StreamGate(onText: { text in seen.withLock { $0.append(text) } })
        gate.forward("Lo siento, pero no puedo acceder a internet para consultar eso ahora mismo.")
        gate.forward("Hecho.")
        #expect(seen.withLock { $0 }.isEmpty)
        gate.finish("Hecho.")
        #expect(seen.withLock { $0 } == ["Hecho."])
    }
}

@Suite struct KnowledgeRequestTests {
    @Test func storiesAndExplanationsAreKnowledge() {
        for text in ["Cuéntame la historia del Imperio Romano", "Oye Jarvis, explícame la fotosíntesis", "Tell me about black holes", "Dame una idea para cenar",
                     "cuéntame un chiste", "Describe the Eiffel Tower", "Escríbeme un poema corto"] {
            #expect(FridayPlanner.looksLikeKnowledgeRequest(text), "\(text)")
        }
        for text in ["Dame mis recordatorios", "Abre Notas", "Escribe un correo a Marta", "Tell Marta I'm late", "¿Qué hora es?"] {
            #expect(!FridayPlanner.looksLikeKnowledgeRequest(text), "\(text)")
        }
    }
}
