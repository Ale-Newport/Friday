import Foundation
import FridayCore
import FridayIntelligence
import FridaySpeech
import FridayBrowser
import WakeWordKit
import WakeWordCore
import os

// MARK: - The assistant: one pipeline for voice and chat
//
//   wake word ─► listen (ring buffer → VAD + STT) ─► Action Engine (planner → tools) ─► speak ─► follow-ups
//   typed text ──────────────────────────────────────┘                                   └─► UI transcript

public actor Assistant {
    static let logger = Logger(subsystem: "com.alejandro.friday", category: "assistant")

    public let engine: ActionEngine
    public let registry: ToolRegistry
    public let planner: FridayPlanner
    public let listener: VoiceListener
    public let output: SpeechOutput
    public let web: WebAgentIntegration?
    private let settings: @Sendable () -> VoiceSettings
    private let onTurn: (@Sendable (String, String, Language?) async -> Void)?

    private var snapshot = AssistantSnapshot()
    private var observers: [UUID: @Sendable (AssistantSnapshot) -> Void] = [:]
    private var currentCommand: Task<EngineResponse, Never>?
    private var activeSession: ActivationSession?
    private var approvalContinuation: CheckedContinuation<Bool, Never>?
    private var approvalPrompt: PendingPrompt?
    private var manualContinuation: CheckedContinuation<Bool, Never>?
    private var streamingItemID: UUID?
    /// What Friday last said aloud: a conversation-mode capture that repeats it is the speakers heard by the microphone.
    private var lastSpokenReply = ""

    public init(
        engine: ActionEngine, registry: ToolRegistry, planner: FridayPlanner, listener: VoiceListener, output: SpeechOutput,
        web: WebAgentIntegration?, settings: @escaping @Sendable () -> VoiceSettings,
        onTurn: (@Sendable (String, String, Language?) async -> Void)? = nil
    ) {
        self.engine = engine
        self.registry = registry
        self.planner = planner
        self.listener = listener
        self.output = output
        self.web = web
        self.settings = settings
        self.onTurn = onTurn
    }

    // MARK: Observation

    public func observe(_ handler: @escaping @Sendable (AssistantSnapshot) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        handler(snapshot)
        return id
    }

    public func stopObserving(_ id: UUID) { observers[id] = nil }

    public var current: AssistantSnapshot { snapshot }

    private func publish(_ change: (inout AssistantSnapshot) -> Void) {
        change(&snapshot)
        snapshot.revision += 1
        if snapshot.transcript.count > 400 { snapshot.transcript.removeFirst(snapshot.transcript.count - 400) }
        for handler in observers.values { handler(snapshot) }
    }

    private func setPhase(_ phase: AssistantPhase) {
        publish { $0.phase = phase }
        if let session = activeSession {
            switch phase {
            case .listening: session.setPhase(.listening)
            case .thinking: session.setPhase(.thinking)
            case .acting, .waiting: session.setPhase(.acting)
            case .speaking: session.setPhase(.speaking)
            default: break
            }
        }
    }

    private func append(_ item: TranscriptItem) { publish { $0.transcript.append(item) } }

    // MARK: Typed commands (chat, IPC, hotkey)

    /// Runs a typed command through the same pipeline as voice.
    @discardableResult
    public func submit(_ text: String, source: CommandSource = .app, session: String = "chat", speak: Bool? = nil) async -> EngineResponse {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        append(TranscriptItem(role: .user, text: trimmed, source: source.rawValue))
        let response = await run(CommandRequest(text: trimmed, language: nil, source: source, session: session))
        let shouldSpeak = speak ?? (settings().speakResponses && (source == .voice || settings().speakTypedResponses))
        if shouldSpeak, !response.message.isEmpty, response.status != .cancelled {
            setPhase(.speaking(response.message))
            await output.speak(response.message, language: response.language)
            setPhase(.idle)
        }
        return response
    }

    /// Executes one command through the engine, streaming progress into the transcript.
    private func run(_ request: CommandRequest) async -> EngineResponse {
        currentCommand?.cancel()
        setPhase(.thinking)
        publish { $0.currentSteps = [] }
        let engine = engine
        let registry = registry
        let itemID = UUID()
        streamingItemID = itemID
        append(TranscriptItem(id: itemID, role: .assistant, text: "", source: request.source.rawValue, isStreaming: true))
        let me = self
        let task = Task<EngineResponse, Never> {
            await engine.process(request) { event in
                Task { await me.handle(event, registry: registry, itemID: itemID) }
            }
        }
        currentCommand = task
        let response = await task.value
        if currentCommand == task { currentCommand = nil }
        await onTurn?(request.text, response.message, response.language)
        // Computed before `publish`: the closure holds exclusive access to `snapshot`, and reading it again from
        // inside would be an exclusivity violation (it aborted the app on every voice command).
        let latency = latencyReport(response: response)
        publish { snapshot in
            if let index = snapshot.transcript.firstIndex(where: { $0.id == itemID }) {
                snapshot.transcript[index].text = response.message
                snapshot.transcript[index].response = response
                snapshot.transcript[index].isStreaming = false
            }
            snapshot.pending = Self.pendingPrompt(for: response)
            snapshot.currentSteps = []
            snapshot.lastLatency = latency
        }
        setPhase(.idle)
        return response
    }

    private func latencyReport(response: EngineResponse) -> LatencyReport {
        var report = snapshot.lastLatency ?? LatencyReport()
        if let diagnostics = planner.lastDiagnostics {
            report.routingMs = diagnostics.routing?.latencyMs
            report.planningMs = diagnostics.modelLatencyMs
            report.path = diagnostics.path
            report.provider = diagnostics.providerID
            report.model = diagnostics.model
        }
        report.toolsMs = response.results.reduce(0) { $0 + $1.durationMs }
        report.totalMs = response.durationMs
        return report
    }

    private func handle(_ event: EngineEvent, registry: ToolRegistry, itemID: UUID) {
        switch event {
        case .planned(_, let steps):
            let titles = steps.map { registry.descriptor(for: $0.tool)?.title ?? $0.tool.rawValue }
            publish { $0.currentSteps = titles }
            if let first = titles.first { setPhase(.acting(first)) }
        case .stepStarted(_, let callID):
            _ = callID
        case .stepFinished(_, let result):
            let line = (result.success ? "✓ " : "• ") + (registry.descriptor(for: result.tool)?.title ?? result.tool.rawValue) + ": " + String(result.message.prefix(160))
            append(TranscriptItem(role: .step, text: line, source: "engine", response: nil))
        case .responseText(_, let text):
            publish { snapshot in
                if let index = snapshot.transcript.firstIndex(where: { $0.id == itemID }) { snapshot.transcript[index].text = text }
            }
        }
    }

    static func pendingPrompt(for response: EngineResponse) -> PendingPrompt? {
        for result in response.results {
            if let confirmation = result.confirmation, let token = confirmation.token {
                return PendingPrompt(kind: .confirmation(destructive: confirmation.destructive), question: confirmation.prompt, options: [], token: token)
            }
            if let clarification = result.clarification {
                return PendingPrompt(kind: .clarification, question: clarification.question, options: clarification.options.map(\.label), token: clarification.token)
            }
        }
        return nil
    }

    /// Answers a pending confirmation/clarification (buttons in the UI).
    @discardableResult
    public func resolve(token: String, decision: PendingDecision, label: String? = nil, source: CommandSource = .app) async -> EngineResponse {
        if let label { append(TranscriptItem(role: .user, text: label, source: source.rawValue)) }
        setPhase(.thinking)
        let engine = engine
        let registry = registry
        let itemID = UUID()
        append(TranscriptItem(id: itemID, role: .assistant, text: "", source: source.rawValue, isStreaming: true))
        let me = self
        let response = await engine.resolve(token: token, decision: decision, source: source) { event in
            Task { await me.handle(event, registry: registry, itemID: itemID) }
        }
        publish { snapshot in
            if let index = snapshot.transcript.firstIndex(where: { $0.id == itemID }) {
                snapshot.transcript[index].text = response.message
                snapshot.transcript[index].response = response
                snapshot.transcript[index].isStreaming = false
            }
            snapshot.pending = Self.pendingPrompt(for: response)
        }
        setPhase(.idle)
        return response
    }

    /// Stops speech and cancels the running command. Irreversible steps that already ran stay reported.
    public func interrupt() async {
        await output.stop()
        await listener.cancel()
        currentCommand?.cancel()
        if let continuation = approvalContinuation { approvalContinuation = nil; continuation.resume(returning: false) }
        if let continuation = manualContinuation { manualContinuation = nil; continuation.resume(returning: false) }
        publish { $0.pending = nil }
        setPhase(.idle)
    }

    public func clearConversation() async {
        await engine.clearSession("voice")
        await engine.clearSession("chat")
        web?.resetConversation()
        publish { $0.transcript = []; $0.pending = nil }
    }

    // MARK: Voice interaction (called by the wake-word bridge)

    /// Seconds of audio before the detector's end-of-keyword time that belong to the command capture.
    static let commandStartMargin = 0.6

    static let stopPhrases = ["stop", "cancel", "cancel that", "wait", "never mind", "nevermind", "forget it", "forget what i just said", "para", "cancela", "cancela eso", "espera", "olvídalo", "olvidalo", "déjalo", "dejalo", "nada"]
    static let endPhrases = ["that's all", "that is all", "thanks that's all", "thank you", "thanks", "stop listening", "go to sleep", "eso es todo", "gracias", "gracias eso es todo", "deja de escuchar", "ya está", "ya esta", "nada más", "nada mas", "adiós", "adios"]

    public func handleActivation(_ event: WakeWordEvent, session: ActivationSession) async {
        let clock = ContinuousClock()
        let activatedAt = clock.now
        activeSession = session
        session.beginCommand()
        publish { $0.inVoiceSession = true }
        defer { activeSession = nil; setPhase(.idle); publish { $0.inConversation = false; $0.inVoiceSession = false } }
        // Where the wake word ended in the shared ring buffer: the command starts there. The detector fires a few
        // hundred milliseconds after the keyword's last sound (it needs right context), so the capture starts that
        // much earlier or the first word of a command spoken in one breath ("Jarvis what time is it") is lost; the
        // normaliser strips whatever tail of the wake word the recogniser hears.
        var startPosition = max(0, listener.recorder.position(at: event.audioEndTime) - Int(Self.commandStartMargin * Double(MicrophoneRecorder.sampleRate)))
        let settings = settings()
        switch settings.acknowledgementStyle {
        case .chime: Task { await self.output.chime() }
        case .spoken: Task { await self.output.speak("Yes?", language: .en) }
        case .silent: break
        }
        var first = true
        var latency = LatencyReport()
        latency.wakeToListenMs = FridayPlanner_ms(activatedAt.duration(to: clock.now))
        while !Task.isCancelled {
            setPhase(.listening(partial: ""))
            let me = self
            let outcome = await listener.listen(from: startPosition, waitForSpeech: first ? settings.noSpeechTimeoutSeconds : settings.conversationTimeoutSeconds) { partial in
                Task { await me.setPhase(.listening(partial: partial)) }
            }
            first = false
            switch outcome {
            case .silence:
                if snapshot.inConversation { return }  // the conversation ended quietly
                await output.speak(Language(hint: Locale.current.language.languageCode?.identifier) == .es ? "¿Sí?" : "Yes?", language: .en)
                let retry = await listener.listen(from: listener.recorder.position, waitForSpeech: 4) { partial in Task { await me.setPhase(.listening(partial: partial)) } }
                guard case .utterance(let capture) = retry else { return }
                await process(capture, latency: &latency, clock: clock)
            case .cancelled:
                return
            case .failed(let reason):
                Self.logger.error("listening failed: \(reason, privacy: .public)")
                setPhase(.error(reason))
                return
            case .utterance(let capture):
                if snapshot.inConversation, Self.isEcho(capture.text, of: lastSpokenReply) {
                    Self.logger.info("ignored an echo of Friday's own speech")
                    startPosition = listener.recorder.position
                    continue
                }
                await process(capture, latency: &latency, clock: clock)
            }
            guard settings.conversationMode, !Task.isCancelled else { return }
            publish { $0.inConversation = true }
            startPosition = listener.recorder.position
            latency = LatencyReport()
        }
    }

    private func process(_ capture: UtteranceCapture, latency: inout LatencyReport, clock: ContinuousClock) async {
        if let ended = capture.speechEndedAt { latency.speechEndToTranscriptMs = FridayPlanner_ms(ended.duration(to: capture.transcriptReadyAt)) }
        let normalized = UtteranceNormalizer.normalize(capture.text, wakeWord: settings().wakeWord).text
        let folded = KeywordRouter.fold(normalized).trimmingCharacters(in: CharacterSet(charactersIn: " .,!¡¿?"))
        if Self.endPhrases.contains(folded) {
            await output.speak(capture.language == .es ? "Hasta luego." : "Okay.", language: capture.language ?? .en)
            publish { $0.inConversation = false }
            activeSession?.finish(.completed)
            return
        }
        if Self.stopPhrases.contains(folded) {
            await interrupt()
            if !normalized.isEmpty { append(TranscriptItem(role: .user, text: capture.text, source: "voice")) }
            await output.speak(capture.language == .es ? "Vale." : "Okay.", language: capture.language ?? .en)
            return
        }
        // Pending question? The engine resolves yes/no/option answers itself through the same session.
        append(TranscriptItem(role: .user, text: capture.text, source: "voice"))
        let started = clock.now
        let response = await run(CommandRequest(text: capture.text, language: capture.language, source: .voice, session: "voice"))
        latency.totalMs = FridayPlanner_ms(started.duration(to: clock.now))
        publish { $0.lastLatency = latency }
        guard !response.message.isEmpty, response.status != .cancelled else { return }
        setPhase(.speaking(response.message))
        lastSpokenReply = response.message
        let speakTask = Task { await self.output.speak(response.message, language: response.language) }
        if settings().bargeInEnabled {
            // Barge-in: sustained speech, clearly louder than the playback the microphone picks up, stops the speech;
            // the next loop turn listens to it. The detector is a child of the group so that finishing the speech
            // cancels it at once (an unstructured task here kept every reply "speaking" for the detector's full timeout).
            let listener = listener
            let interrupted = await withTaskGroup(of: Bool.self) { group in
                group.addTask { _ = await speakTask.value; return false }
                group.addTask { await listener.waitForSpeech(timeout: 120, minimumDuration: 0.5, calibration: 0.8) }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            if interrupted { await output.stop() }
        } else {
            _ = await speakTask.value
        }
        if let pending = snapshot.pending {
            // Spoken questions need a spoken answer: the loop listens again right away.
            publish { $0.inConversation = true }
            _ = pending
        }
    }
}

extension Assistant {
    /// True when most of the words Friday heard are words it just said (the speakers reaching the microphone).
    static func isEcho(_ heard: String, of spoken: String) -> Bool {
        let heardWords = KeywordRouter.fold(heard).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 }
        guard heardWords.count >= 2, !spoken.isEmpty else { return false }
        let spokenWords = Set(KeywordRouter.fold(spoken).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let overlap = heardWords.filter { spokenWords.contains($0) }.count
        return Double(overlap) / Double(heardWords.count) >= 0.6
    }
}

func FridayPlanner_ms(_ duration: Duration) -> Int {
    let (seconds, attoseconds) = duration.components
    return Int(seconds * 1000 + attoseconds / 1_000_000_000_000_000)
}

// MARK: - Browser approvals through the assistant

extension Assistant: BrowserInteractionHandling {
    nonisolated public func progress(_ progress: BrowserProgress) {
        Task { await self.browserProgress(progress) }
    }

    private func browserProgress(_ progress: BrowserProgress) {
        switch progress.kind {
        case .step, .status, .pageChanged:
            publish { $0.browserStatusLine = progress.title + (progress.url.map { " — \($0)" } ?? "") }
            if case .acting = snapshot.phase { setPhase(.acting(progress.title)) }
        case .waitingForUser:
            publish { $0.browserStatusLine = progress.title }
        case .finished:
            publish { $0.browserStatusLine = nil }
        case .answerDelta: break
        }
    }

    public func approve(_ approval: BrowserApproval) async -> Bool {
        let prompt = PendingPrompt(kind: .browserApproval, question: approval.question + (approval.detail.map { "\n" + $0 } ?? ""), options: ["Approve", "Deny"], token: approval.confirmationID)
        approvalPrompt = prompt
        publish { $0.pending = prompt }
        setPhase(.waiting(approval.question))
        if settings().speakResponses {
            let language = approval.language  // the question is already phrased in the user's language
            await output.speak(approval.question + " " + (language == .es ? "¿Continúo?" : "Should I continue?"), language: language)
            // Listen for a spoken yes/no for a few seconds; the UI buttons work too.
            let spoken = await listener.listen(from: listener.recorder.position, waitForSpeech: 8)
            if case .utterance(let capture) = spoken {
                let folded = KeywordRouter.fold(capture.text)
                let yes = ["yes", "yeah", "yep", "sure", "ok", "okay", "go ahead", "approve", "confirm", "do it", "sí", "si", "vale", "claro", "adelante", "confirmo", "hazlo", "dale"]
                let no = ["no", "nope", "deny", "cancel", "stop", "don't", "no lo hagas", "cancela", "para"]
                if yes.contains(where: { folded == $0 || folded.hasPrefix($0 + " ") }) { return answerApproval(true) }
                if no.contains(where: { folded == $0 || folded.hasPrefix($0 + " ") }) { return answerApproval(false) }
            }
        }
        return await withCheckedContinuation { continuation in
            if approvalPrompt == nil { continuation.resume(returning: false); return }
            approvalContinuation = continuation
        }
    }

    private func answerApproval(_ approved: Bool) -> Bool {
        approvalPrompt = nil
        publish { $0.pending = nil }
        return approved
    }

    /// UI buttons for a browser approval.
    public func answerBrowserApproval(_ approved: Bool) {
        guard approvalPrompt != nil else { return }
        _ = answerApproval(approved)
        if let continuation = approvalContinuation { approvalContinuation = nil; continuation.resume(returning: approved) }
    }

    public func waitForUser(taskID: String, kind: String, message: String, url: String?) async -> Bool {
        let prompt = PendingPrompt(kind: .browserManual, question: message, options: ["Done", "Cancel"], token: taskID)
        publish { $0.pending = prompt }
        setPhase(.waiting(message))
        if settings().speakResponses {
            let language = LanguageDetector.detect(message, fallback: .en)
            await output.speak(language == .es ? "Necesito que lo completes tú en el navegador. Dime «listo» cuando termines." : "I need you to finish that in the browser. Say “done” when you're ready.", language: language)
        }
        return await withCheckedContinuation { continuation in manualContinuation = continuation }
    }

    public func answerManual(_ done: Bool) {
        publish { $0.pending = nil }
        if let continuation = manualContinuation { manualContinuation = nil; continuation.resume(returning: done) }
    }
}

// MARK: - Wake-word bridge

/// The `AssistantActivationHandler` the wake-word runtime calls. Keeps the runtime's contract: the detector stays
/// gated until this returns; cancellation ends the session.
public struct AssistantActivationBridge: AssistantActivationHandler {
    private let assistant: Assistant
    public init(assistant: Assistant) { self.assistant = assistant }
    public func onWakeWordDetected(_ event: WakeWordEvent, session: ActivationSession) async {
        await assistant.handleActivation(event, session: session)
    }
}
