import Foundation
import AVFoundation
import FridayCore

/// `AVSpeechSynthesizer` rendered to buffers (no direct playback): the zero-dependency fallback voice. Voice
/// quality depends on what the user downloaded in System Settings ▸ Accessibility ▸ Spoken Content.
public final class AppleTextToSpeech: TextToSpeechEngine, @unchecked Sendable {
    public let id = "apple"
    public let displayName = "Apple voices"

    public init() {}

    public func availability() async -> EngineAvailability {
        AVSpeechSynthesisVoice.speechVoices().isEmpty ? .unavailable("No system voices.") : .available
    }

    public func warmUp() async {}

    public func voices() async -> [TTSVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") || $0.language.hasPrefix("es") }
            .filter { !$0.identifier.contains("speech.synthesis.voice") }  // novelty voices
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
            .map { voice in
                let quality: String
                switch voice.quality {
                case .premium: quality = " (Premium)"
                case .enhanced: quality = " (Enhanced)"
                default: quality = ""
                }
                return TTSVoice(id: voice.identifier, name: voice.name + quality, language: voice.language, engineID: id)
            }
    }

    /// The best installed voice for a language (premium > enhanced > compact).
    public static func bestVoice(for language: Language) -> AVSpeechSynthesisVoice? {
        let prefix = language == .es ? "es" : "en"
        let preferred = language == .es ? ["es-ES", "es-MX", "es-US"] : ["en-US", "en-GB"]
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) && !$0.identifier.contains("speech.synthesis.voice") && !$0.identifier.contains("eloquence") }
        return candidates.max { a, b in
            let qa = a.quality.rawValue, qb = b.quality.rawValue
            if qa != qb { return qa < qb }
            return (preferred.firstIndex(of: a.language) ?? 9) > (preferred.firstIndex(of: b.language) ?? 9)
        }
    }

    public func synthesize(_ text: String, voice: TTSVoice, rate: Float) -> AsyncThrowingStream<AudioChunk, any Error> {
        AsyncThrowingStream { continuation in
            let synthesizer = AVSpeechSynthesizer()
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(identifier: voice.id) ?? AVSpeechSynthesisVoice(language: voice.language)
            utterance.rate = min(max(AVSpeechUtteranceDefaultSpeechRate * rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
            let box = SynthesizerBox(synthesizer)
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    continuation.finish()
                    box.release()
                    return
                }
                let samples = Self.mono(pcm)
                if !samples.isEmpty { continuation.yield(AudioChunk(samples: samples, sampleRate: Int(pcm.format.sampleRate))) }
            }
            continuation.onTermination = { _ in
                box.stop()
            }
        }
    }

    static func mono(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return [] }
        if let floats = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: floats[0], count: frames))
        }
        if let ints = buffer.int16ChannelData {
            return UnsafeBufferPointer(start: ints[0], count: frames).map { Float($0) / 32768 }
        }
        if let ints = buffer.int32ChannelData {
            return UnsafeBufferPointer(start: ints[0], count: frames).map { Float($0) / 2_147_483_648 }
        }
        return []
    }
}

/// Keeps the synthesizer alive until it finished writing, and lets a cancelled consumer stop it.
final class SynthesizerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var synthesizer: AVSpeechSynthesizer?
    init(_ synthesizer: AVSpeechSynthesizer) { self.synthesizer = synthesizer }
    func stop() {
        lock.withLock {
            synthesizer?.stopSpeaking(at: .immediate)
            synthesizer = nil
        }
    }
    func release() { lock.withLock { synthesizer = nil } }
}
