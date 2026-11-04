import Foundation
import FridayCore

/// Errors thrown by ``MemoryStore``.
public enum MemoryError: Error, Sendable, Hashable {
    /// SQLite reported a problem. The message never contains stored content.
    case sqlite(message: String)
    /// A record could not be encoded to, or decoded from, its stored JSON form.
    case encoding(String)
    /// Memory is switched off; nothing was stored.
    case disabled
    /// No record has the given identifier or key.
    case notFound
    /// A caller-supplied value is unusable (empty content, empty routine…).
    case invalidInput(String)

    public var localizedText: LocalizedText {
        switch self {
        case .sqlite:
            return LocalizedText(en: "Friday's memory database reported an error.", es: "La base de datos de memoria de Friday informó de un error.")
        case .encoding:
            return LocalizedText(en: "A memory record could not be encoded.", es: "No se pudo codificar un registro de memoria.")
        case .disabled:
            return LocalizedText(en: "Memory is turned off, so nothing was stored.", es: "La memoria está desactivada, así que no se guardó nada.")
        case .notFound:
            return LocalizedText(en: "There is no such memory.", es: "No existe esa memoria.")
        case .invalidInput(let detail):
            return LocalizedText(en: "The request is not valid: \(detail)", es: "La solicitud no es válida: \(detail)")
        }
    }
}

/// The categories of long-term memory items.
public enum MemoryKind: String, Codable, Sendable, CaseIterable, Hashable {
    /// How the user likes things ("coffee: oat milk", "always answer in Spanish").
    case preference
    /// A named thing Friday has met: a contact, playlist, app, document, project or place.
    case entity
    /// A fact worth keeping.
    case knowledge
    /// A described multi-step way of doing something.
    case workflow
    /// Something the user asked Friday to do or track.
    case task
}

/// One long-term memory.
public struct MemoryItem: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var kind: MemoryKind
    /// Optional stable key; remembering the same key again replaces the content (`entity:playlist:deep focus`).
    public var key: String?
    public var content: String
    /// Who produced the memory: `user`, `assistant`, `tool`…
    public var source: String
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?
    public var useCount: Int
    public var pinned: Bool

    public init(
        id: UUID = UUID(), kind: MemoryKind, key: String? = nil, content: String, source: String,
        createdAt: Date = Date(), updatedAt: Date = Date(), lastUsedAt: Date? = nil, useCount: Int = 0,
        pinned: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.key = key
        self.content = content
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
        self.pinned = pinned
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, key, content, source, pinned
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastUsedAt = "last_used_at"
        case useCount = "use_count"
    }

    public var json: JSONValue {
        .object(
            [
                "id": .string(id.uuidString), "kind": .string(kind.rawValue), "key": JSONValue(key),
                "content": .string(content), "source": .string(source),
                "created_at": .string(isoTimestamp(createdAt)),
                "updated_at": .string(isoTimestamp(updatedAt)),
                "last_used_at": JSONValue(lastUsedAt.map { isoTimestamp($0) }),
                "use_count": .int(useCount), "pinned": .bool(pinned),
            ].droppingNulls())
    }
}

/// One message of a conversation, kept so Friday can follow up across restarts.
public struct ConversationTurn: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var sessionID: String
    /// `user` or `assistant`.
    public var role: String
    public var text: String
    public var language: String?
    public var createdAt: Date
    /// A short description of the tools that ran for this turn, if any.
    public var toolSummary: String?

    public init(
        id: UUID = UUID(), sessionID: String, role: String, text: String, language: String? = nil,
        createdAt: Date = Date(), toolSummary: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.role = role
        self.text = text
        self.language = language
        self.createdAt = createdAt
        self.toolSummary = toolSummary
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, language
        case sessionID = "session_id"
        case createdAt = "created_at"
        case toolSummary = "tool_summary"
    }
}

/// A conversation as listed by ``MemoryStore/sessions(limit:)``.
public struct ConversationSession: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    /// The first thing the user said in the session.
    public var title: String?
    public var lastActivity: Date
    public var turnCount: Int

    public init(id: String, title: String?, lastActivity: Date, turnCount: Int) {
        self.id = id
        self.title = title
        self.lastActivity = lastActivity
        self.turnCount = turnCount
    }

    private enum CodingKeys: String, CodingKey {
        case id, title
        case lastActivity = "last_activity"
        case turnCount = "turn_count"
    }
}

/// Something Friday is doing or has done, persisted so it can be resumed or reported after a restart.
public struct TaskRecord: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var title: String
    /// Free-form, e.g. `pending`, `in_progress`, `done`, `failed`, `cancelled`.
    public var status: String
    public var createdAt: Date
    public var updatedAt: Date
    public var detail: String?
    public var payload: JSONValue?

    public init(
        id: UUID = UUID(), title: String, status: String = "pending", createdAt: Date = Date(),
        updatedAt: Date = Date(), detail: String? = nil, payload: JSONValue? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.detail = detail
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, status, detail, payload
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public var json: JSONValue {
        .object(
            [
                "id": .string(id.uuidString), "title": .string(title), "status": .string(status),
                "created_at": .string(isoTimestamp(createdAt)),
                "updated_at": .string(isoTimestamp(updatedAt)),
                "detail": JSONValue(detail), "payload": payload ?? .null,
            ].droppingNulls())
    }
}

/// A learned workflow: trigger phrases in any language and the tool calls they expand to.
public struct Routine: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var phrases: [String]
    public var steps: [ToolCall]
    public var createdAt: Date
    public var lastRunAt: Date?
    public var runCount: Int

    public init(
        id: UUID = UUID(), name: String, phrases: [String], steps: [ToolCall], createdAt: Date = Date(),
        lastRunAt: Date? = nil, runCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.phrases = phrases
        self.steps = steps
        self.createdAt = createdAt
        self.lastRunAt = lastRunAt
        self.runCount = runCount
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, phrases, steps
        case createdAt = "created_at"
        case lastRunAt = "last_run_at"
        case runCount = "run_count"
    }

    public var json: JSONValue {
        .object(
            [
                "id": .string(id.uuidString), "name": .string(name),
                "phrases": .array(phrases.map(JSONValue.string)),
                "steps": .array(
                    steps.map { .object(["tool": .string($0.tool.rawValue), "arguments": .object($0.arguments)]) }),
                "created_at": .string(isoTimestamp(createdAt)),
                "last_run_at": JSONValue(lastRunAt.map { isoTimestamp($0) }),
                "run_count": .int(runCount),
            ].droppingNulls())
    }
}

/// Everything in the store, as produced by ``MemoryStore/export()`` and accepted by ``MemoryStore/restore(_:)``.
public struct MemoryExport: Codable, Sendable, Hashable {
    public static let currentVersion = 1

    public var version: Int
    public var exportedAt: Date
    public var enabled: Bool
    public var retentionDays: Int?
    public var items: [MemoryItem]
    public var conversations: [ConversationTurn]
    public var tasks: [TaskRecord]
    public var routines: [Routine]

    public init(
        version: Int = MemoryExport.currentVersion, exportedAt: Date, enabled: Bool, retentionDays: Int?,
        items: [MemoryItem], conversations: [ConversationTurn], tasks: [TaskRecord], routines: [Routine]
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.enabled = enabled
        self.retentionDays = retentionDays
        self.items = items
        self.conversations = conversations
        self.tasks = tasks
        self.routines = routines
    }

    private enum CodingKeys: String, CodingKey {
        case version, enabled, items, conversations, tasks, routines
        case exportedAt = "exported_at"
        case retentionDays = "retention_days"
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// ISO-8601 timestamp in the user's current time zone, for JSON payloads returned by tools.
func isoTimestamp(_ date: Date) -> String { ISODates.string(from: date, timeZone: .current) }
