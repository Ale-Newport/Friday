import Foundation
import FridayCore
import FridaySpeech
import os

/// Chooses a voice for a language and speaks through the active engine, with immediate cancellation.
public actor SpeechOutput {
    static let logger = Logger(subsystem: "com.alejandro.friday", category: "speech-output")

    private var engines: [String: any TextToSpeechEngine]
    public let player: SpeechPlayer
    private let settings: @Sendable () -> VoiceSettings
    private var voiceCache: [String: [TTSVoice]] = [:]
    private var speaking: Task<Bool, Never>?
    public private(set) var isSpeaking = false

    public init(engines: [any TextToSpeechEngine], player: SpeechPlayer = SpeechPlayer(), settings: @escaping @Sendable () -> VoiceSettings) {
        self.engines = Dictionary(uniqueKeysWithValues: engines.map { ($0.id, $0) })
        self.player = player
        self.settings = settings
    }

    public func availableEngines() async -> [(id: String, name: String, availability: FridaySpeech.EngineAvailability)] {
        var result: [(String, String, FridaySpeech.EngineAvailability)] = []
        for engine in engines.values.sorted(by: { $0.id < $1.id }) { result.append((engine.id, engine.displayName, await engine.availability())) }
        return result
    }

    public func voices(engineID: String? = nil) async -> [TTSVoice] {
        let id = engineID ?? settings().ttsEngineID
        if let cached = voiceCache[id] { return cached }
        guard let engine = engines[id] else { return [] }
        let voices = await engine.voices()
        voiceCache[id] = voices
        return voices
    }

    /// The engine to use: the configured one when available, otherwise the Apple voices.
    func activeEngine() async -> (any TextToSpeechEngine)? {
        let preferred = settings().ttsEngineID
        if let engine = engines[preferred], await engine.availability().isAvailable { return engine }
        if let apple = engines["apple"], await apple.availability().isAvailable { return apple }
        return engines.values.first
    }

    func voice(for language: Language, engine: any TextToSpeechEngine) async -> TTSVoice? {
        let settings = settings()
        let voices = await voices(engineID: engine.id)
        let chosenID = language == .es ? settings.spanishVoiceID : settings.englishVoiceID
        if let chosenID, let voice = voices.first(where: { $0.id == chosenID }) { return voice }
        // Sensible defaults per engine.
        let defaults: [String] = engine.id == "kokoro"
            ? (language == .es ? ["ef_dora", "em_alex", "em_santa"] : ["af_heart", "af_bella", "bf_emma", "am_michael"])
            : []
        for id in defaults { if let voice = voices.first(where: { $0.id == id || $0.name == id }) { return voice } }
        return voices.first { $0.baseLanguage == language } ?? voices.first
    }

    public func warmUp() async {
        for engine in engines.values { await engine.warmUp() }
    }

    /// Speaks `text` in `language`. Returns true when the whole text was played (false when interrupted).
    @discardableResult
    public func speak(_ text: String, language: Language, onStart: (@Sendable () -> Void)? = nil) async -> Bool {
        await stop()
        let cleaned = SpokenText.clean(text)
        // The reply's own words choose the voice when they clearly are not in the conversation's language.
        let language = SpokenLanguage.forSynthesis(cleaned, declared: language)
        guard !cleaned.isEmpty, let engine = await activeEngine(), let voice = await voice(for: language, engine: engine) else { return false }
        let settings = settings()
        let player = player
        isSpeaking = true
        let task = Task { () -> Bool in
            await player.setVolume(settings.speakingVolume)
            let wrapped = AsyncThrowingStream<AudioChunk, any Error> { continuation in
                let forwarder = Task {
                    var firstChunk = true
                    do {
                        for try await chunk in engine.synthesize(cleaned, voice: voice, rate: settings.speakingRate) {
                            if firstChunk { firstChunk = false; onStart?() }
                            continuation.yield(chunk)
                        }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in forwarder.cancel() }
            }
            do {
                return try await player.play(wrapped)
            } catch {
                Self.logger.error("speech failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        speaking = task
        // Cancelling the caller (a barge-in group, a voice session that timed out) stops the playback: the player
        // would otherwise keep playing the buffers it already holds and `speak` would wait for them.
        let completed = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.stop(if: task) }
        }
        if speaking == task { speaking = nil; isSpeaking = false }
        return completed
    }

    /// Stops only while `task` is the utterance being spoken: a cancelled `speak` must not cut off a newer one.
    private func stop(if task: Task<Bool, Never>) async {
        guard speaking == task else { return }
        await stop()
    }

    /// Synthesises `text` with the active engine and writes it as a 16-bit mono WAV (for tests and `fridayctl
    /// --synthesize`): nothing is played. Returns the duration in seconds.
    @discardableResult
    public func synthesizeToFile(_ text: String, language: Language, url: URL, engineID: String? = nil) async throws -> Double {
        let cleaned = SpokenText.clean(text)
        guard !cleaned.isEmpty else { throw SpeechError.synthesisFailed("Nothing to say.") }
        let language = SpokenLanguage.forSynthesis(cleaned, declared: language)
        let engine: (any TextToSpeechEngine)?
        if let engineID { engine = engines[engineID] } else { engine = await activeEngine() }
        guard let engine, let voice = await voice(for: language, engine: engine) else { throw SpeechError.engineUnavailable("No voice for \(language.rawValue).") }
        var samples: [Float] = []
        var sampleRate = 24_000
        for try await chunk in engine.synthesize(cleaned, voice: voice, rate: settings().speakingRate) {
            sampleRate = chunk.sampleRate
            samples.append(contentsOf: chunk.samples)
        }
        guard !samples.isEmpty else { throw SpeechError.synthesisFailed("The engine produced no audio.") }
        try WAVWriter.write(samples: samples, sampleRate: sampleRate, to: url)
        return Double(samples.count) / Double(sampleRate)
    }

    public func stop() async {
        speaking?.cancel()
        speaking = nil
        await player.stop()
        isSpeaking = false
    }

    /// A short two-tone acknowledgement, generated locally (no file).
    public func chime() async {
        let rate = 24_000
        var samples: [Float] = []
        for (frequency, duration) in [(880.0, 0.09), (1174.66, 0.12)] {
            let count = Int(Double(rate) * duration)
            for index in 0..<count {
                let t = Double(index) / Double(rate)
                let envelope = min(1, Double(index) / 400) * min(1, Double(count - index) / 800)
                samples.append(Float(sin(2 * .pi * frequency * t) * 0.25 * envelope))
            }
        }
        let stream = AsyncThrowingStream<AudioChunk, any Error> { continuation in
            continuation.yield(AudioChunk(samples: samples, sampleRate: rate))
            continuation.finish()
        }
        await player.setVolume(settings().speakingVolume)
        _ = try? await player.play(stream)
    }
}

extension SpeechPlayer {
    func setVolume(_ volume: Float) { self.volume = volume }
}

/// Prepares assistant text for speech: strips markdown, links and code, shortens very long answers.
public enum SpokenText {
    public static func clean(_ text: String, maxCharacters: Int = 900) -> String {
        var result = text
        // Markdown links → their text; bare URLs → "link".
        result = result.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[*_`#>]+"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\((verified|verificado|unverified|sin verificar)[^)]*\)"#, with: "", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.count > maxCharacters {
            // Cut at a sentence boundary.
            let prefix = String(result.prefix(maxCharacters))
            if let end = prefix.lastIndex(where: { ".!?".contains($0) }) {
                result = String(prefix[...end])
            } else {
                result = prefix + "…"
            }
        }
        return result
    }
}

/// Minimal 16-bit PCM WAV writer (mono).
enum WAVWriter {
    static func write(samples: [Float], sampleRate: Int, to url: URL) throws {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(byteCount))
        data.reserveCapacity(data.count + byteCount)
        for sample in samples { append(Int16(max(-1, min(1, sample)) * 32767)) }
        try data.write(to: url, options: .atomic)
    }
}
