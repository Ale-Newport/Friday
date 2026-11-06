import AppKit
import Foundation
import FridayCore
import FridayIntegrations

/// The rain-check launch agent: a signed, UI-less application bundle (so UserNotifications has a real application
/// identity) that launchd starts for one bounded pass every 15 minutes — see
/// `Resources/LaunchAgents/com.alejandro.friday.conditions.plist` — independently of the foreground Friday process.
/// Started with `--authorize-notifications` (Settings ▸ Integrations ▸ Future conditions) it only asks for the
/// notification permission and records the answer where Friday.app reads it (`ConditionService.statusURL`).
///
/// Ported from Apple-Integrations' `Agent/ConditionAgent.swift`. The job store, the weather lookup and the
/// notifications are the same `FridayIntegrations` code Friday.app uses, so both processes share one job file; the
/// `FridayConditionAgent` target in project.yml builds this file and embeds the result in Friday.app.
@main
@MainActor
struct ConditionAgent {
    static func main() {
        let application = NSApplication.shared
        let authorize = CommandLine.arguments.contains("--authorize-notifications")
        application.setActivationPolicy(authorize ? .accessory : .prohibited)
        Task { @MainActor in
            let notifier = SystemConditionNotifications()
            let allowed = await notifier.allowed(request: authorize)
            let status: JSONValue = [
                "notifications_authorized": .bool(allowed),
                "checked_at": .string(ISODates.string(from: Date(), timeZone: .current)),
                "agent_bundle": .string(Bundle.main.bundleIdentifier ?? ""),
            ]
            if JarvisPaths.ensurePrivateDirectory(ConditionService.statusURL.deletingLastPathComponent()) {
                try? JSONEncoder().encode(status).write(to: ConditionService.statusURL, options: .atomic)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: ConditionService.statusURL.path)
            }
            // The toggle in Friday's settings is the only thing that turns evaluation on. It is re-read before every
            // job, so switching it off while a pass is running stops the pass.
            if !authorize && ConditionService.parentSettings().capabilities.backgroundConditionsEnabled {
                await ConditionJobStore().evaluate(isEnabled: {
                    ConditionService.parentSettings().capabilities.backgroundConditionsEnabled
                })
            }
            application.terminate(nil)
        }
        application.run()
    }
}
