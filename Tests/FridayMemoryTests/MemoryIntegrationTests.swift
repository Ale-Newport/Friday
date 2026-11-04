import Foundation
import FridayCore
import Testing

@testable import FridayMemory

@Suite("MemoryIntegration")
struct MemoryIntegrationTests {
    private let store: MemoryStore
    private let registry: ToolRegistry

    init() throws {
        store = try MemoryStore.inMemory()
        registry = ToolRegistry(integrations: [MemoryIntegration(store: store)])
    }

    @Test func declaresTheExpectedToolsAndNeedsNoPermissions() async throws {
        let integration = MemoryIntegration(store: store)
        #expect(integration.id == .memory)
        #expect(integration.symbolName == "brain")
        #expect(integration.permissionRequirements.isEmpty)
        #expect(await integration.status().state == .ready)
        #expect(await integration.authorization(for: integration.tools[0]) == .authorized)
        #expect(await integration.requestAuthorization(for: integration.tools[0]) == .authorized)
        let names = Set(integration.tools.map(\.name.rawValue))
        #expect(
            names == [
                "memory.remember", "memory.recall", "memory.forget", "memory.list", "memory.clear_conversations", "memory.export",
                "memory.status", "routines.save", "routines.list", "routines.delete", "tasks.list",
            ])
        for descriptor in integration.tools {
            #expect(descriptor.integration == .memory)
            #expect(descriptor.examples.contains { $0.language == .en }, "\(descriptor.name) needs an English example")
            #expect(descriptor.examples.contains { $0.language == .es }, "\(descriptor.name) needs a Spanish example")
            for example in descriptor.examples {
                #expect(throws: Never.self, "\(descriptor.name): \(example.phrase)") {
                    try registry.validate(ToolCall(tool: descriptor.name, arguments: example.arguments))
                }
            }
        }
        #expect(registry.descriptor(for: .memoryRemember)?.deduplicate == true)
        #expect(registry.descriptor(for: .memoryForget)?.safety == .destructive)
        #expect(registry.descriptor(for: .memoryRecall)?.safety == .readOnly)
        #expect(registry.descriptor(for: .memoryRemember)?.parameter(named: "kind")?.defaultValue == "knowledge")
    }

    @Test func rememberThenRecallInBothLanguages() async throws {
        let remembered = try await registry.run(.memoryRemember, ["content": "Tomo el café con leche de avena", "kind": "preference", "key": "Café"])
        let output = try #require(remembered.output)
        #expect(output.verification.isVerified)
        #expect(output.message.hasPrefix("Remembered (preference): Tomo el café"))
        #expect(output.data?["key"] == "cafe")
        #expect(output.data?["kind"] == "preference")
        let id = try #require(output.data?["id"]?.stringValue)
        #expect(try await store.item(id: try #require(UUID(uuidString: id)))?.content == "Tomo el café con leche de avena")

        // Default kind applies; remembering the same key updates rather than duplicates.
        _ = try await registry.run(.memoryRemember, ["content": "Prefiero leche de avena", "key": "cafe"])
        #expect(try await store.count() == 1)
        let fact = try await registry.run(.memoryRemember, ["content": "The office wifi is called Nebula"], context: executionContext(language: .es))
        #expect(fact.output?.message.hasPrefix("Recordado (conocimiento):") == true)

        let recalled = try await registry.run(.memoryRecall, ["query": "cafe con leche"], context: executionContext(language: .es))
        let recall = try #require(recalled.output)
        #expect(recall.message.hasPrefix("Recuerdo 1 cosa sobre «cafe con leche»:"))
        #expect(recall.data?["count"] == 1)
        #expect(recall.data?["items"]?[0]?["content"] == "Prefiero leche de avena")
        #expect(recall.verification == .notApplicable)

        let english = try await registry.run(.memoryRecall, ["query": "wifi", "kind": "knowledge", "limit": 3])
        #expect(english.output?.message.contains("[knowledge] The office wifi is called Nebula") == true)
        let nothing = try await registry.run(.memoryRecall, ["query": "zebra"])
        #expect(nothing.output?.message == "I don't remember anything about “zebra”.")
        #expect(nothing.output?.data?["count"] == 0)
    }

    @Test func forgetAsksForConfirmationThenDeletesAndVerifies() async throws {
        let stored = try await store.remember(kind: .preference, key: "coffee", content: "Flat white")
        let asked = try await registry.run(.memoryForget, ["key": "coffee"])
        let confirmation = try #require(asked.confirmation)
        #expect(confirmation.destructive)
        #expect(confirmation.prompt == "Forget “Flat white”? This cannot be undone.")
        #expect(confirmation.call.tool == .memoryForget)
        #expect(confirmation.call.arguments["id"] == .string(stored.id.uuidString))
        #expect(try await store.count() == 1)

        let done = try await registry.confirm(confirmation, language: .es)
        let output = try #require(done.output)
        #expect(output.message == "Olvidado: Flat white")
        #expect(output.verification == .verified("Comprobado que la memoria ya no existe."))
        #expect(try await store.count() == 0)

        await #expect(throws: JarvisError.self) { try await registry.run(.memoryForget, ["key": "coffee"]) }
        await #expect(throws: JarvisError.self) { try await registry.run(.memoryForget, ["id": "not-a-uuid"]) }
        #expect(throws: JarvisError.self) { try registry.validate(ToolCall(tool: .memoryForget, arguments: [:])) }
        // Confirmation is per call: an unconfirmed context asks again even with the resolved id.
        let again = try await store.remember(kind: .knowledge, content: "Second")
        let askedById = try await registry.run(.memoryForget, ["id": .string(again.id.uuidString)])
        #expect(askedById.confirmation != nil)
        #expect(try await store.count() == 1)
    }

    @Test func listStatusAndExport() async throws {
        _ = try await store.remember(kind: .preference, key: "coffee", content: "Flat white", now: fixedNow)
        _ = try await store.remember(kind: .knowledge, content: "Gym on Tuesdays", now: fixedNow)
        try await store.appendTurn(session: "s1", role: "user", text: "hola", now: fixedNow)
        try await store.recordTask(TaskRecord(title: "Index photos", status: "in_progress"))
        _ = try await store.saveRoutine(name: "Study", phrases: ["start studying"], steps: [ToolCall(tool: .musicPause)])

        let list = try await registry.run(.memoryList, ["kind": "preference"])
        #expect(list.output?.data?["count"] == 1)
        #expect(list.output?.message.contains("[preference] Flat white (coffee)") == true)
        let all = try await registry.run(.memoryList, [:], context: executionContext(language: .es))
        #expect(all.output?.message.hasPrefix("2 memorias guardadas (muestro 2):") == true)
        let empty = try await registry.run(.memoryList, ["kind": "workflow"])
        #expect(empty.output?.message == "I have no stored memories of kind workflow.")

        let status = try await registry.run(.memoryStatus, [:])
        let data = try #require(status.output?.data)
        #expect(data["enabled"] == true)
        #expect(data["items"] == 2)
        #expect(data["items_by_kind"]?["preference"] == 1)
        #expect(data["conversation_turns"] == 1)
        #expect(data["sessions"] == 1)
        #expect(data["tasks"] == 1)
        #expect(data["routines"] == 1)
        #expect(data["retention_days"] == .int(MemoryStore.defaultRetentionDays))
        #expect(data["full_text_search"] == true)
        #expect(status.output?.message.hasPrefix("Memory is on: 2 memories, 1 conversation turns in 1 sessions, 1 tasks, 1 routines.") == true)
        try await store.setEnabled(false)
        let off = try await registry.run(.memoryStatus, [:], context: executionContext(language: .es))
        #expect(off.output?.message.hasPrefix("La memoria está desactivada") == true)
        let offRecall = try await registry.run(.memoryRecall, ["query": "coffee"])
        #expect(offRecall.output?.message == "Memory is turned off, so I can't recall anything.")
        await #expect(throws: JarvisError.failed(code: "memory_disabled", MemoryError.disabled.localizedText)) {
            try await registry.run(.memoryRemember, ["content": "nope"])
        }
        try await store.setEnabled(true)

        let export = try await registry.run(.memoryExport, [:])
        #expect(export.output?.message == "Exported 2 memories, 1 conversation turns, 1 tasks and 1 routines as JSON.")
        #expect(export.output?.data?["items"]?.arrayValue?.count == 2)
        #expect(export.output?.data?["routines"]?[0]?["name"] == "Study")
        #expect(export.output?.data?["conversations"]?[0]?["text"] == "hola")
        #expect(export.output?.data?["enabled"] == true)
    }

    @Test func clearConversationsNeedsConfirmation() async throws {
        try await store.appendTurn(session: "s1", role: "user", text: "uno")
        try await store.appendTurn(session: "s1", role: "assistant", text: "dos")
        try await store.appendTurn(session: "s2", role: "user", text: "tres")

        let one = try await registry.run(.memoryClearConversations, ["session": "s1"], context: executionContext(language: .es))
        let askOne = try #require(one.confirmation)
        #expect(askOne.prompt == "¿Borro los 2 mensajes guardados de esta conversación? No se puede deshacer.")
        #expect(askOne.call.arguments["session"] == "s1")
        #expect(try await store.turnCount() == 3)
        let clearedOne = try #require(try await registry.confirm(askOne).output)
        #expect(clearedOne.message == "Deleted 2 conversation turns.")
        #expect(clearedOne.verification.isVerified)
        #expect(try await store.turnCount() == 1)

        let all = try await registry.run(.memoryClearConversations, [:])
        let askAll = try #require(all.confirmation)
        #expect(askAll.prompt == "Delete all 1 stored conversation turns? This cannot be undone.")
        #expect(askAll.destructive)
        let clearedAll = try #require(try await registry.confirm(askAll, language: .es).output)
        #expect(clearedAll.message == "Borrado 1 mensaje de conversación.")
        #expect(try await store.sessions().isEmpty)
    }

    @Test func routinesSaveListAndDeleteThroughTools() async throws {
        let steps = #"[{"tool":"music.play_playlist","arguments":{"name":"Deep Focus"}},{"tool":"timers.create","arguments":{"duration_seconds":1500}}]"#
        let saved = try await registry.run(.routinesSave, ["name": "Study", "phrases": ["start studying", "empezar a estudiar"], "steps_json": .string(steps)])
        let output = try #require(saved.output)
        #expect(output.verification.isVerified)
        #expect(output.message == "Routine “Study” saved: say “start studying” / “empezar a estudiar” to run music.play_playlist, timers.create.")
        #expect(output.data?["steps"]?.arrayValue?.count == 2)
        #expect(output.data?["steps"]?[1]?["arguments"]?["duration_seconds"] == 1500)
        let routine = try #require(try await store.findRoutine(matching: "empieza a estudiar"))
        #expect(routine.steps.map(\.tool) == [.musicPlayPlaylist, .timersCreate])
        #expect(routine.steps[0].arguments == ["name": "Deep Focus"])

        // A single phrase may arrive as a bare string; the validator wraps it.
        let spanish = try await registry.run(
            .routinesSave, ["name": "Noche", "phrases": "buenas noches", "steps_json": #"[{"tool":"music.pause"}]"#],
            context: executionContext(language: .es))
        #expect(spanish.output?.message == "Rutina «Noche» guardada: di “buenas noches” para ejecutar music.pause.")

        for bad in ["not json", "{}", "[]", #"[{"arguments":{}}]"#, #"[{"tool":"nodot"}]"#, #"[{"tool":"music.play","arguments":"x"}]"#, #"[{"tool":"music.play","extra":1}]"#, #"[{"tool":"Music.Play"}]"#] {
            await #expect(throws: JarvisError.self, "\(bad)") {
                try await registry.run(.routinesSave, ["name": "Bad", "phrases": ["x"], "steps_json": .string(bad)])
            }
        }
        #expect(try await store.routines().count == 2)

        let list = try await registry.run(.routinesList, [:])
        #expect(list.output?.data?["count"] == 2)
        #expect(list.output?.message.contains("• Study — “start studying” / “empezar a estudiar” → 2 steps") == true)
        #expect(list.output?.message.contains("• Noche — “buenas noches” → 1 step") == true)

        let ask = try await registry.run(.routinesDelete, ["name": "study"], context: executionContext(language: .es))
        let confirmation = try #require(ask.confirmation)
        #expect(confirmation.prompt == "¿Borro la rutina «Study»? No se puede deshacer.")
        #expect(confirmation.call.arguments["id"] == .string(routine.id.uuidString))
        let deleted = try #require(try await registry.confirm(confirmation).output)
        #expect(deleted.message == "Routine “Study” deleted.")
        #expect(deleted.verification.isVerified)
        #expect(try await store.routines().map(\.name) == ["Noche"])
        await #expect(throws: JarvisError.self) { try await registry.run(.routinesDelete, ["name": "Study"]) }
        let emptyList = try await registry.run(.routinesList, [:], context: executionContext(language: .es))
        _ = try await registry.confirm(try #require(try await registry.run(.routinesDelete, ["name": "noche"]).confirmation))
        #expect(emptyList.output?.message.hasPrefix("1 rutina:") == true)
        #expect(try await registry.run(.routinesList, [:], context: executionContext(language: .es)).output?.message == "Todavía no he aprendido ninguna rutina.")
    }

    @Test func tasksListShowsWhatFridayIsWorkingOn() async throws {
        let none = try await registry.run(.tasksList, [:])
        #expect(none.output?.message == "I'm not tracking any tasks.")
        try await store.recordTask(TaskRecord(title: "Organise Downloads", status: "in_progress", createdAt: fixedNow, updatedAt: fixedNow, detail: "120 files left"))
        try await store.recordTask(TaskRecord(title: "Send weekly summary", status: "done", createdAt: fixedNow, updatedAt: fixedNow + 1))
        let active = try await registry.run(.tasksList, ["status": "In Progress"])
        #expect(active.output?.message == "1 task:\n• [in_progress] Organise Downloads — 120 files left")
        #expect(active.output?.data?["tasks"]?[0]?["status"] == "in_progress")
        let all = try await registry.run(.tasksList, ["limit": 10], context: executionContext(language: .es))
        #expect(all.output?.message.hasPrefix("2 tareas:\n• [done] Send weekly summary") == true)
        let missing = try await registry.run(.tasksList, ["status": "failed"], context: executionContext(language: .es))
        #expect(missing.output?.message == "No hay tareas con estado «failed».")
    }

    @Test func validationRejectsBadArguments() async throws {
        #expect(throws: JarvisError.self) { try registry.validate(ToolCall(tool: .memoryRemember, arguments: ["content": "x", "kind": "secret"])) }
        #expect(throws: JarvisError.self) { try registry.validate(ToolCall(tool: .memoryRemember, arguments: [:])) }
        #expect(throws: JarvisError.self) { try registry.validate(ToolCall(tool: .memoryRecall, arguments: ["query": "x", "limit": 0])) }
        #expect(throws: JarvisError.self) { try registry.validate(ToolCall(tool: .routinesSave, arguments: ["name": "x", "phrases": ["a"]])) }
        #expect(throws: JarvisError.self) { try registry.validate(ToolCall(tool: .routinesDelete, arguments: [:])) }
        #expect(throws: JarvisError.self) { try registry.validate(ToolCall(tool: "memory.nope", arguments: [:])) }
        #expect(MemoryIntegration.isWellFormedToolName("music.play_playlist"))
        #expect(!MemoryIntegration.isWellFormedToolName("music"))
        #expect(!MemoryIntegration.isWellFormedToolName("music.play.now"))
        #expect(!MemoryIntegration.isWellFormedToolName("Music.play"))
    }
}
