import Foundation
import Testing
import FridayCore
@testable import FridayAssistant

/// A store that can be told to fail, to check the integration never reports what it could not save.
actor FailingScheduleStore: ScheduleStoring {
    var items: [ScheduledCommand] = []
    var failing = false
    func setFailing(_ value: Bool) { failing = value }
    func all() -> [ScheduledCommand] { items }
    func save(_ item: ScheduledCommand) throws {
        if failing { throw ScheduleStoreError.notPersisted("disk full") }
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item } else { items.append(item) }
    }
    func remove(id: UUID) throws {
        if failing { throw ScheduleStoreError.notPersisted("disk full") }
        items.removeAll { $0.id == id }
    }
}

@Suite struct ScheduleIntegrationTests {
    static let zone = TimeZone(identifier: "Europe/Madrid")!
    /// Friday 6 November 2026, 10:00 Madrid.
    static let now = Date(timeIntervalSince1970: 1_793_955_600)

    func context(language: Language = .en, now: Date = Self.now) -> ExecutionContext {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.zone
        calendar.firstWeekday = 2
        return ExecutionContext(language: language, now: now, calendar: calendar, settings: JarvisSettings(), source: .test)
    }

    func run(_ integration: ScheduleIntegration, _ tool: ToolName, _ arguments: JSONObject, language: Language = .en) async throws -> ToolOutcome {
        let registry = ToolRegistry(integrations: [integration])
        let validated = try registry.validate(ToolCall(tool: tool, arguments: arguments))
        return try await integration.execute(validated, context: context(language: language))
    }

    @Test func aWeekdayScheduleNeverFirstFiresOnAWeekend() async throws {
        let store = FailingScheduleStore()
        let integration = ScheduleIntegration(store: store)
        // Saturday 7 November 2026 at 09:00 Madrid.
        let outcome = try await run(integration, "schedule.create", ["command": "check my calendar", "at": "2026-11-07T09:00:00+01:00", "repeat": "weekdays"])
        guard case .done(let output) = outcome else { Issue.record("expected done, got \(outcome)"); return }
        let saved = await store.items
        #expect(saved.count == 1)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.zone
        #expect(saved.first.map { calendar.component(.weekday, from: $0.dueAt) } == 2)  // Monday
        #expect(saved.first.map { calendar.component(.hour, from: $0.dueAt) } == 9)
        #expect(output.message.contains("weekend"))
        #expect(output.verification.isVerified)
    }

    @Test func aFailedSaveIsReportedNotVerified() async throws {
        let store = FailingScheduleStore()
        await store.setFailing(true)
        let integration = ScheduleIntegration(store: store)
        await #expect(throws: JarvisError.self) {
            _ = try await run(integration, "schedule.create", ["command": "open Notes", "at": "2026-11-06T20:00:00+01:00"], language: .es)
        }
        #expect(await store.items.isEmpty)
    }

    @Test func cancellingByTextAsksWhenSeveralMatch() async throws {
        let store = FailingScheduleStore()
        try await store.save(ScheduledCommand(command: "open Notes and Music", dueAt: Self.now.addingTimeInterval(3_600)))
        try await store.save(ScheduledCommand(command: "open Notes", dueAt: Self.now.addingTimeInterval(7_200)))
        let integration = ScheduleIntegration(store: store)
        let outcome = try await run(integration, "schedule.cancel", ["match": "notes"], language: .es)
        guard case .clarify(let clarification) = outcome else { Issue.record("expected a clarification, got \(outcome)"); return }
        #expect(clarification.options.count == 2)
        #expect(clarification.question.contains("cancelo"))
        // Choosing an option cancels exactly that one.
        let chosen = try await run(integration, "schedule.cancel", clarification.options[1].call.arguments)
        guard case .done(let output) = chosen else { Issue.record("expected done, got \(chosen)"); return }
        #expect(output.message.contains("open Notes”"))
        let remaining = await store.items.filter { $0.status == "scheduled" }
        #expect(remaining.map(\.command) == ["open Notes and Music"])
    }

    @Test func cancellingByTextWithOneMatchCancelsIt() async throws {
        let store = FailingScheduleStore()
        try await store.save(ScheduledCommand(command: "play my study playlist", dueAt: Self.now.addingTimeInterval(3_600)))
        let integration = ScheduleIntegration(store: store)
        let outcome = try await run(integration, "schedule.cancel", ["match": "study"])
        guard case .done(let output) = outcome else { Issue.record("expected done, got \(outcome)"); return }
        #expect(output.verification.isVerified)
        #expect(await store.items.first?.status == "cancelled")
    }

    @Test func theFileStoreWritesAtomicallyAndReadsBack() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("friday-schedule-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("schedule.json")
        let store = FileScheduleStore(url: url)
        let item = ScheduledCommand(command: "open Notes", dueAt: Self.now)
        try await store.save(item)
        let reloaded = FileScheduleStore(url: url)
        #expect(await reloaded.all().map(\.id) == [item.id])
        // An unwritable location fails loudly and leaves the list unchanged.
        let broken = FileScheduleStore(url: directory.appendingPathComponent("missing/dir/schedule.json"))
        await #expect(throws: ScheduleStoreError.self) { try await broken.save(item) }
        #expect(await broken.all().isEmpty)
    }

    @Test func theSchedulerSkipsAnItemWhoseRunCannotBeRecorded() async throws {
        let store = FailingScheduleStore()
        try await store.save(ScheduledCommand(command: "open Notes", dueAt: Self.now.addingTimeInterval(-60)))
        let ran = Mutex<[String]>([])
        let scheduler = CommandScheduler(store: store) { item in ran.set(ran.get() + [item.command]) }
        await store.setFailing(true)
        await scheduler.tick(now: Self.now)
        #expect(ran.get().isEmpty)
        await store.setFailing(false)
        await scheduler.tick(now: Self.now)  // still deferred: retried only after a while
        #expect(ran.get().isEmpty)
        await scheduler.tick(now: Self.now.addingTimeInterval(CommandScheduler.retryAfter + 1))
        #expect(ran.get() == ["open Notes"])
        #expect(await store.items.first?.status == "done")
    }
}
