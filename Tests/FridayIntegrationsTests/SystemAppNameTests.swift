import Foundation
import FridayCore
import Testing

@testable import FridayIntegrations

/// Replies name the app in the language of the reply (#2: "abre la Calculadora" answered "Abrí Calculator",
/// while closing it answered "Cerré Calculadora").
@Suite struct SystemAppNameTests {
    final class FakeSystem: SystemOperating, @unchecked Sendable {
        let installed: [JSONValue]
        let running: [JSONValue]
        init(installed: [JSONValue], running: [JSONValue]) { self.installed = installed; self.running = running }
        func applications(runningOnly: Bool) async -> [JSONValue] { runningOnly ? running : installed }
        func openApplication(bundleID: String) async throws {}
        func closeApplication(bundleID: String) async throws -> Bool { true }
        func openURL(_ url: URL) async -> Bool { true }
        func clipboard() async -> String? { nil }
        func setClipboard(_ text: String) async -> Bool { true }
        func information() async -> JSONValue { .object([:]) }
        func screenshot() async throws -> String { "" }
    }

    static let calculatorInstalled: JSONValue = [
        "id": "com.apple.calculator", "name": "Calculator", "alt_name": "Calculadora",
        "name_en": "Calculator", "name_es": "Calculadora",
    ]
    static let calculatorRunning: JSONValue = [
        "id": "com.apple.calculator", "name": "Calculadora", "alt_name": "Calculator", "running": true,
        "name_en": "Calculator", "name_es": "Calculadora",
    ]
    static let chromeInstalled: JSONValue = ["id": "com.google.Chrome", "name": "Google Chrome"]

    private func registry() -> ToolRegistry {
        let system = FakeSystem(installed: [Self.calculatorInstalled, Self.chromeInstalled], running: [Self.calculatorRunning])
        return ToolRegistry(integrations: [SystemIntegration(native: system, scripts: FakeScripts())])
    }

    @Test func openingAndClosingUseTheSameNameInSpanish() async throws {
        let es = executionContext(language: .es)
        let opened = try await registry().run("system.open_app", ["application": "Calculadora"], context: es)
        let closed = try await registry().run("system.close_app", ["application": "Calculadora"], context: es)
        #expect(opened.output?.message == "Abrí Calculadora")
        #expect(closed.output?.message == "Cerré Calculadora")
    }

    @Test func englishRepliesUseTheEnglishNameEvenWhenTheSystemIsInSpanish() async throws {
        let en = executionContext(language: .en)
        let opened = try await registry().run("system.open_app", ["application": "Calculator"], context: en)
        let closed = try await registry().run("system.close_app", ["application": "calculator"], context: en)
        #expect(opened.output?.message == "Opened Calculator")
        #expect(closed.output?.message == "Closed Calculator")
    }

    @Test func closingAnInstalledAppThatIsNotRunningSaysSo() async throws {
        let system = FakeSystem(installed: [Self.calculatorInstalled, Self.chromeInstalled], running: [])
        let registry = ToolRegistry(integrations: [SystemIntegration(native: system, scripts: FakeScripts())])
        let en = try await registry.run("system.close_app", ["application": "Calculator"], context: executionContext(language: .en))
        #expect(en.output?.message == "Calculator isn't open.")
        let es = try await registry.run("system.close_app", ["application": "Calculadora"], context: executionContext(language: .es))
        #expect(es.output?.message == "Calculadora no está abierta.")
        await #expect(throws: (any Error).self) {
            try await registry.run("system.close_app", ["application": "Nonexistent Thing"], context: executionContext(language: .en))
        }
    }

    @Test func appsWithoutTranslationsKeepTheirName() async throws {
        let opened = try await registry().run("system.open_app", ["application": "Chrome"], context: executionContext(language: .es))
        #expect(opened.output?.message == "Abrí Google Chrome")
    }

    @Test func theRealCalculatorBundleHasBothNames() {
        let url = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        guard FileManager.default.fileExists(atPath: url.path), #available(macOS 15.4, *) else { return }
        let names = NativeSystemOperations.languageNames(url)
        #expect(names["name_en"]?.stringValue == "Calculator")
        #expect(names["name_es"]?.stringValue == "Calculadora")
    }
}
