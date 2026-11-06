import Foundation
import AVFoundation
import Speech
import FridayCore
import WakeWordKit
import os

/// Apple's on-device `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26+): streaming volatile results, Spanish and
/// English models, no network once the models are installed. One transcriber handles one locale, so for
/// `.bilingual` the session runs two transcribers on the same audio and keeps the hypothesis that is longer
/// and more confident (code-switched sentences come back mostly right from the primary locale).
///
/// The language models are system assets that Apple installs once, on request (`warmUp()` or `installAssets()`);
/// until they are installed `availability()` says `.needsSetup`, since nothing can be recognised yet.
public struct AppleSpeechRecognizer: SpeechRecognizer {
    public let id = "apple"
    public let displayName = "Apple on-device speech"
    static let logger = Logger(subsystem: "com.alejandro.friday", category: "stt.apple")

    /// The most contextual strings handed to a session. Apple's recognisers work best with a short list of names
    /// and terms; a longer vocabulary is cut here, keeping the first entries (the user's list, then the wake word).
    public static let maxVocabularyEntries = 100
    /// Longer entries are phrases, not names; they are dropped rather than boosted.
    public static let maxVocabularyEntryLength = 60
    /// How long `finish()` waits for the final results before returning what it has.
    public static let finishTimeout: Duration = .seconds(4)

    public var localeFor: @Sendable (Language) -> Locale

    public init(locales: [Language: Locale] = [.en: Locale(identifier: "en_US"), .es: Locale(identifier: "es_ES")]) {
        self.localeFor = { language in locales[language] ?? Locale(identifier: language == .es ? "es_ES" : "en_US") }
    }

    public func availability() async -> EngineAvailability {
        guard #available(macOS 26, *) else {
            return .unavailable(LocalizedText(en: "Needs macOS 26 or newer.", es: "Necesita macOS 26 o posterior."))
        }
        let supported = await SpeechTranscriber.supportedLocales
        guard !supported.isEmpty else {
            return .unavailable(LocalizedText(
                en: "Apple speech recognition reports no supported languages on this Mac.",
                es: "El reconocimiento de voz de Apple no ofrece ningún idioma en este Mac."))
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied:
            return .unavailable(LocalizedText(
                en: "Speech recognition is denied in System Settings ▸ Privacy & Security ▸ Speech Recognition.",
                es: "El reconocimiento de voz está denegado en Ajustes del Sistema ▸ Privacidad y seguridad ▸ Reconocimiento de voz."))
        case .restricted:
            return .unavailable(LocalizedText(en: "Speech recognition is restricted on this Mac.", es: "El reconocimiento de voz está restringido en este Mac."))
        default: break
        }
        // The models are system assets: supported but not installed means nothing can be recognised yet. The
        // installed locales are authoritative; `AssetInventory.status` is consulted only for the rest, since it says
        // "supported" for a locale this process has not asked about yet, even when its model is on disk.
        let installed = Set(await SpeechTranscriber.installedLocales.map(\.identifier))
        var missing: [Language] = []
        var downloading: [Language] = []
        for language in [Language.en, .es] {
            let locale = localeFor(language)
            guard let equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                return .unavailable(LocalizedText(
                    en: "Apple speech recognition does not support \(Self.name(of: language, in: .en)) (\(locale.identifier)) on this Mac.",
                    es: "El reconocimiento de voz de Apple no admite \(Self.name(of: language, in: .es)) (\(locale.identifier)) en este Mac."))
            }
            if installed.contains(equivalent.identifier) || installed.contains(locale.identifier) { continue }
            switch await AssetInventory.status(forModules: [transcriber(for: language)]) {
            case .installed: continue
            case .downloading: downloading.append(language)
            case .supported: missing.append(language)
            case .unsupported:
                return .unavailable(LocalizedText(
                    en: "Apple speech recognition does not support \(Self.name(of: language, in: .en)) (\(locale.identifier)) on this Mac.",
                    es: "El reconocimiento de voz de Apple no admite \(Self.name(of: language, in: .es)) (\(locale.identifier)) en este Mac."))
            @unknown default: continue
            }
        }
        if !downloading.isEmpty {
            return .needsSetup(LocalizedText(
                en: "Apple's on-device speech model for \(Self.names(of: downloading, in: .en)) is being downloaded; listening works once it is installed.",
                es: "El modelo de voz local de Apple para \(Self.names(of: downloading, in: .es)) se está descargando; la escucha funcionará cuando esté instalado."))
        }
        if !missing.isEmpty {
            return .needsSetup(LocalizedText(
                en: "Apple's on-device speech model for \(Self.names(of: missing, in: .en)) is not installed. Friday asks macOS to download it once (from Apple, about 100 MB per language) when it starts; that needs a network connection.",
                es: "El modelo de voz local de Apple para \(Self.names(of: missing, in: .es)) no está instalado. Friday pide a macOS que lo descargue una vez (de Apple, unos 100 MB por idioma) al arrancar; para eso hace falta conexión de red."))
        }
        return .available
    }

    static func name(of language: Language, in ui: Language) -> String {
        switch (language, ui) {
        case (.en, .en): return "English"
        case (.es, .en): return "Spanish"
        case (.en, .es): return "inglés"
        case (.es, .es): return "español"
        }
    }

    static func names(of languages: [Language], in ui: Language) -> String {
        languages.map { name(of: $0, in: ui) }.joined(separator: ui == .es ? " y " : " and ")
    }

    public static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    /// Installs the language models that are missing (a one-time download from Apple, managed by macOS) and reserves
    /// them so the system keeps them. Nothing is downloaded when they are already installed.
    public func warmUp() async {
        guard #available(macOS 26, *) else { return }
        do {
            try await installAssets()
        } catch {
            Self.logger.error("speech model install failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The explicit form of `warmUp()`: throws when macOS could not install a model (no network, no space …).
    public func installAssets() async throws {
        guard #available(macOS 26, *) else { throw SpeechError.engineUnavailable("Needs macOS 26 or newer.") }
        for language in [Language.en, .es] {
            let module = transcriber(for: language)
            // Nil when the model is already installed: nothing is downloaded then.
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                Self.logger.notice("installing Apple's on-device speech model for \(language.rawValue, privacy: .public)")
                try await request.downloadAndInstall()
            }
            _ = try? await AssetInventory.reserve(locale: localeFor(language))
        }
    }

    @available(macOS 26, *)
    private func transcriber(for language: Language) -> SpeechTranscriber {
        SpeechTranscriber(locale: localeFor(language), preset: .progressiveTranscription)
    }

    public func makeSession(language: SpeechLanguageHint, vocabulary: [String]) async throws -> any SpeechRecognitionSession {
        guard #available(macOS 26, *) else { throw SpeechError.engineUnavailable("Needs macOS 26 or newer.") }
        let languages: [Language]
        switch language {
        case .fixed(let one): languages = [one]
        case .bilingual(let primary): languages = [primary, primary == .en ? .es : .en]
        case .auto: languages = [.en, .es]
        }
        return try await AppleSession(languages: languages.map { ($0, localeFor($0)) }, vocabulary: vocabulary)
    }

    /// The vocabulary as it is handed to the analyzers: trimmed, without blanks, duplicates and entries too long to be
    /// a name, and at most `maxVocabularyEntries` of them (the first ones win).
    public static func contextualStrings(from vocabulary: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in vocabulary {
            let entry = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty, entry.count <= maxVocabularyEntryLength else { continue }
            let key = entry.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(entry)
            if result.count == maxVocabularyEntries { break }
        }
        return result
    }
}

@available(macOS 26, *)
final class AppleSession: SpeechRecognitionSession, @unchecked Sendable {
    private struct Lane {
        let language: Language
        let analyzer: SpeechAnalyzer
        let transcriber: SpeechTranscriber
        let input: AsyncStream<AnalyzerInput>.Continuation
        var latest = ""
        var finalText = ""
        var confidence: Double = 0
    }

    private let lock = NSLock()
    private var lanes: [Lane] = []
    private var converter: AVAudioConverter?
    private let format: AVAudioFormat
    private var inputFormat: AVAudioFormat?
    private let updatesContinuation: AsyncStream<TranscriptUpdate>.Continuation
    public let updates: AsyncStream<TranscriptUpdate>
    private var readers: [Task<Void, Never>] = []
    private var finishedLanes = 0
    private var cancelled = false
    /// `finish()` resolves exactly once, from whichever comes first: the last lane's results ending, the timeout, or
    /// `cancel()`. The gate keeps that promise (see `resolveFinish`).
    private var finishResolved = false
    private var finishContinuation: CheckedContinuation<TranscriptUpdate, Never>?
    /// The words `makeSession` was given, as handed to the analyzers (for diagnostics and tests).
    let contextualStrings: [String]
    /// The same words, applied to the transcript.
    let vocabulary: RecognitionVocabulary

    init(languages: [(Language, Locale)], vocabulary: [String]) async throws {
        var continuation: AsyncStream<TranscriptUpdate>.Continuation!
        updates = AsyncStream { continuation = $0 }
        updatesContinuation = continuation
        contextualStrings = AppleSpeechRecognizer.contextualStrings(from: vocabulary)
        self.vocabulary = RecognitionVocabulary(contextualStrings)
        var lanes: [Lane] = []
        var bestFormat: AVAudioFormat?
        for (language, locale) in languages {
            let transcriber = SpeechTranscriber(
                locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: [.transcriptionConfidence])
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
            if bestFormat == nil {
                bestFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            }
            if !contextualStrings.isEmpty {
                // Names, apps and the wake word, for the analyzer to favour those spellings. (Measured on macOS 27.0:
                // the context is set, but SpeechTranscriber's output does not change; `vocabulary` applies the same
                // words to the transcript, see RecognitionVocabulary.)
                let context = AnalysisContext()
                context.contextualStrings[.general] = contextualStrings
                do {
                    try await analyzer.setContext(context)
                } catch {
                    AppleSpeechRecognizer.logger.warning(
                        "vocabulary not applied to \(locale.identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            try await analyzer.start(inputSequence: stream)
            lanes.append(Lane(language: language, analyzer: analyzer, transcriber: transcriber, input: input))
        }
        guard let format = bestFormat ?? AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) else {
            throw SpeechError.recognitionFailed("No analyzer audio format.")
        }
        self.format = format
        self.lanes = lanes
        for index in lanes.indices {
            let transcriber = lanes[index].transcriber
            readers.append(Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard let self else { return }
                        let text = String(result.text.characters)
                        let confidence = Self.confidence(of: result.text)
                        self.record(laneIndex: index, text: text, isFinal: result.isFinal, confidence: confidence)
                    }
                } catch {
                    if self?.isCancelled != true {
                        AppleSpeechRecognizer.logger.error("transcriber stream ended: \(error.localizedDescription, privacy: .public)")
                    }
                }
                self?.laneFinished()
            })
        }
    }

    static func confidence(of text: AttributedString) -> Double {
        var total = 0.0
        var count = 0
        for run in text.runs {
            if let value = run.transcriptionConfidence { total += value; count += 1 }
        }
        return count == 0 ? 0 : total / Double(count)
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    private func record(laneIndex: Int, text: String, isFinal: Bool, confidence: Double) {
        let update: TranscriptUpdate? = lock.withLock {
            guard laneIndex < lanes.count, !cancelled, !finishResolved else { return nil }
            if isFinal {
                lanes[laneIndex].finalText += (lanes[laneIndex].finalText.isEmpty ? "" : " ") + text
                lanes[laneIndex].latest = ""
            } else {
                lanes[laneIndex].latest = text
            }
            lanes[laneIndex].confidence = confidence
            // Publish the best lane's current hypothesis.
            let best = bestLaneLocked()
            return TranscriptUpdate(text: best.text, isFinal: false, language: best.language, confidence: best.confidence)
        }
        if let update { updatesContinuation.yield(update) }
    }

    private func bestLaneLocked() -> (text: String, language: Language, confidence: Double) {
        var best: (String, Language, Double) = ("", lanes.first?.language ?? .en, 0)
        for lane in lanes {
            let text = (lane.finalText + " " + lane.latest).trimmingCharacters(in: .whitespaces)
            // Longer text with comparable confidence wins; a clearly more confident lane wins at similar length.
            let score = Double(text.count) * (0.5 + lane.confidence)
            let bestScore = Double(best.0.count) * (0.5 + best.2)
            if score > bestScore { best = (text, lane.language, lane.confidence) }
        }
        return (vocabulary.apply(to: best.0), best.1, best.2)
    }

    private func finalUpdateLocked() -> TranscriptUpdate {
        let best = bestLaneLocked()
        return TranscriptUpdate(text: best.text, isFinal: true, language: best.language, confidence: best.confidence)
    }

    func feed(_ chunk: AudioChunk) {
        guard !chunk.samples.isEmpty else { return }
        let source = AVAudioFormat(standardFormatWithSampleRate: Double(chunk.sampleRate), channels: 1)!
        let buffer = Self.pcmBuffer(chunk.samples, format: source)
        let converted: AVAudioPCMBuffer
        if source.sampleRate == format.sampleRate, source.commonFormat == format.commonFormat {
            converted = buffer
        } else {
            lock.lock()
            if converter == nil || inputFormat?.sampleRate != source.sampleRate {
                converter = AVAudioConverter(from: source, to: format)
                inputFormat = source
            }
            let converter = self.converter
            lock.unlock()
            guard let converter else { return }
            let frames = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / source.sampleRate) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0 else { return }
            converted = out
        }
        let lanes = lock.withLock { self.lanes }
        for lane in lanes { lane.input.yield(AnalyzerInput(buffer: converted)) }
    }

    static func pcmBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }

    private func laneFinished() {
        let done: Bool = lock.withLock {
            finishedLanes += 1
            return finishedLanes >= lanes.count
        }
        if done { resolveFinish(publishFinal: true) }
    }

    /// Resolves `finish()` exactly once: takes the final transcript and the waiting continuation under the lock and
    /// clears the slot, so a second caller (the timeout after the lanes, a lane after the timeout, `cancel()` after
    /// either) finds nothing to resume. With `publishFinal` the final transcript is also sent to `updates`, which ends
    /// either way. Returns false when it had already been resolved.
    @discardableResult
    private func resolveFinish(publishFinal: Bool) -> Bool {
        let resolution: (final: TranscriptUpdate, continuation: CheckedContinuation<TranscriptUpdate, Never>?)? = lock.withLock {
            guard !finishResolved else { return nil }
            finishResolved = true
            let continuation = finishContinuation
            finishContinuation = nil
            return (finalUpdateLocked(), continuation)
        }
        guard let resolution else { return false }
        if publishFinal { updatesContinuation.yield(resolution.final) }
        updatesContinuation.finish()
        resolution.continuation?.resume(returning: resolution.final)
        return true
    }

    func finish() async -> TranscriptUpdate {
        let lanes = lock.withLock { self.lanes }
        for lane in lanes { lane.input.finish() }
        // Finalisation runs on its own: each analyzer returns when its lane's results have ended, which is also what
        // resolves the gate below through `laneFinished`. Nothing here awaits these tasks, so the cap holds.
        for lane in lanes {
            Task { try? await lane.analyzer.finalizeAndFinishThroughEndOfInput() }
        }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: AppleSpeechRecognizer.finishTimeout)
            guard !Task.isCancelled, let self else { return }
            if self.resolveFinish(publishFinal: true) {
                AppleSpeechRecognizer.logger.warning("finalisation took longer than \(AppleSpeechRecognizer.finishTimeout); returning the current hypothesis")
                self.tearDown()
            }
        }
        let final = await withCheckedContinuation { (continuation: CheckedContinuation<TranscriptUpdate, Never>) in
            let already: TranscriptUpdate? = lock.withLock {
                if finishResolved { return finalUpdateLocked() }
                finishContinuation = continuation
                return nil
            }
            if let already { continuation.resume(returning: already) }
        }
        timeout.cancel()
        return final
    }

    func cancel() {
        lock.withLock { cancelled = true }
        for lane in lock.withLock({ lanes }) { lane.input.finish() }
        tearDown()
        resolveFinish(publishFinal: false)
    }

    /// Stops the analyzers (their results streams end, so the reader tasks do too) and the readers themselves.
    private func tearDown() {
        for lane in lock.withLock({ lanes }) {
            Task { await lane.analyzer.cancelAndFinishNow() }
        }
        for reader in readers { reader.cancel() }
    }
}
