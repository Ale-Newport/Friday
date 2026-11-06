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
        // Describing the screen degrades to Accessibility text without Screen Recording, so it must not be blocked by it.
        #expect(requirement("computer.describe_screen") == ComputerPermissions.accessibility.id)
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
        // Screen Recording is optional: the integration is ready as soon as Accessibility is granted.
        if AXIsProcessTrusted() {
            #expect(status.state == .ready)
            #expect((status.detail == nil) == CGPreflightScreenCaptureAccess())
        } else {
            #expect(status.state == .needsPermission)
            #expect(status.detail?.en.contains("Accessibility") == true)
            #expect(status.detail?.es.contains("Accesibilidad") == true)
        }
    }

    @Test func rejectsWindowIDsOutsideThirtyTwoBits() throws {
        let registry = registry
        for tool in [ComputerIntegration.focusWindow, ComputerIntegration.screenshot, ComputerIntegration.closeWindow] {
            #expect(throws: JarvisError.self, Comment(rawValue: tool.rawValue)) { try registry.validate(ToolCall(tool: tool, arguments: ["window_id": 4_294_967_296])) }
            #expect(throws: JarvisError.self, Comment(rawValue: tool.rawValue)) { try registry.validate(ToolCall(tool: tool, arguments: ["window_id": 0])) }
            #expect(throws: Never.self, Comment(rawValue: tool.rawValue)) { try registry.validate(ToolCall(tool: tool, arguments: ["window_id": 4_294_967_295])) }
        }
        #expect(try ComputerIntegration.windowID(1) == 1)
        #expect(try ComputerIntegration.windowID(Int(UInt32.max)) == UInt32.max)
        for bad in [0, -1, Int(UInt32.max) + 1, Int.max, Int.min] {
            #expect(throws: JarvisError.self, Comment(rawValue: String(bad))) { try ComputerIntegration.windowID(bad) }
        }
    }

    @Test func describeScreenAndClickDeclareTheirSafetyParameters() {
        let byName = Dictionary(uniqueKeysWithValues: integration.tools.map { ($0.name.rawValue, $0) })
        let save = byName["computer.describe_screen"]?.parameter(named: "save_screenshot")
        #expect(save?.defaultValue == false, "nothing is written to disk unless asked")
        #expect(byName["computer.describe_screen"]?.summary.contains("Accessibility text alone") == true)
        #expect(byName["computer.click"]?.parameter(named: "expect_label") != nil)
        #expect(byName["computer.type_text"]?.summary.contains("never as Enter") == true)
        let ok = try? registry.validate(ToolCall(tool: ComputerIntegration.describeScreen, arguments: ["save_screenshot": true]))
        #expect(ok?.bool("save_screenshot") == true)
    }

    @Test func menuCloseCommandsAskFirst() async throws {
        let call = try registry.validate(ToolCall(tool: ComputerIntegration.menu, arguments: ["path": "File > Close"]))
        let outcome = try await integration.execute(call, context: executionContext())
        #expect(outcome.confirmation?.prompt == "Run the menu command File > Close?")
        #expect(outcome.confirmation?.destructive == true)
        let spanish = try registry.validate(ToolCall(tool: ComputerIntegration.menu, arguments: ["items": ["Archivo", "Cerrar todo"]]))
        let outcomeES = try await integration.execute(spanish, context: executionContext(language: .es))
        #expect(outcomeES.confirmation?.prompt == "¿Ejecutar el comando de menú Archivo > Cerrar todo?")
    }

    @Test func lineBreaksAreNormalisedBeforeTyping() {
        #expect(AccessibilityService.normalizedLineBreaks("a\r\nb\rc\nd") == "a\nb\nc\nd")
        #expect(AccessibilityService.normalizedLineBreaks("plain") == "plain")
        let refusal = MultilineInsertionRefused(app: AppInfo(pid: 1, bundleID: nil, name: "Terminal", localizedName: "Terminal"), target: "", lines: 3)
        #expect(refusal.lines == 3)
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

@Suite struct ProcessSupportTests {
    @Test func drainsBothPipesSoAChattyStderrCannotBlockStdout() async throws {
        // 300 KB on stderr is far more than a pipe buffer holds; the child must still finish and report stdout.
        let result = try await ProcessSupport.run(
            executable: "/bin/sh", arguments: ["-c", "head -c 300000 /dev/zero >&2; echo ok"], timeout: 10)
        #expect(result.status == 0)
        #expect(result.standardOutput == "ok\n")
        #expect(result.standardError.utf8.count == 300_000)
    }

    @Test func timeoutEscalatesToSigkillForChildrenThatIgnoreSigterm() async throws {
        let started = Date()
        await #expect(throws: ProcessFailure.timedOut) {
            try await ProcessSupport.run(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; sleep 30"], timeout: 0.3)
        }
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 0.3 + ProcessSupport.killGracePeriod + 5, "the child must be killed shortly after the grace period, not after 30 s")
    }

    @Test func reportsOrdinaryExitStatusAndOutput() async throws {
        let result = try await ProcessSupport.run(executable: "/bin/sh", arguments: ["-c", "echo out; echo err >&2; exit 3"], timeout: 5)
        #expect(result.status == 3)
        #expect(result.standardOutput == "out\n")
        #expect(result.standardError == "err\n")
        await #expect(throws: ProcessFailure.self) {
            try await ProcessSupport.run(executable: "/nonexistent/binary", arguments: [], timeout: 1)
        }
    }
}

@Suite struct ScreenshotRetentionTests {
    @Test func pruneKeepsOnlyRecentScreenshots() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("friday-screenshots-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        func write(_ name: String, age: TimeInterval) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try Data([0xFF, 0xD8]).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now - age], ofItemAtPath: url.path)
            return url
        }
        var recent: [URL] = []
        for index in 0..<25 { recent.append(try write("screenshot-\(index).jpg", age: Double(index) * 60)) }
        let old = try write("screenshot-old.jpg", age: 2 * 24 * 3600)
        let other = try write("notes.txt", age: 10 * 24 * 3600)
        let newest = recent[0]

        let removed = ScreenCaptureService.pruneScreenshots(in: folder, keeping: newest, now: now)
        #expect(removed == 6, "25 recent + 1 old: everything beyond the newest 20 and the old one go")
        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(remaining.count == 21)
        #expect(remaining.contains("notes.txt"), "only JPEGs are touched")
        #expect(remaining.contains(newest.lastPathComponent))
        #expect(!remaining.contains(old.lastPathComponent))
        #expect(!remaining.contains("screenshot-24.jpg"))
        #expect(remaining.contains("screenshot-19.jpg"))
        _ = other
        // The file just written always survives, even when it is the oldest and beyond the limit.
        let stale = try write("screenshot-just-written.jpg", age: 5 * 24 * 3600)
        #expect(ScreenCaptureService.pruneScreenshots(in: folder, keeping: stale, now: now) == 0)
        #expect(FileManager.default.fileExists(atPath: stale.path))
        // Without the exemption it goes (old and beyond the newest 20).
        #expect(ScreenCaptureService.pruneScreenshots(in: folder, now: now) == 1)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(ScreenCaptureService.pruneScreenshots(in: URL(fileURLWithPath: "/nonexistent/folder"), now: now) == 0)
    }
}
