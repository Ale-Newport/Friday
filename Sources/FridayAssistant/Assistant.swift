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
    /// The voice reply being spoken while the model is still writing it (see `process`).
    private var voiceReply: VoiceReplyStream?

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
    /// the tool's title, so the transcript reads "Connect Chrome" rather than "web.connect". It queues like any
    /// other command of its session.
    @discardableResult
    public func execute(_ call: ToolCall, source: CommandSource = .app, session: String = "chat", speak: Bool? = nil) async -> EngineResponse {
        let title = registry.descriptor(for: call.tool)?.title ?? call.tool.rawValue
        append(TranscriptItem(role: .user, text: title, source: source.rawValue))
        let itemID = UUID()
        append(TranscriptItem(id: itemID, role: .assistant, text: "", source: source.rawValue, isStreaming: true))
        for command in running.values where command.session == session { command.task.cancel() }
        let engine = engine
        let registry = registry
        let me = self
        let previous = queueTail
        let commandID = UUID()
        let task = Task<EngineResponse, Never> {
            _ = await previous?.value
            if Task.isCancelled {
                return EngineResponse(input: title, language: .en, status: .cancelled, message: "Cancelled.")
            }
            await me.commandStarted()
            let (events, continuation) = AsyncStream<EngineEvent>.makeStream()
            @Sendable func consume() async {
                for await event in events { await me.handle(event, registry: registry, itemID: itemID) }
            }
            async let consumed: Void = consume()
            let response = await engine.execute(call, source: source, session: session) { continuation.yield($0) }
            continuation.finish()
            await consumed
            return response
        }
        queueTail = Task { _ = await task.value }
        running[commandID] = RunningCommand(session: session, task: task)
        let response = await task.value
        running[commandID] = nil
        publish { snapshot in
            if let index = snapshot.transcript.firstIndex(where: { $0.id == itemID }) {
                snapshot.transcript[index].text = response.message
                snapshot.transcript[index].response = response
                snapshot.transcript[index].isStreaming = false
            }
            snapshot.pending = Self.pendingPrompt(for: response)
            snapshot.currentSteps = []
        }
        settle()
        let shouldSpeak = speak ?? (settings().speakResponses && settings().speakTypedResponses)
        if shouldSpeak, !response.message.isEmpty, response.status != .cancelled {
            setPhase(.speaking(response.message))
            await output.speak(response.message, language: response.language)
            settle()
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
        if request.source == .voice, voiceReply != nil, voiceReply?.itemID == nil { voiceReply?.itemID = itemID }
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
            if voiceReply?.itemID == itemID { voiceReply?.receive(text) }
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

    /// Whole utterances that stop Friday (besides what `StopCommand` recognises word by word).
    static let stopPhrases: Set<String> = ["stop", "cancel", "cancel that", "never mind", "nevermind", "forget it", "forget what i just said", "para", "cancela", "cancela eso", "olvidalo", "dejalo", "nada", "deja de hablar", "para de hablar", "no sigas", "no hables mas", "ya basta", "es suficiente", "stop talking", "that's enough", "thats enough", "be quiet", "shut up", "no more"]
    static let endPhrases: Set<String> = ["that's all", "thats all", "that is all", "thanks that's all", "thanks thats all", "thank you", "thanks", "stop listening", "go to sleep", "eso es todo", "gracias", "gracias eso es todo", "deja de escuchar", "ya esta", "nada mas", "adios", "hasta luego"]
    /// "Wait": stop talking or acting and listen again, silently.
    static let holdPhrases: Set<String> = ["wait", "hold on", "one moment", "one second", "espera", "espera un momento", "un momento", "un segundo", "espera un segundo"]
    /// Words that can make up a stop command on their own ("para ya", "cállate, Jarvis", "ok stop").
    static let stopCoreWords: Set<String> = ["para", "parar", "pare", "paren", "detente", "deten", "alto", "basta", "calla", "callate", "callese", "callaos", "silencio", "cancela", "cancelar", "cancelalo", "dejalo", "olvidalo", "suficiente", "stop", "cancel", "quiet", "enough", "shut", "halt", "abort", "hush", "silence", "nevermind", "duermete", "sleep", "adios", "bye", "goodbye"]
    static let stopFillerWords: Set<String> = ["ya", "vale", "ok", "okay", "jarvis", "friday", "por", "favor", "porfa", "please", "hey", "oye", "eh", "ahora", "now", "de", "hablar", "talking", "it", "that", "eso", "up", "ya", "no", "sigas", "mas", "more", "ahi", "right", "there", "a", "dormir", "go", "to", "listening", "escuchar", "deja", "the", "si", "hombre", "tio", "anda", "venga", "ok", "bien", "vale", "gracias", "thanks"]
    /// Words the stop-command recogniser is told to expect.
    public static let stopVocabulary = ["para", "cállate", "basta", "detente", "silencio", "cancela", "stop", "shut up", "quiet", "enough", "déjalo", "olvídalo", "Jarvis"]

    enum StopKind { case stop, hold }

    /// Whether an utterance is a stop ("para", "cállate ya", "stop talking"), a hold ("espera"), or neither.
    /// "Para" as a preposition never qualifies: every word must be a stop or filler word ("para mañana" is not a stop).
    static func stopKind(_ text: String) -> StopKind? {
        let normalized = UtteranceNormalizer.normalize(text).text
        let key = phraseKey(normalized.isEmpty ? text : normalized)
        if holdPhrases.contains(key) { return .hold }
        if stopPhrases.contains(key) || endPhrases.contains(key) { return .stop }
        let words = key.split(separator: " ").map(String.init)
        guard !words.isEmpty, words.count <= 6 else { return nil }
        guard words.contains(where: { stopCoreWords.contains($0) }) else { return nil }
        return words.allSatisfy({ stopCoreWords.contains($0) || stopFillerWords.contains($0) }) ? .stop : nil
    }

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
        // While the user speaks the command: load the local model and open the online voice's connections.
        planner.prewarm()
        let output = output
        Task { await output.prepareForReply() }
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
        /// While a follow-up window is open (conversation mode, nothing asked): when it closes. Speech in the room that
        /// is not addressed to Friday is ignored and does not extend it, so a conversation nearby never keeps the
        /// session — and the wake word — busy.
        var followUpDeadline: ContinuousClock.Instant?
        latency.wakeToListenMs = milliseconds(activatedAt.duration(to: clock.now))
        while !Task.isCancelled {
            setPhase(.listening(partial: ""))
            let me = self
            // A follow-up must begin within its window: continuous talk in the room must not hold the session open.
            let giveUp = followUpDeadline.map { Double(clock.now.duration(to: $0).components.seconds) + 10 }
            let outcome = await listener.listen(from: startPosition, waitForSpeech: waitForSpeech, giveUpAfter: giveUp) { partial in
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
                if let deadline = followUpDeadline, snapshot.pending == nil,
                   !Self.isAddressedToFriday(capture.text, wakeWord: settings.wakeWord, variants: settings.wakeWordVariants) {
                    Self.logger.info("ignored a follow-up that is not addressed to Friday")
                    let remaining = clock.now.duration(to: deadline)
                    guard remaining > .milliseconds(500) else { return }
                    startPosition = listener.recorder.position
                    waitForSpeech = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
                    continue
                }
                if let heard = capture.language { language = heard }
                turn = await process(capture, latency: &latency, clock: clock)
            }
            reprompted = false
            switch turn {
            case .ended:
                Self.logger.info("voice session ended")
                return
            case .listenAgain(let resumeFrom, let required):
                guard required || settings.conversationMode, !Task.isCancelled else { return }
                publish { $0.inConversation = true }
                startPosition = resumeFrom ?? listener.recorder.position
                waitForSpeech = settings.conversationTimeoutSeconds
                // Every follow-up must be addressed to Friday — also the words that interrupted it, since people
                // talking near the Mac can trigger a barge-in — except an answer to a question Friday asked (the
                // filter skips those while `pending` is set).
                followUpDeadline = clock.now + .seconds(settings.conversationTimeoutSeconds)
                latency = LatencyReport()
            }
        }
    }

    private func process(_ capture: UtteranceCapture, latency: inout LatencyReport, clock: ContinuousClock) async -> TurnOutcome {
        if let ended = capture.speechEndedAt { latency.speechEndToTranscriptMs = milliseconds(ended.duration(to: capture.transcriptReadyAt)) }
        let settings = settings()
        let language = capture.language ?? LanguageDetector.detect(capture.text, fallback: .en)
        // "Para", "cállate", "gracias, eso es todo": stop everything and go back to waiting for the wake word, without
        // a word. "Espera": stop, and listen again, also silently.
        switch Self.stopKind(capture.text) {
        case .stop?:
            Self.logger.info("utterance is a stop command: ending the session")
            await interrupt()
            publish { $0.inConversation = false }
            return .ended
        case .hold?:
            await interrupt()
            return .listenAgain(from: nil, required: true)
        case nil:
            break
        }
        // Pending question? The engine resolves yes/no/option answers itself through the same session.
        append(TranscriptItem(role: .user, text: capture.text, source: "voice"))
        let started = clock.now
        let request = CommandRequest(text: capture.text, language: capture.language, source: .voice, session: "voice")
        let outcome = await runSpeakingAndWatching(request, latency: latency, language: language, speak: settings.speakResponses)
        latency.totalMs = milliseconds(started.duration(to: clock.now))
        let total = latency.totalMs
        publish { snapshot in
            var merged = snapshot.lastLatency ?? LatencyReport()
            merged.totalMs = total
            snapshot.lastLatency = merged
        }
        switch outcome {
        case .stopped(let heard):
            Self.logger.info("stopped by voice: \(heard, privacy: .private)")
            publish { $0.inConversation = false }
            return .ended
        case .interrupted(let position):
            // The words that interrupted Friday are already in the ring buffer: the next capture starts there.
            return .listenAgain(from: position, required: true)
        case .finished:
            // A spoken question needs a spoken answer: listen again even with conversation mode off.
            return .listenAgain(from: nil, required: snapshot.pending != nil)
        }
    }

    enum VoiceTurnResult: Sendable {
        case finished
        /// Barge-in: the user started talking over the reply at this recorder position.
        case interrupted(Int)
        /// A stop command was heard while the command ran or the reply was spoken.
        case stopped(String)
    }

    private enum TurnEvent: Sendable {
        case response(EngineResponse)
        case speech(Int?)
        case stopHeard(String)
        case idle
    }

    /// Runs a voice command and speaks its reply, with three things alongside:
    ///  * the reply is spoken while the model is still writing it (phrase by phrase, see `VoiceReplyStream`);
    ///  * a stop command ("para", "cállate", "stop") cancels the command and the speech at any moment;
    ///  * a command still working after a few seconds gets a short "un momento", so silence never feels like a hang.
    private func runSpeakingAndWatching(_ request: CommandRequest, latency: LatencyReport, language: Language, speak: Bool) async -> VoiceTurnResult {
        let (segments, continuation) = AsyncStream<String>.makeStream()
        let reply = VoiceReplyStream(continuation: continuation)
        voiceReply = reply
        defer { voiceReply = nil }
        let listener = listener
        let me = self
        let watchFrom = listener.recorder.position
        let acknowledge = settings().acknowledgeLongTasks
        let watch = settings().stopWatcherEnabled
        return await withTaskGroup(of: TurnEvent.self) { group in
            group.addTask { .response(await me.run(request, voiceLatency: latency)) }
            if watch {
                group.addTask {
                    let heard = await listener.watchForCommand(from: watchFrom, language: language) { text in Assistant.stopKind(text) == .stop }
                    return heard.map(TurnEvent.stopHeard) ?? .idle
                }
            }
            if speak {
                group.addTask { .speech(await me.speakWithBargeIn(segments: segments, language: language)) }
                if acknowledge {
                    group.addTask {
                        try? await Task.sleep(for: .seconds(3))
                        if !Task.isCancelled { await me.acknowledgeIfStillWorking(language: language) }
                        return .idle
                    }
                }
            } else {
                continuation.finish()
            }
            var result: VoiceTurnResult = .finished
            var responded = false
            var spoke = !speak
            /// A reply that arrived after the streamed speech had already ended (a question Friday asked aloud
            /// mid-task — a browser approval — takes over the voice and ends that stream): spoken on its own.
            var unspoken: (text: String, language: Language)?
            while let event = await group.next() {
                switch event {
                case .response(let response):
                    Self.logger.info("turn: response (\(response.status.rawValue, privacy: .public))")
                    responded = true
                    lastSpokenReply = response.message
                    if response.status == .cancelled || response.message.isEmpty || !speak {
                        voiceReply?.finish(with: nil)
                    } else if spoke {
                        unspoken = (response.message, response.language)
                    } else {
                        setPhase(.speaking(response.message))
                        voiceReply?.finish(with: response.message)
                    }
                case .speech(let interruptedAt):
                    Self.logger.info("turn: speech ended\(interruptedAt == nil ? "" : " by a barge-in", privacy: .public)")
                    spoke = true
                    if let interruptedAt {
                        result = .interrupted(interruptedAt)
                        // The user is talking over Friday: what is still running for this session yields to them.
                        for command in running.values where command.session == "voice" { command.task.cancel() }
                    }
                case .stopHeard(let text):
                    Self.logger.info("turn: stop command heard")
                    await interrupt()
                    voiceReply?.finish(with: nil)
                    result = .stopped(text)
                case .idle:
                    break
                }
                if case .stopped = result { break }
                if case .interrupted = result { break }
                if responded, spoke { break }
            }
            group.cancelAll()
            if case .finished = result, let unspoken {
                setPhase(.speaking(unspoken.text))
                if let at = await speakWithBargeIn(text: unspoken.text, language: unspoken.language) { result = .interrupted(at) }
            }
            return result
        }
    }

    private func speakWithBargeIn(text: String, language: Language) async -> Int? {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        for phrase in SpeechSegmenter.segments(SpokenText.clean(text)) { continuation.yield(phrase) }
        continuation.finish()
        return await speakWithBargeIn(segments: stream, language: language)
    }

    /// "Un momento" when the command is still thinking or acting and nothing has been said yet.
    private func acknowledgeIfStillWorking(language: Language) {
        guard let reply = voiceReply, !reply.hasSpoken, !running.isEmpty, snapshot.pending == nil else { return }
        switch snapshot.phase {
        case .thinking, .acting:
            reply.say(language.pick("One moment.", "Un momento."))
        default:
            break
        }
    }

    /// Speaks the phrases as they arrive. With barge-in enabled, sustained speech clearly louder than the playback the
    /// microphone picks up stops the speech; the detector calibrates on the playback itself, so it only starts once
    /// the first audio chunk plays. Returns the recorder position where the interruption began, or nil when the reply
    /// was spoken to the end.
    private func speakWithBargeIn(segments: AsyncStream<String>, language: Language) async -> Int? {
        let output = output
        let listener = listener
        let me = self
        let onFirstAudio: @Sendable () -> Void = { Task { await me.speechStarted() } }
        guard settings().bargeInEnabled else {
            await output.speak(segments: segments, language: language, onStart: onFirstAudio)
            return nil
        }
        let (playbackStarted, startSignal) = AsyncStream<Void>.makeStream()
        return await withTaskGroup(of: Int?.self) { group in
            group.addTask {
                await output.speak(segments: segments, language: language) { onFirstAudio(); startSignal.yield() }
                startSignal.finish()
                return nil
            }
            group.addTask {
                var iterator = playbackStarted.makeAsyncIterator()
                guard await iterator.next() != nil else { return nil }  // nothing was played
                // Louder and longer than for a normal endpoint while Friday talks (Jarvis-Live's echo rule): its own
                // voice through the speakers must not count as the user.
                return await listener.waitForSpeech(timeout: 120, minimumDuration: 0.5, calibration: 0.8, margin: 9)
            }
            let first = await group.next() ?? nil
            // The loser must end inside the group: a stopped player returns from `speak` at once, and a cancelled
            // detector returns within one 50 ms tick. Otherwise the implicit wait would speak the whole reply.
            if first != nil { await output.stop() }
            group.cancelAll()
            return first
        }
    }

    private func speechStarted() {
        if case .speaking = snapshot.phase { return }
        setPhase(.speaking(voiceReply?.spokenText ?? ""))
    }

}

/// The reply of one voice command, spoken while it is being written.
///
/// The planner streams the model's text as it arrives (`EngineEvent.responseText`, the whole text so far, restarting
/// on each model round). Complete phrases go to the voice at once; the first is held back until it is long enough
/// that it cannot be a bare "Done." claim the planner may still reject. When the final reply arrives, whatever it adds
/// to what was streamed is spoken; a final reply that differs from the stream (a tool result summarised) is spoken
/// whole after it. A reply that never streamed is simply spoken whole.
final class VoiceReplyStream: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<String>.Continuation
    private var segmenter = SpeechSegmenter.Incremental()
    /// The model's text in the current round, the phrases of it already handed to the voice, and those held back.
    private var roundText = ""
    private var roundEmitted = ""
    private var held: [String] = []
    private var streamOpen = false
    private var emitted = 0
    private var finished = false
    var itemID: UUID?
    /// Streamed text shorter than this is not spoken until the reply is final.
    static let minimumStreamedCharacters = 40

    init(continuation: AsyncStream<String>.Continuation) { self.continuation = continuation }

    var hasSpoken: Bool { lock.withLock { emitted > 0 } }
    var spokenText: String { lock.withLock { roundEmitted } }

    /// The model's text so far (this round; a text that does not continue the previous one starts a new round).
    func receive(_ text: String) {
        lock.withLock {
            guard !finished else { return }
            if !text.hasPrefix(roundText) {
                // A new model round (a preamble, then tool results, then the answer): what was held of the old round
                // is dropped; what was already said stays said.
                segmenter = SpeechSegmenter.Incremental()
                roundText = ""
                roundEmitted = ""
                held = []
                streamOpen = false
            }
            let delta = String(text.dropFirst(roundText.count))
            roundText = text
            held += segmenter.append(delta.replacingOccurrences(of: #"[*_`#>]+"#, with: "", options: .regularExpression))
            if !streamOpen {
                guard roundText.count >= Self.minimumStreamedCharacters else { return }
                streamOpen = true
            }
            for phrase in held { yield(phrase); roundEmitted += (roundEmitted.isEmpty ? "" : " ") + phrase }
            held = []
        }
    }

    /// Something to say before the reply (an acknowledgement).
    func say(_ phrase: String) {
        lock.withLock { if !finished { yield(phrase) } }
    }

    /// The final reply (nil: nothing more to say). Ends the stream.
    func finish(with message: String?) {
        lock.withLock {
            guard !finished else { return }
            finished = true
            defer { continuation.finish() }
            guard let message else { return }
            let final = SpokenText.clean(message)
            let rest: String
            if !roundEmitted.isEmpty, Self.key(final).hasPrefix(Self.key(roundEmitted)) {
                // The stream was this reply: say only what it has not said yet.
                rest = Self.remainder(of: final, after: roundEmitted)
            } else {
                rest = final
            }
            for phrase in SpeechSegmenter.segments(rest) { yield(phrase) }
        }
    }

    private func yield(_ phrase: String) {
        continuation.yield(phrase)
        emitted += 1
    }

    static func key(_ text: String) -> String {
        KeywordRouter.fold(text).filter { $0.isLetter || $0.isNumber }
    }

    /// The part of `final` after the words of `streamed` (compared on letters and digits only).
    static func remainder(of final: String, after streamed: String) -> String {
        let target = key(streamed)
        guard !target.isEmpty else { return final }
        var matched = 0
        var index = final.startIndex
        let targetCharacters = Array(target)
        while index < final.endIndex, matched < targetCharacters.count {
            let folded = KeywordRouter.fold(String(final[index])).filter { $0.isLetter || $0.isNumber }
            for character in folded where matched < targetCharacters.count && character == targetCharacters[matched] { matched += 1 }
            index = final.index(after: index)
        }
        // Only the leading punctuation the stream already said (", " after "Canberra"); the end stays as it is.
        let rest = final[index...].drop { $0.isWhitespace || ".,;:".contains($0) }
        return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Verbs that open a request, in both languages ("abre…", "pon…", "dime…", "open…", "tell me…").
    static let requestVerbs: Set<String> = [
        "abre", "abreme", "cierra", "pon", "ponme", "quita", "busca", "buscame", "dime", "dame", "crea", "anade", "agrega", "recuerdame", "recuerda",
        "apunta", "anota", "envia", "enviale", "manda", "mandale", "escribe", "escribele", "llama", "reproduce", "sube", "baja", "borra", "elimina",
        "enciende", "apaga", "activa", "desactiva", "muestra", "muestrame", "ensename", "explica", "explicame", "cuentame", "traduce", "calcula",
        "haz", "hazme", "mira", "comprueba", "revisa", "lee", "leeme", "programa", "cambia", "guarda", "descarga", "repite", "continua", "sigue",
        "open", "close", "quit", "play", "pause", "search", "find", "look", "tell", "give", "create", "add", "remind", "remember", "note", "send",
        "email", "text", "message", "call", "turn", "switch", "show", "explain", "translate", "calculate", "make", "set", "check", "read",
        "schedule", "change", "save", "download", "repeat", "continue", "write", "delete", "remove", "skip", "start",
    ]
    static let leadingFillers: Set<String> = ["y", "and", "vale", "ok", "okay", "ahora", "now", "tambien", "also", "oye", "hey", "porfa", "please", "luego", "then", "bueno", "so", "entonces"]

    /// Whether a follow-up heard without the wake word is meant for Friday: it names Friday, is a stop, a question, a
    /// request (starts with a request verb) or clearly belongs to one of Friday's areas. "Sí, tengo los dos un 8,75" or
    /// "Marc y Albert" from a conversation in the room are not.
    static func isAddressedToFriday(_ text: String, wakeWord: String, variants: [String]) -> Bool {
        if WakeWordMatcher.matches(text, wakeWord: wakeWord, variants: variants) { return true }
        if stopKind(text) != nil { return true }
        if text.contains("?") { return true }
        if KeywordRouter.route(text) != nil { return true }
        let words = phraseKey(text).split(separator: " ").map(String.init)
        // A question without its marks (the recogniser often drops them). A bare "que"/"como" starts statements as
        // often as questions ("que estaba en el gimnasio"), so only with a word that makes it a question.
        let questionWords: Set<String> = ["what", "whats", "who", "when", "where", "why", "how", "which", "cuando", "donde", "cual", "cuanto", "cuanta", "cuantos", "cuantas", "quien", "porque"]
        let afterQue: Set<String> = ["hora", "tiempo", "dia", "tal", "tengo", "hay", "es", "son", "significa", "pasa", "hace", "opinas", "piensas", "me", "te", "puedo", "puedes"]
        let start = Array(words.drop { leadingFillers.contains($0) })
        if let first = start.first {
            if questionWords.contains(first) { return true }
            if ["que", "como"].contains(first), start.count > 1, afterQue.contains(start[1]) { return true }
            if first == "por", start.count > 1, start[1] == "que" { return true }
        }
        for word in words.prefix(3) {
            if requestVerbs.contains(word) { return true }
            if !leadingFillers.contains(word) { break }
        }
        return false
    }

    /// A spoken yes/no for a browser approval, or nil when the utterance is neither.
    static func spokenApproval(_ text: String) -> Bool? {
        if let decision = ReplyClassifier.classify(text, optionCount: 0) {
            switch decision {
            case .confirm: return true
            case .cancel: return false
            case .choose, .answer: break
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
        if case .waiting = snapshot.phase { setPhase(.thinking) }
        return approved
    }

    private func withdrawApproval(_ id: UUID) async {
        guard approvalPrompt?.id == id else { return }
        approvalPrompt = nil
        publish { $0.pending = nil }
        if case .waiting = snapshot.phase { setPhase(.idle) }
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
        if case .waiting = snapshot.phase { setPhase(.idle) }
        if let continuation = manualContinuation { manualContinuation = nil; continuation.resume(returning: false) }
        await output.stop()
        await listener.cancel()
    }

    /// UI buttons while the browser waits for the user; also reached by the spoken "done"/"listo".
    public func answerManual(_ done: Bool) async {
        guard manualPrompt != nil else { return }
        manualPrompt = nil
        publish { $0.pending = nil }
        if case .waiting = snapshot.phase { setPhase(.thinking) }
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
