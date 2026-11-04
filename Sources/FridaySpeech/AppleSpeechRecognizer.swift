import Foundation
import AVFoundation
import Speech
import FridayCore
import WakeWordKit
import os

/// Apple's on-device `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26+): streaming volatile results, Spanish and
/// English models already installed on this Mac, no network. One transcriber handles one locale, so for
/// `.bilingual` the session runs two transcribers on the same audio and keeps the hypothesis that is longer
/// and more confident (code-switched sentences come back mostly right from the primary locale).
public struct AppleSpeechRecognizer: SpeechRecognizer {
    public let id = "apple"
    public let displayName = "Apple on-device speech"
    static let logger = Logger(subsystem: "com.alejandro.friday", category: "stt.apple")

    public var localeFor: @Sendable (Language) -> Locale

    public init(locales: [Language: Locale] = [.en: Locale(identifier: "en_US"), .es: Locale(identifier: "es_ES")]) {
        self.localeFor = { language in locales[language] ?? Locale(identifier: language == .es ? "es_ES" : "en_US") }
    }

    public func availability() async -> EngineAvailability {
        guard #available(macOS 26, *) else { return .unavailable("Needs macOS 26 or newer.") }
        let supported = await SpeechTranscriber.supportedLocales
        guard !supported.isEmpty else { return .unavailable("SpeechTranscriber reports no supported locales.") }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied: return .unavailable("Speech recognition is denied in System Settings ▸ Privacy & Security ▸ Speech Recognition.")
        case .restricted: return .unavailable("Speech recognition is restricted on this Mac.")
        default: break
        }
        return .available
    }

    public static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    public func warmUp() async {
        guard #available(macOS 26, *) else { return }
        for language in [Language.en, .es] {
            let locale = localeFor(language)
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            if let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try? await request.downloadAndInstall()
            }
            _ = try? await AssetInventory.reserve(locale: locale)
        }
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
        var finished = false
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
    private var finishContinuation: CheckedContinuation<TranscriptUpdate, Never>?

    init(languages: [(Language, Locale)], vocabulary: [String]) async throws {
        var continuation: AsyncStream<TranscriptUpdate>.Continuation!
        updates = AsyncStream { continuation = $0 }
        updatesContinuation = continuation
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
                    AppleSpeechRecognizer.logger.error("transcriber stream ended: \(error.localizedDescription, privacy: .public)")
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

    private func record(laneIndex: Int, text: String, isFinal: Bool, confidence: Double) {
        let update: TranscriptUpdate? = lock.withLock {
            guard laneIndex < lanes.count, !cancelled else { return nil }
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
        return best
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
        for lane in lanes where !lane.finished { lane.input.yield(AnalyzerInput(buffer: converted)) }
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
        if done { completeFinish() }
    }

    private func completeFinish() {
        let final: TranscriptUpdate = lock.withLock {
            let best = bestLaneLocked()
            return TranscriptUpdate(text: best.text, isFinal: true, language: best.language, confidence: best.confidence)
        }
        updatesContinuation.yield(final)
        updatesContinuation.finish()
        let continuation = lock.withLock { () -> CheckedContinuation<TranscriptUpdate, Never>? in
            let c = finishContinuation
            finishContinuation = nil
            return c
        }
        continuation?.resume(returning: final)
    }

    func finish() async -> TranscriptUpdate {
        let lanes = lock.withLock { self.lanes }
        for lane in lanes { lane.input.finish() }
        return await withTaskGroup(of: TranscriptUpdate.self) { group in
            group.addTask { [self] in
                await withCheckedContinuation { continuation in
                    let already: TranscriptUpdate? = self.lock.withLock {
                        if self.finishedLanes >= self.lanes.count {
                            let best = self.bestLaneLocked()
                            return TranscriptUpdate(text: best.text, isFinal: true, language: best.language, confidence: best.confidence)
                        }
                        self.finishContinuation = continuation
                        return nil
                    }
                    if let already { continuation.resume(returning: already) }
                }
            }
            group.addTask { [self] in
                for lane in lanes { try? await lane.analyzer.finalizeAndFinishThroughEndOfInput() }
                try? await Task.sleep(for: .seconds(4))
                return self.lock.withLock {
                    let best = self.bestLaneLocked()
                    return TranscriptUpdate(text: best.text, isFinal: true, language: best.language, confidence: best.confidence)
                }
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
    }

    func cancel() {
        lock.withLock { cancelled = true }
        for lane in lock.withLock({ lanes }) {
            lane.input.finish()
            Task { await lane.analyzer.cancelAndFinishNow() }
        }
        for reader in readers { reader.cancel() }
        updatesContinuation.finish()
    }
}
