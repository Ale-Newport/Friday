import Foundation
import FridayCore
import FridayIntelligence
import FridaySpeech
@testable import FridayAssistant

// Test doubles for the voice pipeline: a recogniser that answers from a script, a text-to-speech engine that only
// records what it was asked to say, a scriptable interpreter and a mock integration. The microphone recorder and
// the energy voice-activity detector are the real ones, fed with synthetic audio.

/// 16 kHz mono audio: `amplitude` 0.3 reads as speech to the energy detector, 0.001 as a quiet room.
func tone(seconds: Double, amplitude: Float, frequency: Float = 220) -> [Float] {
    (0..<Int(seconds * 16_000)).map { i in amplitude * sin(Float(i) * 2 * .pi * frequency / 16_000) }
}

func feed(_ recorder: MicrophoneRecorder, _ samples: [Float]) {
    samples.withUnsafeBufferPointer { recorder.tap($0, sampleRate: 16_000) }
}

/// One spoken utterance as the detector sees it: a burst of sound followed by enough silence to end it.
func utteranceAudio(speechSeconds: Double = 0.6, silenceSeconds: Double = 0.8) -> [Float] {
    tone(seconds: speechSeconds, amplitude: 0.3) + tone(seconds: silenceSeconds, amplitude: 0.001)
}

func testDetector() -> any VoiceActivityDetector {
    EnergyVoiceActivityDetector(minimumSilence: 0.3, minimumSpeech: 0.2)
}

/// Settings the tests can change between calls.
final class SettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: VoiceSettings
    init(_ value: VoiceSettings = SettingsBox.fast()) { self.value = value }
    var current: VoiceSettings {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
    func update(_ change: (inout VoiceSettings) -> Void) { lock.withLock { change(&value) } }

    /// Short timeouts so a suite runs in seconds; no chime, no barge-in unless a test turns it on.
    static func fast() -> VoiceSettings {
        var settings = VoiceSettings()
        settings.noSpeechTimeoutSeconds = 0.5
        settings.conversationTimeoutSeconds = 0.6
        settings.endpointSilenceSeconds = 0.3
        settings.maxUtteranceSeconds = 6
        settings.acknowledgementStyle = .silent
        settings.bargeInEnabled = false
        settings.speakResponses = true
        settings.spokenLanguage = .english
        settings.recognizerID = "scripted"
        // The watcher makes its own recognition sessions, which would take scripted answers meant for the main
        // listener; tests that exercise it turn it on.
        settings.stopWatcherEnabled = false
        settings.verifyWakeWord = false
        settings.acknowledgeLongTasks = false
        return settings
    }
}

// MARK: Recognition

final class ScriptedSession: SpeechRecognitionSession, @unchecked Sendable {
    private let lock = NSLock()
    private let transcript: TranscriptUpdate
    private(set) var fedSamples = 0
    private let continuation: AsyncStream<TranscriptUpdate>.Continuation
    let updates: AsyncStream<TranscriptUpdate>
    let vocabulary: [String]

    init(transcript: TranscriptUpdate, vocabulary: [String]) {
        self.transcript = transcript
        self.vocabulary = vocabulary
        var continuation: AsyncStream<TranscriptUpdate>.Continuation!
        updates = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    var samplesFed: Int { lock.withLock { fedSamples } }
    func feed(_ chunk: AudioChunk) { lock.withLock { fedSamples += chunk.samples.count } }
    func finish() async -> TranscriptUpdate { continuation.finish(); return transcript }
    func cancel() { continuation.finish() }
}

/// Answers each session from the next script entry (an empty string: speech heard but no words).
final class ScriptedRecognizer: SpeechRecognizer, @unchecked Sendable {
    let id = "scripted"
    let displayName = "Scripted"
    private let lock = NSLock()
    private var script: [(text: String, language: Language?)]
    private(set) var sessions: [ScriptedSession] = []
    /// Called with the session index each time a session is created (tests feed the next utterance then).
    var onSession: (@Sendable (Int) -> Void)?

    init(_ script: [String] = [], language: Language? = nil) {
        self.script = script.map { ($0, language) }
    }

    func push(_ text: String, language: Language? = nil) { lock.withLock { script.append((text, language)) } }
    var createdSessions: [ScriptedSession] { lock.withLock { sessions } }

    func availability() async -> EngineAvailability { .available }
    func warmUp() async {}

    func makeSession(language: SpeechLanguageHint, vocabulary: [String]) async throws -> any SpeechRecognitionSession {
        let (entry, index): ((text: String, language: Language?), Int) = lock.withLock {
            let next = script.isEmpty ? ("", nil) : script.removeFirst()
            return (next, sessions.count)
        }
        let session = ScriptedSession(transcript: TranscriptUpdate(text: entry.text, isFinal: true, language: entry.language, confidence: 0.9), vocabulary: vocabulary)
        lock.withLock { sessions.append(session) }
        onSession?(index)
        return session
    }
}

// MARK: Synthesis

/// Records what Friday says. Each utterance takes the next entry of `delays` to "play" (zero once the list is
/// used up) unless it is stopped; one empty chunk is yielded first so `onStart` fires without touching the audio
/// device.
final class RecordingSpeechEngine: TextToSpeechEngine, @unchecked Sendable {
    let id = "recording"
    let displayName = "Recording"
    private let lock = NSLock()
    private var texts: [String] = []
    private var _delays: [Duration] = []
    var delays: [Duration] {
        get { lock.withLock { _delays } }
        set { lock.withLock { _delays = newValue } }
    }

    func availability() async -> EngineAvailability { .available }
    func warmUp() async {}
    func voices() async -> [TTSVoice] {
        [TTSVoice(id: "en", name: "en", language: "en-US", engineID: id), TTSVoice(id: "es", name: "es", language: "es-ES", engineID: id)]
    }

    var spoken: [String] { lock.withLock { texts } }

    func synthesize(_ text: String, voice: TTSVoice, rate: Float) -> AsyncThrowingStream<AudioChunk, any Error> {
        let delay: Duration = lock.withLock {
            texts.append(text)
            return _delays.isEmpty ? .zero : _delays.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(AudioChunk(samples: [], sampleRate: 16_000))
                if delay > .zero { try await Task.sleep(for: delay) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: Engine side

/// Interprets by text: "echo …" runs the echo tool, "slow <ms>" the sleeping tool, "delete …" the destructive tool
/// (which asks for confirmation first); anything else is a conversational reply.
struct TestInterpreter: CommandInterpreting {
    let identifier = "test"
    func interpret(_ request: InterpretationRequest) async throws -> Interpretation {
        let text = request.text.lowercased()
        func plan(_ tool: ToolName, _ arguments: JSONObject) -> Interpretation {
            .plan(ToolPlan(steps: [ToolCall(tool: tool, arguments: arguments, sourceText: request.text)], language: request.language, interpreter: identifier))
        }
        if text.hasPrefix("echo ") { return plan("mock.echo", ["text": .string(String(request.text.dropFirst(5)))]) }
        if text.hasPrefix("slow") { return plan("mock.slow", ["ms": .int(Int(text.dropFirst(4).trimmingCharacters(in: .whitespaces)) ?? 500)]) }
        if text.hasPrefix("delete") { return plan("mock.delete", ["what": .string(request.text)]) }
        return .reply("Reply to \(request.text)")
    }
}

final class MockTools: AppIntegration, @unchecked Sendable {
    let id: IntegrationID = "mock"
    let displayName = LocalizedText("Mock")
    let summary = LocalizedText("mock")
    let symbolName = "puzzlepiece"
    let permissionRequirements: [PermissionRequirement] = []
    private let lock = NSLock()
    private var _calls: [(tool: String, confirmed: Bool)] = []
    var calls: [(tool: String, confirmed: Bool)] { lock.withLock { _calls } }

    var tools: [ToolDescriptor] {
        [
            ToolDescriptor(name: "mock.echo", integration: id, title: "Echo", summary: "echo", parameters: [.string("text", "text")], safety: .readOnly),
            ToolDescriptor(name: "mock.slow", integration: id, title: "Slow", summary: "sleeps", parameters: [.integer("ms", "milliseconds")], safety: .readOnly, timeout: 20),
            ToolDescriptor(name: "mock.delete", integration: id, title: "Delete", summary: "deletes", parameters: [.string("what", "what")], safety: .destructive),
        ]
    }

    func status() async -> IntegrationStatus { IntegrationStatus(state: .ready) }
    func authorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }
    func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }

    func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
        lock.withLock { _calls.append((call.descriptor.name.rawValue, context.isConfirmed)) }
        switch call.descriptor.name.rawValue {
        case "mock.echo":
            return .done(ToolOutput(message: "Echo: \(call.string("text") ?? "")", verification: .notApplicable))
        case "mock.slow":
            try await Task.sleep(for: .milliseconds(call.int("ms") ?? 500))
            return .done(ToolOutput(message: "Slow done.", verification: .notApplicable))
        case "mock.delete":
            if context.isConfirmed { return .done(ToolOutput(message: "Deleted.", verification: .verified("gone"))) }
            return .confirm(ConfirmationRequest(prompt: "Delete it?", call: call.call, destructive: true))
        default:
            throw JarvisError.validation([ValidationIssue(.unknownTool, "unknown")])
        }
    }
}

// MARK: The assistant under test

/// Everything an assistant needs, with the real engine, recorder and detector and scripted speech ends.
final class AssistantHarness: @unchecked Sendable {
    let settings: SettingsBox
    let recorder = MicrophoneRecorder(seconds: 30)
    let recognizer: ScriptedRecognizer
    let tts = RecordingSpeechEngine()
    let tools = MockTools()
    let engine: ActionEngine
    let listener: VoiceListener
    let output: SpeechOutput
    let assistant: Assistant

    init(script: [String] = [], language: Language? = nil, settings: VoiceSettings = SettingsBox.fast()) {
        let box = SettingsBox(settings)
        self.settings = box
        recognizer = ScriptedRecognizer(script, language: language)
        let registry = ToolRegistry(integrations: [tools])
        engine = ActionEngine(registry: registry, interpreter: TestInterpreter(), settings: InMemorySettings())
        let secrets = InMemorySecretStore()
        let auth = ChatGPTAuthService(secrets: secrets, defaults: UserDefaults(suiteName: "friday.assistant-tests.\(UUID().uuidString)")!)
        let intelligence = IntelligenceSettings()
        let providers = ProviderRegistry(auth: auth, secrets: secrets, settings: { intelligence })
        let planner = FridayPlanner(providers: providers, router: IntentRouter(), settings: { intelligence })
        listener = VoiceListener(recorder: recorder, recognizers: [recognizer], detector: { testDetector() }, settings: { box.current })
        output = SpeechOutput(engines: [tts], settings: { box.current })
        assistant = Assistant(engine: engine, registry: registry, planner: planner, listener: listener, output: output, web: nil, settings: { box.current })
    }

    /// Puts one spoken utterance into the microphone buffer (heard by a listen that starts at or before it).
    func speakIntoMicrophone(speechSeconds: Double = 0.6) {
        feed(recorder, utteranceAudio(speechSeconds: speechSeconds))
    }
}

func milliseconds(since start: ContinuousClock.Instant) -> Int {
    let (seconds, attoseconds) = start.duration(to: .now).components
    return Int(seconds * 1000 + attoseconds / 1_000_000_000_000_000)
}
