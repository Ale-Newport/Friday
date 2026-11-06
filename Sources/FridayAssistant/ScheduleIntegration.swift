import Foundation
import FridayCore
import os

// MARK: - Scheduled commands ("at 8 PM open my study apps", "in 20 minutes remind me to stretch")
//
// A scheduled item is a Friday command text with a due time (and optional daily/weekly repeat). It is persisted by the
// host (`ScheduleStore`) and run by the assistant's scheduler loop while Friday is running — Friday is a login item,
// and it never claims a task will run while it is not running.

public struct ScheduledCommand: Codable, Sendable, Identifiable, Hashable {
    public enum Repeat: String, Codable, Sendable { case none, daily, weekdays, weekly }
    public var id: UUID
    public var command: String
    public var dueAt: Date
    public var repeatRule: Repeat
    public var language: String?
    public var createdAt: Date
    public var lastRunAt: Date?
    public var status: String  // scheduled | done | cancelled | failed

    public init(id: UUID = UUID(), command: String, dueAt: Date, repeatRule: Repeat = .none, language: String? = nil, createdAt: Date = Date(), lastRunAt: Date? = nil, status: String = "scheduled") {
        self.id = id
        self.command = command
        self.dueAt = dueAt
        self.repeatRule = repeatRule
        self.language = language
        self.createdAt = createdAt
        self.lastRunAt = lastRunAt
        self.status = status
    }
}

/// Persistence for scheduled commands (the app backs it with a JSON file). `save` and `remove` throw when the
/// change could not be written, so nothing is ever reported as scheduled that would not survive a restart.
public protocol ScheduleStoring: Sendable {
    func all() async -> [ScheduledCommand]
    func save(_ item: ScheduledCommand) async throws
    func remove(id: UUID) async throws
}

public enum ScheduleStoreError: Error, LocalizedError, Sendable, Equatable {
    case notPersisted(String)

    public var errorDescription: String? {
        switch self {
        case .notPersisted(let detail): return "The schedule could not be written: \(detail)"
        }
    }
}

/// JSON file store, owner-only permissions. Every change is written atomically and read back before it is
/// acknowledged; a failed write leaves the in-memory list as it was.
public actor FileScheduleStore: ScheduleStoring {
    private let url: URL
    private var items: [ScheduledCommand]

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([ScheduledCommand].self, from: data) { items = decoded } else { items = [] }
    }

    public func all() -> [ScheduledCommand] { items }

    public func save(_ item: ScheduledCommand) throws {
        let before = items
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item } else { items.append(item) }
        do { try persist() } catch { items = before; throw error }
    }

    public func remove(id: UUID) throws {
        let before = items
        items.removeAll { $0.id == id }
        do { try persist() } catch { items = before; throw error }
    }

    private func persist() throws {
        let data: Data
        do { data = try JSONEncoder().encode(items) } catch { throw ScheduleStoreError.notPersisted(error.localizedDescription) }
        do { try data.write(to: url, options: [.atomic]) } catch { throw ScheduleStoreError.notPersisted(error.localizedDescription) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        // Verify: what is on disk decodes to what is in memory.
        guard let written = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([ScheduledCommand].self, from: written), decoded.map(\.id) == items.map(\.id) else {
            throw ScheduleStoreError.notPersisted("the file does not read back")
        }
    }
}

public struct ScheduleIntegration: AppIntegration {
    public let id: IntegrationID = "schedule"
    public let displayName = LocalizedText(en: "Scheduled commands", es: "Comandos programados")
    public let summary = LocalizedText(en: "Runs a Friday command later or on a schedule, while Friday is running.", es: "Ejecuta un comando de Friday más tarde o periódicamente, mientras Friday esté abierto.")
    public let symbolName = "clock.arrow.circlepath"
    public let permissionRequirements: [PermissionRequirement] = []
    let store: any ScheduleStoring

    public init(store: any ScheduleStoring) { self.store = store }

    public var tools: [ToolDescriptor] {
        [
            ToolDescriptor(
                name: "schedule.create", integration: id, title: "Schedule a command",
                summary: "Run a Friday command at a time (\"at 8 PM open my study apps\", \"every weekday at 9 check my calendar\"). The command text is what Friday should do at that moment, in the user's words. Runs only while Friday is open.",
                parameters: [
                    .string("command", "What Friday should do, e.g. 'open Notes and Music'", required: true, maxLength: 500),
                    .dateTime("at", "When to run it (first run for repeats)", required: true),
                    .choice("repeat", ["none", "daily", "weekdays", "weekly"], "Repeat rule", default: "none"),
                ],
                safety: .modifying, timeout: 10, deduplicate: true,
                examples: [
                    ToolExample("at 8 PM open my study apps", arguments: ["command": "open Notes and play my study playlist", "at": "2026-11-04T20:00:00+01:00"]),
                    ToolExample("cada día a las 9 revisa mi calendario", language: .es, arguments: ["command": "qué tengo hoy en el calendario", "at": "2026-11-05T09:00:00+01:00", "repeat": "daily"]),
                ]),
            ToolDescriptor(name: "schedule.list", integration: id, title: "List scheduled commands", summary: "Shows what Friday will run later.", safety: .readOnly, timeout: 5,
                examples: [ToolExample("what have you scheduled", arguments: [:]), ToolExample("qué tienes programado", language: .es, arguments: [:])]),
            ToolDescriptor(
                name: "schedule.cancel", integration: id, title: "Cancel a scheduled command",
                summary: "Cancels a scheduled command by id or by matching its text.",
                parameters: [.string("id", "The schedule id"), .string("match", "Words from the command text")],
                constraints: [.atLeastOne(["id", "match"])], safety: .modifying, timeout: 5),
        ]
    }

    public func status() async -> IntegrationStatus { IntegrationStatus(state: .ready) }
    public func authorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }
    public func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }

    /// The first run of a weekday schedule: the given time, moved past a weekend if it falls in one.
    static func firstWeekday(onOrAfter date: Date, calendar: Calendar) -> Date {
        var date = date
        while calendar.isDateInWeekend(date) { date = calendar.date(byAdding: .day, value: 1, to: date) ?? date }
        return date
    }

    public func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
        let formatter = DateFormatter()
        formatter.locale = context.language.locale
        formatter.timeZone = context.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        switch call.descriptor.name.rawValue {
        case "schedule.create":
            guard let command = call.string("command"), let requested = call.string("at").flatMap({ ISODates.date(from: $0, timeZone: context.timeZone) }) else {
                throw JarvisError.validation([ValidationIssue(.invalidValue, "command and at are required")])
            }
            guard requested > context.now.addingTimeInterval(-60) else {
                throw JarvisError.validation([ValidationIssue(.invalidValue, context.t("That time is in the past.", "Esa hora ya pasó."))])
            }
            let repeatRule = ScheduledCommand.Repeat(rawValue: call.string("repeat") ?? "none") ?? .none
            let when = repeatRule == .weekdays ? Self.firstWeekday(onOrAfter: requested, calendar: context.calendar) : requested
            let item = ScheduledCommand(command: command, dueAt: when, repeatRule: repeatRule, language: context.language.rawValue)
            do {
                try await store.save(item)
            } catch {
                throw JarvisError.failed("schedule_not_saved", en: "I couldn't save that schedule: \(error.localizedDescription)", es: "No pude guardar esa programación: \(error.localizedDescription)")
            }
            let saved = await store.all().first { $0.id == item.id }
            let moved = when != requested ? context.t(" (moved past the weekend)", " (movido al siguiente día laborable)") : ""
            let message = context.t("Scheduled for \(formatter.string(from: when))\(moved): “\(command)”. Friday must be running at that time.", "Programado para \(formatter.string(from: when))\(moved): «\(command)». Friday debe estar abierto a esa hora.")
            return .done(ToolOutput(message: message, data: try JSONValue.encoding(item), verification: saved != nil ? .verified("written and re-read from the schedule store") : .unverified("not found after saving")))
        case "schedule.list":
            let items = await store.all().filter { $0.status == "scheduled" }.sorted { $0.dueAt < $1.dueAt }
            let lines = items.map { "• \(formatter.string(from: $0.dueAt))\($0.repeatRule == .none ? "" : " (\($0.repeatRule.rawValue))"): \($0.command)" }
            let message = items.isEmpty ? context.t("Nothing is scheduled.", "No hay nada programado.") : lines.joined(separator: "\n")
            return .done(ToolOutput(message: message, data: try JSONValue.encoding(items), verification: .notApplicable))
        case "schedule.cancel":
            let items = await store.all().filter { $0.status == "scheduled" }
            var matches: [ScheduledCommand] = []
            if let id = call.string("id").flatMap(UUID.init(uuidString:)) {
                matches = items.filter { $0.id == id }
            } else if let match = call.string("match") {
                let folded = match.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                matches = items.filter { $0.command.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).contains(folded) }
            }
            guard var found = matches.first else {
                return .done(ToolOutput(message: context.t("No scheduled command matches.", "Ningún comando programado coincide."), verification: .notApplicable))
            }
            if matches.count > 1 {
                // Several match: the user picks; the option carries the exact id so the choice is unambiguous.
                let options = matches.sorted { $0.dueAt < $1.dueAt }.map { item in
                    ClarificationOption(label: "\(formatter.string(from: item.dueAt)): \(item.command)", call: ToolCall(tool: call.descriptor.name, arguments: ["id": .string(item.id.uuidString)]))
                }
                return .clarify(Clarification(question: context.t("Several scheduled commands match. Which one should I cancel?", "Varios comandos programados coinciden. ¿Cuál cancelo?"), options: options))
            }
            found.status = "cancelled"
            do {
                try await store.save(found)
            } catch {
                throw JarvisError.failed("schedule_not_saved", en: "I couldn't record the cancellation: \(error.localizedDescription)", es: "No pude guardar la cancelación: \(error.localizedDescription)")
            }
            return .done(ToolOutput(message: context.t("Cancelled “\(found.command)”.", "Cancelado «\(found.command)»."), data: try JSONValue.encoding(found), verification: .verified("status cancelled in the store")))
        default:
            throw JarvisError.validation([ValidationIssue(.unknownTool, "Unknown tool")])
        }
    }
}

/// Runs due commands through the assistant. Started by the app; checks every 15 s.
public actor CommandScheduler {
    static let logger = Logger(subsystem: "com.alejandro.friday", category: "scheduler")
    private let store: any ScheduleStoring
    private let run: @Sendable (ScheduledCommand) async -> Void
    private var loop: Task<Void, Never>?
    /// Items whose state could not be saved: not run (a one-shot would otherwise repeat every tick) and retried later.
    private var deferred: [UUID: Date] = [:]
    static let retryAfter: TimeInterval = 300

    public init(store: any ScheduleStoring, run: @escaping @Sendable (ScheduledCommand) async -> Void) {
        self.store = store
        self.run = run
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    public func stop() { loop?.cancel(); loop = nil }

    func tick(now: Date = Date()) async {
        for var item in await store.all() where item.status == "scheduled" && item.dueAt <= now {
            if let failedAt = deferred[item.id], now.timeIntervalSince(failedAt) < Self.retryAfter { continue }
            // Missed by a long time (asleep, not running): run once now, and say so through the command itself.
            Self.logger.info("running scheduled command \(item.id.uuidString, privacy: .public)")
            item.lastRunAt = now
            switch item.repeatRule {
            case .none: item.status = "done"
            case .daily: item.dueAt = Self.next(item.dueAt, days: 1, after: now)
            case .weekly: item.dueAt = Self.next(item.dueAt, days: 7, after: now)
            case .weekdays:
                var next = Self.next(item.dueAt, days: 1, after: now)
                while Calendar.current.isDateInWeekend(next) { next = Calendar.current.date(byAdding: .day, value: 1, to: next) ?? next }
                item.dueAt = next
            }
            do {
                try await store.save(item)
            } catch {
                Self.logger.error("could not record the run of \(item.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                deferred[item.id] = now
                continue
            }
            deferred[item.id] = nil
            await run(item)
        }
    }

    static func next(_ date: Date, days: Int, after now: Date) -> Date {
        var next = date
        while next <= now { next = Calendar.current.date(byAdding: .day, value: days, to: next) ?? now.addingTimeInterval(Double(days) * 86_400) }
        return next
    }
}
