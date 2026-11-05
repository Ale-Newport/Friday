import Foundation
import Testing
import FridayCore
@testable import FridayIntelligence

private func bigCatalogue() -> [ToolDescriptor] {
    var tools: [ToolDescriptor] = [
        ToolDescriptor(name: "friday.find_tools", integration: "friday", title: "Find tools", summary: "Find", parameters: [.string("query", "q", required: true)], safety: .readOnly),
        ToolDescriptor(name: "friday.ask_user", integration: "friday", title: "Ask", summary: "Ask the user", parameters: [.string("question", "q", required: true)], safety: .readOnly),
        ToolDescriptor(name: "friday.current_time", integration: "friday", title: "Time", summary: "Now", safety: .readOnly),
        ToolDescriptor(name: "memory.remember", integration: "memory", title: "Remember", summary: "Store a fact", parameters: [.string("text", "t", required: true)], safety: .modifying),
        ToolDescriptor(name: "memory.recall", integration: "memory", title: "Recall", summary: "Find facts", safety: .readOnly),
        ToolDescriptor(name: "reminders.create", integration: "reminders", title: "Create reminder", summary: "Create a reminder in a list", parameters: [.string("title", "title", required: true)], safety: .modifying),
        ToolDescriptor(name: "reminders.list", integration: "reminders", title: "List reminders", summary: "List reminders", safety: .readOnly),
        ToolDescriptor(name: "music.play", integration: "music", title: "Play", summary: "Play a song, album or playlist", parameters: [.string("query", "q", required: true)], safety: .modifying),
    ]
    for index in 0..<60 {
        tools.append(ToolDescriptor(name: ToolName("misc.tool_\(index)"), integration: "misc", title: "Misc \(index)", summary: "Unrelated utility number \(index)", safety: .readOnly))
    }
    return tools
}

@Suite struct NarrowingTests {
    private func request(_ text: String) -> InterpretationRequest {
        InterpretationRequest(text: text, language: .en, now: Date(), calendar: .current, settings: JarvisSettings(), tools: bigCatalogue())
    }

    @Test func smallCataloguesAreOfferedWhole() {
        let few = Array(bigCatalogue().prefix(8))
        let chosen = FridayPlanner.narrow(few, for: request("anything"), routing: .unknown, limit: 14)
        #expect(chosen.count == few.count)
    }

    @Test func metaToolsAndRelevantToolsSurviveTheCut() {
        let chosen = FridayPlanner.narrow(bigCatalogue(), for: request("remind me to buy oat milk"), routing: .unknown, limit: 14)
        let names = Set(chosen.map(\.name.rawValue))
        #expect(chosen.count <= 14)
        let spanish = FridayPlanner.narrow(bigCatalogue(), for: request("recuérdame comprar leche de avena"), routing: .unknown, limit: 14)
        #expect(spanish.contains { $0.name.rawValue == "reminders.create" })
        #expect(names.contains("friday.find_tools"))
        #expect(names.contains("friday.ask_user"))
        #expect(names.contains("memory.recall"))
        #expect(names.contains("reminders.create"))
    }

    @Test func routedCategoryComesFirst() {
        let routing = RoutingDecision(category: .music, confidence: 0.9, multistepProbability: 0.1, dangerProbability: 0, questionProbability: 0, source: "rules", latencyMs: 0)
        let chosen = FridayPlanner.narrow(bigCatalogue(), for: request("put something on"), routing: routing, limit: 8)
        #expect(chosen.contains { $0.name.rawValue == "music.play" })
        #expect(chosen.count <= 8)
    }

    @Test func toolsUsedInTheWorkflowStayAvailable() {
        var req = request("and now the second step")
        req.observations = [ToolResult(callID: UUID(), tool: "misc.tool_57", status: .completed, message: "ok")]
        let chosen = FridayPlanner.narrow(bigCatalogue(), for: req, routing: .unknown, limit: 10)
        #expect(chosen.contains { $0.name.rawValue == "misc.tool_57" })
    }

    @Test func areaSummaryListsIntegrations() {
        let summary = FridayPlanner.areaSummary(bigCatalogue())
        #expect(summary.contains("- reminders: create, list"))
        #expect(summary.contains("- misc:"))
        #expect(summary.contains("(60 tools)"))
    }

    @Test func profilesDependOnLocality() {
        #expect(FridayPlanner.ModelProfile.profile(for: CompatibleProvider(baseURL: URL(string: "http://127.0.0.1:11434/v1")!)).toolLimit == 20)
        #expect(FridayPlanner.ModelProfile.profile(for: CompatibleProvider(baseURL: URL(string: "https://openrouter.ai/api/v1")!)).toolLimit == 64)
    }
}

@Suite struct WakeWordTailTests {
    @Test func leadingTailOfTheWakeWordIsDropped() {
        let result = UtteranceNormalizer.normalize("vis, what time is it")
        #expect(result.text == "what time is it")
        #expect(result.strippedWakeWord)
    }

    @Test func ordinaryShortWordsAreKept() {
        #expect(UtteranceNormalizer.normalize("is it raining").text == "is it raining")
        #expect(UtteranceNormalizer.normalize("vis a vis the plan").text == "a vis the plan" || UtteranceNormalizer.normalize("vis a vis the plan").text == "vis a vis the plan")
        #expect(UtteranceNormalizer.normalize("abre Notas").text == "abre Notas")
    }
}
