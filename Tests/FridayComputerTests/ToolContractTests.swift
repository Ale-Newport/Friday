import ApplicationServices
import Foundation
import FridayCore
import Testing

@testable import FridayComputer

@Suite struct ToolContractTests {
    let integration = ComputerIntegration()
    var registry: ToolRegistry { ToolRegistry(integrations: [integration]) }

    @Test func declaresTheExpectedTools() {
        let names = Set(integration.tools.map(\.name.rawValue))
        let expected: Set<String> = [
            "computer.frontmost", "computer.windows", "computer.displays", "computer.focus_app", "computer.focus_window", "computer.arrange_window",
            "computer.set_window_frame", "computer.minimize_window", "computer.close_window", "computer.ui_elements", "computer.click", "computer.type_text",
            "computer.press_keys", "computer.menu", "computer.selected_text", "computer.screenshot", "computer.describe_screen", "computer.lock_screen",
            "computer.set_appearance", "computer.scroll",
        ]
        #expect(names == expected)
        #expect(integration.tools.count == expected.count, "no duplicate tool names")
        #expect(integration.tools.allSatisfy { $0.integration == "computer" && $0.name.namespace == "computer" })
        #expect(!names.contains("system.screenshot") && !names.contains("system.open_app"))
    }

    @Test func everyExampleValidates() throws {
        let registry = registry
        var count = 0
        for descriptor in registry.descriptors {
            #expect(descriptor.examples.contains { $0.language == .en }, "\(descriptor.name) needs an English example")
            #expect(descriptor.examples.contains { $0.language == .es }, "\(descriptor.name) needs a Spanish example")
            for example in descriptor.examples {
                #expect(throws: Never.self, "\(descriptor.name): \(example.phrase)") {
                    try registry.validate(ToolCall(tool: descriptor.name, arguments: example.arguments))
                }
                count += 1
            }
        }
        #expect(count >= 60)
    }

    @Test func schemaDescriptionIncludesEveryTool() {
        let schema = registry.schemaDescription()
        #expect(schema.arrayValue?.count == integration.tools.count)
        let click = schema.arrayValue?.first { $0["name"]?.stringValue == "computer.click" }
        #expect(click?["constraints"]?.arrayValue?.first?.stringValue == "at least one of: element_id, label")
        #expect(click?["permissions"]?.arrayValue?.compactMap(\.stringValue).contains("macos.accessibility") == true)
    }

    @Test func mapsToolsToPermissions() {
        func requirement(_ name: String) -> String? {
            integration.tools.first { $0.name.rawValue == name }.flatMap(integration.requirement(for:))?.id
        }
        #expect(requirement("computer.screenshot") == ComputerPermissions.screenRecording.id)
        #expect(requirement("computer.describe_screen") == ComputerPermissions.screenRecording.id)
        #expect(requirement("computer.set_appearance") == ComputerPermissions.systemEventsAutomation.id)
        for name in ["computer.ui_elements", "computer.click", "computer.type_text", "computer.press_keys", "computer.menu", "computer.arrange_window", "computer.selected_text", "computer.scroll", "computer.focus_window", "computer.close_window"] {
            #expect(requirement(name) == ComputerPermissions.accessibility.id, Comment(rawValue: name))
        }
        for name in ["computer.frontmost", "computer.windows", "computer.displays", "computer.focus_app", "computer.lock_screen"] {
            #expect(requirement(name) == nil, Comment(rawValue: name))
        }
    }

    @Test func authorizationReflectsTrustWithoutPrompting() async {
        let tool = integration.tools.first { $0.name == ComputerIntegration.click }!
        let state = await integration.authorization(for: tool)
        if AXIsProcessTrusted() {
            #expect(state == .authorized)
        } else {
            #expect(state == .notDetermined(ComputerPermissions.accessibility))
        }
        let frontmost = integration.tools.first { $0.name == ComputerIntegration.frontmost }!
        #expect(await integration.authorization(for: frontmost) == .authorized)
        let status = await integration.status()
        #expect(status.permissions.map(\.requirement.id) == [ComputerPermissions.accessibility.id, ComputerPermissions.screenRecording.id])
    }

    @Test func safetyFlagsAndTimeouts() {
        let byName = Dictionary(uniqueKeysWithValues: integration.tools.map { ($0.name.rawValue, $0) })
        #expect(byName["computer.close_window"]?.requiresConfirmation == true)
        for name in ["computer.frontmost", "computer.windows", "computer.displays", "computer.ui_elements", "computer.selected_text", "computer.screenshot", "computer.describe_screen"] {
            #expect(byName[name]?.safety == .readOnly, Comment(rawValue: name))
        }
        for name in ["computer.click", "computer.type_text", "computer.press_keys", "computer.menu", "computer.arrange_window", "computer.lock_screen", "computer.set_appearance", "computer.scroll"] {
            #expect(byName[name]?.safety == .modifying, Comment(rawValue: name))
        }
        #expect(byName["computer.type_text"]?.timeout == 60)
    }

    @Test func destructiveShortcutsAskFirst() async throws {
        let registry = registry
        let call = try registry.validate(ToolCall(tool: ComputerIntegration.pressKeys, arguments: ["keys": "cmd+q"]))
        let outcome = try await integration.execute(call, context: executionContext())
        let confirmation = try #require(outcome.confirmation)
        #expect(confirmation.destructive)
        #expect(confirmation.prompt.contains("cmd+q"))
        #expect(confirmation.call.arguments["keys"]?.stringValue == "cmd+q")
        let spanish = try await integration.execute(call, context: executionContext(language: .es))
        #expect(spanish.confirmation?.prompt.hasPrefix("¿Pulsar") == true)
    }

    @Test func riskyMenuCommandsAskFirst() async throws {
        let call = try registry.validate(ToolCall(tool: ComputerIntegration.menu, arguments: ["path": "Edit > Delete"]))
        let outcome = try await integration.execute(call, context: executionContext())
        #expect(outcome.confirmation?.prompt == "Run the menu command Edit > Delete?")
        let spanish = try registry.validate(ToolCall(tool: ComputerIntegration.menu, arguments: ["items": ["Archivo", "Eliminar"]]))
        let outcomeES = try await integration.execute(spanish, context: executionContext(language: .es))
        #expect(outcomeES.confirmation?.prompt == "¿Ejecutar el comando de menú Archivo > Eliminar?")
    }

    @Test func rejectsUnknownShortcutsBeforeTouchingTheSystem() async throws {
        let call = try registry.validate(ToolCall(tool: ComputerIntegration.pressKeys, arguments: ["keys": "hyper+banana"]))
        await #expect(throws: JarvisError.self) {
            try await integration.execute(call, context: executionContext())
        }
    }

    @Test func rejectsSingleLevelMenuPaths() async throws {
        let call = try registry.validate(ToolCall(tool: ComputerIntegration.menu, arguments: ["path": "File"]))
        await #expect(throws: JarvisError.self) {
            try await integration.execute(call, context: executionContext())
        }
    }

    @Test func validatorRejectsBadArguments() {
        let registry = registry
        #expect(throws: JarvisError.self) { try registry.validate(ToolCall(tool: ComputerIntegration.click, arguments: [:])) }
        #expect(throws: JarvisError.self) { try registry.validate(ToolCall(tool: ComputerIntegration.arrangeWindow, arguments: ["preset": "diagonal"])) }
        #expect(throws: JarvisError.self) { try registry.validate(ToolCall(tool: ComputerIntegration.scroll, arguments: ["direction": "down", "amount": 99])) }
        #expect(throws: JarvisError.self) { try registry.validate(ToolCall(tool: ComputerIntegration.setWindowFrame, arguments: ["x": 0, "y": 0])) }
        let ok = try? registry.validate(ToolCall(tool: ComputerIntegration.arrangeWindow, arguments: ["preset": "Left Half", "app": "Safari"]))
        #expect(ok?.string("preset") == "left_half")
    }

    @Test func permissionRequirementsAreBilingualWithSettingsLinks() {
        for requirement in integration.permissionRequirements {
            #expect(!requirement.title.en.isEmpty && !requirement.title.es.isEmpty)
            #expect(!requirement.rationale.en.isEmpty && !requirement.rationale.es.isEmpty)
            #expect(requirement.settingsURL?.hasPrefix("x-apple.systempreferences:") == true)
        }
        #expect(ComputerPermissions.SettingsPane.accessibility.url == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        #expect(ComputerPermissions.SettingsPane.screenCapture.url == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        #expect(ComputerPermissions.SettingsPane.notifications.url == "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        #expect(ComputerPermissions.SettingsPane.allCases.count == 9)
    }

    @Test func appleScriptArgumentsStayData() {
        #expect(ProcessSupport.appleScriptErrorCode("execution error: Not authorized to send Apple events to System Events. (-1743)") == -1743)
        #expect(ProcessSupport.appleScriptErrorCode("fine") == nil)
        #expect(ComputerIntegration.appearanceScript.contains("item 1 of argv"))
        #expect(!ComputerIntegration.appearanceScript.contains("\u{0000}"))
    }
}
