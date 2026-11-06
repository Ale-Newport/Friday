import Foundation
import Testing
import FridayAudio
import FridayCore
import FridaySpeech
@testable import FridayAssistant

/// Measures what the optional wake-word verification stage costs with Apple's on-device recogniser on real audio.
///
/// Runs only when `FRIDAY_WAKE_WORD_FIXTURES` names WAV files of someone saying the wake word (optionally followed
/// by a command), as `path[@endSeconds]` entries separated by `:`; `endSeconds` is where the detector would report
/// the keyword's end (default: 1.1 s, or the end of the file for clips shorter than that). Clips without the wake
/// word go in `FRIDAY_WAKE_WORD_NEGATIVES` with the same syntax and must be rejected. Prints one line per clip and
/// the median; the budget below which the stage could be on by default is 300 ms (reported, not asserted).
@Suite(.serialized) struct WakeWordVerificationLatencyTests {
    struct Fixture { let url: URL; let endSeconds: Double?; let expected: Bool }

    static func fixtures(_ variable: String, expected: Bool) -> [Fixture] {
        guard let raw = ProcessInfo.processInfo.environment[variable], !raw.isEmpty else { return [] }
        return raw.split(separator: ":").map { entry in
            let parts = entry.split(separator: "@", maxSplits: 1).map(String.init)
            return Fixture(url: URL(fileURLWithPath: parts[0]), endSeconds: parts.count > 1 ? Double(parts[1]) : nil, expected: expected)
        }
    }

    @Test func verificationLatencyOnRealAudio() async throws {
        let fixtures = Self.fixtures("FRIDAY_WAKE_WORD_FIXTURES", expected: true) + Self.fixtures("FRIDAY_WAKE_WORD_NEGATIVES", expected: false)
        guard !fixtures.isEmpty else { print("latency measurement skipped: FRIDAY_WAKE_WORD_FIXTURES is not set"); return }
        let recognizer = AppleSpeechRecognizer()
        guard await recognizer.availability().isAvailable else { print("latency measurement skipped: Apple recogniser unavailable"); return }
        let settings: VoiceSettings = {
            var settings = VoiceSettings()
            settings.recognizerID = "apple"
            settings.spokenLanguage = .automatic
            return settings
        }()
        let recorder = MicrophoneRecorder(seconds: 30)
        let listener = VoiceListener(recorder: recorder, recognizers: [recognizer], detector: { testDetector() }, settings: { settings })
        await listener.warmUp()
        var durations: [Int] = []
        var wrong: [String] = []
        for (index, fixture) in fixtures.enumerated() {
            let audio = try InjectableCaptureSource.load(contentsOf: fixture.url)
            let before = recorder.position
            audio.samples.withUnsafeBufferPointer { recorder.tap($0, sampleRate: audio.sampleRate) }
            let length = recorder.position - before
            let end = fixture.endSeconds.map { before + min(length, Int($0 * Double(MicrophoneRecorder.sampleRate))) } ?? (before + min(length, Int(1.1 * Double(MicrophoneRecorder.sampleRate))))
            // The first run pays for model loading; measure each fixture twice and keep the warm one.
            var warm: WakeWordVerification?
            for _ in 0..<2 { warm = await listener.verifyWakeWord(endingAt: end, wakeWord: "Jarvis", margin: Assistant.commandStartMargin) }
            guard let verification = warm else { continue }
            durations.append(verification.durationMs)
            if verification.isRejected == fixture.expected { wrong.append(fixture.url.lastPathComponent) }
            print("[\(index)] \(fixture.url.lastPathComponent): \(verification.outcome) in \(verification.durationMs) ms")
        }
        let sorted = durations.sorted()
        guard !sorted.isEmpty else { return }
        let median = sorted[sorted.count / 2]
        print("wake-word verification: median \(median) ms, max \(sorted.last ?? 0) ms over \(sorted.count) clips (budget for a default: 300 ms); wrong decisions: \(wrong)")
        #expect(wrong.isEmpty, "clips with the wake word are accepted, clips without it rejected")
    }
}
