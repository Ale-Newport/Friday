import Foundation
import Testing
import WakeWordKit
@testable import SherpaOnnxBackend

// MARK: - A model whose behaviour the test writes

/// What a clip is, to the scripted model. Audio is told apart by its pitch: the model counts how often the signal crosses zero.
enum Voice: Float {
    case person = 400        // the person saying the word
    case otherPerson = 500   // the same word in another way (held-back utterances of a different kind)
    case lookalike = 800     // "Travis", "Harvest"…
    case talk = 1_600        // ordinary speech
    case cough = 5           // not a word at all

    /// A second of it, 0.2 in amplitude.
    func clip(seconds: Double = 1) -> [Float] {
        (0..<Int(seconds * 16_000)).map { 0.2 * sinf(2 * .pi * rawValue * Float($0) / 16_000) }
    }

    /// What a frame of audio is, judging by its pitch (nil for quiet).
    static func of(_ frame: [Float]) -> Voice? {
        frame.withUnsafeBufferPointer { samples -> Voice? in
            var loud = false
            var crossings = 0
            var previous = samples[0] < 0
            for sample in samples {
                if abs(sample) > 0.1 { loud = true }
                let negative = sample < 0
                if negative != previous { crossings += 1 }
                previous = negative
            }
            return loud ? Voice.nearest(toFrequency: Float(crossings) / 2 / (Float(samples.count) / 16_000)) : nil
        }
    }

    private static func nearest(toFrequency frequency: Float) -> Voice? {
        return [Voice.cough, .person, .otherPerson, .lookalike, .talk].min { abs($0.rawValue - frequency) < abs($1.rawValue - frequency) }
    }
}

/// The network of a fairy tale: which pronunciations fire on which kinds of audio, and what it "hears" in each, are written down.
final class ScriptedModel: SherpaBindings, SherpaRecognizerBindings, @unchecked Sendable {
    private struct State {
        var streams: [UInt: Set<String>] = [:]
        var next: UInt = 0x4000
        var recognizers = 0
    }
    private let state = Protected(State())
    let version = "scripted"
    /// Pronunciation → the voices it fires on.
    var fires: [String: Set<Voice>] = [:]
    /// What the recogniser hears in each kind of voice.
    var hears: [Voice: [String]] = [:]

    func makeSpotter(_ settings: SpotterSettings) throws(NativeFailure) -> OpaquePointer { pointer() }
    func destroySpotter(_ spotter: OpaquePointer) {}

    func makeStream(spotter: OpaquePointer, keywords: String) throws(NativeFailure) -> OpaquePointer {
        let pronunciations = Set(keywords.split(separator: "/").map { entry in
            String(entry.split(separator: ":", maxSplits: 1).first ?? "").trimmingCharacters(in: .whitespaces)
        })
        let made = pointer()
        state.withLock { $0.streams[UInt(bitPattern: made)] = pronunciations }
        return made
    }

    func destroyStream(_ stream: OpaquePointer) { state.withLock { $0.streams[UInt(bitPattern: stream)] = nil } }
    func reset(spotter: OpaquePointer, stream: OpaquePointer) {}

    func feed(spotter: OpaquePointer, stream: OpaquePointer, samples: UnsafePointer<Float>, count: Int, sampleRate: Int) -> String? {
        let frame = Array(UnsafeBufferPointer(start: samples, count: count))
        guard let voice = Voice.of(frame) else { return nil }
        let active = state.withLock { $0.streams[UInt(bitPattern: stream)] ?? [] }
        return active.contains { fires[$0]?.contains(voice) == true } ? "JARVIS" : nil
    }

    func makeRecognizer(_ settings: SpotterSettings) throws(NativeFailure) -> OpaquePointer { pointer() }
    func destroyRecognizer(_ recognizer: OpaquePointer) {}

    func transcribe(recognizer: OpaquePointer, samples: UnsafePointer<Float>, count: Int, sampleRate: Int) -> [String] {
        let all = Array(UnsafeBufferPointer(start: samples, count: count))
        // The loudest stretch decides what is heard.
        let frames = stride(from: 0, to: all.count - 1_600, by: 1_600).compactMap { Voice.of(Array(all[$0..<$0 + 1_600])) }
        guard let voice = frames.first else { return [] }
        return hears[voice] ?? []
    }

    private func pointer() -> OpaquePointer {
        state.withLock { state in
            state.next += 0x10
            return OpaquePointer(bitPattern: state.next)!
        }
    }
}

/// Polls `condition` until it holds, for at most `timeout`.
func eventually(_ what: String, timeout: Duration = .seconds(20), _ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw TimedOutWaiting(what: what)
}

struct TimedOutWaiting: Error, CustomStringConvertible {
    let what: String
    var description: String { "timed out waiting for \(what)" }
}

// MARK: - The tests

@Suite(.timeLimit(.minutes(2)))
struct VoiceTunerTests {
    /// A tuner running on the scripted model: nothing here touches the real library or the Mac's voices.
    static func tuner(
        _ model: ScriptedModel, files: SherpaOnnxWakeWordEngine.ModelFiles, words: [[Float]], speech: [[Float]], workers: Int = 2, baseline: [String]? = nil
    ) -> VoiceTuner {
        var options = VoiceTuner.Options()
        options.workers = workers
        options.baseline = baseline
        options.sensitivity = 0.5
        options.injectedReference = (words, speech)
        options.usesTextbookVariations = false    // what the model is heard to say is enough here; the real run tries the textbook list too
        options.noisyCopies = 0                   // the scripted model hears exact sounds; noise is covered by NoiseAugmentationTests
        var tuner = VoiceTuner(library: URL(fileURLWithPath: "/nonexistent/lib.dylib"), model: files, options: options)
        tuner.makeEngine = { configuration in
            var configuration = configuration
            configuration.integrity = .unverified
            configuration.pronunciations = ["A B C D"]   // the sounds of this model; the built-in list is in another alphabet
            return SherpaOnnxWakeWordEngine(configuration: configuration, makeBindings: { model })
        }
        tuner.makeRecognizer = { configuration in
            var configuration = configuration
            configuration.integrity = .unverified
            return SherpaSoundRecognizer(configuration: configuration, makeBindings: { model })
        }
        return tuner
    }

    static func utterances(_ voice: Voice, count: Int, source: String) -> [VoiceTuner.Utterance] {
        (0..<count).map { _ in VoiceTuner.Utterance(samples: voice.clip(), source: source) }
    }

    /// The usual world: "A B C D" wakes on the person but also on look-alikes; "A B C D A" also on ordinary talk; "B C D A" on the person only.
    static func world() -> ScriptedModel {
        let model = ScriptedModel()
        model.fires = [
            "A B C D": [.person, .lookalike],
            "A B C D A": [.person, .talk],
            "B C D A": [.person],
        ]
        model.hears = [.person: ["A", "B", "C", "D", "A"], .otherPerson: ["A", "B", "C", "D", "A"], .lookalike: ["B", "C", "D"], .talk: ["C", "D", "C", "D", "A"], .cough: ["A"]]
        return model
    }

    static let words = (0..<8).map { _ in Voice.lookalike.clip(seconds: 0.8) }
    static let speech = [Voice.talk.clip(seconds: 3), Voice.talk.clip(seconds: 2)]

    @Test func itFindsAWayOfSayingItThatHearsThePersonAndStaysQuietOnEverythingElse() async throws {
        let model = Self.world()
        let fixture = try Fixture.model(); defer { fixture.cleanup() }
        let tuner = Self.tuner(model, files: fixture.files, words: Self.words, speech: Self.speech)
        let outcome = try await tuner.tune(
            utterances: Self.utterances(.person, count: 8, source: "jarvis") + Self.utterances(.person, count: 4, source: "hey-jarvis"),
            ordinaryTalk: [Voice.talk.clip(seconds: 4)]
        )

        #expect(outcome.pronunciations == ["B C D A"], "the one that wakes on a look-alike and the one that wakes on talk are both refused: \(outcome.pronunciations)")
        #expect(outcome.report.verdict == .improved && outcome.refusal == nil)
        #expect(outcome.report.total == 12 && outcome.report.heldBack == 3, "every third of each source is held back")
        #expect(outcome.report.heardBefore == 0 && outcome.report.heardAfter == 3, "the built-in list hears none (its sounds are not this model's), the new one all")
        #expect(outcome.report.totalHeardBefore == 0 && outcome.report.totalHeardAfter == 12)
        #expect(outcome.report.silenceChecks == 8 + 2 + 1 && outcome.report.falseAlarms == 0)
        #expect(outcome.profileText.contains("B C D A") && outcome.profileText.hasPrefix(VoiceProfileFile.marker))
        #expect(String(decoding: outcome.report.payload, as: UTF8.self) == outcome.profileText)
        #expect(outcome.bySource.map(\.source) == ["hey-jarvis", "jarvis"] && outcome.bySource.allSatisfy { $0.before == 0 && $0.after == $0.count })
    }

    @Test func aPronunciationThatWakesOnTheLookAlikesIsNotChosenEvenIfItHearsTheMost() async throws {
        let model = Self.world()
        model.fires = ["A B C D": [.person, .lookalike]]       // the only one that hears the person is the one that also wakes on look-alikes
        let fixture = try Fixture.model(); defer { fixture.cleanup() }
        let outcome = try await Self.tuner(model, files: fixture.files, words: Self.words, speech: Self.speech)
            .tune(utterances: Self.utterances(.person, count: 12, source: "jarvis"), ordinaryTalk: [Voice.talk.clip(seconds: 4)])
        #expect(outcome.pronunciations.isEmpty)
        guard case .notImproved = outcome.report.verdict else { Issue.record("expected 'no better': \(outcome.report.verdict)"); return }
        #expect(outcome.refusal != nil)
    }

    @Test func aFewLookAlikesMayWakeIt_butNotMany() async throws {
        let model = Self.world()
        model.fires = ["B C D A": [.person]]
        let fixture = try Fixture.model(); defer { fixture.cleanup() }
        // One look-alike clip in a hundred is tolerated (at least one is): "B C D A" is clean here, so it is chosen.
        let outcome = try await Self.tuner(model, files: fixture.files, words: Self.words, speech: Self.speech)
            .tune(utterances: Self.utterances(.person, count: 12, source: "jarvis"), ordinaryTalk: [Voice.talk.clip(seconds: 4)])
        #expect(outcome.pronunciations == ["B C D A"])
    }

    @Test func nothingIsLearnedFromAFitThatOnlyWorksOnTheUtterancesItWasTaughtWith() async throws {
        let model = Self.world()
        // "B C D A" hears the person but not the person's other way of saying it, which is what the held-back phrases are.
        model.fires = ["B C D A": [.person]]
        let fixture = try Fixture.model(); defer { fixture.cleanup() }
        // Utterances 2, 5 and 8 of one source are held back: make exactly those another kind of voice.
        var utterances = Self.utterances(.person, count: 9, source: "jarvis")
        for index in [2, 5, 8] { utterances[index] = VoiceTuner.Utterance(samples: Voice.otherPerson.clip(), source: "jarvis") }
        let outcome = try await Self.tuner(model, files: fixture.files, words: Self.words, speech: Self.speech)
            .tune(utterances: utterances, ordinaryTalk: [Voice.talk.clip(seconds: 4)])
        #expect(outcome.report.heldBack == 3 && outcome.report.heardAfter == 0, "\(outcome.report)")
        guard case .notImproved(let reason) = outcome.report.verdict else { Issue.record("expected 'no better': \(outcome.report.verdict)"); return }
        #expect(reason.contains("hadn’t learned from"))
        #expect(outcome.refusal == reason)
    }

    @Test func tooFewPhrasesToHoldSomeBackCannotBeInstalled() async throws {
        let model = Self.world()
        let fixture = try Fixture.model(); defer { fixture.cleanup() }
        let outcome = try await Self.tuner(model, files: fixture.files, words: Self.words, speech: Self.speech)
            .tune(utterances: Self.utterances(.person, count: 6, source: "jarvis"), ordinaryTalk: [Voice.talk.clip(seconds: 4)])
        guard case .notEnoughSpeech(let reason) = outcome.report.verdict else { Issue.record("expected 'not enough': \(outcome.report.verdict)"); return }
        #expect(reason.contains("too few phrases"), "\(reason)")
        #expect(outcome.report.heldBack == 0 && outcome.refusal != nil)
    }

    /// Nine phrases of one source whose held-back ones (the 3rd, 6th and 9th) are a person, another way, another way — and whose learning
    /// ones include that other way too, so that a list hearing both is the better fit.
    static func mixedPhrases() -> [VoiceTuner.Utterance] {
        let voices: [Voice] = [.person, .person, .person, .person, .otherPerson, .otherPerson, .otherPerson, .person, .otherPerson]
        return voices.map { VoiceTuner.Utterance(samples: $0.clip(), source: "jarvis") }
    }

    @Test func whatIsAlreadyInForceIsWhatTheNewListHasToBeat() async throws {
        let model = Self.world()
        model.fires = ["B C D": [.person], "B C D A": [.person, .otherPerson]]   // the profile in force hears one way; a better list hears both
        let fixture = try Fixture.model(); defer { fixture.cleanup() }

        let withProfile = try await Self.tuner(model, files: fixture.files, words: Self.words, speech: Self.speech, baseline: ["B C D"])
            .tune(utterances: Self.mixedPhrases(), ordinaryTalk: [Voice.talk.clip(seconds: 4)])
        #expect(withProfile.pronunciations == ["B C D A"] && withProfile.report.verdict == .improved, "\(withProfile.pronunciations) \(withProfile.report.verdict)")
        #expect(withProfile.report.heldBack == 3 && withProfile.report.heardBefore == 1 && withProfile.report.heardAfter == 3,
                "‘before’ is how the profile in force does (1 of 3), not the built-in list (0): \(withProfile.report)")

        let withoutOne = try await Self.tuner(model, files: fixture.files, words: Self.words, speech: Self.speech)
            .tune(utterances: Self.mixedPhrases(), ordinaryTalk: [Voice.talk.clip(seconds: 4)])
        #expect(withoutOne.report.heardBefore == 0, "with nothing of the person's own, the built-in list is the one to beat")
    }

    @Test func aProfileThatAlreadyDoesAsWellIsNotReplaced() async throws {
        let model = Self.world()
        model.fires = ["B C D A": [.person, .otherPerson]]
        let fixture = try Fixture.model(); defer { fixture.cleanup() }
        let outcome = try await Self.tuner(model, files: fixture.files, words: Self.words, speech: Self.speech, baseline: ["B C D A"])
            .tune(utterances: Self.mixedPhrases(), ordinaryTalk: [Voice.talk.clip(seconds: 4)])
        #expect(outcome.report.heardBefore == 3 && outcome.report.heardAfter == 3)
        guard case .notImproved = outcome.report.verdict else { Issue.record("expected 'no better': \(outcome.report.verdict)"); return }
        #expect(outcome.refusal != nil, "a lesson that finds nothing better than the person’s profile leaves it alone")
    }

    @Test func utterancesInWhichTheNetworkHearsNothingAreLeftOut_andTooFewUsableOnesStopTheLesson() async throws {
        let model = Self.world()
        let fixture = try Fixture.model(); defer { fixture.cleanup() }
        let coughs = Self.utterances(.cough, count: 10, source: "jarvis")      // the network hears one sound in each: not a word
        let log = Protected<[String]>([])
        let outcome = try await Self.tuner(model, files: fixture.files, words: Self.words, speech: Self.speech)
            .tune(utterances: coughs + Self.utterances(.person, count: 2, source: "jarvis"), ordinaryTalk: [], log: { line in log.withLock { $0.append(line) } })
        guard case .notEnoughSpeech(let reason) = outcome.report.verdict else { Issue.record("expected 'not enough': \(outcome.report.verdict)"); return }
        #expect(reason.contains("Only 2"), "\(reason)")
        #expect(log.get().contains { $0.contains("10 stretches of sound were too short or too faint") })
    }

    @Test func withoutAnyOrdinarySpeechToCheckAgainstItWillNotInstallAnything() async throws {
        let model = Self.world()
        let fixture = try Fixture.model(); defer { fixture.cleanup() }
        let outcome = try await Self.tuner(model, files: fixture.files, words: Self.words, speech: [])
            .tune(utterances: Self.utterances(.person, count: 12, source: "jarvis"), ordinaryTalk: [])
        #expect(outcome.pronunciations == ["B C D A"], "it can still say what hears the person…")
        guard case .notEnoughSpeech(let reason) = outcome.report.verdict else { Issue.record("…but must not be installed: \(outcome.report.verdict)"); return }
        #expect(reason.contains("no ordinary speech"), "\(reason)")
    }

    @Test func theSameRecordingsGiveTheSameAnswer() async throws {
        let fixture = try Fixture.model(); defer { fixture.cleanup() }
        var seen: [[String]] = []
        for workers in [1, 3] {
            let outcome = try await Self.tuner(Self.world(), files: fixture.files, words: Self.words, speech: Self.speech, workers: workers)
                .tune(utterances: Self.utterances(.person, count: 12, source: "jarvis"), ordinaryTalk: [Voice.talk.clip(seconds: 4)])
            seen.append(outcome.pronunciations + [String(decoding: outcome.report.payload.prefix(40), as: UTF8.self)])
        }
        #expect(Set(seen.map { $0.joined(separator: "|") }).count == 1, "\(seen)")
    }

    @Test func progressNeverGoesBackAndEndsAtTheEnd() async throws {
        let fixture = try Fixture.model(); defer { fixture.cleanup() }
        let steps = Protected<[VoiceTrainingProgress]>([])
        _ = try await Self.tuner(Self.world(), files: fixture.files, words: Self.words, speech: Self.speech)
            .tune(utterances: Self.utterances(.person, count: 12, source: "jarvis"), ordinaryTalk: [Voice.talk.clip(seconds: 4)],
                  progress: { step in steps.withLock { $0.append(step) } })
        let fractions = steps.get().map(\.fraction)
        #expect(fractions == fractions.sorted(), "\(fractions)")
        #expect(fractions.last == 1 && fractions.first ?? 1 < 0.1)
        #expect(steps.get().allSatisfy { !$0.message.isEmpty })
    }

    @Test func cancellingStopsItAndReleasesTheEngines() async throws {
        let model = Self.world()
        let fixture = try Fixture.model(); defer { fixture.cleanup() }
        let engines = Protected<[SherpaOnnxWakeWordEngine]>([])
        var tuner = Self.tuner(model, files: fixture.files, words: Self.words, speech: Self.speech)
        let make = tuner.makeEngine
        tuner.makeEngine = { configuration in
            let engine = make(configuration)
            engines.withLock { $0.append(engine) }
            return engine
        }
        let started = Protected(false)
        let task = Task {
            try await tuner.tune(
                utterances: Self.utterances(.person, count: 12, source: "jarvis"), ordinaryTalk: [Voice.talk.clip(seconds: 4)],
                progress: { step in if step.fraction > 0.2 { started.withLock { $0 = true } } }
            )
        }
        try await eventually("the analysis to be under way") { started.get() }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("a cancelled analysis must not return a result")
        } catch let error as VoiceTrainingError {
            #expect(error == .cancelled)
        }
        #expect(!engines.get().isEmpty && engines.get().allSatisfy { $0.activity.fed >= 0 })
    }

    @Test func anEngineThatCannotBeLoadedIsReportedForThePerson() async throws {
        let fixture = try Fixture.model(); defer { fixture.cleanup() }
        var tuner = VoiceTuner(library: URL(fileURLWithPath: "/nonexistent/lib.dylib"), model: fixture.files, options: VoiceTuner.Options())
        tuner.makeEngine = { configuration in
            var configuration = configuration
            configuration.integrity = .unverified
            return SherpaOnnxWakeWordEngine(configuration: configuration)   // the real library, which is not there
        }
        do {
            _ = try await tuner.tune(utterances: Self.utterances(.person, count: 12, source: "jarvis"), ordinaryTalk: [])
            Issue.record("expected the engine to be unavailable")
        } catch let error as VoiceTrainingError {
            guard case .unavailable(let message) = error else { Issue.record("wrong error \(error)"); return }
            #expect(!message.isEmpty)
        }
    }

    @Test func theCandidatesIncludeTheTextbookVariationsAndOnlyUseSoundsTheModelHas() {
        let candidates = TuningRun.candidatePronunciations()
        #expect(candidates.count > 1_000 && candidates.contains("JH AA1 R V IH0 S") && candidates.contains("HH AA1 B IY0 Z"))
        #expect(candidates == candidates.sorted() && Set(candidates).count == candidates.count)
    }
}

// MARK: - The file the profile lives in

struct VoiceProfileFileTests {
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aProfileIsReadableTextWithItsOwnHeader() throws {
        let folder = try Self.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let day = Date(timeIntervalSince1970: 1_790_000_000)   // 2026-09-21
        let text = VoiceProfileFile.text(pronunciations: ["JH AA1 R V IH0 S", "HH AA1 R B IY0 S"], phrases: 28, sensitivity: 0.5, date: day)
        let lines = text.components(separatedBy: "\n")
        #expect(lines[0].hasPrefix("# Pronunciations of “Jarvis” learned from your voice"))
        #expect(lines[1].contains("28 phrases") && lines[1].contains("sensitivity 0.50") && lines[1].contains("learned 2026-"))
        #expect(lines[2] == "JH AA1 R V IH0 S" && lines[3] == "HH AA1 R B IY0 S")
        // …and the engine reads exactly the two lines of sounds, the header being comments.
        let file = folder.appendingPathComponent("jarvis_pronunciations.txt")
        try text.write(to: file, atomically: true, encoding: .utf8)
        #expect(try SherpaOnnxBackend.parsePronunciations(from: file) == ["JH AA1 R V IH0 S", "HH AA1 R B IY0 S"])
    }

    @Test func writingKeepsWhatWasThereAndNeverOverwritesAnEarlierCopy() throws {
        let folder = try Self.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("jarvis_pronunciations.txt")
        try "# mine, by hand\nJH AA1 R V AH0 S\n".write(to: file, atomically: true, encoding: .utf8)

        #expect(try VoiceProfileFile.write("first\n", replacing: file) == "jarvis_pronunciations.txt.previous")
        #expect(try VoiceProfileFile.write("second\n", replacing: file) == "jarvis_pronunciations.txt.previous-2")
        #expect(try VoiceProfileFile.write("third\n", replacing: file) == "jarvis_pronunciations.txt.previous-3")
        #expect(try String(contentsOf: file, encoding: .utf8) == "third\n")
        #expect(try String(contentsOf: folder.appendingPathComponent("jarvis_pronunciations.txt.previous"), encoding: .utf8) == "# mine, by hand\nJH AA1 R V AH0 S\n",
                "the file the person wrote is still there, however many lessons follow")
        #expect(try String(contentsOf: folder.appendingPathComponent("jarvis_pronunciations.txt.previous-2"), encoding: .utf8) == "first\n")
    }

    @Test func aFirstProfileCreatesTheFolderAndKeepsNothing() throws {
        let folder = try Self.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Models/jarvis_pronunciations.txt")
        #expect(try VoiceProfileFile.write("x\n", replacing: file) == nil)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aFolderIsNeverReplaced() throws {
        let folder = try Self.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("a-folder")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try VoiceProfileFile.write("x\n", replacing: target) }
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func settingAsideKeepsTheProfileUnderANewName() throws {
        let folder = try Self.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("jarvis_pronunciations.txt")
        #expect(try VoiceProfileFile.setAside(file) == nil, "nothing to set aside")
        try "profile\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(try VoiceProfileFile.setAside(file) == "jarvis_pronunciations.txt.previous")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try "again\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(try VoiceProfileFile.setAside(file) == "jarvis_pronunciations.txt.previous-2")
    }

    @Test func revertingPutsBackTheProfileThatWasThere_andLosesNothing() throws {
        let folder = try Self.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("jarvis_pronunciations.txt")
        try "# mine, by hand\nJH AA1 R V AH0 S\n".write(to: file, atomically: true, encoding: .utf8)
        let kept = try VoiceProfileFile.write("learned\n", replacing: file)
        #expect(kept == "jarvis_pronunciations.txt.previous")

        try VoiceProfileFile.revert(file, restoring: kept)
        #expect(try String(contentsOf: file, encoding: .utf8) == "# mine, by hand\nJH AA1 R V AH0 S\n", "the person’s own list is in force again")
        #expect(try String(contentsOf: folder.appendingPathComponent("jarvis_pronunciations.txt.previous"), encoding: .utf8) == "# mine, by hand\nJH AA1 R V AH0 S\n")
        #expect(try String(contentsOf: folder.appendingPathComponent("jarvis_pronunciations.txt.previous-2"), encoding: .utf8) == "learned\n", "and what was given up is kept")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains("restoring") }
        #expect(leftovers.isEmpty, "\(leftovers)")
    }

    @Test func revertingWhenNothingWasThereGoesBackToTheEnginesOwnList() throws {
        let folder = try Self.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("jarvis_pronunciations.txt")
        let kept = try VoiceProfileFile.write("learned\n", replacing: file)
        #expect(kept == nil)
        try VoiceProfileFile.revert(file, restoring: kept)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try String(contentsOf: folder.appendingPathComponent("jarvis_pronunciations.txt.previous"), encoding: .utf8) == "learned\n")
    }

    @Test func revertingWithoutTheKeptCopyOrWithANameThatIsNoFileHereSetsTheProfileAside() throws {
        for name in ["jarvis_pronunciations.txt.previous", "../elsewhere", "", ".."] {
            let folder = try Self.folder(); defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("jarvis_pronunciations.txt")
            try "learned\n".write(to: file, atomically: true, encoding: .utf8)
            try VoiceProfileFile.revert(file, restoring: name)       // (the copy it names is not there, or is not a name at all)
            #expect(!FileManager.default.fileExists(atPath: file.path), "‘\(name)’")
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("jarvis_pronunciations.txt.previous").path), "‘\(name)’")
        }
    }

    @Test func aProfileFileTooLargeToBeOneIsDescribedWithoutReadingItAll() throws {
        let folder = try Self.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("jarvis_pronunciations.txt")
        try Data(repeating: 0x41, count: 8 * 1_024 * 1_024).write(to: file)
        let started = ContinuousClock.now
        #expect(VoiceProfileFile.describe(file)?.summary == "A pronunciation file that can’t be read")
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test func theProfileInForceIsWhatTheEngineWouldRead() throws {
        let folder = try Self.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("jarvis_pronunciations.txt")
        #expect(SherpaOnnxBackend.customPronunciations(in: folder) == nil, "no file: the built-in list")
        try "# only a comment\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(SherpaOnnxBackend.customPronunciations(in: folder) == nil, "a file with no line in it leaves the built-in list in force too")
        try "# mine\nJH AA1  R V AH0 S\nHH AA1 B IY0 Z # and this\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(SherpaOnnxBackend.customPronunciations(in: folder) == ["JH AA1 R V AH0 S", "HH AA1 B IY0 Z"])
        try Data([0xff, 0xfe, 0x00]).write(to: file)
        #expect(SherpaOnnxBackend.customPronunciations(in: folder) == nil, "a file the engine cannot read is no baseline")
    }

    @Test func theProfileIsDescribedForThePerson() throws {
        let folder = try Self.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("jarvis_pronunciations.txt")
        #expect(VoiceProfileFile.describe(file) == nil)

        try VoiceProfileFile.text(pronunciations: ["A B", "C D", "E F"], phrases: 28, sensitivity: 1, date: Date()).write(to: file, atomically: true, encoding: .utf8)
        let learned = try #require(VoiceProfileFile.describe(file))
        #expect(learned.summary.hasPrefix("3 ways of saying it, learned on ") && learned.learnedAt != nil, "\(learned.summary)")

        try "# written by hand\nJH AA1 R V AH0 S\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(VoiceProfileFile.describe(file)?.summary == "A pronunciation file of your own (1 way of saying it)")

        try Data([0xff, 0xfe, 0x00]).write(to: file)
        #expect(VoiceProfileFile.describe(file)?.summary == "A pronunciation file that can’t be read")
    }
}

// MARK: - The trainer the application sees

struct VoiceTrainerTests {
    @Test func theDescriptorOfferedToTheAppCanLearn_andTheOneWithoutAFolderCannot() {
        let folder = FileManager.default.temporaryDirectory
        #expect(SherpaOnnxBackend.descriptor.voiceTrainer == nil)
        #expect(SherpaOnnxBackend.descriptor(profileDirectory: folder, referenceSpeechCache: folder).voiceTrainer != nil)
    }

    @Test func installingWritesTheProfileTheEngineReads_andRemovingSetsItAside() throws {
        let folder = try VoiceProfileFileTests.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let trainer = SherpaOnnxBackend.voiceTrainer(profileDirectory: folder, referenceSpeechCache: folder)
        #expect(trainer.currentProfile() == nil)

        let text = VoiceProfileFile.text(pronunciations: ["JH AA1 R B IY0 Z"], phrases: 12, sensitivity: 0.5)
        let report = VoiceTrainingReport(verdict: .improved, payload: Data(text.utf8))
        let change = try trainer.install(report)
        #expect(change.keptPrevious == nil)
        #expect(trainer.currentProfile()?.summary.hasPrefix("1 way of saying it") == true)
        // The engine's own reader sees the pronunciation.
        #expect(try SherpaOnnxBackend.parsePronunciations(from: folder.appendingPathComponent("jarvis_pronunciations.txt")) == ["JH AA1 R B IY0 Z"])

        #expect(try trainer.removeProfile()?.keptPrevious == "jarvis_pronunciations.txt.previous")
        #expect(trainer.currentProfile() == nil)
        #expect(try trainer.removeProfile() == nil, "nothing left to set aside")
    }

    @Test func aFailedInstallIsUndoneByTheTrainerThatMadeIt() throws {
        let folder = try VoiceProfileFileTests.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("jarvis_pronunciations.txt")
        let trainer = SherpaOnnxBackend.voiceTrainer(profileDirectory: folder, referenceSpeechCache: folder)
        try "JH AA1 R V AH0 S\n".write(to: file, atomically: true, encoding: .utf8)     // a list of the person’s own

        let report = VoiceTrainingReport(verdict: .improved, payload: Data(VoiceProfileFile.text(pronunciations: ["JH AA1 R B IY0 Z"], phrases: 12, sensitivity: 0.5).utf8))
        let change = try trainer.install(report)
        #expect(try SherpaOnnxBackend.parsePronunciations(from: file) == ["JH AA1 R B IY0 Z"])
        try trainer.revert(change)
        #expect(try SherpaOnnxBackend.parsePronunciations(from: file) == ["JH AA1 R V AH0 S"], "the person’s own list is back in force")
    }

    @Test func learningWithoutTheEnginesFilesSaysSoInsteadOfFailingObscurely() async throws {
        let folder = try VoiceProfileFileTests.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let trainer = SherpaOnnxBackend.voiceTrainer(profileDirectory: folder, referenceSpeechCache: folder)
        do {
            _ = try await trainer.learn(VoiceRecordings(), EngineEnvironment(), { _ in })
            Issue.record("expected the engine to be unavailable")
        } catch let error as VoiceTrainingError {
            guard case .unavailable(let message) = error else { Issue.record("wrong error \(error)"); return }
            #expect(message.contains("files are missing"), "\(message)")
        }
    }

    @Test func aResultThatIsNotAnImprovementCannotBeInstalled() throws {
        let folder = try VoiceProfileFileTests.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let trainer = SherpaOnnxBackend.voiceTrainer(profileDirectory: folder, referenceSpeechCache: folder)
        #expect(throws: (any Error).self) { try trainer.install(VoiceTrainingReport(verdict: .notImproved(reason: "no"), payload: Data("x".utf8))) }
        #expect(throws: (any Error).self) { try trainer.install(VoiceTrainingReport(verdict: .improved, payload: Data())) }
        #expect(trainer.currentProfile() == nil)
    }
}

// MARK: - Against the real network

/// The whole analysis on the real model, with the Mac's own voices standing in for the person. It does not claim an improvement
/// (clear English voices are heard already); it shows that nothing in the real path — the library, the recogniser, the engines,
/// the checks — breaks, and that what comes out is coherent.
@Suite(.enabled(if: RealSherpa.isAvailable && RealSherpa.voiceExists("Samantha") && RealSherpa.voiceExists("Moira"), "needs the sherpa files and macOS voices"), .timeLimit(.minutes(3)))
struct RealVoiceTunerTests {
    @Test func theRealModelCanBeAnalysedEndToEnd() async throws {
        let voices = ["Samantha", "Moira"]
        let phrases = ["Jarvis", "Hey Jarvis", "Jarvis, what time is it?", "Okay Jarvis, turn on the lights.", "Jarvis, are you there?"]
        var utterances: [VoiceTuner.Utterance] = []
        for voice in voices {
            for phrase in phrases { utterances.append(.init(samples: try RealSherpa.speech(phrase, voice: voice), source: voice)) }
        }
        let words = try ["Travis", "Jarvik"].map { try RealSherpa.speech($0, voice: "Samantha") }
        let speech = try [
            "After the concert we walked along the river until the lights of the bridge came on. It was cold, but nobody wanted to go home yet.",
        ].map { try RealSherpa.speech($0, voice: "Moira") }

        var options = VoiceTuner.Options()
        options.workers = 2
        options.usesTextbookVariations = false    // minutes of work for the real list; here only what the network is heard to say…
        options.candidateLimit = 5                // …and only a few of those: this is a check that the real path works, not a measurement
        options.noisyCopies = 0
        options.injectedReference = (words, speech)
        let steps = Protected<[Double]>([])
        let outcome = try await VoiceTuner(library: RealSherpa.library, model: RealSherpa.model, options: options)
            .tune(utterances: utterances, ordinaryTalk: [try RealSherpa.speech("I went to the market this morning and bought bread, tomatoes and a little cheese.", voice: "Samantha")],
                  progress: { step in steps.withLock { $0.append(step.fraction) } })

        let report = outcome.report
        #expect(report.total >= 6 && report.total <= utterances.count, "most of the clear voices' phrases have something to learn from: \(report.total)")
        #expect(report.heldBack >= 3 && report.heardBefore <= report.heldBack && report.heardAfter <= report.heldBack)
        #expect(report.totalHeardBefore >= report.total / 2, "the built-in list hears clear voices: \(report.totalHeardBefore) of \(report.total)")
        #expect(report.silenceChecks == words.count + speech.count + 1)
        #expect(steps.get() == steps.get().sorted() && steps.get().last == 1)
        if case .improved = report.verdict {
            // What it would install must be a profile the engine accepts.
            let folder = try VoiceProfileFileTests.folder(); defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("jarvis_pronunciations.txt")
            try outcome.profileText.write(to: file, atomically: true, encoding: .utf8)
            let parsed = try #require(try SherpaOnnxBackend.parsePronunciations(from: file))
            #expect(parsed == outcome.pronunciations)
            let engine = SherpaOnnxWakeWordEngine(configuration: .init(libraryURL: RealSherpa.library, model: RealSherpa.model, pronunciations: parsed))
            try await engine.initialize()
            engine.shutdown()
        } else {
            #expect(outcome.refusal != nil)
        }
    }
}
