import Foundation
import Testing
import WakeWordKit
@testable import SherpaOnnxBackend

// MARK: - Asking the model what it hears

final class FakeRecognizer: SherpaRecognizerBindings, @unchecked Sendable {
    private struct State { var made = 0, destroyed = 0; var heard: [[Float]] = [] }
    private let state = Protected(State())
    var tokens = ["JH", "AA1", "R"]
    var made: Int { state.withLock { $0.made } }
    var destroyed: Int { state.withLock { $0.destroyed } }
    var heard: [[Float]] { state.withLock { $0.heard } }

    func makeRecognizer(_ settings: SpotterSettings) throws(NativeFailure) -> OpaquePointer {
        state.withLock { state in
            state.made += 1
            return OpaquePointer(bitPattern: 0x2000 + UInt(state.made) * 0x10)!
        }
    }
    func destroyRecognizer(_ recognizer: OpaquePointer) { state.withLock { $0.destroyed += 1 } }
    func transcribe(recognizer: OpaquePointer, samples: UnsafePointer<Float>, count: Int, sampleRate: Int) -> [String] {
        state.withLock { $0.heard.append(Array(UnsafeBufferPointer(start: samples, count: count))) }
        return tokens
    }
}

struct SherpaSoundRecognizerTests {
    static func recognizer(_ fake: FakeRecognizer, model: SherpaOnnxWakeWordEngine.ModelFiles, integrity: ModelIntegrity = .unverified,
                           normaliser: LevelNormaliser.Configuration? = nil) -> SherpaSoundRecognizer {
        SherpaSoundRecognizer(
            configuration: .init(libraryURL: URL(fileURLWithPath: "/x"), model: model, integrity: integrity, levelNormaliser: normaliser),
            makeBindings: { fake }
        )
    }

    @Test func itHearsNothingUntilItIsReady_andAfterItIsShutDown() throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let fake = FakeRecognizer()
        let recognizer = Self.recognizer(fake, model: model.files)
        #expect(recognizer.sounds(in: [0.1, 0.2]).isEmpty && fake.heard.isEmpty, "not initialised")
        try recognizer.initialize()
        try recognizer.initialize()   // idempotent
        #expect(fake.made == 1)
        #expect(recognizer.sounds(in: [Float](repeating: 0.1, count: 1_600)) == ["JH", "AA1", "R"])
        #expect(recognizer.sounds(in: []).isEmpty, "silence of length zero")
        recognizer.shutdown()
        recognizer.shutdown()
        #expect(recognizer.sounds(in: [0.1]).isEmpty)
        #expect(fake.destroyed == 1, "released exactly once")
        #expect(throws: WakeWordError.shutDown) { try recognizer.initialize() }
    }

    @Test func aDamagedModelIsRefusedBeforeTheLibraryIsAskedToLoadIt() throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let fake = FakeRecognizer()
        let wrong = ModelDigests(encoder: String(repeating: "0", count: 64), decoder: String(repeating: "1", count: 64),
                                 joiner: String(repeating: "2", count: 64), tokens: String(repeating: "3", count: 64))
        let recognizer = Self.recognizer(fake, model: model.files, integrity: .verified(wrong))
        do {
            try recognizer.initialize()
            Issue.record("a damaged model must be refused")
        } catch {
            guard case .engineUnavailable(let detail) = error else { Issue.record("wrong error \(error)"); return }
            #expect(detail.contains("damaged or unexpected") && detail.contains("encoder.onnx"))
        }
        #expect(fake.made == 0)
        let missing = try Fixture.model(); missing.cleanup()
        #expect(throws: (any Error).self) { try Self.recognizer(fake, model: missing.files).initialize() }
    }

    @Test func audioIsBroughtToTheEnginesLevelBeforeTheModelHearsIt() throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let fake = FakeRecognizer()
        let recognizer = Self.recognizer(fake, model: model.files, normaliser: .init())
        try recognizer.initialize()
        defer { recognizer.shutdown() }
        _ = recognizer.sounds(in: [Float](repeating: 0.02, count: 1_600))
        let heard = try #require(fake.heard.first)
        #expect(abs((heard.first ?? 0) - powf(10, -6 / 20)) < 1e-4, "−34 dBFS brought to the −6 dBFS target: \(heard.first ?? 0)")

        let plain = FakeRecognizer()
        let untouched = Self.recognizer(plain, model: model.files, normaliser: nil)
        try untouched.initialize()
        defer { untouched.shutdown() }
        _ = untouched.sounds(in: [Float](repeating: 0.02, count: 1_600))
        #expect(plain.heard.first == [Float](repeating: 0.02, count: 1_600), "with no level stage, as it is")
    }

    @Test func aClickInTheRecordingDoesNotDecideTheGainOfTheWordInIt() throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let fake = FakeRecognizer()
        let recognizer = Self.recognizer(fake, model: model.files, normaliser: .init())
        try recognizer.initialize()
        defer { recognizer.shutdown() }
        // A key struck (a peak of 0.5, little energy) in one 100 ms frame, and a word at arm's length (0.02) in the next.
        var click = [Float](repeating: Fixture.quiet, count: 1_600)
        for index in 0..<192 { click[index] = 0.5 * expf(-Float(index) / 25) * (index % 2 == 0 ? 1 : -1) }
        _ = recognizer.sounds(in: click + [Float](repeating: 0.02, count: 1_600))
        let heard = try #require(fake.heard.first)
        // The engine counts the click as four times its RMS (about 0.18), so the gain is about 2.8: the word lands near 0.056.
        // Taken from the raw peak (0.5) the gain would be 1 and the word would reach the model at 0.02.
        #expect(abs((heard.last ?? 0) - 0.056) < 0.004, "the word reaches the model at \(heard.last ?? 0)")
    }

    @Test func whatReachesTheModelNeverLeavesFullScale_whateverTheRecordingHolds() throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let fake = FakeRecognizer()
        let recognizer = Self.recognizer(fake, model: model.files, normaliser: .init())
        try recognizer.initialize()
        defer { recognizer.shutdown() }
        _ = recognizer.sounds(in: [0.2, -3.5, 7, 0.1])   // beyond full scale: a clipped or badly scaled file
        let heard = try #require(fake.heard.first)
        #expect(heard.count == 4 && heard.allSatisfy { abs($0) <= 1 }, "\(heard)")
    }

    @Test func numbersThatAreNotAudioNeverReachTheModel() throws {
        let model = try Fixture.model(); defer { model.cleanup() }
        let fake = FakeRecognizer()
        let recognizer = Self.recognizer(fake, model: model.files)
        try recognizer.initialize()
        defer { recognizer.shutdown() }
        #expect(recognizer.sounds(in: [0.1, .nan, 0.1]).isEmpty && recognizer.sounds(in: [.infinity]).isEmpty && recognizer.sounds(in: [900]).isEmpty)
        #expect(fake.heard.isEmpty)
    }
}

// MARK: - The Mac's own speech tools

struct MacSpeechTests {
    @Test func aToolReportsWhetherItSucceeded() {
        #expect(MacSpeech.run("/usr/bin/true", []))
        #expect(!MacSpeech.run("/usr/bin/false", []))
        #expect(!MacSpeech.run("/nonexistent/tool", []))
    }

    @Test func argumentsReachTheToolByteForByte() throws {
        // Foundation's Process hands a program "ó" as "o" plus a combining accent; `say -v "Mónica"` then finds no such voice.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-args-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let precomposed = "Eddy (Espa\u{00F1}ol (M\u{00E9}xico))"
        let decomposed = "Eddy (Espan\u{0303}ol (Me\u{0301}xico))"
        for (index, argument) in [precomposed, decomposed, "plain", "  spaces  and \"quotes\" "].enumerated() {
            let file = folder.appendingPathComponent("arg\(index)")
            #expect(MacSpeech.run("/bin/sh", ["-c", "printf %s \"$1\" > \"$2\"", "sh", argument, file.path]))
            #expect(Array((try Data(contentsOf: file))) == Array(argument.utf8), "‘\(argument)’ arrived as it was written")
        }
    }

    /// How long this machine takes to start and reap a process that does nothing (milliseconds on a Mac, seconds on
    /// some CI virtual machines): the stopping-time bounds below are measured on top of it.
    static func launchCost() -> Duration {
        let started = ContinuousClock.now
        _ = MacSpeech.run("/usr/bin/true", [])
        return ContinuousClock.now - started
    }

    @Test func aToolThatNeverFinishesIsStoppedAfterItsTime() {
        let launch = Self.launchCost()
        let started = ContinuousClock.now
        #expect(!MacSpeech.run("/bin/sleep", ["30"], timeout: 0.4))
        #expect(ContinuousClock.now - started < .seconds(5) + launch, "a wedged tool must not hold up what waits for it")
    }

    @Test func cancellingStopsAToolThatIsRunning() async {
        let cancelled = Protected(false)
        let launch = Self.launchCost()
        let started = ContinuousClock.now
        let ran = Task { await offPool { MacSpeech.run("/bin/sleep", ["30"], isCancelled: { cancelled.get() }) } }
        try? await Task.sleep(for: .milliseconds(300))
        cancelled.withLock { $0 = true }
        #expect(await ran.value == false)
        #expect(ContinuousClock.now - started < .seconds(5) + launch)
    }

    @Test func speechIsKeptOnlyIfThereIsSomething_inItToKeep() throws {
        // On a Mac whose speech service answers, this is a WAV with audio in it; where it cannot be reached (a sandbox) `say` succeeds
        // without a sound, and that must not be cached as if it were speech.
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-speech-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let request = MacSpeech.Request(voice: "", rate: 175, text: "Good morning.")
        if let wav = MacSpeech.cachedSpeech(request, in: cache) {
            #expect((try FileManager.default.attributesOfItem(atPath: wav.path)[.size] as? Int ?? 0) > 2_000)
            #expect((MacSpeech.readWAV(wav)?.count ?? 0) > 1_000)
        } else {
            let kept = (try? FileManager.default.contentsOfDirectory(atPath: cache.path))?.filter { $0.hasSuffix(".wav") } ?? []
            #expect(kept.isEmpty, "nothing that is not speech is kept: \(kept)")
        }
    }
}

struct ReferenceVoiceTests {
    @Test func ofVoicesThatSoundAlikeTheFirstStays() {
        let clip: [Float] = [0.5, 0.4]
        let clips: [String: [Float]] = ["Mónica": clip, "Paulina": clip, "Flo": [0.1, 0.9]]
        #expect(ReferenceSpeech.genuine(among: ["Mónica", "Paulina", "Flo"], clips: clips) == ["Mónica", "Flo"])
        #expect(ReferenceSpeech.genuine(among: ["Paulina", "Mónica", "Flo"], clips: clips) == ["Paulina", "Flo"])
    }

    @Test func aVoiceIsNotLeftOutForBeingTheSystemsOwn() {
        // On a Mac whose own voice is one of the reference voices, that voice is a voice like any other: only the stand-ins for it are copies.
        let clips: [String: [Float]] = ["Samantha": [0.1, 0.2], "Mónica": [0.3, 0.4], "Paulina": [0.5, 0.6]]
        #expect(ReferenceSpeech.genuine(among: ["Mónica", "Paulina", "Samantha"], clips: clips) == ["Mónica", "Paulina", "Samantha"])
    }

    @Test func aVoiceThatCouldNotBeMadeToSpeakIsNotThere() {
        let clips: [String: [Float]] = ["Samantha": [0.5], "Silent": []]
        #expect(ReferenceSpeech.genuine(among: ["Samantha", "Silent", "Nobody"], clips: clips) == ["Samantha"])
        #expect(ReferenceSpeech.genuine(among: ["Samantha"], clips: [:]).isEmpty)
    }
}

/// On a Mac whose speech service answers: the reference voices the app asks for are really different voices.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FRIDAY_HEADLESS_CI"] == nil && RealSherpa.voiceExists("Samantha") && RealSherpa.voiceExists("Paulina"), "needs macOS voices"), .timeLimit(.minutes(3)))
struct RealReferenceVoiceTests {
    @Test func theVoicesTheAppAsksForAreToldApartFromStandIns() throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-voices-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let requests = ReferenceSpeech.requests()
        let voices = Array(Set((requests.words + requests.speech).map(\.voice))).sorted()
        MacSpeech.prepare(voices.map { MacSpeech.Request(voice: $0, rate: ReferenceSpeech.probeRate, text: ReferenceSpeech.probeText) }, cache: cache)

        let genuine = ReferenceSpeech.genuineVoices(among: voices, cache: cache)
        #expect(genuine.contains("Samantha") && genuine.contains("Paulina"), "\(genuine.sorted())")
        // A voice with accents in its name is found by that name (it was once the system's voice in disguise), when this Mac has it.
        if RealSherpa.voiceExists("Eddy (Espa\u{00F1}ol (M\u{00E9}xico))") {
            #expect(genuine.contains("Eddy (Espa\u{00F1}ol (M\u{00E9}xico))"), "\(genuine.sorted())")
        }
        // Whatever is kept sounds different from everything else that is kept.
        let clips = try genuine.sorted().map { voice in
            try #require(MacSpeech.samples(voice: voice, rate: ReferenceSpeech.probeRate, text: ReferenceSpeech.probeText, cache: cache))
        }
        #expect(Set(clips).count == clips.count)
        // A name that is no voice at all is spoken by the system's own voice: it is a copy, and adds a voice only if the system's voice is not
        // among the others already (here it is: Mónica).
        let withAnImpostor = ReferenceSpeech.genuineVoices(among: voices + ["Nobody At All"], cache: cache)
        #expect(withAnImpostor.count - genuine.count <= 1, "\(withAnImpostor.sorted())")
    }
}
