import Foundation
import Testing
import FridayCore
@testable import FridayBrowser

@Suite struct WebAgentTests {
    @Test func toolsValidateTheirExamples() throws {
        let integration = WebAgentIntegration()
        let registry = ToolRegistry(integrations: [integration])
        #expect(registry.descriptors.map(\.name.rawValue).sorted() == ["web.cancel", "web.connect", "web.current_task", "web.focus", "web.status", "web.task"])
        for descriptor in registry.descriptors {
            for example in descriptor.examples {
                _ = try registry.validate(ToolCall(tool: descriptor.name, arguments: example.arguments))
            }
        }
    }

    @Test func withoutASidecarToolsReportSetupNotFailure() async {
        let integration = WebAgentIntegration()
        let status = await integration.status()
        #expect(status.state == .needsSetup)
        let descriptor = integration.tools.first { $0.name.rawValue == "web.status" }!
        if case .unavailable = await integration.authorization(for: descriptor) {} else { Issue.record("expected unavailable without a client") }
    }

    @Test func taskStateMergesEventsOnce() {
        let state = RunState()
        #expect(state.markHandled("c1"))
        #expect(!state.markHandled("c1"))
        state.setAnswer("hello", cards: .array([]))
        state.finish(status: "done", error: nil)
        state.finish(status: "failed", error: "late")   // first result wins
        let (answer, _, status, error) = state.snapshot()
        #expect(answer == "hello")
        #expect(status == "done")
        #expect(error == "late")
        #expect(RunState.isFinished("partial"))
        #expect(!RunState.isFinished("running"))
    }

    @Test func describesATaskInBothLanguages() {
        let task: JSONValue = ["status": "running", "steps": [["id": "1"], ["id": "2"]], "current": ["title": "Searching Google"], "waiting": .null]
        #expect(WebAgentIntegration.describe(task, language: .en).contains("2 steps"))
        #expect(WebAgentIntegration.describe(task, language: .es).contains("Ahora: Searching Google"))
    }
}
