import Foundation
import FridayCore

public extension IntegrationID {
    static let memory: IntegrationID = "memory"
}

public extension ToolName {
    static let memoryRemember: ToolName = "memory.remember"
    static let memoryRecall: ToolName = "memory.recall"
    static let memoryForget: ToolName = "memory.forget"
    static let memoryList: ToolName = "memory.list"
    static let memoryClearConversations: ToolName = "memory.clear_conversations"
    static let memoryExport: ToolName = "memory.export"
    static let memoryStatus: ToolName = "memory.status"
    static let routinesSave: ToolName = "routines.save"
    static let routinesList: ToolName = "routines.list"
    static let routinesDelete: ToolName = "routines.delete"
    static let tasksList: ToolName = "tasks.list"
}

/// Exposes ``MemoryStore`` to the engine as tools: remembering, recalling and forgetting memories, learned
/// routines and Friday's own task list. Everything stays on this Mac, so no macOS permission is involved.
public struct MemoryIntegration: AppIntegration {
    public let id: IntegrationID = .memory
    public let displayName = LocalizedText(en: "Memory", es: "Memoria")
    public let summary = LocalizedText(
        en: "What Friday remembers about you, your routines and its own tasks. Stored locally, never uploaded.",
        es: "Lo que Friday recuerda de ti, tus rutinas y sus propias tareas. Se guarda en este Mac, nunca se sube.")
    public let symbolName = "brain"
    public let permissionRequirements: [PermissionRequirement] = []

    private let store: MemoryStore
    private static let log = JarvisLog.integration(.memory)

    public init(store: MemoryStore) { self.store = store }

    private static let rememberKinds = [MemoryKind.preference, .entity, .knowledge, .workflow].map(\.rawValue)
    private static let allKinds = MemoryKind.allCases.map(\.rawValue)

    public var tools: [ToolDescriptor] {
        [
            ToolDescriptor(
                name: .memoryRemember, integration: id, title: "Remember",
                summary:
                    "Stores something to remember long-term: a preference, a named entity (contact, playlist, app, document, project, place), a fact or a described workflow. Giving a key lets later calls update the same memory.",
                parameters: [
                    .string("content", "What to remember, in the user's words.", required: true, maxLength: 2_000),
                    .choice("kind", Self.rememberKinds, "Category of the memory.", default: MemoryKind.knowledge.rawValue),
                    .string("key", "Optional stable key (e.g. 'coffee', 'playlist de estudio'); remembering the same key again replaces the content.", maxLength: 200),
                ],
                safety: .modifying, deduplicate: true,
                examples: [
                    ToolExample("Remember that I take my coffee with oat milk", arguments: ["content": "I take my coffee with oat milk", "kind": "preference", "key": "coffee"]),
                    ToolExample("Recuerda que mi lista de estudio es la playlist Deep Focus", language: .es, arguments: ["content": "La lista de estudio es la playlist Deep Focus", "kind": "entity", "key": "playlist de estudio"]),
                ]),
            ToolDescriptor(
                name: .memoryRecall, integration: id, title: "Recall",
                summary: "Searches long-term memory, case- and accent-insensitively, and returns the most relevant memories best first.",
                parameters: [
                    .string("query", "Words to look for.", required: true, maxLength: 500),
                    .choice("kind", Self.allKinds, "Restrict to one category."),
                    .integer("limit", "Maximum number of memories.", min: 1, max: 50, default: 8),
                ],
                safety: .readOnly,
                examples: [
                    ToolExample("What do you remember about my coffee?", arguments: ["query": "coffee"]),
                    ToolExample("¿Qué sabes de mi lista de estudio?", language: .es, arguments: ["query": "lista de estudio"]),
                ]),
            ToolDescriptor(
                name: .memoryForget, integration: id, title: "Forget",
                summary: "Permanently deletes one memory, by id or by key. Asks for confirmation first.",
                parameters: [
                    .string("id", "Memory id from memory.recall or memory.list.", maxLength: 40),
                    .string("key", "The memory's key.", maxLength: 200),
                ],
                constraints: [.atLeastOne(["id", "key"])], safety: .destructive,
                examples: [
                    ToolExample("Forget what I told you about my coffee", arguments: ["key": "coffee"]),
                    ToolExample("Olvida lo de mi lista de estudio", language: .es, arguments: ["key": "playlist de estudio"]),
                ]),
            ToolDescriptor(
                name: .memoryList, integration: id, title: "List memories",
                summary: "Lists stored memories, newest first, optionally of one category.",
                parameters: [
                    .choice("kind", Self.allKinds, "Restrict to one category."),
                    .integer("limit", "Maximum number of memories.", min: 1, max: 100, default: 20),
                ],
                safety: .readOnly,
                examples: [
                    ToolExample("What do you remember about me?", arguments: [:]),
                    ToolExample("Enséñame mis preferencias guardadas", language: .es, arguments: ["kind": "preference"]),
                ]),
            ToolDescriptor(
                name: .memoryClearConversations, integration: id, title: "Clear conversations",
                summary: "Permanently deletes stored conversation history (one session or all). Asks for confirmation first.",
                parameters: [.string("session", "Session id to clear; omit to clear every conversation.", maxLength: 200)],
                safety: .destructive,
                examples: [
                    ToolExample("Clear our conversation history", arguments: [:]),
                    ToolExample("Borra el historial de conversaciones", language: .es, arguments: [:]),
                ]),
            ToolDescriptor(
                name: .memoryExport, integration: id, title: "Export memory",
                summary: "Returns everything Friday remembers (memories, conversations, tasks, routines) as JSON.",
                safety: .readOnly,
                examples: [
                    ToolExample("Export everything you remember", arguments: [:]),
                    ToolExample("Exporta tu memoria", language: .es, arguments: [:]),
                ]),
            ToolDescriptor(
                name: .memoryStatus, integration: id, title: "Memory status",
                summary: "Whether memory is on, how many memories of each kind are stored, the retention period and the search backend.",
                safety: .readOnly,
                examples: [
                    ToolExample("Is your memory turned on?", arguments: [:]),
                    ToolExample("¿Cuántas cosas recuerdas?", language: .es, arguments: [:]),
                ]),
            ToolDescriptor(
                name: .routinesSave, integration: id, title: "Save routine",
                summary:
                    "Teaches Friday a routine: trigger phrases (any language) and the ordered tool calls to run. steps_json is a JSON array of {\"tool\": \"namespace.name\", \"arguments\": {...}}. Saving an existing name replaces it.",
                parameters: [
                    .string("name", "Routine name.", required: true, maxLength: 100),
                    .strings("phrases", "Trigger phrases, e.g. [\"start studying\", \"empezar a estudiar\"].", required: true, maxItems: 20, maxLength: 200),
                    .string("steps_json", "JSON array of steps: [{\"tool\": \"music.play_playlist\", \"arguments\": {\"name\": \"Deep Focus\"}}].", required: true, maxLength: 20_000),
                ],
                safety: .modifying,
                examples: [
                    ToolExample(
                        "When I say start studying, play my Deep Focus playlist and set a 25 minute timer",
                        arguments: [
                            "name": "Study", "phrases": ["start studying", "study time"],
                            "steps_json": #"[{"tool":"music.play_playlist","arguments":{"name":"Deep Focus"}},{"tool":"timers.create","arguments":{"duration_seconds":1500}}]"#,
                        ]),
                    ToolExample(
                        "Cuando diga empezar a estudiar, pon la playlist Deep Focus y un temporizador de 25 minutos", language: .es,
                        arguments: [
                            "name": "Estudiar", "phrases": ["empezar a estudiar", "a estudiar"],
                            "steps_json": #"[{"tool":"music.play_playlist","arguments":{"name":"Deep Focus"}},{"tool":"timers.create","arguments":{"duration_seconds":1500}}]"#,
                        ]),
                ]),
            ToolDescriptor(
                name: .routinesList, integration: id, title: "List routines",
                summary: "Lists the routines Friday has learned, with their trigger phrases and steps.",
                safety: .readOnly,
                examples: [
                    ToolExample("What routines do you know?", arguments: [:]),
                    ToolExample("¿Qué rutinas tienes guardadas?", language: .es, arguments: [:]),
                ]),
            ToolDescriptor(
                name: .routinesDelete, integration: id, title: "Delete routine",
                summary: "Permanently deletes a routine by name or id. Asks for confirmation first.",
                parameters: [
                    .string("name", "Routine name.", maxLength: 100),
                    .string("id", "Routine id from routines.list.", maxLength: 40),
                ],
                constraints: [.atLeastOne(["name", "id"])], safety: .destructive,
                examples: [
                    ToolExample("Delete the study routine", arguments: ["name": "Study"]),
                    ToolExample("Borra la rutina de estudiar", language: .es, arguments: ["name": "Estudiar"]),
                ]),
            ToolDescriptor(
                name: .tasksList, integration: id, title: "List tasks",
                summary: "Lists what Friday is working on or has done (its own task records), most recent first.",
                parameters: [
                    .string("status", "Only tasks with this status, e.g. pending, in_progress, done, failed.", maxLength: 40),
                    .integer("limit", "Maximum number of tasks.", min: 1, max: 100, default: 20),
                ],
                safety: .readOnly,
                examples: [
                    ToolExample("What are you working on?", arguments: ["status": "in_progress"]),
                    ToolExample("¿Qué tareas tienes pendientes?", language: .es, arguments: ["status": "pending"]),
                ]),
        ]
    }

    public func status() async -> IntegrationStatus {
        let enabled = await store.isEnabled
        return IntegrationStatus(
            state: .ready,
            detail: enabled ? nil : LocalizedText(en: "Memory is turned off.", es: "La memoria está desactivada."))
    }

    public func authorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }
    public func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }

    public func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
        try Task.checkCancellation()
        do {
            switch call.descriptor.name {
            case .memoryRemember: return try await remember(call, context)
            case .memoryRecall: return try await recall(call, context)
            case .memoryForget: return try await forget(call, context)
            case .memoryList: return try await list(call, context)
            case .memoryClearConversations: return try await clearConversations(call, context)
            case .memoryExport: return try await export(context)
            case .memoryStatus: return try await memoryStatus(context)
            case .routinesSave: return try await saveRoutine(call, context)
            case .routinesList: return try await listRoutines(context)
            case .routinesDelete: return try await deleteRoutine(call, context)
            case .tasksList: return try await listTasks(call, context)
            default:
                throw JarvisError.validation([ValidationIssue(.unknownTool, "Unknown tool '\(call.descriptor.name.rawValue)'.")])
            }
        } catch let error as MemoryError {
            Self.log.error("\(call.descriptor.name.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .private)")
            throw Self.translate(error)
        }
    }

    // MARK: - Memory items

    private func remember(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let content = call.string("content") ?? ""
        let kind = call.string("kind").flatMap(MemoryKind.init(rawValue:)) ?? .knowledge
        let item = try await store.remember(kind: kind, key: call.string("key"), content: content, source: context.source.rawValue, now: context.now)
        guard let stored = try await store.item(id: item.id), stored.content == item.content else {
            throw JarvisError.verificationFailed(LocalizedText(en: "The memory could not be read back after saving.", es: "No se pudo releer la memoria después de guardarla."))
        }
        return .done(
            ToolOutput(
                message: context.t("Remembered (\(Self.kindName(kind, .en))): \(stored.content)", "Recordado (\(Self.kindName(kind, .es))): \(stored.content)"),
                data: stored.json,
                verification: .verified(context.t("Read the memory back from the local database.", "Memoria releída de la base de datos local."))))
    }

    private func recall(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let query = call.string("query") ?? ""
        let kinds = call.string("kind").flatMap(MemoryKind.init(rawValue:)).map { [$0] } ?? []
        let items = try await store.recall(query: query, kinds: kinds, limit: call.int("limit") ?? 8, now: context.now)
        let message: String
        if items.isEmpty {
            message = await store.isEnabled
                ? context.t("I don't remember anything about “\(query)”.", "No recuerdo nada sobre «\(query)».")
                : context.t("Memory is turned off, so I can't recall anything.", "La memoria está desactivada, así que no puedo recordar nada.")
        } else {
            message = context.t("I remember \(items.count) thing\(items.count == 1 ? "" : "s") about “\(query)”:", "Recuerdo \(items.count) cosa\(items.count == 1 ? "" : "s") sobre «\(query)»:")
                + "\n" + items.map { "• " + Self.line(for: $0, context.language) }.joined(separator: "\n")
        }
        return .done(
            ToolOutput(
                message: message, data: ["query": .string(query), "count": .int(items.count), "items": .array(items.map(\.json))],
                verification: .notApplicable))
    }

    private func forget(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let item: MemoryItem?
        if let id = call.string("id") {
            guard let uuid = UUID(uuidString: id) else {
                throw JarvisError.invalidArgument(parameter: "id", LocalizedText(en: "The memory id is not valid.", es: "El id de la memoria no es válido."))
            }
            item = try await store.item(id: uuid)
        } else {
            item = try await store.item(key: call.string("key") ?? "")
        }
        guard let item else {
            throw JarvisError.notFound("memory_not_found", en: "I don't have a memory matching that.", es: "No tengo ninguna memoria que coincida.")
        }
        let preview = Self.preview(item.content)
        guard context.isConfirmed else {
            return .confirm(
                ConfirmationRequest(
                    prompt: context.t("Forget “\(preview)”? This cannot be undone.", "¿Olvido «\(preview)»? No se puede deshacer."),
                    call: call.call.adding(["id": .string(item.id.uuidString)]), destructive: true))
        }
        try await store.forget(id: item.id)
        guard try await store.item(id: item.id) == nil else {
            throw JarvisError.verificationFailed(LocalizedText(en: "The memory is still there after deleting it.", es: "La memoria sigue ahí después de borrarla."))
        }
        return .done(
            ToolOutput(
                message: context.t("Forgotten: \(preview)", "Olvidado: \(preview)"), data: ["id": .string(item.id.uuidString), "key": JSONValue(item.key)].droppingNulls().asObject,
                verification: .verified(context.t("Checked that the memory no longer exists.", "Comprobado que la memoria ya no existe."))))
    }

    private func list(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let kind = call.string("kind").flatMap(MemoryKind.init(rawValue:))
        let items = try await store.items(kind: kind, limit: call.int("limit") ?? 20)
        let total = try await store.count(kind: kind)
        let message: String
        if items.isEmpty {
            message = context.t("I have no stored memories\(kind.map { " of kind \(Self.kindName($0, .en))" } ?? "").", "No tengo memorias guardadas\(kind.map { " de tipo \(Self.kindName($0, .es))" } ?? "").")
        } else {
            message = context.t("\(total) memor\(total == 1 ? "y" : "ies") stored (showing \(items.count)):", "\(total) memoria\(total == 1 ? "" : "s") guardada\(total == 1 ? "" : "s") (muestro \(items.count)):")
                + "\n" + items.map { "• " + Self.line(for: $0, context.language) }.joined(separator: "\n")
        }
        return .done(ToolOutput(message: message, data: ["count": .int(total), "items": .array(items.map(\.json))], verification: .notApplicable))
    }

    private func clearConversations(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let session = call.string("session")
        let before = try await store.turnCount(session: session)
        guard context.isConfirmed else {
            let prompt = session == nil
                ? context.t("Delete all \(before) stored conversation turns? This cannot be undone.", "¿Borro los \(before) mensajes de conversación guardados? No se puede deshacer.")
                : context.t("Delete the \(before) stored turns of this conversation? This cannot be undone.", "¿Borro los \(before) mensajes guardados de esta conversación? No se puede deshacer.")
            return .confirm(ConfirmationRequest(prompt: prompt, call: call.call, destructive: true))
        }
        let removed: Int
        if let session { removed = try await store.clearConversation(session: session) } else { removed = try await store.clearAllConversations() }
        guard try await store.turnCount(session: session) == 0 else {
            throw JarvisError.verificationFailed(LocalizedText(en: "Some conversation turns are still stored.", es: "Todavía quedan mensajes de conversación guardados."))
        }
        return .done(
            ToolOutput(
                message: context.t("Deleted \(removed) conversation turn\(removed == 1 ? "" : "s").", "Borrado\(removed == 1 ? "" : "s") \(removed) mensaje\(removed == 1 ? "" : "s") de conversación."),
                data: ["removed": .int(removed)],
                verification: .verified(context.t("Checked that no turns remain.", "Comprobado que no quedan mensajes."))))
    }

    private func export(_ context: ExecutionContext) async throws -> ToolOutcome {
        let data = try await store.export(now: context.now)
        let snapshot: JSONValue
        do { snapshot = try JSONDecoder().decode(JSONValue.self, from: data) } catch { throw Self.translate(.encoding("export")) }
        let items = snapshot["items"]?.arrayValue?.count ?? 0
        let turns = snapshot["conversations"]?.arrayValue?.count ?? 0
        let tasks = snapshot["tasks"]?.arrayValue?.count ?? 0
        let routines = snapshot["routines"]?.arrayValue?.count ?? 0
        return .done(
            ToolOutput(
                message: context.t(
                    "Exported \(items) memories, \(turns) conversation turns, \(tasks) tasks and \(routines) routines as JSON.",
                    "Exportadas \(items) memorias, \(turns) mensajes de conversación, \(tasks) tareas y \(routines) rutinas en JSON."),
                data: snapshot, verification: .notApplicable))
    }

    private func memoryStatus(_ context: ExecutionContext) async throws -> ToolOutcome {
        let enabled = await store.isEnabled
        let retention = await store.retentionDays
        let fts = store.hasFullTextSearch
        var counts: JSONObject = [:]
        var total = 0
        for kind in MemoryKind.allCases {
            let count = try await store.count(kind: kind)
            counts[kind.rawValue] = .int(count)
            total += count
        }
        let turns = try await store.turnCount()
        let sessions = try await store.sessions(limit: 1_000).count
        let tasks = try await store.tasks(limit: 1_000).count
        let routines = try await store.routines().count
        let retentionText = retention.map { context.t("\($0) days", "\($0) días") } ?? context.t("forever", "para siempre")
        let message = context.t(
            "Memory is \(enabled ? "on" : "off"): \(total) memories, \(turns) conversation turns in \(sessions) sessions, \(tasks) tasks, \(routines) routines. Retention: \(retentionText).",
            "La memoria está \(enabled ? "activada" : "desactivada"): \(total) memorias, \(turns) mensajes en \(sessions) conversaciones, \(tasks) tareas, \(routines) rutinas. Retención: \(retentionText).")
        return .done(
            ToolOutput(
                message: message,
                data: [
                    "enabled": .bool(enabled), "items": .int(total), "items_by_kind": .object(counts), "conversation_turns": .int(turns),
                    "sessions": .int(sessions), "tasks": .int(tasks), "routines": .int(routines), "retention_days": JSONValue(retention),
                    "full_text_search": .bool(fts), "storage": "local",
                ],
                verification: .notApplicable))
    }

    // MARK: - Routines

    private func saveRoutine(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let name = call.string("name") ?? ""
        let phrases = call.strings("phrases")
        let steps = try Self.parseSteps(call.string("steps_json") ?? "")
        let routine = try await store.saveRoutine(name: name, phrases: phrases, steps: steps, now: context.now)
        guard let stored = try await store.routine(id: routine.id), stored.steps == steps, stored.phrases == routine.phrases else {
            throw JarvisError.verificationFailed(LocalizedText(en: "The routine could not be read back after saving.", es: "No se pudo releer la rutina después de guardarla."))
        }
        let tools = steps.map(\.tool.rawValue).joined(separator: ", ")
        return .done(
            ToolOutput(
                message: context.t(
                    "Routine “\(stored.name)” saved: say \(Self.quoted(stored.phrases)) to run \(tools).",
                    "Rutina «\(stored.name)» guardada: di \(Self.quoted(stored.phrases)) para ejecutar \(tools)."),
                data: stored.json,
                verification: .verified(context.t("Read the routine back from the local database.", "Rutina releída de la base de datos local."))))
    }

    private func listRoutines(_ context: ExecutionContext) async throws -> ToolOutcome {
        let routines = try await store.routines()
        let message: String
        if routines.isEmpty {
            message = context.t("I haven't learned any routines yet.", "Todavía no he aprendido ninguna rutina.")
        } else {
            message = context.t("\(routines.count) routine\(routines.count == 1 ? "" : "s"):", "\(routines.count) rutina\(routines.count == 1 ? "" : "s"):") + "\n"
                + routines.map { routine in
                    "• \(routine.name) — \(Self.quoted(routine.phrases)) → " + context.t("\(routine.steps.count) step\(routine.steps.count == 1 ? "" : "s")", "\(routine.steps.count) paso\(routine.steps.count == 1 ? "" : "s")")
                }.joined(separator: "\n")
        }
        return .done(ToolOutput(message: message, data: ["count": .int(routines.count), "routines": .array(routines.map(\.json))], verification: .notApplicable))
    }

    private func deleteRoutine(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let routine: Routine?
        if let id = call.string("id") {
            guard let uuid = UUID(uuidString: id) else {
                throw JarvisError.invalidArgument(parameter: "id", LocalizedText(en: "The routine id is not valid.", es: "El id de la rutina no es válido."))
            }
            routine = try await store.routine(id: uuid)
        } else {
            routine = try await store.routine(named: call.string("name") ?? "")
        }
        guard let routine else {
            throw JarvisError.notFound("routine_not_found", en: "I don't have a routine with that name.", es: "No tengo ninguna rutina con ese nombre.")
        }
        guard context.isConfirmed else {
            return .confirm(
                ConfirmationRequest(
                    prompt: context.t("Delete the routine “\(routine.name)”? This cannot be undone.", "¿Borro la rutina «\(routine.name)»? No se puede deshacer."),
                    call: call.call.adding(["id": .string(routine.id.uuidString)]), destructive: true))
        }
        try await store.deleteRoutine(id: routine.id)
        guard try await store.routine(id: routine.id) == nil else {
            throw JarvisError.verificationFailed(LocalizedText(en: "The routine is still there after deleting it.", es: "La rutina sigue ahí después de borrarla."))
        }
        return .done(
            ToolOutput(
                message: context.t("Routine “\(routine.name)” deleted.", "Rutina «\(routine.name)» borrada."),
                data: ["id": .string(routine.id.uuidString), "name": .string(routine.name)],
                verification: .verified(context.t("Checked that the routine no longer exists.", "Comprobado que la rutina ya no existe."))))
    }

    /// Parses `steps_json` into well-formed tool calls, explaining exactly what is wrong otherwise.
    static func parseSteps(_ text: String) throws -> [ToolCall] {
        func invalid(_ en: String, _ es: String) -> JarvisError {
            .invalidArgument(parameter: "steps_json", LocalizedText(en: en, es: es))
        }
        let value: JSONValue
        do { value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) } catch {
            throw invalid("steps_json is not valid JSON.", "steps_json no es JSON válido.")
        }
        guard let array = value.arrayValue else { throw invalid("steps_json must be a JSON array of steps.", "steps_json debe ser un array JSON de pasos.") }
        guard !array.isEmpty else { throw invalid("A routine needs at least one step.", "Una rutina necesita al menos un paso.") }
        guard array.count <= 50 else { throw invalid("A routine can have at most 50 steps.", "Una rutina puede tener como máximo 50 pasos.") }
        var steps: [ToolCall] = []
        for (index, element) in array.enumerated() {
            guard let object = element.objectValue else { throw invalid("Step \(index + 1) must be an object.", "El paso \(index + 1) debe ser un objeto.") }
            guard let tool = object["tool"]?.stringValue?.trimmingCharacters(in: .whitespaces), isWellFormedToolName(tool) else {
                throw invalid("Step \(index + 1) needs a 'tool' like 'music.play_playlist'.", "El paso \(index + 1) necesita un 'tool' como 'music.play_playlist'.")
            }
            var arguments: JSONObject = [:]
            if let raw = object["arguments"], !raw.isNull {
                guard let parsed = raw.objectValue else { throw invalid("Step \(index + 1): 'arguments' must be an object.", "Paso \(index + 1): 'arguments' debe ser un objeto.") }
                arguments = parsed
            }
            let known: Set<String> = ["tool", "arguments", "id", "assumptions", "source_text"]
            if let stray = object.keys.first(where: { !known.contains($0) }) {
                throw invalid("Step \(index + 1) has an unknown field '\(stray)'.", "El paso \(index + 1) tiene un campo desconocido '\(stray)'.")
            }
            let id = object["id"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? UUID()
            steps.append(ToolCall(id: id, tool: ToolName(tool), arguments: arguments, sourceText: object["source_text"]?.stringValue))
        }
        return steps
    }

    static func isWellFormedToolName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { ($0.isASCII && $0.isLetter && $0.isLowercase) || $0.isNumber || $0 == "_" }
        }
    }

    // MARK: - Tasks

    private func listTasks(_ call: ValidatedToolCall, _ context: ExecutionContext) async throws -> ToolOutcome {
        let status = call.string("status").map { TextFolding.fold($0).replacingOccurrences(of: " ", with: "_") }
        let tasks = try await store.tasks(status: status, limit: call.int("limit") ?? 20)
        let message: String
        if tasks.isEmpty {
            message = status.map { context.t("No tasks with status “\($0)”.", "No hay tareas con estado «\($0)».") }
                ?? context.t("I'm not tracking any tasks.", "No tengo ninguna tarea registrada.")
        } else {
            message = context.t("\(tasks.count) task\(tasks.count == 1 ? "" : "s"):", "\(tasks.count) tarea\(tasks.count == 1 ? "" : "s"):") + "\n"
                + tasks.map { "• [\($0.status)] \($0.title)" + ($0.detail.map { " — " + $0 } ?? "") }.joined(separator: "\n")
        }
        return .done(ToolOutput(message: message, data: ["count": .int(tasks.count), "tasks": .array(tasks.map(\.json))], verification: .notApplicable))
    }

    // MARK: - Helpers

    static func translate(_ error: MemoryError) -> JarvisError {
        switch error {
        case .disabled: return .failed(code: "memory_disabled", error.localizedText)
        case .notFound: return .notFound(code: "memory_not_found", error.localizedText)
        case .invalidInput: return .invalidArgument(parameter: "content", error.localizedText)
        case .sqlite: return .failed(code: "memory_database", error.localizedText)
        case .encoding: return .failed(code: "memory_encoding", error.localizedText)
        }
    }

    static func kindName(_ kind: MemoryKind, _ language: Language) -> String {
        switch kind {
        case .preference: return language.pick("preference", "preferencia")
        case .entity: return language.pick("entity", "entidad")
        case .knowledge: return language.pick("knowledge", "conocimiento")
        case .workflow: return language.pick("workflow", "flujo de trabajo")
        case .task: return language.pick("task", "tarea")
        }
    }

    private static func line(for item: MemoryItem, _ language: Language) -> String {
        "[\(kindName(item.kind, language))] " + item.content + (item.key.map { " (\($0))" } ?? "")
    }

    private static func preview(_ content: String) -> String {
        let flat = content.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= 80 ? flat : String(flat.prefix(77)) + "…"
    }

    private static func quoted(_ phrases: [String]) -> String {
        phrases.map { "“\($0)”" }.joined(separator: " / ")
    }
}

private extension JSONObject {
    var asObject: JSONValue { .object(self) }
}
