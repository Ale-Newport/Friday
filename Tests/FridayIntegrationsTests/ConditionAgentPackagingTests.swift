import Foundation
import FridayCore
import Testing

@testable import FridayIntegrations

/// The rain-check launch agent is packaged by project.yml (the `FridayConditionAgent` app target embedded in
/// Friday.app) and registered through `ConditionService.plistName`. Nothing ties the plist, the agent's Info.plist, the
/// XcodeGen spec and the constants together before an app build, so these checks keep them consistent.
@Suite struct ConditionAgentPackagingTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func plist(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(relativePath))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func launchdPlistNamesTheEmbeddedAgent() throws {
        let plist = try Self.plist("Resources/LaunchAgents/" + ConditionService.plistName)
        #expect(plist["Label"] as? String == ConditionService.launchdLabel)
        #expect(ConditionService.launchdLabel == "com.alejandro.friday.conditions")
        #expect(plist["BundleProgram"] as? String == ConditionService.agentBundleProgram)
        #expect(plist["StartInterval"] as? Int == 900)
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["LimitLoadToSessionType"] as? String == "Aqua")
    }

    @Test func agentInfoPlistDescribesAUILessHelper() throws {
        let plist = try Self.plist("Agent/Info.plist")
        #expect(plist["CFBundleName"] as? String == ConditionService.agentName)
        #expect(plist["CFBundleExecutable"] as? String == "$(EXECUTABLE_NAME)")
        #expect(plist["CFBundleIdentifier"] as? String == "$(PRODUCT_BUNDLE_IDENTIFIER)")
        #expect(plist["LSUIElement"] as? Bool == true)
        #expect(plist["NSPrincipalClass"] as? String == "NSApplication")
        #expect(FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("Agent/ConditionAgent.swift").path))
    }

    @Test func projectSpecBuildsAndEmbedsTheAgent() throws {
        let spec = try String(contentsOf: Self.root.appendingPathComponent("project.yml"), encoding: .utf8)
        #expect(spec.contains("FridayConditionAgent:"))
        #expect(spec.contains("- target: FridayConditionAgent"))
        #expect(spec.contains("PRODUCT_NAME: \(ConditionService.agentName)"))
        #expect(spec.contains("PRODUCT_BUNDLE_IDENTIFIER: \(ConditionService.agentBundleID)"))
        #expect(ConditionService.agentBundleID.hasPrefix(ConditionService.parentBundleID + "."))
        #expect(spec.contains("subpath: Contents/Library/LoginItems"))
        #expect(spec.contains("subpath: Contents/Library/LaunchAgents"))
        #expect(spec.contains("Resources/LaunchAgents/\(ConditionService.plistName)"))
        #expect(spec.contains("path: Agent"))
    }

    @Test func parentSettingsReadTheKeyFridayAppSaves() throws {
        let suite = "friday.tests.conditions." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ConditionService.settingsKey == "friday.engine.settings.v1")
        #expect(ConditionService.parentSettings(defaults: defaults).capabilities.backgroundConditionsEnabled == false)
        var settings = JarvisSettings()
        settings.capabilities.backgroundConditionsEnabled = true
        UserDefaultsSettingsStore(defaults: defaults, key: ConditionService.settingsKey).save(settings)
        #expect(ConditionService.parentSettings(defaults: defaults).capabilities.backgroundConditionsEnabled == true)
    }

    @Test func lastAgentStatusReadsWhatTheAgentWrites() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("friday-agent-status-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ConditionService.lastAgentStatus(url: url) == nil)
        let status: JSONValue = [
            "notifications_authorized": .bool(true),
            "checked_at": .string("2026-11-06T10:00:00+01:00"),
            "agent_bundle": .string(ConditionService.agentBundleID),
        ]
        try JSONEncoder().encode(status).write(to: url)
        let read = try #require(ConditionService.lastAgentStatus(url: url))
        #expect(read.notificationsAuthorized)
        #expect(read.agentBundleID == ConditionService.agentBundleID)
        #expect(read.checkedAt != nil)
        try JSONEncoder().encode(JSONValue.object(["notifications_authorized": .bool(false)])).write(to: url)
        #expect(ConditionService.lastAgentStatus(url: url)?.notificationsAuthorized == false)
    }

    @Test func conditionsIntegrationReportsSetupUntilTheAgentIsEnabled() async {
        let disabled = ConditionsIntegration(enabled: { false }, notificationsAuthorized: { false })
        let status = await disabled.status()
        #expect(status.state == .needsSetup)
        #expect(status.detail?.en.contains("Settings > Integrations") == true)
        let enabled = ConditionsIntegration(enabled: { true }, notificationsAuthorized: { true })
        #expect(await enabled.status().state == .ready)
    }
}
