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
    /// Commands in flight, by command id. They run one at a time (`queueTail`); a newer command of the same
    /// session supersedes the running one, a command of another session (scheduler, chat while a voice command
    /// runs) waits its turn.
    private struct RunningCommand { let session: String; let task: Task<EngineResponse, Never> }
    private var running: [UUID: RunningCommand] = [:]
    private var queueTail: Task<Void, Never>?
    private var activeSession: ActivationSession?
    private var approvalContinuation: CheckedContinuation<Bool, Never>?
    private var approvalPrompt: PendingPrompt?
    /// A UI answer that arrived while `approve()` was still speaking or listening.
    private var approvalAnswer: Bool?
    private var manualContinuation: CheckedContinuation<Bool, Never>?
    private var manualPrompt: PendingPrompt?
    private var manualAnswer: Bool?
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

    /// Back to idle unless another command is still running (the HUD must not show idle while it works). An error
    /// stays until the next interaction replaces it, so the HUD can show it before hiding.
    private func settle() {
        guard running.isEmpty else { return }
        if case .error = snapshot.phase { return }
        setPhase(.idle)
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
            settle()
        }
        return response
    }

    /// Runs one tool call directly — a Settings button, an option the UI already resolved — without interpretation:
    /// no model is involved, and the result lands in the transcript like any other command's. The user line shows
    /// the tool's title, so the transcript reads "Connect Chrome" rather than "web.connect".
    @discardableResult
    public func execute(_ call: ToolCall, source: CommandSource = .app, session: String = "chat", speak: Bool? = nil) async -> EngineResponse {
        let title = registry.descriptor(for: call.tool)?.title ?? call.tool.rawValue
        append(TranscriptItem(role: .user, text: title, source: source.rawValue))
        currentCommand?.cancel()
        setPhase(.thinking)
        publish { $0.currentSteps = [] }
        let engine = engine
        let registry = registry
        let itemID = UUID()
        streamingItemID = itemID
        append(TranscriptItem(id: itemID, role: .assistant, text: "", source: source.rawValue, isStreaming: true))
        let me = self
        let task = Task<EngineResponse, Never> {
            await engine.execute(call, source: source, session: session) { event in
                Task { await me.handle(event, registry: registry, itemID: itemID) }
            }
        }
        currentCommand = task
        let response = await task.value
        if currentCommand == task { currentCommand = nil }
        publish { snapshot in
            if let index = snapshot.transcript.firstIndex(where: { $0.id == itemID }) {
                snapshot.transcript[index].text = response.message
                snapshot.transcript[index].response = response
                snapshot.transcript[index].isStreaming = false
            }
            snapshot.pending = Self.pendingPrompt(for: response)
            snapshot.currentSteps = []
        }
        setPhase(.idle)
        let shouldSpeak = speak ?? (settings().speakResponses && settings().speakTypedResponses)
        if shouldSpeak, !response.message.isEmpty, response.status != .cancelled {
            setPhase(.speaking(response.message))
            await output.speak(response.message, language: response.language)
            setPhase(.idle)
        }
        return response
    }

    /// Executes one command through the engine, streaming progress into the transcript.
    ///
    /// Commands run one after another. A new command from the same session cancels the one in flight (the user
    /// corrected themselves); one from another session waits, so a scheduled command or a typed message never
    /// aborts a voice command that is being executed.
    private func run(_ request: CommandRequest, voiceLatency: LatencyReport? = nil) async -> EngineResponse {
        let itemID = UUID()
        append(TranscriptItem(id: itemID, role: .assistant, text: "", source: request.source.rawValue, isStreaming: true))
        for command in running.values where command.session == request.session { command.task.cancel() }
        let engine = engine
        let registry = registry
        let me = self
        let previous = queueTail
        let commandID = UUID()
        let task = Task<EngineResponse, Never> {
            _ = await previous?.value
            if Task.isCancelled {
                let language = request.language ?? LanguageDetector.detect(request.text, fallback: .en)
                return EngineResponse(input: request.text, language: language, status: .cancelled, message: language.pick("Cancelled.", "Cancelado."))
            }
            await me.commandStarted()
            // Engine events are consumed in order by one task, so a late `responseText` can never land after the
            // final transcript text.
            let (events, continuation) = AsyncStream<EngineEvent>.makeStream()
            @Sendable func consume() async {
                for await event in events { await me.handle(event, registry: registry, itemID: itemID) }
            }
            async let consumed: Void = consume()
            let response = await engine.process(request) { continuation.yield($0) }
            continuation.finish()
            await consumed
            return response
        }
        queueTail = Task { _ = await task.value }
        running[commandID] = RunningCommand(session: request.session, task: task)
        let response = await task.value
        running[commandID] = nil
        await onTurn?(request.text, response.message, response.language)
        // Computed before `publish`: the closure holds exclusive access to `snapshot`, and reading it again from
        // inside would be an exclusivity violation (it aborted the app on every voice command).
        let latency = latencyReport(response: response, base: voiceLatency)
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
        settle()
        return response
    }

    private func commandStarted() {
        setPhase(.thinking)
        publish { $0.currentSteps = [] }
    }

    /// The timings of one command: the voice part (wake word → listening, speech end → transcript) comes from the
    /// caller, routing/model/tool timings from the planner and the response.
    private func latencyReport(response: EngineResponse, base: LatencyReport?) -> LatencyReport {
        var report = base ?? LatencyReport()
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
                if let index = snapshot.transcript.firstIndex(where: { $0.id == itemID }), snapshot.transcript[index].isStreaming {
                    snapshot.transcript[index].text = text
                }
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
        let (events, continuation) = AsyncStream<EngineEvent>.makeStream()
        @Sendable func consume() async {
            for await event in events { await me.handle(event, registry: registry, itemID: itemID) }
        }
        async let consumed: Void = consume()
        let response = await engine.resolve(token: token, decision: decision, source: source) { continuation.yield($0) }
        continuation.finish()
        await consumed
        publish { snapshot in
            if let index = snapshot.transcript.firstIndex(where: { $0.id == itemID }) {
                snapshot.transcript[index].text = response.message
                snapshot.transcript[index].response = response
                snapshot.transcript[index].isStreaming = false
            }
            snapshot.pending = Self.pendingPrompt(for: response)
        }
        settle()
        return response
    }

    /// Stops speech, cancels the running commands and withdraws every open question — in the UI and in the engine,
    /// so a cancelled confirmation can never be run by a later "yes". Irreversible steps that already ran stay reported.
    public func interrupt() async {
        await output.stop()
        await listener.cancel()
        for command in running.values { command.task.cancel() }
        approvalPrompt = nil
        manualPrompt = nil
        if let continuation = approvalContinuation { approvalContinuation = nil; continuation.resume(returning: false) }
        if let continuation = manualContinuation { manualContinuation = nil; continuation.resume(returning: false) }
        if let pending = snapshot.pending, let token = pending.token {
            switch pending.kind {
            case .confirmation, .clarification: _ = await engine.resolve(token: token, decision: .cancel, source: .app)
            case .browserApproval, .browserManual: break
            }
        }
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

    static let stopPhrases: Set<String> = ["stop", "cancel", "cancel that", "wait", "never mind", "nevermind", "forget it", "forget what i just said", "para", "cancela", "cancela eso", "espera", "olvidalo", "dejalo", "nada"]
    static let endPhrases: Set<String> = ["that's all", "thats all", "that is all", "thanks that's all", "thanks thats all", "thank you", "thanks", "stop listening", "go to sleep", "eso es todo", "gracias", "gracias eso es todo", "deja de escuchar", "ya esta", "nada mas", "adios", "hasta luego"]

    /// The form end/stop phrases are matched in: folded, without punctuation anywhere, single spaces.
    static func phraseKey(_ text: String) -> String {
        KeywordRouter.fold(text)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[.,!?¡¿;:"«»]"#, with: "", options: .regularExpression)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    private enum TurnOutcome {
        /// The user ended the conversation; the session ends when the handler returns.
        case ended
        /// Listen again, from `from` (nil: from now). `required` is true when a spoken answer is awaited or the
        /// user just interrupted Friday, so it applies even with conversation mode off.
        case listenAgain(from: Int?, required: Bool)
    }

    public func handleActivation(_ event: WakeWordEvent, session: ActivationSession) async {
        let activatedAt = ContinuousClock.now
        activeSession = session
        session.beginCommand()
        let endPosition = listener.recorder.position(at: event.audioEndTime)
        // The runtime cancels the handler task when detection is disabled or the session times out; the listener,
        // the speech and the voice command in flight do not see that on their own.
        await withTaskCancellationHandler {
            await runVoiceSession(wakeWordEndPosition: endPosition, activatedAt: activatedAt)
        } onCancel: {
            Task { await self.voiceSessionCancelled() }
        }
        activeSession = nil
    }

    private func voiceSessionCancelled() async {
        await listener.cancel()
        await output.stop()
        for command in running.values where command.session == "voice" { command.task.cancel() }
    }

    /// The voice session after a wake word: verify (optionally), acknowledge, listen, act, speak, follow up.
    /// Returning ends the wake-word session. `wakeWordEndPosition` is the recorder position of the detector's
    /// end-of-keyword time.
    func runVoiceSession(wakeWordEndPosition endPosition: Int, activatedAt: ContinuousClock.Instant = .now) async {
        let clock = ContinuousClock()
        let settings = settings()
        publish { $0.inVoiceSession = true }
        defer { settle(); publish { $0.inConversation = false; $0.inVoiceSession = false } }
        var latency = LatencyReport()
        if settings.verifyWakeWord {
            let verification = await listener.verifyWakeWord(endingAt: endPosition, wakeWord: settings.wakeWord, margin: Self.commandStartMargin)
            latency.wakeVerificationMs = verification.durationMs
            switch verification.outcome {
            case .rejected(let transcript):
                Self.logger.info("activation rejected after \(verification.durationMs) ms: heard \(transcript, privacy: .private)")
                publish { $0.lastLatency = latency }
                return
            case .accepted(let transcript):
                Self.logger.debug("wake word verified in \(verification.durationMs) ms: \(transcript, privacy: .private)")
            case .skipped(let reason):
                Self.logger.info("wake word not verified (\(reason, privacy: .public)); continuing")
            }
        }
        // Where the wake word ended in the shared ring buffer: the command starts there. The detector fires a few
        // hundred milliseconds after the keyword's last sound (it needs right context), so the capture starts that
        // much earlier or the first word of a command spoken in one breath ("Jarvis what time is it") is lost; the
        // normaliser strips whatever tail of the wake word the recogniser hears.
        var startPosition = max(0, endPosition - Int(Self.commandStartMargin * Double(MicrophoneRecorder.sampleRate)))
        var language = settings.promptLanguage
        switch settings.acknowledgementStyle {
        case .chime: Task { await self.output.chime() }
        case .spoken: Task { [language] in await self.output.speak(language.pick("Yes?", "¿Sí?"), language: language) }
        case .silent: break
        }
        var waitForSpeech = settings.noSpeechTimeoutSeconds
        var reprompted = false
        latency.wakeToListenMs = milliseconds(activatedAt.duration(to: clock.now))
        while !Task.isCancelled {
            setPhase(.listening(partial: ""))
            let me = self
            let outcome = await listener.listen(from: startPosition, waitForSpeech: waitForSpeech) { partial in
                Task { await me.setPhase(.listening(partial: partial)) }
            }
            let turn: TurnOutcome
            switch outcome {
            case .silence:
                // Nothing after the wake word: ask once. In a conversation, silence simply ends it.
                guard !snapshot.inConversation, !reprompted else { return }
                reprompted = true
                await output.speak(language.pick("Yes?", "¿Sí?"), language: language)
                startPosition = listener.recorder.position
                waitForSpeech = min(4, settings.noSpeechTimeoutSeconds)
                continue
            case .unintelligible:
                // Speech, but no words: ask again once rather than ending the session with an error.
                guard !reprompted else { return }
                reprompted = true
                await output.speak(language.pick("Sorry?", "¿Perdona?"), language: language)
                startPosition = listener.recorder.position
                waitForSpeech = min(4, settings.noSpeechTimeoutSeconds)
                continue
            case .cancelled:
                return
            case .failed(let reason):
                // A real recogniser problem (none available, the session could not start): say so, in the user's
                // language, and end the session.
                Self.logger.error("listening failed: \(reason.en, privacy: .public)")
                setPhase(.error(reason.resolved(language)))
                await output.speak(reason.resolved(language), language: language)
                return
            case .utterance(let capture):
                if snapshot.inConversation, Self.isEcho(capture.text, of: lastSpokenReply) {
                    Self.logger.info("ignored an echo of Friday's own speech")
                    startPosition = listener.recorder.position
                    continue
                }
                if let heard = capture.language { language = heard }
                turn = await process(capture, latency: &latency, clock: clock)
            }
            reprompted = false
            switch turn {
            case .ended:
                return
            case .listenAgain(let resumeFrom, let required):
                guard required || settings.conversationMode, !Task.isCancelled else { return }
                publish { $0.inConversation = true }
                startPosition = resumeFrom ?? listener.recorder.position
                waitForSpeech = settings.conversationTimeoutSeconds
                latency = LatencyReport()
            }
        }
    }

    private func process(_ capture: UtteranceCapture, latency: inout LatencyReport, clock: ContinuousClock) async -> TurnOutcome {
        if let ended = capture.speechEndedAt { latency.speechEndToTranscriptMs = milliseconds(ended.duration(to: capture.transcriptReadyAt)) }
        let normalized = UtteranceNormalizer.normalize(capture.text, wakeWord: settings().wakeWord).text
        let key = Self.phraseKey(normalized)
        let language = capture.language ?? LanguageDetector.detect(capture.text, fallback: .en)
        if Self.endPhrases.contains(key) {
            await output.speak(language.pick("Okay.", "Hasta luego."), language: language)
            publish { $0.inConversation = false }
            return .ended
        }
        if Self.stopPhrases.contains(key) {
            await interrupt()
            if !normalized.isEmpty { append(TranscriptItem(role: .user, text: capture.text, source: "voice")) }
            await output.speak(language.pick("Okay.", "Vale."), language: language)
            return .listenAgain(from: nil, required: false)
        }
        // Pending question? The engine resolves yes/no/option answers itself through the same session.
        append(TranscriptItem(role: .user, text: capture.text, source: "voice"))
        let started = clock.now
        let response = await run(CommandRequest(text: capture.text, language: capture.language, source: .voice, session: "voice"), voiceLatency: latency)
        latency.totalMs = milliseconds(started.duration(to: clock.now))
        let total = latency.totalMs
        publish { snapshot in
            var merged = snapshot.lastLatency ?? LatencyReport()
            merged.totalMs = total
            snapshot.lastLatency = merged
        }
        // A spoken question needs a spoken answer: listen again even with conversation mode off.
        let awaitingAnswer = snapshot.pending != nil
        guard !response.message.isEmpty, response.status != .cancelled else { return .listenAgain(from: nil, required: awaitingAnswer) }
        setPhase(.speaking(response.message))
        lastSpokenReply = response.message
        if let interruptedAt = await speakWithBargeIn(response.message, language: response.language) {
            // The words that interrupted Friday are already in the ring buffer: the next capture starts there.
            return .listenAgain(from: interruptedAt, required: true)
        }
        return .listenAgain(from: nil, required: awaitingAnswer)
    }

    /// Speaks the reply. With barge-in enabled, sustained speech clearly louder than the playback the microphone
    /// picks up stops the speech; the detector calibrates on the playback itself, so it only starts once the first
    /// audio chunk plays (synthesis can take a few hundred milliseconds). Returns the recorder position where the
    /// interruption began, or nil when the reply was spoken to the end.
    private func speakWithBargeIn(_ text: String, language: Language) async -> Int? {
        let output = output
        let listener = listener
        guard settings().bargeInEnabled else {
            await output.speak(text, language: language)
            return nil
        }
        let (playbackStarted, startSignal) = AsyncStream<Void>.makeStream()
        return await withTaskGroup(of: Int?.self) { group in
            group.addTask {
                await output.speak(text, language: language) { startSignal.yield() }
                startSignal.finish()
                return nil
            }
            group.addTask {
                var iterator = playbackStarted.makeAsyncIterator()
                guard await iterator.next() != nil else { return nil }  // nothing was played
                return await listener.waitForSpeech(timeout: 120, minimumDuration: 0.5, calibration: 0.8)
            }
            let first = await group.next() ?? nil
            // The loser must end inside the group: a stopped player returns from `speak` at once, and a cancelled
            // detector returns within one 50 ms tick. Otherwise the implicit wait would speak the whole reply.
            if first != nil { await output.stop() }
            group.cancelAll()
            return first
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

    /// A spoken yes/no for a browser approval, or nil when the utterance is neither.
    static func spokenApproval(_ text: String) -> Bool? {
        if let decision = ReplyClassifier.classify(text, optionCount: 0) {
            switch decision {
            case .confirm: return true
            case .cancel: return false
            case .choose: break
            }
        }
        let key = phraseKey(text)
        let yes = ["yes", "yeah", "yep", "sure", "ok", "okay", "go ahead", "approve", "approved", "confirm", "do it", "si", "vale", "claro", "adelante", "confirmo", "hazlo", "dale", "aprobado"]
        let no = ["no", "nope", "deny", "denied", "cancel", "stop", "dont", "don't", "no lo hagas", "cancela", "para", "rechaza", "rechazado"]
        if yes.contains(where: { key == $0 || key.hasPrefix($0 + " ") }) { return true }
        if no.contains(where: { key == $0 || key.hasPrefix($0 + " ") }) { return false }
        return nil
    }

    /// A spoken "done"/"cancel" while the browser waits for the user, or nil to keep waiting.
    static func spokenManualAnswer(_ text: String) -> Bool? {
        let key = phraseKey(text)
        let done = ["done", "i'm done", "im done", "ready", "finished", "go on", "continue", "carry on", "ok done", "okay done", "listo", "ya esta", "termine", "hecho", "sigue", "continua", "ya esta hecho", "vale listo"]
        let cancel = ["cancel", "stop", "give up", "forget it", "never mind", "cancela", "para", "dejalo", "olvidalo", "dejalo estar"]
        if key == "ya" { return true }  // only on its own: "ya no quiero" is not "done"
        if done.contains(where: { key == $0 || key.hasPrefix($0 + " ") || key.hasSuffix(" " + $0) }) { return true }
        if cancel.contains(where: { key == $0 || key.hasPrefix($0 + " ") }) { return false }
        return nil
    }
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
        approvalAnswer = nil
        publish { $0.pending = prompt }
        setPhase(.waiting(approval.question))
        return await withTaskCancellationHandler {
            if settings().speakResponses {
                let language = approval.language
                await output.speak(approval.question + " " + language.pick("Should I continue?", "¿Continúo?"), language: language)
                // The UI buttons work at any time: an answer given while Friday was asking wins, and Stop withdraws.
                if let decided = approvalOutcome(for: prompt) { return decided }
                // Listen for a spoken yes/no for a few seconds.
                let spoken = await listener.listen(from: listener.recorder.position, waitForSpeech: 8)
                if let decided = approvalOutcome(for: prompt) { return decided }
                if case .utterance(let capture) = spoken, let decision = Self.spokenApproval(capture.text) {
                    append(TranscriptItem(role: .user, text: capture.text, source: "voice"))
                    return answerApproval(decision)
                }
            }
            return await withCheckedContinuation { continuation in
                if let decided = approvalOutcome(for: prompt) { continuation.resume(returning: decided); return }
                approvalContinuation = continuation
            }
        } onCancel: {
            Task { await self.withdrawApproval(prompt.id) }
        }
    }

    /// An answer that arrived through the UI, or `false` when the prompt was withdrawn (Stop, cancellation); nil
    /// while the question is still open.
    private func approvalOutcome(for prompt: PendingPrompt) -> Bool? {
        if let answer = approvalAnswer { approvalAnswer = nil; return answer }
        if approvalPrompt?.id != prompt.id { return false }
        return nil
    }

    private func answerApproval(_ approved: Bool) -> Bool {
        approvalPrompt = nil
        publish { $0.pending = nil }
        return approved
    }

    private func withdrawApproval(_ id: UUID) async {
        guard approvalPrompt?.id == id else { return }
        approvalPrompt = nil
        publish { $0.pending = nil }
        if let continuation = approvalContinuation { approvalContinuation = nil; continuation.resume(returning: false) }
        await output.stop()
        await listener.cancel()
    }

    /// UI buttons for a browser approval. Works while Friday is still asking aloud: the answer is kept, the
    /// question is cut short and `approve` returns it.
    public func answerBrowserApproval(_ approved: Bool) async {
        guard approvalPrompt != nil else { return }
        _ = answerApproval(approved)
        if let continuation = approvalContinuation {
            approvalContinuation = nil
            continuation.resume(returning: approved)
        } else {
            approvalAnswer = approved
            await output.stop()
            await listener.cancel()
        }
    }

    public func waitForUser(taskID: String, kind: String, message: String, url: String?) async -> Bool {
        let prompt = PendingPrompt(kind: .browserManual, question: message, options: ["Done", "Cancel"], token: taskID)
        manualPrompt = prompt
        manualAnswer = nil
        publish { $0.pending = prompt }
        setPhase(.waiting(message))
        return await withTaskCancellationHandler {
            var voice: Task<Void, Never>?
            if settings().speakResponses {
                let language = LanguageDetector.detect(message, fallback: .en)
                await output.speak(language.pick("I need you to finish that in the browser. Say “done” when you're ready.", "Necesito que lo completes tú en el navegador. Dime «listo» cuando termines."), language: language)
                if manualOutcome(for: prompt) == nil {
                    // Keep listening for the spoken "done" until the prompt is answered (by voice, button or Stop).
                    voice = Task { await self.listenForManualAnswer(prompt) }
                }
            }
            let result = await withCheckedContinuation { continuation in
                if let decided = manualOutcome(for: prompt) { continuation.resume(returning: decided); return }
                manualContinuation = continuation
            }
            voice?.cancel()
            return result
        } onCancel: {
            Task { await self.withdrawManual(prompt.id) }
        }
    }

    private func listenForManualAnswer(_ prompt: PendingPrompt) async {
        while !Task.isCancelled, manualPrompt?.id == prompt.id {
            let outcome = await listener.listen(from: listener.recorder.position, waitForSpeech: 20)
            guard manualPrompt?.id == prompt.id else { return }
            switch outcome {
            case .utterance(let capture):
                guard let answer = Self.spokenManualAnswer(capture.text) else { continue }
                append(TranscriptItem(role: .user, text: capture.text, source: "voice"))
                await answerManual(answer)
                return
            case .silence, .unintelligible:
                continue
            case .cancelled, .failed:
                return
            }
        }
    }

    private func manualOutcome(for prompt: PendingPrompt) -> Bool? {
        if let answer = manualAnswer { manualAnswer = nil; return answer }
        if manualPrompt?.id != prompt.id { return false }
        return nil
    }

    private func withdrawManual(_ id: UUID) async {
        guard manualPrompt?.id == id else { return }
        manualPrompt = nil
        publish { $0.pending = nil }
        if let continuation = manualContinuation { manualContinuation = nil; continuation.resume(returning: false) }
        await output.stop()
        await listener.cancel()
    }

    /// UI buttons while the browser waits for the user; also reached by the spoken "done"/"listo".
    public func answerManual(_ done: Bool) async {
        guard manualPrompt != nil else { return }
        manualPrompt = nil
        publish { $0.pending = nil }
        if let continuation = manualContinuation {
            manualContinuation = nil
            continuation.resume(returning: done)
        } else {
            manualAnswer = done
            await output.stop()
            await listener.cancel()
        }
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
