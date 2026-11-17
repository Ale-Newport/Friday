import Foundation
import FridayCore
import Testing

@testable import FridayMemory

@Suite("MemoryStore")
struct MemoryStoreTests {
    // MARK: Items

    @Test func rememberReadBackAndForget() async throws {
        let store = try MemoryStore.inMemory()
        let item = try await store.remember(kind: .preference, key: "coffee", content: "Oat milk latte", source: "user", now: fixedNow)
        #expect(item.key == "coffee")
        #expect(item.useCount == 0)
        #expect(try await store.item(id: item.id) == item)
        #expect(try await store.item(key: "COFFEE")?.id == item.id)
        #expect(try await store.count() == 1)
        #expect(try await store.count(kind: .preference) == 1)
        #expect(try await store.count(kind: .knowledge) == 0)
        #expect(try await store.items(kind: .preference).map(\.id) == [item.id])

        try await store.touch(id: item.id, now: fixedNow)
        let touched = try #require(try await store.item(id: item.id))
        #expect(touched.useCount == 1)
        #expect(touched.lastUsedAt == fixedNow)

        try await store.forget(id: item.id)
        #expect(try await store.item(id: item.id) == nil)
        await #expect(throws: MemoryError.notFound) { try await store.forget(id: item.id) }
        await #expect(throws: MemoryError.invalidInput("content is empty")) {
            try await store.remember(kind: .knowledge, content: "   ")
        }
    }

    @Test func rememberUpsertsByFoldedKeyAndDeduplicatesIdenticalContent() async throws {
        let store = try MemoryStore.inMemory()
        let first = try await store.remember(kind: .preference, key: "Café", content: "con leche", now: fixedNow)
        let second = try await store.remember(kind: .preference, key: "cafe", content: "con leche de avena", now: fixedNow + 60)
        #expect(second.id == first.id)
        #expect(second.key == "cafe")
        #expect(second.content == "con leche de avena")
        #expect(second.createdAt == fixedNow)
        #expect(second.updatedAt == fixedNow + 60)
        #expect(try await store.count() == 1)

        let fact = try await store.remember(kind: .knowledge, content: "Mi cumpleaños es el 3 de mayo")
        let again = try await store.remember(kind: .knowledge, content: "mi cumpleanos es el 3 de Mayo")
        #expect(again.id == fact.id)
        #expect(try await store.count() == 2)

        try await store.forgetAll(kind: .preference)
        #expect(try await store.count() == 1)
        try await store.forgetAll()
        #expect(try await store.count() == 0)
    }

    @Test(arguments: [true, false])
    func recallIsAccentAndCaseInsensitiveInSpanish(fullTextSearch: Bool) async throws {
        let store = try MemoryStore.inMemory(fullTextSearch: fullTextSearch)
        #expect(await store.hasFullTextSearch == fullTextSearch)
        let playlist = try await store.remember(kind: .knowledge, content: "playlist Deep Focus = lista de estudio", now: fixedNow)
        _ = try await store.remember(kind: .preference, content: "Canción favorita: Bohemian Rhapsody", now: fixedNow)
        _ = try await store.remember(kind: .knowledge, content: "El gato se llama Pelusa", now: fixedNow)
        _ = try await store.remember(kind: .entity, content: "contact: Mamá — teléfono en Contactos", now: fixedNow)

        let found = try await store.recall(query: "mi lista de estudio", now: fixedNow)
        #expect(found.first?.id == playlist.id)
        #expect(try await store.recall(query: "LISTA DE ESTÚDIO", now: fixedNow).first?.id == playlist.id)
        #expect(try await store.recall(query: "cancion favorita", now: fixedNow).first?.content == "Canción favorita: Bohemian Rhapsody")
        #expect(try await store.recall(query: "CANCIÓN", now: fixedNow).first?.content.hasPrefix("Canción") == true)
        #expect(try await store.recall(query: "telefono de mama", now: fixedNow).first?.kind == .entity)
        #expect(try await store.recall(query: "zzz nothing here", now: fixedNow).isEmpty)
        #expect(try await store.recall(query: "estudio", kinds: [.preference], now: fixedNow).isEmpty)
        #expect(try await store.recall(query: "estudio", kinds: [.knowledge], now: fixedNow).map(\.id) == [playlist.id])
        #expect(try await store.recall(query: "estudio", limit: 0, now: fixedNow).isEmpty)
    }

    @Test func recallRanksExactKeyThenUsageAndRecency() async throws {
        let store = try MemoryStore.inMemory()
        let mention = try await store.remember(kind: .knowledge, content: "The coffee shop on Main Street opens at 7", now: fixedNow)
        let keyed = try await store.remember(kind: .preference, key: "coffee", content: "Flat white, no sugar", now: fixedNow - 86_400 * 20)
        let ranked = try await store.recall(query: "coffee", now: fixedNow)
        #expect(ranked.map(\.id) == [keyed.id, mention.id])

        // Same text match: the one used more often wins, then the more recent one.
        let older = try await store.remember(kind: .knowledge, content: "Backup drive is named Vault", now: fixedNow - 86_400 * 10)
        let newer = try await store.remember(kind: .knowledge, content: "Backup drive is called Vault", now: fixedNow)
        #expect(try await store.recall(query: "backup drive", now: fixedNow).map(\.id) == [newer.id, older.id])
        for _ in 0..<5 { try await store.touch(id: older.id, now: fixedNow - 86_400 * 10) }
        #expect(try await store.recall(query: "backup drive", now: fixedNow).map(\.id) == [older.id, newer.id])

        // Pinned items get a boost too.
        try await store.setPinned(id: newer.id, true)
        #expect(try await store.recall(query: "backup drive", now: fixedNow).first?.id == newer.id)
        #expect(try await store.recall(query: "backup", limit: 1, now: fixedNow).count == 1)
    }

    @Test func disablingMemoryStopsRememberAndRecall() async throws {
        let store = try MemoryStore.inMemory()
        _ = try await store.remember(kind: .knowledge, content: "Kept while disabled", now: fixedNow)
        try await store.setEnabled(false)
        #expect(await store.isEnabled == false)
        await #expect(throws: MemoryError.disabled) { try await store.remember(kind: .knowledge, content: "Should not be stored") }
        #expect(try await store.recall(query: "kept", now: fixedNow).isEmpty)
        #expect(try await store.count() == 1)
        try await store.setEnabled(true)
        #expect(try await store.recall(query: "kept", now: fixedNow).count == 1)
        _ = try await store.remember(kind: .knowledge, content: "Stored again")
        #expect(try await store.count() == 2)
    }

    @Test func disablingMemoryStopsAppendTurn() async throws {
        let store = try MemoryStore.inMemory()
        try await store.appendTurn(session: "s", role: "user", text: "kept", now: fixedNow)
        try await store.setEnabled(false)
        await #expect(throws: MemoryError.disabled) {
            try await store.appendTurn(session: "s", role: "assistant", text: "must not be stored", now: fixedNow + 1)
        }
        #expect(try await store.turnCount() == 1)
        #expect(try await store.recentTurns(session: "s").map(\.text) == ["kept"])
        try await store.setEnabled(true)
        try await store.appendTurn(session: "s", role: "assistant", text: "stored again", now: fixedNow + 2)
        #expect(try await store.turnCount() == 2)
    }

    @Test func retentionRunsAtOpenAndDailyFromWrites() async throws {
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let day = 86_400.0
        let now = Date()
        let staleID: UUID
        let freshID: UUID
        do {
            let store = try MemoryStore(databaseURL: url)
            try await store.setRetentionDays(30)
            staleID = try await store.remember(kind: .knowledge, content: "Stale fact", now: now - 40 * day).id
            freshID = try await store.remember(kind: .knowledge, content: "Fresh fact", now: now).id
            try await store.appendTurn(session: "s", role: "user", text: "old turn", now: now - 45 * day)
            try await store.appendTurn(session: "s", role: "user", text: "new turn", now: now)
            // Writes dated before the last prune never trigger one; everything is still there.
            #expect(try await store.item(id: staleID) != nil)
            #expect(try await store.turnCount() == 2)
        }
        // Opening the database enforces retention without anyone calling prune().
        let reopened = try MemoryStore(databaseURL: url)
        #expect(try await reopened.item(id: staleID) == nil)
        #expect(try await reopened.item(id: freshID) != nil)
        #expect(try await reopened.recentTurns(session: "s").map(\.text) == ["new turn"])
        let pruned = try #require(await reopened.lastPrunedAt)
        #expect(abs(pruned.timeIntervalSince(now)) < 60)

        // A day later the write paths prune again on their own.
        let later = pruned + 2 * day
        _ = try await reopened.remember(kind: .knowledge, content: "Became stale meanwhile", now: pruned - 29 * day)
        #expect(try await reopened.count() == 2)
        try await reopened.appendTurn(session: "s", role: "user", text: "later", now: later)
        #expect(try await reopened.count() == 1)
        #expect(await reopened.lastPrunedAt == later)
        #expect(try await reopened.pruneIfDue(now: later + 60) == 0)
        #expect(await reopened.lastPrunedAt == later)
    }

    @Test func settingsAndDataPersistAcrossReopenWithPrivateFile() async throws {
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try MemoryStore(databaseURL: url)
            // Today, not `fixedNow`: with a 30-day retention a fixed date eventually ages out at reopen (it did on 17 Nov 2026).
            _ = try await store.remember(kind: .preference, key: "language", content: "Prefiere español", now: Date())
            try await store.setEnabled(false)
            try await store.setRetentionDays(30)
            _ = try await store.saveRoutine(name: "Night", phrases: ["good night"], steps: [ToolCall(tool: "music.pause")])
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let reopened = try MemoryStore(databaseURL: url)
        #expect(await reopened.isEnabled == false)
        #expect(await reopened.retentionDays == 30)
        #expect(try await reopened.count() == 1)
        #expect(try await reopened.item(key: "language")?.content == "Prefiere español")
        #expect(try await reopened.routines().map(\.name) == ["Night"])
        try await reopened.setEnabled(true)
        #expect(try await reopened.recall(query: "español").count == 1)
        try await reopened.setRetentionDays(nil)
        #expect(await reopened.retentionDays == nil)
        #expect(try await reopened.prune(now: .distantFuture) == 0)
    }

    @Test func pruneRemovesOnlyStaleUnpinnedItemsAndOldTurns() async throws {
        let store = try MemoryStore.inMemory()
        try await store.setRetentionDays(30)
        let day = 86_400.0
        let stale = try await store.remember(kind: .knowledge, content: "Old fact", now: fixedNow - 40 * day)
        let pinned = try await store.remember(kind: .knowledge, content: "Old but pinned", now: fixedNow - 40 * day)
        try await store.setPinned(id: pinned.id, true)
        let usedRecently = try await store.remember(kind: .knowledge, content: "Old but used", now: fixedNow - 40 * day)
        try await store.touch(id: usedRecently.id, now: fixedNow - 2 * day)
        let fresh = try await store.remember(kind: .knowledge, content: "Fresh fact", now: fixedNow - 1 * day)
        try await store.appendTurn(session: "s", role: "user", text: "old", now: fixedNow - 45 * day)
        try await store.appendTurn(session: "s", role: "user", text: "new", now: fixedNow)

        let removed = try await store.prune(now: fixedNow)
        #expect(removed == 2)
        #expect(try await store.item(id: stale.id) == nil)
        #expect(try await store.item(id: pinned.id) != nil)
        #expect(try await store.item(id: usedRecently.id) != nil)
        #expect(try await store.item(id: fresh.id) != nil)
        #expect(try await store.recentTurns(session: "s").map(\.text) == ["new"])
        #expect(try await store.recall(query: "old fact", now: fixedNow).contains { $0.id == stale.id } == false)
        #expect(try await store.count() == 3)
    }

    // MARK: Entities

    @Test func entitiesUseStableFoldedKeys() async throws {
        let store = try MemoryStore.inMemory()
        let first = try await store.rememberEntity(kind: "playlist", name: "Deep Fócus", detail: "lista de estudio", now: fixedNow)
        #expect(first.key == "entity:playlist:deep focus")
        #expect(first.kind == .entity)
        #expect(first.content == "playlist: Deep Fócus — lista de estudio")
        let second = try await store.rememberEntity(kind: "Playlist", name: "deep focus", detail: "lista de estudio para concentrarse", now: fixedNow + 1)
        #expect(second.id == first.id)
        _ = try await store.rememberEntity(kind: "contact", name: "Mamá", detail: nil)
        #expect(try await store.entities(kind: "playlist").map(\.id) == [first.id])
        #expect(try await store.entities(kind: "contact").first?.content == "contact: Mamá")
        #expect(try await store.entities(kind: "app").isEmpty)
        #expect(try await store.recall(query: "mi lista de estudio", now: fixedNow).first?.id == first.id)
        #expect(try await store.recall(query: "playlist para concentrarse", now: fixedNow).first?.id == first.id)
        await #expect(throws: MemoryError.self) { try await store.rememberEntity(kind: "", name: "x") }
    }

    // MARK: Conversations

    @Test func conversationTurnsAreCappedPerSessionAndListedAsSessions() async throws {
        let store = try MemoryStore.inMemory()
        for index in 0..<(MemoryStore.maxTurnsPerSession + 5) {
            try await store.appendTurn(
                session: "chat-1", role: index.isMultiple(of: 2) ? "user" : "assistant", text: "turn \(index)",
                language: "es", toolSummary: index == 1 ? "music.play" : nil, now: fixedNow + Double(index))
        }
        try await store.appendTurn(session: "chat-2", role: "assistant", text: "hola", now: fixedNow + 1_000)
        try await store.appendTurn(session: "chat-2", role: "user", text: "¿Qué hora es?", now: fixedNow + 1_001)

        #expect(try await store.turnCount(session: "chat-1") == MemoryStore.maxTurnsPerSession)
        let recent = try await store.recentTurns(session: "chat-1", limit: 3)
        #expect(recent.map(\.text) == ["turn 402", "turn 403", "turn 404"])
        #expect(recent.first?.language == "es")
        let oldest = try await store.recentTurns(session: "chat-1", limit: MemoryStore.maxTurnsPerSession).first
        #expect(oldest?.text == "turn 5")

        let sessions = try await store.sessions()
        #expect(sessions.map(\.id) == ["chat-2", "chat-1"])
        #expect(sessions.first?.title == "¿Qué hora es?")
        #expect(sessions.first?.turnCount == 2)
        #expect(sessions.last?.title == "turn 6")

        #expect(try await store.clearConversation(session: "chat-2") == 2)
        #expect(try await store.sessions().map(\.id) == ["chat-1"])
        #expect(try await store.clearAllConversations() == MemoryStore.maxTurnsPerSession)
        #expect(try await store.turnCount() == 0)
        await #expect(throws: MemoryError.self) { try await store.appendTurn(session: " ", role: "user", text: "x") }
    }

    // MARK: Tasks

    @Test func taskRecordsSurviveAndUpdate() async throws {
        let store = try MemoryStore.inMemory()
        let record = TaskRecord(
            title: "Export the quarterly report", status: "in_progress", createdAt: fixedNow, updatedAt: fixedNow,
            detail: "Waiting for Numbers", payload: ["pages": 3, "names": ["a", "b"], "nested": ["ok": true]])
        try await store.recordTask(record)
        #expect(try await store.task(id: record.id) == record)
        #expect(try await store.tasks(status: "in_progress").map(\.id) == [record.id])
        #expect(try await store.tasks(status: "done").isEmpty)

        let done = try await store.updateTask(id: record.id, status: "done", detail: "Saved to Desktop", now: fixedNow + 10)
        #expect(done.status == "done")
        #expect(done.detail == "Saved to Desktop")
        #expect(done.updatedAt == fixedNow + 10)
        #expect(done.payload == record.payload)
        #expect(try await store.tasks().map(\.status) == ["done"])

        let keepsDetail = try await store.updateTask(id: record.id, status: "archived", now: fixedNow + 20)
        #expect(keepsDetail.detail == "Saved to Desktop")
        await #expect(throws: MemoryError.notFound) { try await store.updateTask(id: UUID(), status: "x") }
        try await store.deleteTask(id: record.id)
        #expect(try await store.task(id: record.id) == nil)
    }

    // MARK: Routines

    @Test func routinesMatchFuzzilyAcrossLanguages() async throws {
        let store = try MemoryStore.inMemory()
        let steps = [
            ToolCall(tool: .musicPlayPlaylist, arguments: ["name": "Deep Focus"]),
            ToolCall(tool: .timersCreate, arguments: ["duration_seconds": 1500]),
        ]
        let study = try await store.saveRoutine(name: "Study", phrases: ["empezar a estudiar", "start studying"], steps: steps, now: fixedNow)
        _ = try await store.saveRoutine(name: "Wind down", phrases: ["good night", "buenas noches"], steps: [ToolCall(tool: .musicPause)])

        #expect(try await store.findRoutine(matching: "empieza a estudiar")?.id == study.id)
        #expect(try await store.findRoutine(matching: "Empezár a estudiár")?.id == study.id)
        #expect(try await store.findRoutine(matching: "START STUDYING")?.id == study.id)
        #expect(try await store.findRoutine(matching: "Friday, start studying now please")?.id == study.id)
        #expect(try await store.findRoutine(matching: "oye friday, empieza a estudiar ya")?.id == study.id)
        #expect(try await store.findRoutine(matching: "buenas noches friday")?.name == "Wind down")
        #expect(try await store.findRoutine(matching: "order a pizza") == nil)
        #expect(try await store.findRoutine(matching: "") == nil)

        let saved = try #require(try await store.routine(id: study.id))
        #expect(saved.steps == steps)
        #expect(saved.phrases == ["empezar a estudiar", "start studying"])

        try await store.markRoutineRun(id: study.id, now: fixedNow + 5)
        let ran = try #require(try await store.routine(named: "study"))
        #expect(ran.runCount == 1)
        #expect(ran.lastRunAt == fixedNow + 5)

        let replaced = try await store.saveRoutine(name: "STUDY", phrases: ["study time"], steps: [steps[0]], now: fixedNow + 10)
        #expect(replaced.id == study.id)
        #expect(replaced.runCount == 1)
        #expect(try await store.routines().count == 2)
        #expect(try await store.findRoutine(matching: "empezar a estudiar") == nil)
        #expect(try await store.findRoutine(matching: "study time")?.steps.count == 1)

        try await store.deleteRoutine(id: study.id)
        #expect(try await store.routines().map(\.name) == ["Wind down"])
        await #expect(throws: MemoryError.notFound) { try await store.deleteRoutine(id: study.id) }
        await #expect(throws: MemoryError.self) { try await store.saveRoutine(name: "Empty", phrases: ["x"], steps: []) }
        await #expect(throws: MemoryError.self) { try await store.saveRoutine(name: "No phrases", phrases: [" "], steps: steps) }
    }

    @Test func phraseMatchingThreshold() {
        #expect(PhraseMatching.similarity("empieza a estudiar", "empezar a estudiar") >= 0.85)
        #expect(PhraseMatching.similarity("Canción", "cancion") == 1)
        #expect(PhraseMatching.score(text: "play music", phrase: "start studying") == nil)
        #expect(PhraseMatching.score(text: "start studying", phrase: "start studying") == 1)
        #expect(PhraseMatching.editDistance(Array("abcd"), Array("abdc")) == 1)
    }

    @Test func routineTriggersNeedTheWholePhrase() async throws {
        let store = try MemoryStore.inMemory()
        let steps = [ToolCall(tool: .musicPlayPlaylist, arguments: ["name": "Deep Focus"])]
        let study = try await store.saveRoutine(name: "Study", phrases: ["empezar a estudiar", "start studying"], steps: steps, now: fixedNow)
        // The phrase surrounded only by wake words, politeness and "now" still triggers.
        for utterance in [
            "oye friday, empieza a estudiar ya", "Friday, start studying now please", "can you start studying", "quiero empezar a estudiar",
            "empezar a estudiar, por favor", "start studying!",
        ] {
            #expect(try await store.findRoutine(matching: utterance)?.id == study.id, "\(utterance)")
        }
        // An utterance that merely contains the phrase among other content words is a different request.
        for utterance in [
            "voy a estudiar inglés mañana, pon un recordatorio", "start studying and set a timer for twenty minutes",
            "remind me to start studying at eight", "cuando empiece a estudiar avísame", "a estudiar",
        ] {
            #expect(try await store.findRoutine(matching: utterance) == nil, "\(utterance)")
        }
        #expect(PhraseMatching.score(text: "voy a estudiar hoy", phrase: "a estudiar") == nil)
        #expect(PhraseMatching.score(text: "friday a estudiar", phrase: "a estudiar") != nil)
        let exact = try #require(PhraseMatching.score(text: "start studying", phrase: "start studying"))
        let wrapped = try #require(PhraseMatching.score(text: "hey friday start studying please", phrase: "start studying"))
        #expect(exact > wrapped)
    }

    @Test func shortTriggerPhrasesAreRefused() async throws {
        let store = try MemoryStore.inMemory()
        let steps = [ToolCall(tool: .musicPause)]
        await #expect(throws: MemoryError.self) { try await store.saveRoutine(name: "Tiny", phrases: ["ok"], steps: steps) }
        await #expect(throws: MemoryError.self) { try await store.saveRoutine(name: "Tiny", phrases: ["good night", "a"], steps: steps) }
        #expect(try await store.routines().isEmpty)
        _ = try await store.saveRoutine(name: "Fine", phrases: ["bye"], steps: steps)
        #expect(try await store.routines().count == 1)
    }

    @Test func routinesWithUndecodableStepsStayVisibleAndReplaceable() async throws {
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try MemoryStore(databaseURL: url)
        let steps = [ToolCall(tool: .musicPause)]
        let night = try await store.saveRoutine(name: "Night", phrases: ["good night"], steps: steps, now: fixedNow)
        try await store.markRoutineRun(id: night.id, now: fixedNow)
        // Simulate a stored step format this build can no longer decode.
        let raw = try SQLiteConnection(path: url.path)
        try raw.run("UPDATE routines SET steps = ? WHERE id = ?", [.text("[{\"not\": \"a tool call\"}]"), .text(night.id.uuidString)])

        let listed = try #require(try await store.routines().first)
        #expect(listed.id == night.id)
        #expect(listed.steps.isEmpty)
        #expect(try await store.findRoutine(matching: "good night") == nil, "a routine without steps never runs")
        // Saving the same name replaces the broken row and keeps its identity and counters.
        let replaced = try await store.saveRoutine(name: "night", phrases: ["good night"], steps: steps, now: fixedNow + 1)
        #expect(replaced.id == night.id)
        #expect(replaced.runCount == 1)
        #expect(try await store.findRoutine(matching: "good night")?.steps == steps)
        try await store.deleteRoutine(named: "NIGHT")
        #expect(try await store.routines().isEmpty)
        await #expect(throws: MemoryError.notFound) { try await store.deleteRoutine(named: "night") }
    }

    // MARK: Export

    @Test func exportRoundTripsThroughRestore() async throws {
        let source = try MemoryStore.inMemory()
        try await source.setRetentionDays(90)
        let item = try await source.remember(kind: .preference, key: "coffee", content: "Oat milk", now: fixedNow)
        try await source.touch(id: item.id, now: fixedNow)
        _ = try await source.rememberEntity(kind: "place", name: "Casa", detail: "Madrid", now: fixedNow)
        try await source.appendTurn(session: "s1", role: "user", text: "hola", language: "es", toolSummary: nil, now: fixedNow)
        try await source.appendTurn(session: "s1", role: "assistant", text: "¡Hola!", language: "es", toolSummary: "none", now: fixedNow + 1)
        let task = TaskRecord(title: "Sync photos", status: "pending", createdAt: fixedNow, updatedAt: fixedNow, payload: ["count": 12])
        try await source.recordTask(task)
        let routine = try await source.saveRoutine(name: "Study", phrases: ["start studying"], steps: [ToolCall(tool: .musicPlayPlaylist, arguments: ["name": "Deep Focus"])], now: fixedNow)

        let data = try await source.export(now: fixedNow)
        let decoded = try MemoryExport.decoder.decode(MemoryExport.self, from: data)
        #expect(decoded.version == MemoryExport.currentVersion)
        #expect(decoded.enabled)
        #expect(decoded.retentionDays == 90)
        #expect(decoded.items.count == 2)
        #expect(decoded.items.contains { $0.id == item.id && $0.useCount == 1 })
        #expect(decoded.conversations.map(\.text) == ["hola", "¡Hola!"])
        #expect(decoded.tasks == [task])
        #expect(decoded.routines == [routine])
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"retention_days\" : 90"))
        #expect(text.contains("Oat milk"))

        let target = try MemoryStore.inMemory()
        #expect(try await target.restore(data) == 6)
        #expect(try await target.item(id: item.id) == decoded.items.first { $0.id == item.id })
        #expect(try await target.recall(query: "cafe con leche de avena", now: fixedNow).isEmpty)
        #expect(try await target.recall(query: "oat milk", now: fixedNow).first?.id == item.id)
        #expect(try await target.entities(kind: "place").count == 1)
        #expect(try await target.recentTurns(session: "s1").map(\.text) == ["hola", "¡Hola!"])
        #expect(try await target.task(id: task.id) == task)
        #expect(try await target.routine(id: routine.id) == routine)
        #expect(try await target.findRoutine(matching: "start studying")?.id == routine.id)
        // Restoring again is idempotent.
        #expect(try await target.restore(data) == 6)
        #expect(try await target.count() == 2)
        #expect(try await target.turnCount() == 2)
        await #expect(throws: MemoryError.encoding("export")) { try await target.restore(Data("nope".utf8)) }
    }
}
