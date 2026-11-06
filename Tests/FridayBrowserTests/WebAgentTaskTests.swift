import Foundation
import Testing
import FridayCore
import FridaySidecar
@testable import FridayBrowser

/// `web.task` against the scripted sidecar: liveness when the socket drops, approvals in the user's language, repeated
/// CAPTCHA prompts, cancellation reaching the sidecar, and honest failure when the sidecar is gone.
@Suite(.serialized) struct WebAgentTaskTests {
    @Test func aTaskFinishesFromEventsAndCarriesTheLanguage() async throws {
        let sidecar = FakeSidecar()
        let interaction = RecordingInteraction()
        let integration = TestSupport.integration(sidecar, interaction: interaction)
        let call = try TestSupport.webTask(integration)
        async let outcome = integration.execute(call, context: TestSupport.context(.es))
        #expect(await sidecar.waitForSubscribers(1))
        await sidecar.emit("step.started", ["title": "Abriendo example.com…", "url": "https://example.com"])
        await sidecar.emit("assistant.message", ["text": "Hecho — **Example** está abierta.", "cards": []])
        await sidecar.setTask(["status": "done", "steps": [["id": "1"]], "current": ["url": "https://example.com"], "notices": [], "reconnects": 0])
        await sidecar.emit("task.status", ["status": "done", "error": .null])
        guard case .done(let output) = try await outcome else { Issue.record("expected done"); return }
        #expect(output.message == "Hecho — **Example** está abierta.")
        #expect(output.data?["status"]?.stringValue == "done" && output.data?["task_id"]?.stringValue == "task-1")
        let start = await sidecar.posts.first { $0.path.hasSuffix("/messages") }
        #expect(start?.body?["language"]?.stringValue == "es" && start?.body?["text"]?.stringValue == "open example.com")
        #expect(interaction.progress.contains { $0.kind == .step && $0.title == "Abriendo example.com…" })
        #expect(interaction.progress.last?.kind == .finished)
        #expect(integration.currentTaskID == nil)
    }

    @Test func aDroppedEventSocketIsResubscribedAndThePollerStillTerminates() async throws {
        let sidecar = FakeSidecar()
        let interaction = RecordingInteraction()
        let integration = TestSupport.integration(sidecar, interaction: interaction, pollInterval: .milliseconds(50))
        let call = try TestSupport.webTask(integration)
        async let outcome = integration.execute(call, context: TestSupport.context())
        #expect(await sidecar.waitForSubscribers(1))
        await sidecar.emit("step.started", ["title": "Opening example.com…"])
        await sidecar.dropSockets()          // the server closed the socket (idle timeout / restart)
        #expect(await sidecar.waitForSubscribers(2))   // the reader came back
        await sidecar.failSockets()          // and a failing socket is not fatal either
        #expect(await sidecar.waitForSubscribers(3))
        // No event ever says "done": the REST poller is the terminator.
        await sidecar.setTask(["status": "done", "steps": [], "current": ["url": "https://example.com"]])
        guard case .done(let output) = try await outcome else { Issue.record("expected done"); return }
        #expect(output.message == "Done.")
        #expect(await sidecar.polls >= 1)
        let cancels = await sidecar.posts.filter { $0.path.hasSuffix("/cancel") }
        #expect(cancels.isEmpty)
    }

    @Test func approvalsAreAskedInTheUsersLanguageAndAnsweredToTheSidecar() async throws {
        let sidecar = FakeSidecar()
        let interaction = RecordingInteraction()
        interaction.approveAnswer = true
        let integration = TestSupport.integration(sidecar, interaction: interaction)
        let call = try TestSupport.webTask(integration)
        async let outcome = integration.execute(call, context: TestSupport.context(.es))
        #expect(await sidecar.waitForSubscribers(1))
        await sidecar.emit("confirm.request", ["confirmation_id": "c1", "kind": "purchase", "question": "Jarvis is about to click \"Comprar\" on www.amazon.es, which may make a booking or purchase.",
                                               "detail": "Page: Cesta — https://www.amazon.es/cart", "label": "Comprar", "host": "www.amazon.es", "url": "https://www.amazon.es/cart", "title": "Cesta", "language": "es"])
        #expect(await sidecar.waitForPost(suffix: "/confirm"))
        let confirm = await sidecar.posts.first { $0.path.hasSuffix("/confirm") }
        #expect(confirm?.path == "api/tasks/task-1/confirm")
        #expect(confirm?.body?["confirmation_id"]?.stringValue == "c1" && confirm?.body?["approved"]?.boolValue == true)
        let approval = try #require(interaction.approvals.first)
        #expect(approval.question == "Friday va a pulsar «Comprar» en www.amazon.es, lo que puede hacer una reserva o una compra.")
        #expect(approval.detail == "Página: Cesta — https://www.amazon.es/cart")
        #expect(approval.language == .es && approval.kind == "purchase" && approval.label == "Comprar" && approval.host == "www.amazon.es")
        #expect(!approval.question.contains("Jarvis"))
        // The same confirmation seen again (poll snapshot) is not asked twice.
        await sidecar.emit("confirm.request", ["confirmation_id": "c1", "kind": "purchase", "label": "Comprar", "host": "www.amazon.es"])
        await sidecar.setTask(["status": "done", "steps": []])
        await sidecar.emit("task.status", ["status": "done"])
        _ = try await outcome
        #expect(interaction.approvals.count == 1)
    }

    @Test func repeatedChallengePromptsAreEachShownAndResumed() async throws {
        let sidecar = FakeSidecar()
        let interaction = RecordingInteraction()
        let integration = TestSupport.integration(sidecar, interaction: interaction)
        let call = try TestSupport.webTask(integration)
        async let outcome = integration.execute(call, context: TestSupport.context(.es))
        #expect(await sidecar.waitForSubscribers(1))
        let prompt: JSONValue = ["kind": "captcha", "message": "The site is running a bot check.", "url": "https://x.es/", "host": "x.es", "language": "es"]
        await sidecar.emit("needs_user", prompt.merging(["wait_id": "w1"]))
        #expect(await sidecar.waitForPost(suffix: "/resume", count: 1))
        await sidecar.emit("needs_user", prompt.merging(["wait_id": "w2"]))   // same text, still blocked: must be asked again
        #expect(await sidecar.waitForPost(suffix: "/resume", count: 2))
        #expect(interaction.waits.count == 2)
        #expect(interaction.waits.first?.message == "x.es te pide demostrar que eres humano. Resuélvelo en Chrome y luego di o pulsa Listo.")
        #expect(interaction.waits.first?.kind == "captcha")
        await sidecar.setTask(["status": "done", "steps": []])
        await sidecar.emit("task.status", ["status": "done"])
        _ = try await outcome
    }

    @Test func givingUpOnAChallengeCancelsTheTask() async throws {
        let sidecar = FakeSidecar()
        let interaction = RecordingInteraction()
        interaction.waitAnswer = false
        let integration = TestSupport.integration(sidecar, interaction: interaction)
        let call = try TestSupport.webTask(integration)
        let task = Task { try await integration.execute(call, context: TestSupport.context()) }
        #expect(await sidecar.waitForSubscribers(1))
        await sidecar.emit("needs_user", ["kind": "login", "message": "This page needs you to sign in.", "url": "https://x.test/", "host": "x.test", "wait_id": "w1"])
        #expect(await sidecar.waitForPost(suffix: "/cancel"))
        #expect(interaction.waits.first?.message == "x.test needs you to sign in. Sign in in Chrome, then say or press Done.")
        await sidecar.emit("task.status", ["status": "cancelled"])
        let result = await task.result
        #expect(throws: JarvisError.cancelled) { try result.get() }
    }

    @Test func thePollerHandlesAPromptTheSocketMissed() async throws {
        let sidecar = FakeSidecar()
        let interaction = RecordingInteraction()
        let integration = TestSupport.integration(sidecar, interaction: interaction, pollInterval: .milliseconds(50))
        await sidecar.setTask(["status": "waiting_user", "steps": [], "waiting": ["kind": "confirm", "confirm_kind": "send", "confirmation_id": "c9", "label": "Send", "host": "mail.test", "url": "https://mail.test/compose", "title": "Compose"]])
        let call = try TestSupport.webTask(integration)
        async let outcome = integration.execute(call, context: TestSupport.context())
        #expect(await sidecar.waitForPost(suffix: "/confirm"))
        #expect(interaction.approvals.first?.question == "Friday is about to click “Send” on mail.test, which may send or publish content.")
        #expect(await sidecar.waitForPolls(3))
        #expect(interaction.approvals.count == 1)   // the snapshot keeps saying waiting_user: asked once
        await sidecar.setTask(["status": "done", "steps": []])
        _ = try await outcome
    }

    @Test func cancellingFridayStillCancelsTheSidecarTask() async throws {
        let sidecar = FakeSidecar()
        let interaction = RecordingInteraction()
        interaction.neverAnswers = true
        let integration = TestSupport.integration(sidecar, interaction: interaction)
        let call = try TestSupport.webTask(integration)
        let task = Task { try await integration.execute(call, context: TestSupport.context()) }
        #expect(await sidecar.waitForSubscribers(1))
        // A prompt the user never answers must not keep the task alive once Friday is interrupted.
        await sidecar.emit("confirm.request", ["confirmation_id": "c1", "kind": "payment", "label": "Pay now", "host": "shop.test"])
        #expect(await interaction.waitForPrompts(approvals: 1))
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(await sidecar.waitForPost(suffix: "/cancel"))
        #expect(integration.currentTaskID == nil)
    }

    @Test func aPromptNobodyAnswersEndsWithTheTask() async throws {
        let sidecar = FakeSidecar()
        let interaction = RecordingInteraction()
        interaction.neverAnswers = true
        let integration = TestSupport.integration(sidecar, interaction: interaction, pollInterval: .milliseconds(50))
        let call = try TestSupport.webTask(integration)
        let task = Task { try await integration.execute(call, context: TestSupport.context()) }
        #expect(await sidecar.waitForSubscribers(1))
        await sidecar.emit("needs_user", ["kind": "captcha", "message": "x", "wait_id": "w1", "host": "x.test"])
        #expect(await interaction.waitForPrompts(waits: 1))
        await sidecar.setTask(["status": "cancelled", "steps": []])   // cancelled elsewhere (web.cancel, the sidecar's own timeout)
        let result = await task.result   // does not hang on the unanswered prompt
        #expect(throws: JarvisError.cancelled) { try result.get() }
    }

    @Test func aDeadSidecarFailsHonestlyInTheUsersLanguage() async throws {
        let sidecar = FakeSidecar()
        let interaction = RecordingInteraction()
        let integration = TestSupport.integration(sidecar, interaction: interaction, pollInterval: .milliseconds(30), maxPollFailures: 3)
        await sidecar.setPollAlwaysFails(true)
        let call = try TestSupport.webTask(integration)
        do {
            _ = try await integration.execute(call, context: TestSupport.context(.es))
            Issue.record("expected a failure")
        } catch let error as JarvisError {
            guard case .setupRequired(_, let text) = error else { Issue.record("unexpected \(error)"); return }
            #expect(text.es == "La tarea del navegador falló: El proceso del navegador dejó de responder.")
            #expect(text.en.hasPrefix("The browser task failed:"))
        }
        #expect(interaction.progress.last?.kind == .finished)
        #expect(interaction.progress.last?.detail == "El proceso del navegador dejó de responder.")
    }

    @Test func aLostTaskAndChromeErrorsAreReportedWithStableCodes() async throws {
        let sidecar = FakeSidecar()
        let interaction = RecordingInteraction()
        let integration = TestSupport.integration(sidecar, interaction: interaction, pollInterval: .milliseconds(30))
        let call = try TestSupport.webTask(integration)
        async let outcome = integration.execute(call, context: TestSupport.context())
        #expect(await sidecar.waitForSubscribers(1))
        await sidecar.emit("task.status", ["status": "failed", "error": "Chrome exited immediately (code 1).", "error_code": "chrome_exited"])
        do {
            _ = try await outcome
            Issue.record("expected a failure")
        } catch let error as JarvisError {
            guard case .setupRequired(let instructions, let text) = error else { Issue.record("unexpected \(error)"); return }
            #expect(text.en == "The browser task failed: Chrome quit right after starting.")
            #expect(instructions.steps == ["Chrome quit right after starting."])
        }
        // A task the sidecar no longer knows (it restarted) ends as failed instead of polling forever.
        let second = FakeSidecar()
        await second.setPollNotFound(true)
        let integration2 = TestSupport.integration(second, interaction: interaction, pollInterval: .milliseconds(30))
        do {
            _ = try await integration2.execute(try TestSupport.webTask(integration2), context: TestSupport.context())
            Issue.record("expected a failure")
        } catch let error as JarvisError {
            guard case .setupRequired(_, let text) = error else { Issue.record("unexpected \(error)"); return }
            #expect(text.en == "The browser task failed: The browser sidecar lost the task.")
        }
    }

    @Test func reconnectNoticesReachTheUserAndTheResult() async throws {
        let sidecar = FakeSidecar()
        let interaction = RecordingInteraction()
        let integration = TestSupport.integration(sidecar, interaction: interaction)
        let call = try TestSupport.webTask(integration)
        async let outcome = integration.execute(call, context: TestSupport.context())
        #expect(await sidecar.waitForSubscribers(1))
        await sidecar.emit("task.status", ["status": "running", "notice": "Resumed after Chrome reconnected.", "reconnects": 1, "current": ["title": "Opening example.com…", "url": "https://example.com"]])
        await sidecar.setTask(["status": "done", "steps": [], "notices": ["Resumed after Chrome reconnected."], "reconnects": 1])
        await sidecar.emit("task.status", ["status": "done"])
        guard case .done(let output) = try await outcome else { Issue.record("expected done"); return }
        #expect(output.warnings == ["Resumed after Chrome reconnected."])
        #expect(output.data?["reconnects"]?.intValue == 1)
        #expect(interaction.progress.contains { $0.kind == .status && $0.title == "Resumed after Chrome reconnected." })
    }

    @Test func connectReportsChromeProblemsInTheUsersLanguage() async throws {
        let sidecar = FakeSidecar()
        let integration = TestSupport.integration(sidecar, interaction: RecordingInteraction())
        let output = try await integration.connect(mode: "managed", language: .es)
        #expect(output.message.hasPrefix("Chrome no está conectado:"))   // the fake answers {"ok": true}: no state
        let described = WebAgentIntegration.describe(
            ["status": "waiting_user", "steps": [], "waiting": ["kind": "captcha", "message": "This page shows a CAPTCHA.", "host": "x.es"]], language: .es)
        #expect(described.contains("Esperando: x.es te pide demostrar que eres humano."))
        let confirming = WebAgentIntegration.describe(
            ["status": "waiting_user", "steps": [], "waiting": ["kind": "confirm", "confirm_kind": "upload", "name": "cv.pdf", "host": "jobs.test"]], language: .en)
        #expect(confirming.contains("Waiting: Friday is about to upload “cv.pdf” to jobs.test."))
    }
}

private extension JSONValue {
    func merging(_ other: JSONValue) -> JSONValue {
        guard case .object(var object) = self, case .object(let extra) = other else { return self }
        for (key, value) in extra { object[key] = value }
        return .object(object)
    }
}
