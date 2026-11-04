import Foundation
import FridayCore
import FridaySidecar
import os

// MARK: - Browser automation through the sidecar (the Jarvis Chrome agent)
//
// `web.task` hands a natural-language browsing goal to the sidecar, which plans typed steps with the text model,
// drives Chrome over the DevTools Protocol with Laya choosing among observed elements, and returns a grounded
// answer with cards (links, tables, files, sources). Friday streams its progress to the UI, forwards its
// confirmation requests (purchases, sends, deletions…) to the user, and reports CAPTCHA/login pauses honestly.

public struct BrowserApproval: Sendable, Hashable {
    public var taskID: String
    public var confirmationID: String
    public var kind: String
    public var question: String
    public var detail: String?
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
    /// The user must act in the browser (CAPTCHA, sign-in). Returns when they say they are done, or false to give up.
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
}

public final class WebAgentIntegration: AppIntegration, @unchecked Sendable {
    public let id: IntegrationID = "web"
    public let displayName = LocalizedText(en: "Web browsing (Chrome)", es: "Navegación web (Chrome)")
    public let summary = LocalizedText(en: "Searches, reads and operates websites in Google Chrome for you.", es: "Busca, lee y maneja sitios web en Google Chrome por ti.")
    public let symbolName = "globe"
    public let permissionRequirements: [PermissionRequirement] = []
    static let logger = Logger(subsystem: "com.alejandro.friday", category: "web")

    private let lock = NSLock()
    private var client: SidecarClient?
    private var interaction: any BrowserInteractionHandling = DenyingInteractionHandler()
    private var conversationID: String?
    private var runningTaskID: String?

    public init() {}

    public func setClient(_ client: SidecarClient?) { lock.withLock { self.client = client; if client == nil { conversationID = nil } } }
    public func setInteractionHandler(_ handler: any BrowserInteractionHandling) { lock.withLock { interaction = handler } }
    /// Start a fresh browsing conversation (follow-ups stop reusing earlier tabs and data).
    public func resetConversation() { lock.withLock { conversationID = nil } }
    public var currentTaskID: String? { lock.withLock { runningTaskID } }

    public var tools: [ToolDescriptor] {
        [
            ToolDescriptor(
                name: "web.task", integration: id, title: "Browse the web",
                summary: "Perform a browsing task in Google Chrome with the autonomous browser agent: search the web, open sites, compare results, extract data (prices, flights, tables), fill harmless forms, download files, watch for a page. Give the complete goal in one sentence, including constraints (dates, 'direct flights', 'cheapest', 'top 3'). Returns the agent's grounded answer with links/tables. Purchases, payments, sends and deletions pause for the user's approval; CAPTCHAs and logins pause for the user.",
                parameters: [
                    .string("goal", "What to achieve, in the user's words plus resolved details (e.g. absolute dates)", required: true, maxLength: 2000),
                    .boolean("new_conversation", "Start from a clean slate instead of continuing the previous browsing context", default: false),
                ],
                safety: .modifying, timeout: 900, deduplicate: false,
                examples: [
                    ToolExample("find the cheapest direct flight from London to Barcelona on 2026-11-13", arguments: ["goal": "Find the cheapest direct flight from London to Barcelona on 2026-11-13 and list the top 3 options with prices and links"]),
                    ToolExample("busca en Google machine learning", language: .es, arguments: ["goal": "Buscar en Google 'machine learning' y resumir los tres primeros resultados"]),
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
        guard let client = lock.withLock({ client }) else {
            return IntegrationStatus(state: .needsSetup, detail: LocalizedText(en: "The browser sidecar is not running.", es: "El proceso del navegador no está en marcha."))
        }
        guard (try? await client.health()) == true else {
            return IntegrationStatus(state: .unavailable, detail: LocalizedText(en: "The browser sidecar is not responding.", es: "El proceso del navegador no responde."))
        }
        return IntegrationStatus(state: .ready)
    }

    public func authorization(for tool: ToolDescriptor) async -> AuthorizationState {
        lock.withLock { client } == nil
            ? .unavailable(LocalizedText(en: "The browser agent is not available (sidecar not running).", es: "El agente de navegación no está disponible (proceso no iniciado)."))
            : .authorized
    }

    public func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState { await authorization(for: tool) }

    public func agentStatus() async -> WebAgentStatus {
        guard let client = lock.withLock({ client }) else {
            return WebAgentStatus(sidecarRunning: false, chromeState: "disconnected", chromeMode: "managed", chromeInstalled: false, layaState: "missing", llmModel: "", llmReachable: false, busyTaskID: nil, error: "sidecar not running")
        }
        do {
            let status = try await client.status()
            return WebAgentStatus(
                sidecarRunning: true, chromeState: status["chrome"]?["state"]?.stringValue ?? "?", chromeMode: status["chrome"]?["mode"]?.stringValue ?? "?",
                chromeInstalled: status["chrome"]?["installed"]?.boolValue ?? false, layaState: status["laya"]?["state"]?.stringValue ?? "?",
                llmModel: status["llm"]?["model"]?.stringValue ?? "", llmReachable: status["llm"]?["reachable"]?.boolValue ?? false,
                busyTaskID: status["busy_task_id"]?.stringValue, error: nil)
        } catch {
            return WebAgentStatus(sidecarRunning: true, chromeState: "?", chromeMode: "?", chromeInstalled: false, layaState: "?", llmModel: "", llmReachable: false, busyTaskID: nil, error: error.localizedDescription)
        }
    }

    public func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
        guard let client = lock.withLock({ client }) else {
            throw JarvisError.setupRequired(
                SetupInstructions(title: context.t("Browser agent not running", "Agente de navegación no iniciado"), steps: [context.t("Open Friday ▸ Settings ▸ Browser and start the sidecar.", "Abre Friday ▸ Ajustes ▸ Navegador e inicia el proceso.")]),
                LocalizedText(en: "The browser sidecar is not running.", es: "El proceso del navegador no está en marcha."))
        }
        switch call.descriptor.name.rawValue {
        case "web.status":
            let status = await agentStatus()
            let text = context.t(
                "Chrome: \(status.chromeState) (\(status.chromeMode)), Laya: \(status.layaState), model: \(status.llmModel.isEmpty ? "none" : status.llmModel) (\(status.llmReachable ? "reachable" : "unreachable")).",
                "Chrome: \(status.chromeState) (\(status.chromeMode)), Laya: \(status.layaState), modelo: \(status.llmModel.isEmpty ? "ninguno" : status.llmModel) (\(status.llmReachable ? "accesible" : "inaccesible")).")
            return .done(ToolOutput(message: text, data: try JSONValue.encoding(status), verification: .notApplicable))
        case "web.connect":
            let mode = call.string("mode") ?? "managed"
            let result = try await client.post("api/chrome/connect", ["mode": .string(mode)], timeout: 90)
            let state = result["state"]?.stringValue ?? "?"
            let ok = state == "connected"
            let message = ok
                ? context.t("Chrome is connected (\(mode)).", "Chrome está conectado (\(mode)).")
                : (state == "awaiting_permission"
                    ? context.t("Chrome is asking you to allow remote debugging. Click Allow in Chrome.", "Chrome te pide permitir la depuración remota. Pulsa Permitir en Chrome.")
                    : context.t("Chrome is not connected: \(result["error"]?.stringValue ?? state)", "Chrome no está conectado: \(result["error"]?.stringValue ?? state)"))
            return .done(ToolOutput(message: message, data: result, verification: ok ? .verified("chrome status reports connected") : .unverified(state)))
        case "web.focus":
            let result = try await client.post("api/chrome/focus", nil, timeout: 10)
            return .done(ToolOutput(message: context.t("Brought the browser tab to the front.", "He traído la pestaña del navegador al frente."), data: result, verification: .notApplicable))
        case "web.cancel":
            guard let taskID = lock.withLock({ runningTaskID }) else {
                return .done(ToolOutput(message: context.t("No browser task is running.", "No hay ninguna tarea del navegador en marcha."), verification: .notApplicable))
            }
            let result = try await client.post("api/tasks/\(taskID)/cancel", nil, timeout: 15)
            return .done(ToolOutput(message: context.t("Cancelled the browser task.", "He cancelado la tarea del navegador."), data: result, verification: .verified("task status \(result["status"]?.stringValue ?? "?")")))
        case "web.current_task":
            guard let taskID = lock.withLock({ runningTaskID }) else {
                return .done(ToolOutput(message: context.t("The browser agent is idle.", "El agente de navegación está inactivo."), verification: .notApplicable))
            }
            let task = try await client.get("api/tasks/\(taskID)")
            return .done(ToolOutput(message: Self.describe(task, language: context.language), data: task, verification: .notApplicable))
        case "web.task":
            return try await runTask(goal: call.string("goal") ?? "", newConversation: call.bool("new_conversation") ?? false, client: client, context: context)
        default:
            throw JarvisError.validation([ValidationIssue(.unknownTool, "Unknown tool \(call.descriptor.name)")])
        }
    }

    // MARK: Running a task with live events

    private func runTask(goal: String, newConversation: Bool, client: SidecarClient, context: ExecutionContext) async throws -> ToolOutcome {
        let interaction = lock.withLock { self.interaction }
        if lock.withLock({ runningTaskID }) != nil {
            throw JarvisError.setupRequired(
                SetupInstructions(title: context.t("Browser busy", "Navegador ocupado"), steps: [context.t("Wait for the current browser task or cancel it.", "Espera a que termine la tarea actual del navegador o cancélala.")]),
                LocalizedText(en: "A browser task is already running.", es: "Ya hay una tarea del navegador en marcha."))
        }
        // One conversation per Friday session so follow-ups keep tabs and extracted data.
        var conversationID = lock.withLock { newConversation ? nil : self.conversationID }
        if conversationID == nil {
            let conversation = try await client.post("api/conversations", ["title": .string(String(goal.prefix(56)))], timeout: 15)
            guard let id = conversation["id"]?.stringValue else { throw SidecarError.invalidResponse("no conversation id") }
            conversationID = id
            lock.withLock { self.conversationID = id }
        }
        // Subscribe to events before starting, so nothing is missed.
        let events = client.events()
        let started = try await client.post("api/conversations/\(conversationID!)/messages", ["text": .string(goal)], timeout: 30)
        guard let taskID = started["task"]?["id"]?.stringValue else { throw SidecarError.invalidResponse("no task id") }
        lock.withLock { runningTaskID = taskID }
        defer { lock.withLock { if runningTaskID == taskID { runningTaskID = nil } } }
        Self.logger.info("web task started \(taskID, privacy: .public)")

        let run = RunState()
        let language = context.language

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for try await event in events {
                        guard event["task_id"]?.stringValue == taskID else { continue }
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
                            guard let confirmationID = data["confirmation_id"]?.stringValue, run.markHandled(confirmationID) else { continue }
                            let approval = BrowserApproval(taskID: taskID, confirmationID: confirmationID, kind: data["kind"]?.stringValue ?? "sensitive", question: data["question"]?.stringValue ?? "", detail: data["detail"]?.stringValue)
                            interaction.progress(BrowserProgress(kind: .waitingForUser, taskID: taskID, title: approval.question, detail: approval.detail, url: nil))
                            let approved = await interaction.approve(approval)
                            _ = try? await client.post("api/tasks/\(taskID)/confirm", ["confirmation_id": .string(confirmationID), "approved": .bool(approved)], timeout: 15)
                        case "needs_user":
                            let kind = data["kind"]?.stringValue ?? "manual"
                            let message = data["message"]?.stringValue ?? ""
                            guard run.markHandled("needs:" + kind + message) else { continue }
                            interaction.progress(BrowserProgress(kind: .waitingForUser, taskID: taskID, title: message, detail: kind, url: data["url"]?.stringValue))
                            let resume = await interaction.waitForUser(taskID: taskID, kind: kind, message: message, url: data["url"]?.stringValue)
                            _ = try? await client.post(resume ? "api/tasks/\(taskID)/resume" : "api/tasks/\(taskID)/cancel", nil, timeout: 15)
                        case "task.status":
                            let status = data["status"]?.stringValue ?? ""
                            if let current = data["current"]?["title"]?.stringValue {
                                interaction.progress(BrowserProgress(kind: .status, taskID: taskID, title: current, detail: status, url: data["current"]?["url"]?.stringValue))
                            }
                            if RunState.isFinished(status) {
                                run.finish(status: status, error: data["error"]?.stringValue)
                                return
                            }
                        default: break
                        }
                    }
                }
                group.addTask {
                    // Safety net: poll the task in case the socket drops.
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(5))
                        let task = try await client.get("api/tasks/\(taskID)")
                        let status = task["status"]?.stringValue ?? ""
                        if RunState.isFinished(status) { run.finish(status: status, error: task["error"]?.stringValue); return }
                    }
                }
                _ = try await group.next()
                group.cancelAll()
            }
        } catch is CancellationError {
            _ = try? await client.post("api/tasks/\(taskID)/cancel", nil, timeout: 10)
            throw CancellationError()
        }
        // Final snapshot (answer, cards, steps) is authoritative.
        let task = try await client.get("api/tasks/\(taskID)")
        var (answer, cards, finalStatus, errorText) = run.snapshot()
        let status = finalStatus ?? task["status"]?.stringValue ?? "failed"
        if answer.isEmpty, let conversationID {
            let detail = try? await client.get("api/conversations/\(conversationID)")
            if let messages = detail?["messages"]?.arrayValue, let last = messages.last(where: { $0["role"]?.stringValue == "assistant" && $0["task_id"]?.stringValue == taskID }) {
                answer = last["text"]?.stringValue ?? ""
                cards = last["cards"] ?? cards
            }
        }
        interaction.progress(BrowserProgress(kind: .finished, taskID: taskID, title: status, detail: errorText, url: task["current"]?["url"]?.stringValue))
        let steps = task["steps"]?.arrayValue ?? []
        _ = finalStatus
        let data: JSONValue = [
            "task_id": .string(taskID), "status": .string(status), "answer": .string(answer), "cards": cards,
            "steps": .int(steps.count), "final_url": task["current"]?["url"].map { $0 } ?? .null, "error": errorText.map(JSONValue.string) ?? .null,
            "timings": task["timings"] ?? .null,
        ]
        switch status {
        case "done":
            return .done(ToolOutput(message: answer.isEmpty ? language.pick("Done.", "Hecho.") : answer, data: data, verification: .verified("browser agent reported done after \(steps.count) steps")))
        case "partial":
            return .done(ToolOutput(message: (answer.isEmpty ? "" : answer + "\n") + language.pick("The browser task finished partially\(errorText.map { ": \($0)" } ?? ".")", "La tarea del navegador terminó parcialmente\(errorText.map { ": \($0)" } ?? ".")"), data: data, verification: .unverified("partial: \(errorText ?? "declined or incomplete")"), warnings: [errorText ?? "partial"]))
        case "cancelled":
            throw JarvisError.cancelled
        default:
            throw JarvisError.setupRequired(
                SetupInstructions(title: language.pick("Browser task failed", "La tarea del navegador falló"), steps: [errorText ?? status]),
                LocalizedText(en: "The browser task failed: \(errorText ?? status)", es: "La tarea del navegador falló: \(errorText ?? status)"))
        }
    }

    static func describe(_ task: JSONValue, language: Language) -> String {
        let status = task["status"]?.stringValue ?? "?"
        let current = task["current"]?["title"]?.stringValue
        let steps = task["steps"]?.arrayValue?.count ?? 0
        var text = language.pick("Browser task: \(status), \(steps) steps so far.", "Tarea del navegador: \(status), \(steps) pasos hasta ahora.")
        if let current { text += " " + language.pick("Now: \(current).", "Ahora: \(current).") }
        if let waiting = task["waiting"]?["message"]?.stringValue { text += " " + language.pick("Waiting: \(waiting)", "Esperando: \(waiting)") }
        return text
    }
}


/// Mutable state shared between the event reader and the poller of one browser task.
final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var answer = ""
    private var cards: JSONValue = .array([])
    private var finalStatus: String?
    private var errorText: String?
    private var handled: Set<String> = []

    static func isFinished(_ status: String) -> Bool { ["done", "partial", "failed", "cancelled"].contains(status) }

    func setAnswer(_ text: String?, cards: JSONValue?) {
        lock.withLock {
            if let text { answer = text }
            if let cards { self.cards = cards }
        }
    }
    func markHandled(_ key: String) -> Bool { lock.withLock { handled.insert(key).inserted } }
    func finish(status: String, error: String?) {
        lock.withLock {
            if finalStatus == nil { finalStatus = status }
            if errorText == nil { errorText = error }
        }
    }
    func snapshot() -> (String, JSONValue, String?, String?) { lock.withLock { (answer, cards, finalStatus, errorText) } }
}
