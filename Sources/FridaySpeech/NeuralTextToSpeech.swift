import Foundation
import AVFoundation
import FridayCore
import os

/// Online neural voices (Microsoft's "Read aloud" voices, through the sidecar): by far the most natural Spanish Friday
/// can speak. The transport is injected (the app passes the sidecar client), so this module needs no network code.
///
/// Every `synthesize` call is one request: the speech output already cuts replies into short phrases and prefetches the
/// next one while the current plays. When the transport is missing or fails, the stream throws before any audio and
/// `SpeechOutput` speaks the phrase with the local fallback voice instead.
public final class NeuralTextToSpeech: TextToSpeechEngine, @unchecked Sendable {
    public static let engineID = "neural"
    /// What the transport returns: MP3 (or any format AVAudioFile reads) for one phrase.
    public typealias Fetch = @Sendable (_ text: String, _ voice: String, _ ratePercent: Int) async throws -> Data
    public typealias Warm = @Sendable () async -> Void

    public static let allVoices: [TTSVoice] = [
        ("es-ES-AlvaroNeural", "Álvaro (es-ES)", "es-ES"), ("es-ES-ElviraNeural", "Elvira (es-ES)", "es-ES"),
        ("es-ES-XimenaNeural", "Ximena (es-ES)", "es-ES"), ("es-MX-JorgeNeural", "Jorge (es-MX)", "es-MX"),
        ("es-MX-DaliaNeural", "Dalia (es-MX)", "es-MX"), ("en-GB-RyanNeural", "Ryan (en-GB)", "en-GB"),
        ("en-GB-SoniaNeural", "Sonia (en-GB)", "en-GB"), ("en-US-AndrewNeural", "Andrew (en-US)", "en-US"),
        ("en-US-AvaNeural", "Ava (en-US)", "en-US"), ("en-US-EmmaMultilingualNeural", "Emma multilingual (en-US)", "en-US"),
    ].map { TTSVoice(id: $0.0, name: $0.1, language: $0.2, engineID: engineID) }

    public static let defaultSpanishVoice = "es-ES-AlvaroNeural"
    public static let defaultEnglishVoice = "en-GB-RyanNeural"

    public let id = NeuralTextToSpeech.engineID
    public let displayName = "Neural voices (online)"
    static let logger = Logger(subsystem: "com.alejandro.friday", category: "neural-tts")

    private struct State {
        var fetch: Fetch?
        var warm: Warm?
        /// After a failure the engine reports itself unavailable for a while, so every phrase does not wait for a
        /// timeout while offline.
        var failedUntil: Date = .distantPast
        var lastError: String?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// How long a failure keeps the engine out of the rotation.
    public static let backoff: TimeInterval = 30

    public init() {}

    /// Connects the engine to a transport (nil: none, e.g. the sidecar stopped).
    public func setTransport(fetch: Fetch?, warm: Warm?) {
        state.withLock {
            $0.fetch = fetch
            $0.warm = warm
            if fetch != nil { $0.failedUntil = .distantPast }
        }
    }

    public func availability() async -> EngineAvailability {
        let (fetch, failedUntil, lastError) = state.withLock { ($0.fetch, $0.failedUntil, $0.lastError) }
        guard fetch != nil else {
            return .needsSetup(LocalizedText(
                en: "The online voices need Friday's helper process (the sidecar), which is not running.",
                es: "Las voces online necesitan el proceso auxiliar de Friday (el sidecar), que no está en marcha."))
        }
        if Date() < failedUntil {
            return .unavailable(LocalizedText(
                en: "The online voice could not be reached (\(lastError ?? "offline")); a local voice is speaking meanwhile.",
                es: "No se pudo contactar con la voz online (\(lastError ?? "sin conexión")); mientras tanto habla una voz local."))
        }
        return .available
    }

    /// Opens the connections to the voice service (the TLS handshake is most of the first phrase's latency).
    public func warmUp() async {
        let warm = state.withLock { $0.warm }
        await warm?()
    }

    public func voices() async -> [TTSVoice] { Self.allVoices }

    public func synthesize(_ text: String, voice: TTSVoice, rate: Float) -> AsyncThrowingStream<AudioChunk, any Error> {
        let fetch = state.withLock { $0.fetch }
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard let fetch else {
                    continuation.finish(throwing: SpeechError.engineUnavailable("no transport"))
                    return
                }
                do {
                    let percent = Int(((rate.isFinite ? rate : 1) - 1) * 100)
                    let data = try await fetch(text, voice.id, max(-50, min(100, percent)))
                    try Task.checkCancellation()
                    let chunk = try Self.decode(data)
                    continuation.yield(chunk)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch where Task.isCancelled || Self.isCancellation(error) {
                    // The phrase was dropped (Friday was interrupted, or the prefetched phrase is no longer needed):
                    // not a failure of the service, so no back-off.
                    continuation.finish()
                } catch {
                    let message = error.localizedDescription
                    Self.logger.warning("neural voice failed: \(message, privacy: .public)")
                    self.state.withLock {
                        $0.failedUntil = Date().addingTimeInterval(Self.backoff)
                        $0.lastError = String(message.prefix(120))
                    }
                    continuation.finish(throwing: SpeechError.synthesisFailed(message))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        let nested = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        if (error as NSError).domain == NSURLErrorDomain, (error as NSError).code == NSURLErrorCancelled { return true }
        if let nested, nested.domain == NSURLErrorDomain, nested.code == NSURLErrorCancelled { return true }
        return false
    }

    /// Decodes compressed audio (MP3) into mono float samples.
    static func decode(_ data: Data) throws -> AudioChunk {
        guard !data.isEmpty else { throw SpeechError.synthesisFailed("empty audio") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("friday-tts-\(UUID().uuidString).mp3")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw SpeechError.synthesisFailed("no audio frames")
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else { throw SpeechError.synthesisFailed("unexpected audio format") }
        let count = Int(buffer.frameLength)
        var samples = Array(UnsafeBufferPointer(start: channels[0], count: count))
        if format.channelCount > 1 {
            for channel in 1..<Int(format.channelCount) {
                let other = UnsafeBufferPointer(start: channels[channel], count: count)
                for index in 0..<count { samples[index] += other[index] }
            }
            let scale = 1 / Float(format.channelCount)
            for index in 0..<count { samples[index] *= scale }
        }
        // MP3 encoders pad the start with silence; trim leading near-silence (≤ 60 ms) so phrases join tightly.
        let rate = Int(format.sampleRate)
        let limit = min(samples.count, rate * 6 / 100)
        if let firstSound = samples.prefix(limit).firstIndex(where: { abs($0) > 0.002 }), firstSound > 0 {
            samples.removeFirst(firstSound)
        }
        return AudioChunk(samples: samples, sampleRate: rate)
    }
}
