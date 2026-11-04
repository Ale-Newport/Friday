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
