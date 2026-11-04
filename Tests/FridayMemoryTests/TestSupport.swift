import Foundation
import FridayCore
import FridayMemory

/// A fixed "now" so recency boosts and timestamps are deterministic.
let fixedNow = Date(timeIntervalSince1970: 1_792_238_880)

func executionContext(language: Language = .en, confirmed: Bool = false, now: Date = fixedNow) -> ExecutionContext {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
    calendar.firstWeekday = 2
    return ExecutionContext(language: language, now: now, calendar: calendar, settings: JarvisSettings(), source: .test, isConfirmed: confirmed)
}

extension ToolRegistry {
    /// Validates and runs `tool` the way the engine would: schema validation first, then the integration.
    func run(_ tool: ToolName, _ arguments: JSONObject, context: ExecutionContext = executionContext()) async throws -> ToolOutcome {
        let validated = try validate(ToolCall(tool: tool, arguments: arguments))
        guard let integration = integration(for: tool) else { throw JarvisError.failed("none", en: "none", es: "ninguna") }
        return try await integration.execute(validated, context: context)
    }

    /// Re-runs the exact call a confirmation request carries, marked as confirmed.
    func confirm(_ request: ConfirmationRequest, language: Language = .en) async throws -> ToolOutcome {
        let validated = try validate(request.call)
        guard let integration = integration(for: request.call.tool) else { throw JarvisError.failed("none", en: "none", es: "ninguna") }
        return try await integration.execute(validated, context: executionContext(language: language, confirmed: true))
    }
}

extension ToolOutcome {
    var output: ToolOutput? { if case .done(let output) = self { return output } else { return nil } }
    var confirmation: ConfirmationRequest? { if case .confirm(let value) = self { return value } else { return nil } }
    var clarification: Clarification? { if case .clarify(let value) = self { return value } else { return nil } }
}

func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("friday-memory-tests-" + UUID().uuidString, isDirectory: true)
        .appendingPathComponent("memory.sqlite")
}
