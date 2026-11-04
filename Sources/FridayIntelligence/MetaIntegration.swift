import Foundation
import FridayCore

/// Friday's own tools: capability discovery for the planner and explicit questions to the user.
/// `friday.find_tools` lets the model ask for tool schemas it was not given (the planner narrows the tool set by
/// intent to keep prompts small and fast); `friday.ask_user` turns a question into a clarification the UI/voice
/// layer presents, instead of the model guessing.
public final class FridayMetaIntegration: AppIntegration, @unchecked Sendable {
    public let id: IntegrationID = "friday"
    public let displayName = LocalizedText(en: "Friday", es: "Friday")
    public let summary = LocalizedText(en: "Capability discovery and questions to you.", es: "Descubrimiento de capacidades y preguntas para ti.")
    public let symbolName = "sparkles"
    public let permissionRequirements: [PermissionRequirement] = []

    private let lock = NSLock()
    private var catalog: [ToolDescriptor] = []

    public init() {}

    /// Called once the registry exists (the registry contains this integration, so the catalog arrives later).
    public func setCatalog(_ descriptors: [ToolDescriptor]) {
        lock.withLock { catalog = descriptors.filter { $0.integration != id } }
    }

    public var tools: [ToolDescriptor] {
        [
            ToolDescriptor(
                name: "friday.find_tools", integration: id, title: "Find tools",
                summary: "Search Friday's full capability catalogue for tools matching a need (app name, action, object). Use it when none of the tools you were given fits the request; the matching tools become available for your next step.",
                parameters: [
                    .string("query", "What you need, e.g. 'resize window', 'send email', 'convert heic to png'", required: true, maxLength: 200),
                    .integer("limit", "Maximum tools to return", min: 1, max: 25, default: 10),
                ],
                safety: .readOnly, timeout: 5,
                examples: [
                    ToolExample("find a tool to resize the current window", arguments: ["query": "resize window"]),
                    ToolExample("busca una herramienta para enviar un correo", language: .es, arguments: ["query": "enviar correo"]),
                ]),
            ToolDescriptor(
                name: "friday.ask_user", integration: id, title: "Ask the user",
                summary: "Ask the user a short question when something essential is missing or ambiguous (which of several items, a missing detail, a consequential choice). Optionally offer options. Do not use it for confirmations of tools that confirm by themselves.",
                parameters: [
                    .string("question", "The question, in the user's language", required: true, maxLength: 500),
                    .strings("options", "Up to 6 short options the user can pick", maxItems: 6, maxLength: 80),
                ],
                safety: .readOnly, timeout: 5,
                examples: [ToolExample("ask which meeting to move", arguments: ["question": "Which meeting with Alex: Thursday 10:00 or Thursday 15:00?", "options": ["Thursday 10:00", "Thursday 15:00"]])]),
            ToolDescriptor(
                name: "friday.current_time", integration: id, title: "Current date and time",
                summary: "The exact current date, time, weekday and time zone of this Mac.",
                safety: .readOnly, timeout: 2,
                examples: [ToolExample("what time is it", arguments: [:]), ToolExample("qué hora es", language: .es, arguments: [:])]),
        ]
    }

    public func status() async -> IntegrationStatus { IntegrationStatus(state: .ready) }
    public func authorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }
    public func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }

    public func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
        switch call.descriptor.name.rawValue {
        case "friday.find_tools":
            let query = call.string("query") ?? ""
            let limit = call.int("limit") ?? 10
            let matches = Self.search(query, in: lock.withLock { catalog }, limit: limit)
            let data: JSONValue = .array(
                matches.map { descriptor in
                    [
                        "name": .string(descriptor.name.rawValue), "description": .string(descriptor.summary),
                        "safety": .string(descriptor.safety.rawValue), "supported": .bool(descriptor.isSupported),
                        "parameters": .object(Dictionary(uniqueKeysWithValues: descriptor.parameters.map { ($0.name, $0.jsonSchema) })),
                        "required": .array(descriptor.parameters.filter(\.required).map { .string($0.name) }),
                    ]
                })
            let message = matches.isEmpty
                ? context.t("No tool matches “\(query)”.", "Ninguna herramienta coincide con «\(query)».")
                : context.t("Found \(matches.count) tool(s): ", "Encontradas \(matches.count) herramienta(s): ") + matches.map(\.name.rawValue).joined(separator: ", ")
            return .done(ToolOutput(message: message, data: data, verification: .notApplicable))
        case "friday.ask_user":
            let question = call.string("question") ?? "?"
            // Options are offered as plain text choices; the engine resolves "the first one"/"la segunda" itself.
            let options = call.strings("options")
            var clarification = Clarification(question: question)
            if !options.isEmpty {
                clarification.question = question + "\n" + options.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            }
            return .clarify(clarification)
        case "friday.current_time":
            let formatter = DateFormatter()
            formatter.locale = context.language.locale
            formatter.timeZone = context.timeZone
            formatter.dateStyle = .full
            formatter.timeStyle = .short
            let text = formatter.string(from: context.now)
            let data: JSONValue = [
                "iso": .string(ISODates.string(from: context.now, timeZone: context.timeZone)),
                "time_zone": .string(context.timeZone.identifier), "weekday": .string(formatter.weekdaySymbols[context.calendar.component(.weekday, from: context.now) - 1]),
            ]
            return .done(ToolOutput(message: text, data: data, verification: .notApplicable))
        default:
            throw JarvisError.validation([ValidationIssue(.unknownTool, "Unknown tool \(call.descriptor.name)")])
        }
    }

    static func search(_ query: String, in catalog: [ToolDescriptor], limit: Int) -> [ToolDescriptor] {
        let terms = KeywordRouter.fold(query).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 }
        guard !terms.isEmpty else { return Array(catalog.prefix(limit)) }
        let scored = catalog.compactMap { descriptor -> (ToolDescriptor, Int)? in
            let haystack = KeywordRouter.fold(descriptor.name.rawValue.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ") + " " + descriptor.title + " " + descriptor.summary + " " + descriptor.examples.map(\.phrase).joined(separator: " "))
            var score = 0
            for term in terms {
                if KeywordRouter.fold(descriptor.name.rawValue).contains(term) { score += 5 }
                if haystack.contains(term) { score += 2 }
                // crude stemming: shared 4-letter prefix
                if term.count >= 5, haystack.contains(String(term.prefix(4))) { score += 1 }
            }
            return score > 0 ? (descriptor, score) : nil
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}
