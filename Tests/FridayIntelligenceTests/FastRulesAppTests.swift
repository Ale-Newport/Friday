import Foundation
import Testing
import FridayCore
@testable import FridayIntelligence

@Suite struct FastRulesAppTests {
    private let tools: [ToolDescriptor] = [
        ToolDescriptor(name: "system.open_app", integration: "system", title: "Open app", summary: "Open", parameters: [.string("application", "n", required: true)], safety: .modifying),
        ToolDescriptor(name: "system.close_app", integration: "system", title: "Close app", summary: "Close", parameters: [.string("application", "n", required: true)], safety: .modifying),
    ]

    @Test(arguments: [
        ("abre Notas", "Notes"), ("open Notes", "Notes"), ("abre la Calculadora", "Calculator"), ("Abre Chrome", "Google Chrome"),
        ("launch Safari", "Safari"), ("abre el calendario", "Calendar"), ("open Google Chrome", "Google Chrome"), ("inicia Música", "Music"),
        ("open Notes instead", "Notes"), ("abre Notas entonces", "Notes"), ("open Calculator now", "Calculator"),
    ])
    func openCommandsBecomeOpenApp(text: String, expected: String) {
        let plan = FastRules.plan(for: text, language: .es, tools: tools)
        #expect(plan?.steps.first?.tool.rawValue == "system.open_app", Comment(rawValue: "no plan for \(text)"))
        #expect(plan?.steps.first?.arguments["application"]?.stringValue == expected, Comment(rawValue: "got \(plan?.steps.first?.arguments["application"]?.stringValue ?? "nil") for \(text)"))
    }

    @Test(arguments: ["cierra Notas", "close Notes", "cierra la Calculadora", "quit Safari"])
    func closeCommandsBecomeCloseApp(text: String) {
        let plan = FastRules.plan(for: text, language: .es, tools: tools)
        #expect(plan?.steps.first?.tool.rawValue == "system.close_app", Comment(rawValue: "no plan for \(text)"))
    }

    @Test(arguments: ["open the door", "abre una nota nueva con la lista", "open the file report.pdf", "abre la ventana de ajustes"])
    func nonAppOpensAreLeftToTheModel(text: String) {
        #expect(FastRules.plan(for: text, language: .es, tools: tools) == nil, Comment(rawValue: text))
    }
}
