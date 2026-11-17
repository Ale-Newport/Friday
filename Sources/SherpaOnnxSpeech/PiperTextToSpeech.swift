import Foundation
import FridaySpeech
import os

/// Offline Spanish speech with a Piper (VITS) voice on sherpa-onnx: much more natural in Spanish than Kokoro's Spanish
/// speakers, and the fallback when the online neural voice cannot be reached. One voice (es-ES, male, 22.05 kHz).
/// Native work runs on one serial queue, like `KokoroTextToSpeech`.
public final class PiperTextToSpeech: TextToSpeechEngine, @unchecked Sendable {
    public static let engineID = "piper"
    public static let voiceID = "es_ES-miro-high"
    public static let allVoices = [TTSVoice(id: voiceID, name: "Miró (Piper, es-ES)", language: "es-ES", engineID: engineID)]

    public let id = PiperTextToSpeech.engineID
    public let displayName = "Piper (offline)"
    public let resources: SherpaOnnxSpeechResources
    private let queue = DispatchQueue(label: "friday.speech.piper", qos: .userInitiated)
    private struct State { var engine: NativeTTS?; var lastFailure: SpeechError? }
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(resources: SherpaOnnxSpeechResources) { self.resources = resources }

    var modelURL: URL { resources.piperDirectory.appendingPathComponent("model.onnx") }
    var tokensURL: URL { resources.piperDirectory.appendingPathComponent("tokens.txt") }
    var espeakData: URL { resources.kokoroDirectory.appendingPathComponent(KokoroModelFiles.espeakDataName, isDirectory: true) }

    public var missingFiles: [String] {
        var missing: [String] = []
        if !resources.isLibraryPresent { missing.append(resources.libraryURL.lastPathComponent) }
        for url in [modelURL, tokensURL, espeakData.appendingPathComponent("phontab")] where !FileManager.default.fileExists(atPath: url.path) {
            missing.append(url.lastPathComponent)
        }
        return missing
    }

    public func availability() async -> EngineAvailability {
        let missing = missingFiles
        if !missing.isEmpty { return .needsSetup(resources.setupMessage(missing: missing)) }
        if let failure = state.withLock({ $0.lastFailure }) { return .unavailable(failure.localizedReason) }
        return .available
    }

    public func warmUp() async {
        guard missingFiles.isEmpty, let voice = Self.allVoices.first else { return }
        do { for try await _ in synthesize("Hola.", voice: voice, rate: 1) {} } catch {}
    }

    public func voices() async -> [TTSVoice] { missingFiles.isEmpty ? Self.allVoices : [] }

    public func synthesize(_ text: String, voice: TTSVoice, rate: Float) -> AsyncThrowingStream<AudioChunk, any Error> {
        AsyncThrowingStream { continuation in
            let job = SynthesisJob(continuation: continuation)
            continuation.onTermination = { @Sendable _ in job.cancel() }
            queue.async { [self] in
                if job.isCancelled { continuation.finish(); return }
                do throws(SpeechError) {
                    let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !spoken.isEmpty else { continuation.finish(); return }
                    let engine = try loadedEngine()
                    let speed = min(max(rate.isFinite ? rate : 1, 0.5), 2.0)
                    _ = try engine.generate(spoken, speaker: 0, speed: speed, espeakVoice: nil, silenceScale: 0.2, job: job)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Runs on `queue` only.
    private func loadedEngine() throws(SpeechError) -> NativeTTS {
        if let engine = state.withLock({ $0.engine }) { return engine }
        let missing = missingFiles
        guard missing.isEmpty else { throw .engineUnavailable(resources.setupReason(missing: missing)) }
        do throws(SpeechError) {
            let engine = try NativeTTS.createVits(
                libraryURL: resources.libraryURL, model: modelURL, tokens: tokensURL, dataDirectory: espeakData,
                numThreads: 2, silenceScale: 0.2)
            state.withLock { $0.engine = engine; $0.lastFailure = nil }
            return engine
        } catch {
            state.withLock { $0.lastFailure = error }
            throw error
        }
    }
}
