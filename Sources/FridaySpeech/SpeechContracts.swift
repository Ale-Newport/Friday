import Foundation
import FridayCore

// MARK: - Engine-independent speech contracts
//
// Friday's voice pipeline is built from three replaceable parts: a speech recognizer (microphone audio → text, with
// incremental results), a text-to-speech engine (text → audio chunks), and a voice-activity detector (when does an
// utterance end?). Concrete engines live in their own modules (`SherpaOnnxSpeech` for Kokoro and Silero, this module
// for Apple's SpeechAnalyzer and AVSpeechSynthesizer); the orchestrator only ever sees these protocols.

/// Mono PCM audio, float samples in [-1, 1].
public struct AudioChunk: Sendable {
    public var samples: [Float]
    public var sampleRate: Int
    public init(samples: [Float], sampleRate: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
    }
    public var duration: Double { Double(samples.count) / Double(sampleRate) }
}

/// Which language the recognizer should expect. `.auto` lets engines that can detect the language do so.
public enum SpeechLanguageHint: Sendable, Hashable {
    case auto
    case fixed(Language)
    /// The user speaks both; engines that cannot detect the language run both and pick the better result.
    case bilingual(primary: Language)
}

// MARK: Recognition

public struct TranscriptUpdate: Sendable, Hashable {
    public var text: String
    public var isFinal: Bool
    /// Detected or configured language, when known.
    public var language: Language?
    /// 0…1 when the engine reports one.
    public var confidence: Double?
    public init(text: String, isFinal: Bool, language: Language? = nil, confidence: Double? = nil) {
        self.text = text
        self.isFinal = isFinal
        self.language = language
        self.confidence = confidence
    }
}

/// One live transcription of one utterance. Feed audio as it arrives; read `updates` for volatile and final text;
/// call `finish()` when the utterance ended (silence) to obtain the final transcript.
public protocol SpeechRecognitionSession: AnyObject, Sendable {
    /// Microphone audio at any sample rate (the session resamples).
    func feed(_ chunk: AudioChunk)
    /// Volatile and final text, in order. Finishes after `finish()` or `cancel()`.
    var updates: AsyncStream<TranscriptUpdate> { get }
    /// Signals end of speech and returns the final transcript (may be empty).
    func finish() async -> TranscriptUpdate
    func cancel()
}

public protocol SpeechRecognizer: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// Whether the engine can be used right now (models installed, permission granted …).
    func availability() async -> EngineAvailability
    /// Loads models so the first utterance is not slowed down.
    func warmUp() async
    func makeSession(language: SpeechLanguageHint, vocabulary: [String]) async throws -> any SpeechRecognitionSession
}

/// Whether an engine can be used right now. The messages are shown as they are (Settings ▸ Voice, diagnostics), so
/// they exist in both languages.
public enum EngineAvailability: Sendable, Hashable {
    case available
    /// Usable once something is installed or granted; the text says what.
    case needsSetup(LocalizedText)
    /// Not usable on this Mac (or this build); the text says why.
    case unavailable(LocalizedText)
    public var isAvailable: Bool { self == .available }

    /// The message in `language`; nil when available.
    public func detail(in language: Language) -> String? {
        switch self {
        case .available: return nil
        case .needsSetup(let text), .unavailable(let text): return text.resolved(language)
        }
    }
}

// MARK: Synthesis

public struct TTSVoice: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var name: String
    /// BCP-47 language tag (`en-US`, `es-ES` …).
    public var language: String
    public var engineID: String
    public init(id: String, name: String, language: String, engineID: String) {
        self.id = id
        self.name = name
        self.language = language
        self.engineID = engineID
    }
    public var baseLanguage: Language? { Language(hint: language) }
}

public protocol TextToSpeechEngine: Sendable {
    var id: String { get }
    var displayName: String { get }
    func availability() async -> EngineAvailability
    func warmUp() async
    func voices() async -> [TTSVoice]
    /// Streams audio for `text`. `rate` 1.0 is normal speed. The stream ends when the whole text was synthesised;
    /// cancelling the consuming task stops synthesis promptly.
    func synthesize(_ text: String, voice: TTSVoice, rate: Float) -> AsyncThrowingStream<AudioChunk, any Error>
}

public enum SpeechError: Error, Sendable, Equatable, LocalizedError {
    case engineUnavailable(String)
    case synthesisFailed(String)
    case recognitionFailed(String)
    case permissionDenied(String)

    public var errorDescription: String? {
        switch self {
        case .engineUnavailable(let m): return "Speech engine unavailable: \(m)"
        case .synthesisFailed(let m): return "Could not synthesise speech: \(m)"
        case .recognitionFailed(let m): return "Could not recognise speech: \(m)"
        case .permissionDenied(let m): return "Permission denied: \(m)"
        }
    }
}

// MARK: Voice activity

public struct SpeechSegment: Sendable {
    /// Offset of the first sample, counted from the detector's reset, at 16 kHz.
    public var startSample: Int
    public var samples: [Float]
    public init(startSample: Int, samples: [Float]) {
        self.startSample = startSample
        self.samples = samples
    }
}

/// Decides when someone is speaking. Audio must be 16 kHz mono. Implementations are called from one thread at a time.
public protocol VoiceActivityDetector: AnyObject, Sendable {
    var id: String { get }
    /// Consumes audio. May be called with any chunk size.
    func accept(_ samples: [Float])
    /// True while speech is in progress (after `accept`).
    var isSpeechActive: Bool { get }
    /// Completed segments, oldest first (removed when returned).
    func popSegments() -> [SpeechSegment]
    /// Marks the end of the input: any open segment is closed.
    func flush()
    func reset()
}
