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

    /// The engines for the Settings picker, with "Automatic" (the most natural voice available, with fallbacks) first.
    public func availableEngines() async -> [(id: String, name: String, availability: FridaySpeech.EngineAvailability)] {
        var result: [(String, String, FridaySpeech.EngineAvailability)] = [(Self.automaticID, "Automatic (online neural voice, local fallback)", .available)]
        for engine in engines.values.sorted(by: { $0.id < $1.id }) { result.append((engine.id, engine.displayName, await engine.availability())) }
        return result
    }

    /// The pseudo-engine that picks per language and falls back phrase by phrase.
    public static let automaticID = "auto"

    public func voices(engineID: String? = nil) async -> [TTSVoice] {
        var id = engineID ?? settings().ttsEngineID
        if id == Self.automaticID { id = "neural" }
        if let cached = voiceCache[id] { return cached }
        guard let engine = engines[id] else { return [] }
        let voices = await engine.voices()
        voiceCache[id] = voices
        return voices
    }

    /// The engines to try for `language`, best first. A phrase that one engine cannot say (offline, model missing)
    /// is said by the next, so Friday never goes mute because the network did.
    func engineChain(for language: Language) -> [any TextToSpeechEngine] {
        let preferred = settings().ttsEngineID
        let order: [String]
        switch preferred {
        case Self.automaticID, "neural":
            order = language == .es ? ["neural", "piper", "kokoro", "apple"] : ["neural", "kokoro", "apple"]
        case "piper":
            order = language == .es ? ["piper", "kokoro", "apple"] : ["kokoro", "apple"]
        default:
            order = [preferred, "kokoro", "apple"]
        }
        var seen: Set<String> = []
        // Any other registered engine is a last resort: a voice nobody listed must never leave Friday mute.
        let rest = engines.keys.sorted().filter { !order.contains($0) }
        return (order + rest).compactMap { id in seen.insert(id).inserted ? engines[id] : nil }
    }

    /// The first engine of the chain that is available now (diagnostics, previews).
    func activeEngine(for language: Language = .en) async -> (any TextToSpeechEngine)? {
        for engine in engineChain(for: language) where await engine.availability().isAvailable { return engine }
        return engines.values.first
    }

    func voice(for language: Language, engine: any TextToSpeechEngine) async -> TTSVoice? {
        let settings = settings()
        let voices = await voices(engineID: engine.id)
        let chosenID = language == .es ? settings.spanishVoiceID : settings.englishVoiceID
        if let chosenID, let voice = voices.first(where: { $0.id == chosenID }) { return voice }
        // Sensible defaults per engine.
        let defaults: [String]
        switch engine.id {
        case "kokoro": defaults = language == .es ? ["em_alex", "ef_dora", "em_santa"] : ["af_heart", "af_bella", "bf_emma", "am_michael"]
        case "neural": defaults = language == .es ? ["es-ES-AlvaroNeural", "es-ES-ElviraNeural"] : ["en-GB-RyanNeural", "en-US-AndrewNeural"]
        default: defaults = []
        }
        for id in defaults { if let voice = voices.first(where: { $0.id == id || $0.name == id }) { return voice } }
        return voices.first { $0.baseLanguage == language }
    }

    public func warmUp() async {
        for engine in engines.values { await engine.warmUp() }
    }

    /// Opens the online voice's connections (called on the wake word, so the reply's first phrase does not pay the
    /// TLS handshake). Cheap when they are already open.
    public func prepareForReply() async {
        guard [Self.automaticID, "neural"].contains(settings().ttsEngineID), let neural = engines["neural"] else { return }
        await neural.warmUp()
    }

    /// Speaks `text` in `language`. Returns true when the whole text was played (false when interrupted).
    @discardableResult
    public func speak(_ text: String, language: Language, onStart: (@Sendable () -> Void)? = nil) async -> Bool {
        let segments = SpeechSegmenter.segments(SpokenText.clean(text))
        let (stream, continuation) = AsyncStream<String>.makeStream()
        for segment in segments { continuation.yield(segment) }
        continuation.finish()
        return await speak(segments: stream, language: language, onStart: onStart)
    }

    /// Speaks phrases as they arrive (a reply still being generated). Each phrase is synthesised as soon as it is
    /// received, so the next one is ready while the current one plays; each is voiced by the first engine of the
    /// chain that can say it. Returns true when everything was played.
    @discardableResult
    public func speak(segments: AsyncStream<String>, language: Language, onStart: (@Sendable () -> Void)? = nil) async -> Bool {
        await stop()
        let settings = settings()
        let player = player
        let me = self
        isSpeaking = true
        let task = Task { () -> Bool in
            await player.setVolume(settings.speakingVolume)
            let audio = AsyncThrowingStream<AudioChunk, any Error> { continuation in
                let producer = Task {
                    // Synthesis starts the moment a phrase arrives (into a buffer); playback order is the phrase order,
                    // and each phrase plays from its first chunk on, while the following ones are being prepared.
                    let (jobs, jobQueue) = AsyncStream<AsyncStream<AudioChunk>>.makeStream()
                    let feeder = Task {
                        for await segment in segments {
                            let text = SpokenText.forVoice(segment, language: SpokenLanguage.forSynthesis(segment, declared: language))
                            guard !text.isEmpty else { continue }
                            let phraseLanguage = SpokenLanguage.forSynthesis(text, declared: language)
                            jobQueue.yield(await me.phraseAudio(text, language: phraseLanguage, rate: settings.speakingRate))
                        }
                        jobQueue.finish()
                    }
                    var started = false
                    outer: for await job in jobs {
                        for await chunk in job {
                            if Task.isCancelled { break outer }
                            if !started { started = true; onStart?() }
                            continuation.yield(chunk)
                        }
                    }
                    feeder.cancel()
                    continuation.finish()
                }
                continuation.onTermination = { _ in producer.cancel() }
            }
            do {
                return try await player.play(audio)
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

    /// One phrase's audio, buffered as it is produced, by the first engine of the chain that produces audio for it
    /// (an engine that fails before its first chunk — offline, model missing — hands the phrase to the next one).
    func phraseAudio(_ text: String, language: Language, rate: Float) -> AsyncStream<AudioChunk> {
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        let chain = engineChain(for: language)
        let me = self
        let task = Task {
            for engine in chain {
                if Task.isCancelled { break }
                guard await engine.availability().isAvailable, let voice = await me.voice(for: language, engine: engine) else { continue }
                var produced = false
                do {
                    for try await chunk in engine.synthesize(text, voice: voice, rate: rate) {
                        produced = true
                        continuation.yield(chunk)
                    }
                } catch {
                    Self.logger.info("\(engine.id, privacy: .public) could not say a phrase (\(error.localizedDescription, privacy: .public)); trying the next voice")
                }
                if produced { break }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// One phrase, fully synthesised (files, tests).
    func synthesizePhrase(_ text: String, language: Language, rate: Float) async -> [AudioChunk] {
        var chunks: [AudioChunk] = []
        for await chunk in phraseAudio(text, language: language, rate: rate) { chunks.append(chunk) }
        return chunks
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
        let spoken = SpokenText.forVoice(cleaned, language: language)
        var samples: [Float] = []
        var sampleRate = 24_000
        if let engineID {
            guard let engine = engines[engineID], let voice = await voice(for: language, engine: engine) else { throw SpeechError.engineUnavailable("No voice for \(language.rawValue).") }
            for try await chunk in engine.synthesize(spoken, voice: voice, rate: settings().speakingRate) {
                sampleRate = chunk.sampleRate
                samples.append(contentsOf: chunk.samples)
            }
        } else {
            for chunk in await synthesizePhrase(spoken, language: language, rate: settings().speakingRate) {
                // Phrases from different engines may differ in rate; a file holds one rate (tests use one engine).
                if samples.isEmpty { sampleRate = chunk.sampleRate }
                guard chunk.sampleRate == sampleRate else { continue }
                samples.append(contentsOf: chunk.samples)
            }
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
    /// Language-specific readings the voices get wrong on their own: "12°C" → "12 grados", "°F", "km/h".
    public static func forVoice(_ text: String, language: Language) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let degrees = language == .es ? ("grados", "grados Fahrenheit", "kilómetros por hora") : ("degrees", "degrees Fahrenheit", "kilometres per hour")
        result = result.replacingOccurrences(of: #"(\d)\s*°\s*C\b"#, with: "$1 \(degrees.0)", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(\d)\s*°\s*F\b"#, with: "$1 \(degrees.1)", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(\d)\s*°"#, with: "$1 \(degrees.0)", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(\d)\s*km/h\b"#, with: "$1 \(degrees.2)", options: .regularExpression)
        return result
    }

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
