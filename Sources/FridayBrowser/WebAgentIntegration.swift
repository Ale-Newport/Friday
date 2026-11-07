import Foundation
import FridayCore
import FridaySidecar
import os

// MARK: - Browser automation through the sidecar (the Chrome agent)
//
// `web.task` hands a natural-language browsing goal to the sidecar, which plans typed steps with the text model,
// drives Chrome over the DevTools Protocol with Laya choosing among observed elements, and returns a grounded
// answer with cards (links, tables, files, sources). Friday streams its progress to the UI, forwards its
// confirmation requests (purchases, sends, deletions, downloads, uploads…) to the user in the user's language, and
// reports CAPTCHA/login pauses honestly.
//
// Liveness: the WebSocket is only a fast path. The REST poller is the sole terminator of a task, the event reader
// resubscribes when the socket drops, and every control POST (confirm, resume, cancel) is sent from a detached task
// so it still reaches the sidecar when Friday's own task has already been cancelled ("stop", tool timeout).

/// What the browser integration needs from the sidecar: REST calls and the event stream. `SidecarClient` is the real
/// one; tests drive the integration with a scripted transport and no network.
public protocol SidecarTransport: Sendable {
    func get(_ path: String, timeout: TimeInterval) async throws -> JSONValue
    func post(_ path: String, _ body: JSONValue?, timeout: TimeInterval) async throws -> JSONValue
    func put(_ path: String, _ body: JSONValue, timeout: TimeInterval) async throws -> JSONValue
    func events() -> AsyncThrowingStream<JSONValue, any Error>
}

extension SidecarClient: SidecarTransport {}

public struct BrowserApproval: Sendable, Hashable {
    public var taskID: String
    public var confirmationID: String
    /// payment | purchase | destructive | account | send | download | upload | sensitive
    public var kind: String
    /// Already phrased in the user's language (Friday builds it from the sidecar's structured facts).
    public var question: String
    public var detail: String?
    public var language: Language
    public var label: String?
    public var host: String?
    public var fileName: String?

    public init(taskID: String, confirmationID: String, kind: String, question: String, detail: String? = nil, language: Language = .en,
                label: String? = nil, host: String? = nil, fileName: String? = nil) {
        self.taskID = taskID
        self.confirmationID = confirmationID
        self.kind = kind
        self.question = question
        self.detail = detail
        self.language = language
        self.label = label
        self.host = host
        self.fileName = fileName
    }
}

public struct BrowserProgress: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case step, status, pageChanged, waitingForUser, answerDelta, finished }
    public var kind: Kind
    public var taskID: String
    public var title: String
    public var detail: String?
    public var url: String?
}

/// How the browser integration talks to the person: approvals (must answer) and progress (fire and forget).
public protocol BrowserInteractionHandling: Sendable {
    func approve(_ approval: BrowserApproval) async -> Bool
    func progress(_ progress: BrowserProgress)
    /// The user must act in the browser (CAPTCHA, sign-in). `message` is already in the user's language and says how
    /// to continue. Returns when they say they are done, or false to give up.
    func waitForUser(taskID: String, kind: String, message: String, url: String?) async -> Bool
}

public struct DenyingInteractionHandler: BrowserInteractionHandling {
    public init() {}
    public func approve(_ approval: BrowserApproval) async -> Bool { false }
    public func progress(_ progress: BrowserProgress) {}
    public func waitForUser(taskID: String, kind: String, message: String, url: String?) async -> Bool { false }
}

/// Live state shared with the UI.
public struct WebAgentStatus: Sendable, Hashable, Codable {
    public var sidecarRunning: Bool
    public var chromeState: String
    public var chromeMode: String
    public var chromeInstalled: Bool
    public var layaState: String
    public var llmModel: String
    public var llmReachable: Bool
    public var busyTaskID: String?
    public var error: String?
    /// The sidecar's stable reason for a Chrome problem (`chrome.ERROR_CODES`), when there is one.
    public var chromeErrorCode: String?
    /// The Chrome problem phrased for the user (English text; the UI localises through `WebAgentTexts.chromeError`).
    public var chromeError: String?
}

public final class WebAgentIntegration: AppIntegration, @unchecked Sendable {
    public let id: IntegrationID = "web"
    public let displayName = LocalizedText(en: "Web browsing (Chrome)", es: "Navegación web (Chrome)")
    public let summary = LocalizedText(en: "Searches, reads and operates websites in Google Chrome for you.", es: "Busca, lee y maneja sitios web en Google Chrome por ti.")
    public let symbolName = "globe"
    public let permissionRequirements: [PermissionRequirement] = []
    static let logger = Logger(subsystem: "com.alejandro.friday", category: "web")

    private let lock = NSLock()
    private var transport: (any SidecarTransport)?
    private var interaction: any BrowserInteractionHandling = DenyingInteractionHandler()
    private var conversationID: String?
    private var runningTaskID: String?
    /// How often the task is polled over REST (the safety net that also terminates the task). Tests shorten it.
    var pollInterval: Duration = .seconds(5)
    /// Consecutive failed polls before the task is declared lost (the sidecar died or restarted).
    var maxPollFailures = 6

    public init() {}

    public func setClient(_ client: SidecarClient?) { setTransport(client) }
    /// Injects any transport (tests use a scripted one). `nil` forgets the conversation as well.
    public func setTransport(_ transport: (any SidecarTransport)?) {
        lock.withLock { self.transport = transport; if transport == nil { conversationID = nil } }
    }
    public func setInteractionHandler(_ handler: any BrowserInteractionHandling) { lock.withLock { interaction = handler } }
    /// Start a fresh browsing conversation (follow-ups stop reusing earlier tabs and data).
    public func resetConversation() { lock.withLock { conversationID = nil } }
    public var currentTaskID: String? { lock.withLock { runningTaskID } }

    public var tools: [ToolDescriptor] {
        [
            ToolDescriptor(
                name: "web.task", integration: id, title: "Browse the web",
                summary: "Perform a browsing task in Google Chrome with the autonomous browser agent: search the web, open sites, compare results, extract data (prices, flights, tables), fill harmless forms, download files, upload a file from the user's approved folders (Downloads/Friday) to a form, drag items in sortable lists, watch for a page. Give the complete goal in one sentence, including constraints (dates, 'direct flights', 'cheapest', 'top 3'). Returns the agent's grounded answer with links/tables. Purchases, payments, sends, deletions, downloads and uploads pause for the user's approval; CAPTCHAs and logins pause for the user.",
                parameters: [
                    .string("goal", "What to achieve, in the user's words plus resolved details (e.g. absolute dates)", required: true, maxLength: 2000),
                    .boolean("new_conversation", "Start from a clean slate instead of continuing the previous browsing context", default: false),
                ],
                safety: .modifying, timeout: 900, deduplicate: false,
                examples: [
                    ToolExample("find the cheapest direct flight from London to Barcelona on 2026-11-13", arguments: ["goal": "Find the cheapest direct flight from London to Barcelona on 2026-11-13 and list the top 3 options with prices and links"]),
                    ToolExample("busca en Google machine learning", language: .es, arguments: ["goal": "Buscar en Google 'machine learning' y resumir los tres primeros resultados"]),
                    ToolExample("upload cv.pdf from my Friday downloads to the application form", arguments: ["goal": "Upload the file cv.pdf (in Downloads/Friday) to the application form on the current page"]),
                ]),
            ToolDescriptor(
                name: "web.status", integration: id, title: "Browser agent status",
                summary: "Whether the browser agent is ready: sidecar, Chrome connection, Laya model, text model.",
                safety: .readOnly, timeout: 10),
            ToolDescriptor(
                name: "web.connect", integration: id, title: "Connect Chrome",
                summary: "Launch or attach to Google Chrome for the browser agent. 'managed' starts Chrome with Friday's own automation profile; 'existing' attaches to your running Chrome (you must allow remote debugging in Chrome).",
                parameters: [.choice("mode", ["managed", "existing"], "How to connect", default: "managed")],
                safety: .modifying, timeout: 90),
            ToolDescriptor(
                name: "web.cancel", integration: id, title: "Cancel the browser task",
                summary: "Stops the browser task that is currently running.",
                safety: .modifying, timeout: 15,
                examples: [ToolExample("cancel the browser task", arguments: [:]), ToolExample("cancela la tarea del navegador", language: .es, arguments: [:])]),
            ToolDescriptor(
                name: "web.focus", integration: id, title: "Show the agent's browser tab",
                summary: "Brings the browser agent's current Chrome tab to the front.",
                safety: .readOnly, timeout: 10),
            ToolDescriptor(
                name: "web.current_task", integration: id, title: "Current browser task",
                summary: "What the browser agent is doing right now (steps so far, page, waiting state).",
                safety: .readOnly, timeout: 10),
        ]
    }

    public func status() async -> IntegrationStatus {
        guard let transport = lock.withLock({ transport }) else {
            return IntegrationStatus(state: .needsSetup, detail: LocalizedText(en: "The browser sidecar is not running.", es: "El proceso del navegador no está en marcha."))
        }
        guard (try? await transport.get("health", timeout: 5))?["status"]?.stringValue == "ready" else {
            return IntegrationStatus(state: .unavailable, detail: LocalizedText(en: "The browser sidecar is not responding.", es: "El proceso del navegador no responde."))
        }
        return IntegrationStatus(state: .ready)
    }

    public func authorization(for tool: ToolDescriptor) async -> AuthorizationState {
        // The sidecar starts with the app and takes a few seconds: the first browser command after launch waits for
        // it briefly instead of failing.
        for _ in 0..<40 where lock.withLock({ transport }) == nil {
            try? await Task.sleep(for: .milliseconds(250))
        }
        return lock.withLock { transport } == nil
            ? .unavailable(LocalizedText(en: "The browser agent is not available (sidecar not running).", es: "El agente de navegación no está disponible (proceso no iniciado)."))
            : .authorized
    }

    public func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState { await authorization(for: tool) }

    public func agentStatus() async -> WebAgentStatus {
        guard let transport = lock.withLock({ transport }) else {
            return WebAgentStatus(sidecarRunning: false, chromeState: "disconnected", chromeMode: "managed", chromeInstalled: false, layaState: "missing", llmModel: "", llmReachable: false, busyTaskID: nil, error: "sidecar not running")
        }
        do {
            let status = try await transport.get("api/status", timeout: 30)
            let chrome = status["chrome"] ?? .null
            let code = chrome["error_code"]?.stringValue
            let chromeError = chrome["error"]?.stringValue
            return WebAgentStatus(
                sidecarRunning: true, chromeState: chrome["state"]?.stringValue ?? "?", chromeMode: chrome["mode"]?.stringValue ?? "?",
                chromeInstalled: chrome["installed"]?.boolValue ?? false, layaState: status["laya"]?["state"]?.stringValue ?? "?",
                llmModel: status["llm"]?["model"]?.stringValue ?? "", llmReachable: status["llm"]?["reachable"]?.boolValue ?? false,
                busyTaskID: status["busy_task_id"]?.stringValue, error: nil,
                chromeErrorCode: code, chromeError: chromeError.map { WebAgentTexts.chromeError(code: code, fallback: $0, language: .en) })
        } catch {
            return WebAgentStatus(sidecarRunning: true, chromeState: "?", chromeMode: "?", chromeInstalled: false, layaState: "?", llmModel: "", llmReachable: false, busyTaskID: nil, error: error.localizedDescription)
        }
    }

    /// Launches or attaches to Chrome (Settings ▸ Browser ▸ Connect uses this directly; `web.connect` wraps it).
    public func connect(mode: String, language: Language) async throws -> ToolOutput {
        guard let transport = lock.withLock({ transport }) else { throw Self.sidecarNotRunning(language) }
        let result = try await transport.post("api/chrome/connect", ["mode": .string(mode)], timeout: 90)
        let state = result["state"]?.stringValue ?? "?"
        let ok = state == "connected"
        let message: String
        if ok {
            message = language.pick("Chrome is connected (\(mode)).", "Chrome está conectado (\(mode)).")
        } else if state == "awaiting_permission" {
            message = language.pick("Chrome is asking you to allow remote debugging. Click Allow in Chrome.", "Chrome te pide permitir la depuración remota. Pulsa Permitir en Chrome.")
        } else {
            let reason = WebAgentTexts.chromeError(code: result["error_code"]?.stringValue, fallback: result["error"]?.stringValue ?? state, language: language)
            message = language.pick("Chrome is not connected: \(reason)", "Chrome no está conectado: \(reason)")
        }
        return ToolOutput(message: message, data: result, verification: ok ? .verified("chrome status reports connected") : .unverified(state))
    }

    public func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
        guard let transport = lock.withLock({ transport }) else { throw Self.sidecarNotRunning(context.language) }
        switch call.descriptor.name.rawValue {
        case "web.status":
            let status = await agentStatus()
            var text = context.t(
                "Chrome: \(status.chromeState) (\(status.chromeMode)), Laya: \(status.layaState), model: \(status.llmModel.isEmpty ? "none" : status.llmModel) (\(status.llmReachable ? "reachable" : "unreachable")).",
                "Chrome: \(status.chromeState) (\(status.chromeMode)), Laya: \(status.layaState), modelo: \(status.llmModel.isEmpty ? "ninguno" : status.llmModel) (\(status.llmReachable ? "accesible" : "inaccesible")).")
            if let chromeError = status.chromeError, status.chromeState != "connected" {
                text += " " + WebAgentTexts.chromeError(code: status.chromeErrorCode, fallback: chromeError, language: context.language)
            }
            return .done(ToolOutput(message: text, data: try JSONValue.encoding(status), verification: .notApplicable))
        case "web.connect":
            return .done(try await connect(mode: call.string("mode") ?? "managed", language: context.language))
        case "web.focus":
            let result = try await transport.post("api/chrome/focus", nil, timeout: 10)
            return .done(ToolOutput(message: context.t("Brought the browser tab to the front.", "He traído la pestaña del navegador al frente."), data: result, verification: .notApplicable))
        case "web.cancel":
            guard let taskID = lock.withLock({ runningTaskID }) else {
                return .done(ToolOutput(message: context.t("No browser task is running.", "No hay ninguna tarea del navegador en marcha."), verification: .notApplicable))
            }
            let result = try await transport.post("api/tasks/\(taskID)/cancel", nil, timeout: 15)
            return .done(ToolOutput(message: context.t("Cancelled the browser task.", "He cancelado la tarea del navegador."), data: result, verification: .verified("task status \(result["status"]?.stringValue ?? "?")")))
        case "web.current_task":
            guard let taskID = lock.withLock({ runningTaskID }) else {
                return .done(ToolOutput(message: context.t("The browser agent is idle.", "El agente de navegación está inactivo."), verification: .notApplicable))
            }
            let task = try await transport.get("api/tasks/\(taskID)", timeout: 30)
            return .done(ToolOutput(message: Self.describe(task, language: context.language), data: task, verification: .notApplicable))
        case "web.task":
            return try await runTask(goal: call.string("goal") ?? "", newConversation: call.bool("new_conversation") ?? false, transport: transport, context: context)
        default:
            throw JarvisError.validation([ValidationIssue(.unknownTool, "Unknown tool \(call.descriptor.name)")])
        }
    }

    static func sidecarNotRunning(_ language: Language) -> JarvisError {
        .setupRequired(
            SetupInstructions(title: language.pick("Browser agent not running", "Agente de navegación no iniciado"), steps: [language.pick("Open Friday ▸ Settings ▸ Browser and start the sidecar.", "Abre Friday ▸ Ajustes ▸ Navegador e inicia el proceso.")]),
            LocalizedText(en: "The browser sidecar is not running.", es: "El proceso del navegador no está en marcha."))
    }

    // MARK: Running a task with live events

    private func runTask(goal: String, newConversation: Bool, transport: any SidecarTransport, context: ExecutionContext) async throws -> ToolOutcome {
        let interaction = lock.withLock { self.interaction }
        let language = context.language
        if lock.withLock({ runningTaskID }) != nil {
            throw JarvisError.setupRequired(
                SetupInstructions(title: context.t("Browser busy", "Navegador ocupado"), steps: [context.t("Wait for the current browser task or cancel it.", "Espera a que termine la tarea actual del navegador o cancélala.")]),
                LocalizedText(en: "A browser task is already running.", es: "Ya hay una tarea del navegador en marcha."))
        }
        // One conversation per Friday session so follow-ups keep tabs and extracted data.
        var conversationID = lock.withLock { newConversation ? nil : self.conversationID }
        if conversationID == nil {
            let conversation = try await transport.post("api/conversations", ["title": .string(String(goal.prefix(56)))], timeout: 15)
            guard let id = conversation["id"]?.stringValue else { throw SidecarError.invalidResponse("no conversation id") }
            conversationID = id
            lock.withLock { self.conversationID = id }
        }
        // Subscribe to events before starting, so nothing is missed.
        let events = transport.events()
        let started = try await transport.post("api/conversations/\(conversationID!)/messages", ["text": .string(goal), "language": .string(language.rawValue)], timeout: 30)
        guard let taskID = started["task"]?["id"]?.stringValue else { throw SidecarError.invalidResponse("no task id") }
        lock.withLock { runningTaskID = taskID }
        defer { lock.withLock { if runningTaskID == taskID { runningTaskID = nil } } }
        Self.logger.info("web task started \(taskID, privacy: .public)")

        let run = RunState()
        let session = TaskSession(transport: transport, taskID: taskID, run: run, interaction: interaction, language: language)
        let pollInterval = self.pollInterval
        let maxPollFailures = self.maxPollFailures

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await session.readEvents(initial: events) }
            group.addTask { await session.poll(every: pollInterval, maxFailures: maxPollFailures) }
            // The poller is the sole terminator; a reader that ends early (socket dropped) never ends the task.
            while run.snapshot().finalStatus == nil, await group.next() != nil {}
            group.cancelAll()
        }
        if Task.isCancelled {
            // "stop", interrupt or the tool timeout: tell the sidecar from a task that cannot be cancelled with us.
            _ = await TaskSession.postDetached(transport, "api/tasks/\(taskID)/cancel", nil, timeout: 10)
            throw CancellationError()
        }

        // Final snapshot (answer, cards, steps) is authoritative when the sidecar is still there.
        let task = (try? await transport.get("api/tasks/\(taskID)", timeout: 30)) ?? .null
        var (answer, cards, finalStatus, errorText, errorCode) = run.snapshot()
        let status = finalStatus ?? task["status"]?.stringValue ?? "failed"
        if answer.isEmpty, let conversationID {
            let detail = try? await transport.get("api/conversations/\(conversationID)", timeout: 30)
            if let messages = detail?["messages"]?.arrayValue, let last = messages.last(where: { $0["role"]?.stringValue == "assistant" && $0["task_id"]?.stringValue == taskID }) {
                answer = last["text"]?.stringValue ?? ""
                cards = last["cards"] ?? cards
            }
        }
        let code = errorCode ?? task["error_code"]?.stringValue
        let localizedError = errorText.map { WebAgentTexts.chromeError(code: code, fallback: $0, language: language) }
        interaction.progress(BrowserProgress(kind: .finished, taskID: taskID, title: status, detail: localizedError, url: task["current"]?["url"]?.stringValue))
        let steps = task["steps"]?.arrayValue ?? []
        let notices = task["notices"]?.arrayValue?.compactMap(\.stringValue) ?? run.notices()
        let data: JSONValue = [
            "task_id": .string(taskID), "status": .string(status), "answer": .string(answer), "cards": cards,
            "steps": .int(steps.count), "final_url": task["current"]?["url"].map { $0 } ?? .null, "error": localizedError.map(JSONValue.string) ?? .null,
            "error_code": code.map(JSONValue.string) ?? .null, "timings": task["timings"] ?? .null,
            "reconnects": task["reconnects"] ?? .int(0), "notices": .array(notices.map(JSONValue.string)),
        ]
        switch status {
        case "done":
            return .done(ToolOutput(message: answer.isEmpty ? language.pick("Done.", "Hecho.") : answer, data: data,
                                    verification: .verified("browser agent reported done after \(steps.count) steps"), warnings: notices))
        case "partial":
            let reason = localizedError.map { ": \($0)" } ?? "."
            return .done(ToolOutput(message: (answer.isEmpty ? "" : answer + "\n") + language.pick("The browser task finished partially\(reason)", "La tarea del navegador terminó parcialmente\(reason)"), data: data, verification: .unverified("partial: \(errorText ?? "declined or incomplete")"), warnings: [localizedError ?? "partial"] + notices))
        case "cancelled":
            throw JarvisError.cancelled
        default:
            let reason = localizedError ?? status
            throw JarvisError.setupRequired(
                SetupInstructions(title: language.pick("Browser task failed", "La tarea del navegador falló"), steps: [reason]),
                LocalizedText(en: "The browser task failed: \(reason)", es: "La tarea del navegador falló: \(reason)"))
        }
    }

    static func describe(_ task: JSONValue, language: Language) -> String {
        let status = task["status"]?.stringValue ?? "?"
        let current = task["current"]?["title"]?.stringValue
        let steps = task["steps"]?.arrayValue?.count ?? 0
        var text = language.pick("Browser task: \(status), \(steps) steps so far.", "Tarea del navegador: \(status), \(steps) pasos hasta ahora.")
        if let current { text += " " + language.pick("Now: \(current).", "Ahora: \(current).") }
        if let waiting = task["waiting"], let kind = waiting["kind"]?.stringValue {
            let message = kind == "confirm"
                ? WebAgentTexts.approvalQuestion(kind: waiting["confirm_kind"]?.stringValue ?? "sensitive", data: waiting, language: language)
                : WebAgentTexts.manualMessage(kind: kind, message: waiting["message"]?.stringValue ?? "", host: waiting["host"]?.stringValue, language: language)
            text += " " + language.pick("Waiting: \(message)", "Esperando: \(message)")
        }
        return text
    }
}

// MARK: - One running task: event reader, poller and user prompts

/// The per-task plumbing shared by the event reader and the REST poller. Both may see the same prompt (a confirmation
/// or a CAPTCHA pause): `RunState.markHandled` makes sure it is shown once.
struct TaskSession: Sendable {
    let transport: any SidecarTransport
    let taskID: String
    let run: RunState
    let interaction: any BrowserInteractionHandling
    let language: Language

    /// Reads the sidecar's event stream and resubscribes whenever it ends or fails, until the task is finished.
    func readEvents(initial: AsyncThrowingStream<JSONValue, any Error>) async {
        var stream = initial
        var resubscriptions = 0
        while run.snapshot().finalStatus == nil, !Task.isCancelled {
            do {
                for try await event in stream {
                    guard event["task_id"]?.stringValue == taskID else { continue }
                    await handle(event: event)
                    if run.snapshot().finalStatus != nil { return }
                }
            } catch {
                WebAgentIntegration.logger.warning("event stream for \(taskID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
            guard run.snapshot().finalStatus == nil, !Task.isCancelled else { return }
            resubscriptions += 1
            WebAgentIntegration.logger.info("event stream ended; resubscribing (\(resubscriptions, privacy: .public))")
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            stream = transport.events()
        }
    }

    /// Polls the task over REST: the safety net for a dropped socket and the sole terminator of the task.
    func poll(every interval: Duration, maxFailures: Int) async {
        var failures = 0
        while !Task.isCancelled, run.snapshot().finalStatus == nil {
            try? await Task.sleep(for: interval)
            if Task.isCancelled || run.snapshot().finalStatus != nil { return }
            do {
                let task = try await transport.get("api/tasks/\(taskID)", timeout: 15)
                failures = 0
                let status = task["status"]?.stringValue ?? ""
                if let current = task["current"]?["title"]?.stringValue, status == "running" {
                    interaction.progress(BrowserProgress(kind: .status, taskID: taskID, title: current, detail: status, url: task["current"]?["url"]?.stringValue))
                }
                if RunState.isFinished(status) {
                    run.finish(status: status, error: task["error"]?.stringValue, errorCode: task["error_code"]?.stringValue)
                    return
                }
                if status == "waiting_user", let waiting = task["waiting"], let kind = waiting["kind"]?.stringValue {
                    // The socket may have missed the prompt: handle it from the snapshot (deduplicated with the reader).
                    if kind == "confirm" {
                        await handleConfirmation(waiting, kind: waiting["confirm_kind"]?.stringValue ?? "sensitive")
                    } else {
                        let key = waiting["wait_id"]?.stringValue.map { "needs:" + $0 } ?? "needs:poll:\(kind):\(waiting["message"]?.stringValue ?? "")"
                        await handleNeedsUser(waiting, dedupeKey: key)
                    }
                }
            } catch let error as SidecarError {
                if case .http(let status, _, _) = error, status == 404 {
                    run.finish(status: "failed", error: language.pick("The browser sidecar lost the task.", "El proceso del navegador perdió la tarea."), errorCode: "task_lost")
                    return
                }
                failures += 1
            } catch {
                failures += 1
            }
            if failures >= maxFailures {
                WebAgentIntegration.logger.error("task \(taskID, privacy: .public): \(failures, privacy: .public) consecutive poll failures; giving up")
                run.finish(status: "failed", error: language.pick("The browser sidecar stopped responding.", "El proceso del navegador dejó de responder."), errorCode: "sidecar_unreachable")
                return
            }
        }
    }

    func handle(event: JSONValue) async {
        let type = event["type"]?.stringValue ?? ""
        let data = event["data"] ?? .null
        switch type {
        case "step.started":
            interaction.progress(BrowserProgress(kind: .step, taskID: taskID, title: data["title"]?.stringValue ?? "", detail: data["detail"]?.stringValue, url: data["url"]?.stringValue))
        case "page.updated":
            interaction.progress(BrowserProgress(kind: .pageChanged, taskID: taskID, title: data["title"]?.stringValue ?? "", detail: nil, url: data["url"]?.stringValue))
        case "assistant.delta":
            interaction.progress(BrowserProgress(kind: .answerDelta, taskID: taskID, title: data["text"]?.stringValue ?? "", detail: nil, url: nil))
        case "assistant.message":
            run.setAnswer(data["text"]?.stringValue, cards: data["cards"])
        case "confirm.request":
            await handleConfirmation(data, kind: data["kind"]?.stringValue ?? "sensitive")
        case "needs_user":
            // Keyed on the prompt's own id (the CAPTCHA loop asks again with the same text), never on its content.
            let key = data["wait_id"]?.stringValue.map { "needs:" + $0 } ?? "needs:seq:\(event["seq"]?.intValue ?? -1)"
            await handleNeedsUser(data, dedupeKey: key)
        case "task.status":
            let status = data["status"]?.stringValue ?? ""
            if let notice = data["notice"]?.stringValue, !notice.isEmpty {
                run.addNotice(notice)
                interaction.progress(BrowserProgress(kind: .status, taskID: taskID, title: notice, detail: status, url: data["current"]?["url"]?.stringValue))
            } else if let current = data["current"]?["title"]?.stringValue {
                interaction.progress(BrowserProgress(kind: .status, taskID: taskID, title: current, detail: status, url: data["current"]?["url"]?.stringValue))
            }
            if RunState.isFinished(status) {
                run.finish(status: status, error: data["error"]?.stringValue, errorCode: data["error_code"]?.stringValue)
            }
        default: break
        }
    }

    /// A consequential action (purchase, send, deletion, download, upload…) waits for the user's yes or no.
    func handleConfirmation(_ data: JSONValue, kind: String) async {
        guard let confirmationID = data["confirmation_id"]?.stringValue, run.markHandled("confirm:" + confirmationID) else { return }
        let question = WebAgentTexts.approvalQuestion(kind: kind, data: data, language: language)
        let approval = BrowserApproval(
            taskID: taskID, confirmationID: confirmationID, kind: kind, question: question,
            detail: WebAgentTexts.approvalDetail(kind: kind, data: data, language: language), language: language,
            label: data["label"]?.stringValue, host: data["host"]?.stringValue, fileName: data["name"]?.stringValue)
        interaction.progress(BrowserProgress(kind: .waitingForUser, taskID: taskID, title: approval.question, detail: approval.detail, url: data["url"]?.stringValue))
        // The prompt is abandoned (not answered) when the task ends or Friday is cancelled meanwhile.
        let interaction = self.interaction
        guard let approved = await raceWithFinish({ await interaction.approve(approval) }) else { return }
        _ = await Self.postDetached(transport, "api/tasks/\(taskID)/confirm", ["confirmation_id": .string(confirmationID), "approved": .bool(approved)], timeout: 15)
    }

    /// A CAPTCHA, sign-in wall or other manual step: the user acts in Chrome and says Done (resume) or gives up (cancel).
    func handleNeedsUser(_ data: JSONValue, dedupeKey: String?) async {
        if let dedupeKey, !run.markHandled(dedupeKey) { return }
        let kind = data["kind"]?.stringValue ?? "manual"
        let message = WebAgentTexts.manualMessage(kind: kind, message: data["message"]?.stringValue ?? "", host: data["host"]?.stringValue, language: language)
        let url = data["url"]?.stringValue
        interaction.progress(BrowserProgress(kind: .waitingForUser, taskID: taskID, title: message, detail: kind, url: url))
        let interaction = self.interaction
        let taskID = self.taskID
        guard let resume = await raceWithFinish({ await interaction.waitForUser(taskID: taskID, kind: kind, message: message, url: url) }) else { return }
        _ = await Self.postDetached(transport, resume ? "api/tasks/\(taskID)/resume" : "api/tasks/\(taskID)/cancel", nil, timeout: 15)
    }

    /// Waits for the user's answer, but gives up (returns nil) as soon as the task finishes or this task is cancelled, so
    /// a prompt nobody answers can never keep the browser task alive. The prompt itself keeps running detached; a late
    /// answer is posted anyway and ignored by the sidecar (the confirmation is no longer pending).
    func raceWithFinish(_ ask: @escaping @Sendable () async -> Bool) async -> Bool? {
        let resumer = OnceResumer()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
                resumer.arm(continuation)
                let asker = Task.detached {
                    let answer = await ask()
                    resumer.resume(answer)
                }
                // When the task ends first (cancelled, timed out, failed), the question is withdrawn: the handler's
                // cancellation path clears the prompt the user would otherwise still see.
                run.whenFinished { resumer.resume(nil); asker.cancel() }
            }
        } onCancel: {
            resumer.resume(nil)
        }
    }

    /// A POST that still goes out when the calling task has been cancelled (URLSession aborts requests from a cancelled
    /// task before sending them); the result of a detached task's `value` is not affected by the parent's cancellation.
    static func postDetached(_ transport: any SidecarTransport, _ path: String, _ body: JSONValue?, timeout: TimeInterval) async -> JSONValue? {
        await Task.detached { try? await transport.post(path, body, timeout: timeout) }.value
    }
}

/// Resumes a continuation exactly once, whichever of several racers gets there first.
final class OnceResumer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool?, Never>?
    private var pending: Bool??

    func arm(_ continuation: CheckedContinuation<Bool?, Never>) {
        let early: Bool?? = lock.withLock {
            if let pending { return pending }
            self.continuation = continuation
            return nil
        }
        if let early { continuation.resume(returning: early) }
    }

    func resume(_ value: Bool?) {
        let target: CheckedContinuation<Bool?, Never>? = lock.withLock {
            guard pending == nil else { return nil }
            pending = .some(value)
            defer { continuation = nil }
            return continuation
        }
        target?.resume(returning: value)
    }
}

/// Mutable state shared between the event reader and the poller of one browser task.
final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var answer = ""
    private var cards: JSONValue = .array([])
    private var finalStatus: String?
    private var errorText: String?
    private var errorCode: String?
    private var handled: Set<String> = []
    private var noticeList: [String] = []
    private var finishHandlers: [@Sendable () -> Void] = []

    static func isFinished(_ status: String) -> Bool { ["done", "partial", "failed", "cancelled"].contains(status) }

    func setAnswer(_ text: String?, cards: JSONValue?) {
        lock.withLock {
            if let text { answer = text }
            if let cards { self.cards = cards }
        }
    }
    func markHandled(_ key: String) -> Bool { lock.withLock { handled.insert(key).inserted } }
    func addNotice(_ notice: String) { lock.withLock { if !noticeList.contains(notice) { noticeList.append(notice) } } }
    func notices() -> [String] { lock.withLock { noticeList } }
    func finish(status: String, error: String?, errorCode: String? = nil) {
        let handlers: [@Sendable () -> Void] = lock.withLock {
            if finalStatus == nil { finalStatus = status }
            if errorText == nil { errorText = error }
            if self.errorCode == nil { self.errorCode = errorCode }
            defer { finishHandlers = [] }
            return finishHandlers
        }
        for handler in handlers { handler() }
    }
    /// Runs `handler` once the task has a final status (immediately when it already has one).
    func whenFinished(_ handler: @escaping @Sendable () -> Void) {
        let now: Bool = lock.withLock {
            if finalStatus != nil { return true }
            finishHandlers.append(handler)
            return false
        }
        if now { handler() }
    }
    func snapshot() -> (answer: String, cards: JSONValue, finalStatus: String?, errorText: String?, errorCode: String?) {
        lock.withLock { (answer, cards, finalStatus, errorText, errorCode) }
    }
}

// MARK: - User-facing texts (English and Spanish)

/// Everything the user reads or hears about a browser task is built here from the sidecar's structured facts, so the
/// sidecar stays language-agnostic and the strings say Friday.
public enum WebAgentTexts {
    static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// The approval question for a `confirm.request` (or a `waiting` snapshot), without the trailing "Should I continue?".
    public static func approvalQuestion(kind: String, data: JSONValue, language: Language) -> String {
        let label = clean(data["label"]?.stringValue)
        let host = clean(data["host"]?.stringValue) ?? language.pick("this site", "este sitio")
        let fallback = clean(data["question"]?.stringValue ?? data["message"]?.stringValue)?.replacingOccurrences(of: "Jarvis", with: "Friday")
        switch kind {
        case "download":
            let name = clean(data["name"]?.stringValue).map { language.pick("“\($0)”", "«\($0)»") } ?? clean(data["url"]?.stringValue) ?? language.pick("a file", "un archivo")
            let folder = clean(data["folder"]?.stringValue) ?? language.pick("the Friday downloads folder", "la carpeta de descargas de Friday")
            return language.pick("Friday wants to save \(name) from \(host) to \(folder).", "Friday quiere guardar \(name) de \(host) en \(folder).")
        case "upload":
            let name = clean(data["name"]?.stringValue) ?? language.pick("a file", "un archivo")
            let field = clean(data["field"]?.stringValue).map { language.pick(" (field: \($0))", " (campo: \($0))") } ?? ""
            return language.pick("Friday is about to upload “\(name)” to \(host)\(field).", "Friday va a subir «\(name)» a \(host)\(field).")
        default:
            guard let label else {
                return fallback ?? language.pick("Friday needs your approval to continue.", "Friday necesita tu aprobación para continuar.")
            }
            switch kind {
            case "payment":
                return language.pick("Friday is about to click “\(label)” on \(host), which may spend money or submit a payment.", "Friday va a pulsar «\(label)» en \(host), lo que puede gastar dinero o enviar un pago.")
            case "purchase":
                return language.pick("Friday is about to click “\(label)” on \(host), which may make a booking or purchase.", "Friday va a pulsar «\(label)» en \(host), lo que puede hacer una reserva o una compra.")
            case "destructive":
                return language.pick("Friday is about to click “\(label)” on \(host), which may delete or cancel something.", "Friday va a pulsar «\(label)» en \(host), lo que puede borrar o cancelar algo.")
            case "account":
                return language.pick("Friday is about to click “\(label)” on \(host), which may change account settings or permissions.", "Friday va a pulsar «\(label)» en \(host), lo que puede cambiar ajustes o permisos de la cuenta.")
            case "send":
                return language.pick("Friday is about to click “\(label)” on \(host), which may send or publish content.", "Friday va a pulsar «\(label)» en \(host), lo que puede enviar o publicar contenido.")
            default:
                return language.pick("Friday is about to click “\(label)” on \(host).", "Friday va a pulsar «\(label)» en \(host).")
            }
        }
    }

    /// The small print under an approval: the page, or the file's path and size.
    public static func approvalDetail(kind: String, data: JSONValue, language: Language) -> String? {
        switch kind {
        case "upload":
            var parts: [String] = []
            if let path = clean(data["path"]?.stringValue) { parts.append(path) }
            if let size = data["size"]?.intValue { parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case "download":
            return clean(data["url"]?.stringValue)
        default:
            if let title = clean(data["title"]?.stringValue), let url = clean(data["url"]?.stringValue) {
                return language.pick("Page: \(title) — \(url)", "Página: \(title) — \(url)")
            }
            return clean(data["detail"]?.stringValue)
        }
    }

    /// What the user must do in Chrome for a `needs_user` pause, including how to continue (say or press Done).
    public static func manualMessage(kind: String, message: String, host: String?, language: Language) -> String {
        let site = clean(host) ?? language.pick("The site", "El sitio")
        switch kind {
        case "captcha":
            return language.pick("\(site) is asking you to prove you are human. Solve it in Chrome, then say or press Done.",
                                 "\(site) te pide demostrar que eres humano. Resuélvelo en Chrome y luego di o pulsa Listo.")
        case "login":
            return language.pick("\(site) needs you to sign in. Sign in in Chrome, then say or press Done.",
                                 "\(site) necesita que inicies sesión. Inicia sesión en Chrome y luego di o pulsa Listo.")
        default:
            let what = clean(message)?.replacingOccurrences(of: "Jarvis", with: "Friday")
            if let what {
                return language.pick("\(what) Finish it in Chrome, then say or press Done.", "\(what) Termínalo en Chrome y luego di o pulsa Listo.")
            }
            return language.pick("Friday needs you to finish a step in Chrome. Then say or press Done.", "Friday necesita que termines un paso en Chrome. Luego di o pulsa Listo.")
        }
    }

    /// A Chrome or sidecar problem for the user, from its stable code; unknown codes keep the sidecar's own text.
    public static func chromeError(code: String?, fallback: String?, language: Language) -> String {
        let text = clean(fallback)?.replacingOccurrences(of: "Jarvis", with: "Friday") ?? ""
        switch code {
        case "chrome_not_found":
            return language.pick("Google Chrome was not found. Install it or choose its location in Settings ▸ Browser.", "No se encontró Google Chrome. Instálalo o elige su ubicación en Ajustes ▸ Navegador.")
        case "not_chrome":
            return language.pick("The selected application is not Google Chrome.", "La aplicación seleccionada no es Google Chrome.")
        case "profile_in_use":
            return language.pick("Friday's Chrome profile is open in a window that Friday did not start. Close that Chrome window and try again.", "El perfil de Chrome de Friday está abierto en una ventana que Friday no inició. Cierra esa ventana de Chrome e inténtalo de nuevo.")
        case "chrome_exited":
            return language.pick("Chrome quit right after starting.", "Chrome se cerró nada más iniciarse.")
        case "devtools_timeout":
            return language.pick("Chrome did not accept the automation connection in time.", "Chrome no aceptó la conexión de automatización a tiempo.")
        case "chrome_not_running":
            return language.pick("Google Chrome is not running. Open Chrome first.", "Google Chrome no está abierto. Abre Chrome primero.")
        case "remote_debugging_off":
            return language.pick("Chrome is running without remote debugging. Turn it on at chrome://inspect/#remote-debugging and allow the connection when Chrome asks.", "Chrome está abierto sin depuración remota. Actívala en chrome://inspect/#remote-debugging y permite la conexión cuando Chrome lo pida.")
        case "chrome_disconnected":
            return text.isEmpty
                ? language.pick("Chrome closed the connection to Friday.", "Chrome cerró la conexión con Friday.")
                : language.pick("Chrome closed the connection to Friday. \(text)", "Chrome cerró la conexión con Friday. \(text)")
        case "chrome_not_connected":
            return text.isEmpty ? language.pick("Chrome is not connected.", "Chrome no está conectado.") : text
        case "task_lost":
            return language.pick("The browser sidecar lost the task.", "El proceso del navegador perdió la tarea.")
        case "sidecar_unreachable":
            return language.pick("The browser sidecar stopped responding.", "El proceso del navegador dejó de responder.")
        case "llm_error":
            return language.pick("The text model failed: \(text)", "El modelo de texto falló: \(text)")
        case "laya_unavailable":
            return language.pick("The local decision model (Laya) is not available: \(text)", "El modelo local de decisiones (Laya) no está disponible: \(text)")
        default:
            return text.isEmpty ? language.pick("Unknown error.", "Error desconocido.") : text
        }
    }
}
