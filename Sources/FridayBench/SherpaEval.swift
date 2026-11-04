import CryptoKit
import Foundation
import FridayPlatform
import SherpaOnnxBackend
import WakeWordKit

// jarvis-bench kws-eval — how well does the keyword spotter hear "Jarvis", and what does it hear that it should not?
//
// The corpus is synthesised with the voices macOS ships (`say`), so the whole test needs no recording and no
// microphone: many English voices, and — as a stand-in for a Spanish speaker's accent — Spanish voices reading the
// English word. Everything is cached under the temporary directory. Nothing is stored in the repository.
//
//   jarvis-bench kws-eval [--profile phone16|phone|phone16-fp32|phone-fp32|bpe] [--sherpa DIR] [--sweep] [--quick]
//                         [--threshold T] [--boost B] [--paths N] [--trailing N] [--noise AMPLITUDE] [--minutes M]
//                         [--keywords "TOKENS/TOKENS"] [--set heldout|continuous|spanish] [--rates 200,260,320] [--peak -24] [--agc -10 | --no-agc]
//                         [--crest 5] [--click -10 [--click-gap 0.5]] [--verbose]
//
// Without --boost/--threshold/--paths it evaluates what the app does at the middle of the Sensitivity slider.
//
// TTS is cleaner than a real voice in a real room, so absolute numbers are optimistic; use it to *compare* settings.

private struct EvalOptions {
    var profile = "phone16"
    var sherpa = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Vendor/SherpaOnnx")
    var sweep = false
    var quick = false
    var verbose = false
    /// Evaluate on a second set — other sentences, other speeds, other look-alike words — that no setting was tuned on.
    var heldOut = false
    /// `--set continuous`: "Jarvis" with another word right in front of it, said fast and without a pause — how it is used.
    var continuous = false
    /// `--agc -10` sets the level speech is brought to (dBFS); `--no-agc` feeds the model the audio as it is.
    var agc: LevelNormaliser.Configuration? = LevelNormaliser.Configuration()
    /// `--peak -24`: scale every clip so that its loudest sample is at this level in dBFS. The synthetic voices come out at about −6 dBFS;
    /// a microphone at arm's length delivers speech 15–25 dB lower, and the network does not hear the same thing at both levels.
    var peakDecibels: Float?
    /// `--set spanish`: Spanish voices and Spanish sentences — "Oye Jarvis", Spanish names that sound like it (Javier), ordinary Spanish speech.
    var spanish = false
    /// `--rates 200,260,320`: speaking rates (words per minute) of the word clips, instead of the set's own.
    var rates: [Int]?
    var threshold: Float?
    var boost: Float?
    var trailing = 1
    var paths = SherpaOnnxBackend.defaultMaxActivePaths
    var frame = 1_600
    var gate = true
    var keywords: [String]?
    var speechMinutes = 30.0
    var thresholds: [Float]?
    var boosts: [Float]?
    /// Peak amplitude of the room noise mixed into every clip. Synthesised audio has *digital* silence between words,
    /// which no microphone ever delivers; a model fed exact zeros is outside what it was trained on.
    var noise: Float = 0.003
    /// `--click -10 [--click-gap 0.5]`: a click of this peak (dBFS) — a key pressed, a cup put down — that long before every clip, to see what a
    /// loud transient just ahead of the word does to the level stage.
    var clickDecibels: Float?
    var clickGap = 0.5
    /// `--crest 5`: how many times its RMS a frame's peak may count for in the level stage (1000 = no limit).
    var crest: Float?

    init(_ arguments: [String]) {
        var iterator = arguments.dropFirst(2).makeIterator()
        while let flag = iterator.next() {
            switch flag {
            case "--crest": crest = iterator.next().flatMap(Float.init)
            case "--click": clickDecibels = iterator.next().flatMap(Float.init)
            case "--click-gap": clickGap = iterator.next().flatMap(Double.init) ?? clickGap
            case "--profile": profile = iterator.next() ?? profile
            case "--sherpa": sherpa = URL(fileURLWithPath: iterator.next() ?? sherpa.path)
            case "--sweep": sweep = true
            case "--quick": quick = true
            case "--verbose": verbose = true
            case "--heldout": heldOut = true
            case "--set":
                switch iterator.next() {
                case "heldout": heldOut = true
                case "continuous": continuous = true
                case "spanish": spanish = true
                default: break
                }
            case "--no-agc": agc = nil
            case "--agc":
                if let target = iterator.next().flatMap(Float.init) { var c = LevelNormaliser.Configuration(); c.targetPeakDecibels = target; agc = c }
            case "--peak": peakDecibels = iterator.next().flatMap(Float.init)
            case "--rates": rates = iterator.next().map { $0.split(separator: ",").compactMap { Int($0) } }
            case "--threshold": threshold = iterator.next().flatMap(Float.init)
            case "--boost": boost = iterator.next().flatMap(Float.init)
            case "--trailing": trailing = iterator.next().flatMap(Int.init) ?? trailing
            case "--no-gate": gate = false
            case "--paths": paths = iterator.next().flatMap(Int.init) ?? paths
            case "--frame": frame = iterator.next().flatMap(Int.init) ?? frame
            case "--keywords": keywords = iterator.next().map { $0.split(separator: "/").map { String($0).trimmingCharacters(in: .whitespaces) } }
            case "--minutes": speechMinutes = iterator.next().flatMap(Double.init) ?? speechMinutes
            case "--noise": noise = iterator.next().flatMap(Float.init) ?? noise
            case "--thresholds": thresholds = iterator.next().map { $0.split(separator: ",").compactMap { Float($0) } }
            case "--boosts": boosts = iterator.next().map { $0.split(separator: ",").compactMap { Float($0) } }
            default:
                // Said aloud: an option that is silently ignored (a shell that did not split "--peak -22" into two words, a typo) makes the
                // run measure something other than what was asked, and nothing shows it.
                FileHandle.standardError.write(Data("jarvis-bench: ignoring “\(flag)” — not an option this command knows\n".utf8))
            }
        }
        if let crest, agc != nil { agc?.crestLimit = crest }
    }
}

// MARK: - Model profiles under evaluation

func profile(named name: String) -> SherpaModelProfile? {
    let phoneKeywords = SherpaOnnxBackend.phoneModel.pronunciations
    switch name {
    case "phone16":
        return SherpaOnnxBackend.phoneModel
    case "phone":
        return SherpaModelProfile(
            directory: "sherpa-kws", encoder: "encoder-epoch-13-avg-2-chunk-8-left-64.int8.onnx",
            decoder: "decoder-epoch-13-avg-2-chunk-8-left-64.onnx", joiner: "joiner-epoch-13-avg-2-chunk-8-left-64.int8.onnx",
            tokens: "tokens.txt", pronunciations: phoneKeywords
        )
    case "phone16-fp32":
        return SherpaModelProfile(
            directory: "sherpa-kws", encoder: "encoder-epoch-13-avg-2-chunk-16-left-64.onnx",
            decoder: "decoder-epoch-13-avg-2-chunk-16-left-64.onnx", joiner: "joiner-epoch-13-avg-2-chunk-16-left-64.onnx",
            tokens: "tokens.txt", pronunciations: phoneKeywords
        )
    case "phone-fp32":
        return SherpaModelProfile(
            directory: "sherpa-kws", encoder: "encoder-epoch-13-avg-2-chunk-8-left-64.onnx",
            decoder: "decoder-epoch-13-avg-2-chunk-8-left-64.onnx", joiner: "joiner-epoch-13-avg-2-chunk-8-left-64.onnx",
            tokens: "tokens.txt", pronunciations: phoneKeywords
        )
    case "bpe":
        return SherpaModelProfile(
            directory: "sherpa-kws-bpe", encoder: "encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx",
            decoder: "decoder-epoch-12-avg-2-chunk-16-left-64.onnx", joiner: "joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx",
            tokens: "tokens.txt", pronunciations: ["▁JA R VI S", "▁JA R V IS", "▁ J AR VI S"]
        )
    default:
        return nil
    }
}

// MARK: - Corpus

private enum Kind: String { case positive, decoy, speech, lookalikeSpeech, sound }

private struct Clip {
    let kind: Kind
    let voice: String
    let text: String
    let rate: Int
    let samples: [Float]
    var isSpanish: Bool { ReferenceCorpus.spanishVoices.contains(voice) || ReferenceCorpus.spanishSetVoices.contains(voice) }
}


private let corpusDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-kws-eval", isDirectory: true)

/// 16 kHz mono samples of `text` spoken by `voice`, synthesised once and cached.
private func speech(voice: String, rate: Int, text: String) -> [Float]? {
    MacSpeech.samples(voice: voice, rate: rate, text: text, cache: corpusDirectory)
}

/// Renders clips that are not cached yet, several `say` processes at a time (one after another a cold cache takes a quarter of an hour).
private func prepare(_ requests: [(voice: String, rate: Int, text: String)], concurrency: Int = 6) {
    MacSpeech.prepare(requests.map { MacSpeech.Request(voice: $0.voice, rate: $0.rate, text: $0.text) }, cache: corpusDirectory, concurrency: concurrency)
}

private func readWAV(_ url: URL) -> [Float]? { MacSpeech.readWAV(url) }

/// Any audio file macOS can read, as 16 kHz mono samples.
private func samples(fromRecording url: URL) -> [Float]? { MacSpeech.samples(fromRecording: url) }

// MARK: - Running a configuration

private struct Outcome {
    var clips = 0
    var detected = 0           // clips with at least one detection
    var detections = 0         // total detections
    var seconds = 0.0
    var latencies: [Double] = []   // from the end of the spoken word to the detection, one-word clips only
}

private func contentSeed(_ clip: [Float]) -> UInt64 { EvaluationAudio.contentSeed(clip) }

private func withRoomNoise(_ samples: [Float], level: Float, seed: UInt64) -> [Float] {
    EvaluationAudio.roomNoise(samples, level: level, seed: seed)
}

private func feed(
    _ clip: [Float], through engine: SherpaOnnxWakeWordEngine, sensitivity: Float, noise: Float = 0, seed: UInt64 = 1,
    click: (decibels: Float, gap: Double)? = nil
) throws -> [Double] {
    try EvaluationAudio.feed(clip, through: engine, sensitivity: sensitivity, noise: noise, seed: seed, click: click)
}

/// `clip` scaled so that its loudest sample is at `decibels` dBFS.
private func scaled(_ clip: [Float], toPeak decibels: Float) -> [Float] {
    let peak = clip.reduce(0) { max($0, abs($1)) }
    guard peak > 0 else { return clip }
    let gain = powf(10, decibels / 20) / peak
    return clip.map { $0 * gain }
}

/// Where the voiced part of a clip ends, in seconds from the clip's start (energy above 3 % of the peak).
private func speechEnd(_ clip: [Float]) -> Double {
    let peak = clip.reduce(0) { max($0, abs($1)) }
    guard peak > 0, let last = clip.lastIndex(where: { abs($0) > 0.03 * peak }) else { return 0 }
    return Double(last) / 16_000
}

private struct Report {
    var english = Outcome()
    var spanish = Outcome()
    var decoys = Outcome()
    var speech = Outcome()
    var lookalikeSpeech = Outcome()
    var sounds = Outcome()
    var perText: [String: Outcome] = [:]
    var perRate: [Int: Outcome] = [:]
    var perDecoy: [String: Int] = [:]
    var perVoice: [String: Outcome] = [:]
    var speechAlerts: [(voice: String, text: String)] = []
}

private func evaluate(engine: SherpaOnnxWakeWordEngine, clips: [Clip], verbose: Bool, noise: Float, click: (decibels: Float, gap: Double)? = nil) throws -> Report {
    var report = Report()
    for (number, clip) in clips.enumerated() {
        let times = try feed(clip.samples, through: engine, sensitivity: 0.5, noise: noise, seed: UInt64(number), click: click)
        let detections = times.count
        let seconds = Double(clip.samples.count) / 16_000
        if clip.kind == .positive, let first = times.first, clip.text.hasPrefix("Jarvis") && clip.text.count <= 8 {
            report.english.latencies.append(first - 0.5 - max(0, click?.gap ?? 0) - speechEnd(clip.samples))   // 0.5 s of leading padding (and the click's lead)
        }
        switch clip.kind {
        case .positive:
            if clip.isSpanish {
                report.spanish.clips += 1; report.spanish.detected += detections > 0 ? 1 : 0
            } else {
                report.english.clips += 1; report.english.detected += detections > 0 ? 1 : 0
            }
            report.perText[clip.text, default: Outcome()].clips += 1
            report.perText[clip.text, default: Outcome()].detected += detections > 0 ? 1 : 0
            report.perRate[clip.rate, default: Outcome()].clips += 1
            report.perRate[clip.rate, default: Outcome()].detected += detections > 0 ? 1 : 0
            report.perVoice[clip.voice, default: Outcome()].clips += 1
            report.perVoice[clip.voice, default: Outcome()].detected += detections > 0 ? 1 : 0
            if verbose && detections == 0 { print("    missed: \(clip.voice) @\(clip.rate) “\(clip.text)”") }
        case .decoy:
            report.decoys.clips += 1
            report.decoys.detected += detections > 0 ? 1 : 0
            if detections > 0 { report.perDecoy[clip.text, default: 0] += 1 }
            if verbose && detections > 0 { print("    false accept: \(clip.voice) “\(clip.text)”") }
        case .speech:
            report.speech.clips += 1
            report.speech.seconds += seconds
            report.speech.detections += detections
            if detections > 0 { report.speechAlerts.append((clip.voice, String(clip.text.prefix(40)))) }
        case .sound:
            report.sounds.clips += 1
            report.sounds.detections += detections
            if detections > 0 { report.speechAlerts.append((clip.voice, "[sound] " + clip.text)) }
        case .lookalikeSpeech:
            report.lookalikeSpeech.clips += 1
            report.lookalikeSpeech.seconds += seconds
            report.lookalikeSpeech.detections += detections
            if detections > 0 { report.speechAlerts.append((clip.voice, "[look-alike] " + String(clip.text.prefix(40)))) }
        }
    }
    return report
}

private func percent(_ a: Int, _ b: Int) -> String { b == 0 ? "–" : String(format: "%5.1f%%", 100 * Double(a) / Double(b)) }

private func printReport(_ report: Report, title: String) {
    let hours = report.speech.seconds / 3_600
    let perHour = hours > 0 ? Double(report.speech.detections) / hours : 0
    print(String(format: "  %@", title))
    print("    hits      English voices \(percent(report.english.detected, report.english.clips)) (\(report.english.detected)/\(report.english.clips))"
        + "   Spanish voices \(percent(report.spanish.detected, report.spanish.clips)) (\(report.spanish.detected)/\(report.spanish.clips))")
    print("    decoys    false accepts \(report.decoys.detected)/\(report.decoys.clips)"
        + (report.perDecoy.isEmpty ? "" : "  — " + report.perDecoy.sorted { $0.value > $1.value }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")))
    print(String(format: "    speech    %d false activations in %.1f min of ordinary speech  (%.1f per hour)",
                 report.speech.detections, report.speech.seconds / 60, perHour))
    if report.sounds.clips > 0 {
        print("    sounds    \(report.sounds.detections) false activations in \(report.sounds.clips) clips of non-speech sound (the system's alert sounds, noise bursts, clicks), each at three levels")
    }
    let lookalikeHours = report.lookalikeSpeech.seconds / 3_600
    if lookalikeHours > 0 {
        print(String(format: "    look-alike sentences  %d false activations in %.1f min of speech full of names like Travis and Gervais",
                     report.lookalikeSpeech.detections, report.lookalikeSpeech.seconds / 60))
    }
    let sorted = report.english.latencies.sorted()
    if !sorted.isEmpty {
        print(String(format: "    latency   word end → detection: median %.0f ms, 90th percentile %.0f ms (%d one-word clips)",
                     sorted[sorted.count / 2] * 1000, sorted[min(sorted.count - 1, sorted.count * 9 / 10)] * 1000, sorted.count))
    }
}

// MARK: - Entry point

func kwsEval(_ arguments: [String]) async {
    let options = EvalOptions(arguments)
    guard var chosen = profile(named: options.profile) else { print("unknown profile \(options.profile)"); exit(2) }
    if let keywords = options.keywords { chosen = SherpaModelProfile(directory: chosen.directory, encoder: chosen.encoder, decoder: chosen.decoder, joiner: chosen.joiner, tokens: chosen.tokens, pronunciations: keywords) }

    let library = options.sherpa.appendingPathComponent("lib/libsherpa-onnx-c-api.dylib")
    let modelDirectory = options.sherpa.appendingPathComponent("models/\(chosen.directory)")
    guard FileManager.default.fileExists(atPath: library.path) else { print("library not found at \(library.path) — run Scripts/fetch-sherpa.sh"); exit(2) }
    let model = SherpaOnnxWakeWordEngine.ModelFiles(
        encoder: modelDirectory.appendingPathComponent(chosen.encoder), decoder: modelDirectory.appendingPathComponent(chosen.decoder),
        joiner: modelDirectory.appendingPathComponent(chosen.joiner), tokens: modelDirectory.appendingPathComponent(chosen.tokens)
    )

    // Build the corpus (cached after the first run).
    print("Preparing the synthetic corpus in \(corpusDirectory.path) (first run only: a few minutes)…")
    var clips: [Clip] = []
    let english = options.spanish ? [] : (options.quick ? Array(ReferenceCorpus.englishVoices.prefix(6)) : ReferenceCorpus.englishVoices)
    let spanish = options.spanish ? ReferenceCorpus.spanishSetVoices : ReferenceCorpus.spanishVoices
    let neutralTexts = options.spanish ? ReferenceCorpus.spanishParagraphs : ReferenceCorpus.paragraphs
    let lookalikeTexts = options.spanish ? ReferenceCorpus.spanishLookalikeParagraphs : ReferenceCorpus.lookalikeParagraphs
    let rates = options.rates ?? (options.spanish ? [150, 190, 230] : options.continuous ? [200, 260, 320] : options.heldOut ? [130, 175, 235] : (options.quick ? [175] : [150, 210]))
    let positivePhrases = options.spanish ? ReferenceCorpus.spanishPositives : options.continuous ? ReferenceCorpus.continuousPositives : options.heldOut ? ReferenceCorpus.heldOutPositives : ReferenceCorpus.positives
    let decoyWords = options.spanish ? ReferenceCorpus.spanishDecoys : options.heldOut ? ReferenceCorpus.heldOutDecoys : ReferenceCorpus.decoys
    let speechVoices = options.spanish ? spanish : Array(english.prefix(8)) + spanish
    var requests: [(voice: String, rate: Int, text: String)] = []
    for voice in english + spanish {
        for text in positivePhrases { for rate in rates { requests.append((voice, rate, text)) } }
        for text in decoyWords { requests.append((voice, 175, text)) }
    }
    // The ordinary-speech clips are taken in this order until there is enough (about three a minute).
    for index in 0..<min(speechVoices.count * neutralTexts.count, Int(options.speechMinutes * 4) + 20) {
        requests.append((speechVoices[index % speechVoices.count], 175, neutralTexts[index % neutralTexts.count]))
    }
    let lookalikeCount = lookalikeTexts.count * 4   // 32 clips ≈ 10 min
    for index in 0..<lookalikeCount {
        requests.append((speechVoices[index % speechVoices.count], 175, lookalikeTexts[index % lookalikeTexts.count]))
    }
    prepare(requests)
    func atLevel(_ clip: [Float]) -> [Float] { options.peakDecibels.map { scaled(clip, toPeak: $0) } ?? clip }
    for voice in english + spanish {
        for text in positivePhrases {
            for rate in rates {
                if let samples = speech(voice: voice, rate: rate, text: text) { clips.append(Clip(kind: .positive, voice: voice, text: text, rate: rate, samples: atLevel(samples))) }
            }
        }
        for text in decoyWords {
            if let samples = speech(voice: voice, rate: 175, text: text) { clips.append(Clip(kind: .decoy, voice: voice, text: text, rate: 175, samples: atLevel(samples))) }
        }
    }
    var speechSeconds = 0.0
    var paragraph = 0
    outer: while speechSeconds < options.speechMinutes * 60 {
        for voice in speechVoices {
            let text = neutralTexts[paragraph % neutralTexts.count]
            paragraph += 1
            guard let samples = speech(voice: voice, rate: 175, text: text) else { continue }
            clips.append(Clip(kind: .speech, voice: voice, text: text, rate: 175, samples: atLevel(samples)))
            speechSeconds += Double(samples.count) / 16_000
            if speechSeconds >= options.speechMinutes * 60 { break outer }
        }
    }
    // Non-speech sounds the room can make: the Mac's own alert sounds, bursts of noise, claps. Each at three levels, because the
    // level stage raises whatever opens the gate to the level of speech.
    do {
        var sounds: [(name: String, samples: [Float])] = []
        for name in ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"] {
            if let x = samples(fromRecording: URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")) { sounds.append((name, x)) }
        }
        for (index, seconds) in [0.4, 1.0, 3.0].enumerated() {
            sounds.append(("noise burst \(seconds) s", withRoomNoise([Float](repeating: 0, count: Int(seconds * 16_000)), level: 1, seed: UInt64(20 + index))))
        }
        // A clap: a click that dies away in a quarter of a second.
        sounds.append(("clap", withRoomNoise([Float](repeating: 0, count: 4_000), level: 1, seed: 31).enumerated().map { $0.element * expf(-Float($0.offset) / 600) }))
        for (name, x) in sounds { for level: Float in [-30, -20, -10] { clips.append(Clip(kind: .sound, voice: "\(name)", text: "\(name) at \(Int(level)) dBFS", rate: 0, samples: scaled(x, toPeak: level))) } }
    }
    var lookalikeSeconds = 0.0
    for index in 0..<lookalikeCount {
        let text = lookalikeTexts[index % lookalikeTexts.count]
        guard let samples = speech(voice: speechVoices[index % speechVoices.count], rate: 175, text: text) else { continue }
        clips.append(Clip(kind: .lookalikeSpeech, voice: speechVoices[index % speechVoices.count], text: text, rate: 175, samples: atLevel(samples)))
        lookalikeSeconds += Double(samples.count) / 16_000
    }
    let positives = clips.filter { $0.kind == .positive }.count
    print("Corpus: \(positives) positive clips, \(clips.filter { $0.kind == .decoy }.count) decoys, \(String(format: "%.1f", speechSeconds / 60)) min of ordinary speech, "
        + "\(String(format: "%.1f", lookalikeSeconds / 60)) min of sentences with look-alike names.\n")

    // Configurations to compare.
    var configurations: [(boost: Float, threshold: Float)]
    if options.sweep {
        let thresholds: [Float] = options.thresholds ?? [0.05, 0.1, 0.15, 0.2, 0.3, 0.4]
        let boosts: [Float] = options.boosts ?? options.boost.map { [$0] } ?? [1.0, 2.0, 3.0]
        configurations = boosts.flatMap { b in thresholds.map { (b, $0) } }
    } else {
        let middle = KeywordTuning.default.values(forSensitivity: 0.5)   // what the app does at the middle of the slider
        configurations = [(options.boost ?? middle.boost, options.threshold ?? middle.threshold)]
    }

    print("Profile \(options.profile) · keywords: \(chosen.pronunciations.joined(separator: "  /  ")) · trailing blanks \(options.trailing)")
    for configuration in configurations {
        let tuning = KeywordTuning(boostAtZero: configuration.boost, boostAtOne: configuration.boost, thresholdAtZero: configuration.threshold, thresholdAtOne: configuration.threshold)
        let engine = SherpaOnnxWakeWordEngine(configuration: .init(
            libraryURL: library, model: model, pronunciations: chosen.pronunciations, sensitivity: 0.5, tuning: tuning,
            numTrailingBlanks: options.trailing, maxActivePaths: options.paths, activityGate: options.gate ? ActivityGate.Configuration() : nil,
            levelNormaliser: options.agc, frameLength: options.frame,
            integrity: chosen.digests.map { .verified($0) } ?? .unverified   // variants under evaluation have no pinned digests
        ))
        do {
            let began = HostTime.now
            try await engine.initialize()
            let loaded = HostTime.now.seconds(since: began)
            let started = HostTime.now
            let report = try evaluate(engine: engine, clips: clips, verbose: options.verbose, noise: options.noise,
                                      click: options.clickDecibels.map { ($0, options.clickGap) })
            let took = HostTime.now.seconds(since: started)
            let audio = clips.reduce(0.0) { $0 + Double($1.samples.count + 24_000) / 16_000 }
            printReport(report, title: String(format: "boost %.1f  threshold %.2f   (model loaded in %.0f ms; %.0f s of audio in %.1f s = %.0f× real time)",
                                              configuration.boost, configuration.threshold, loaded * 1000, audio, took, audio / took))
            if options.verbose {
                for (text, outcome) in report.perText.sorted(by: { $0.key < $1.key }) { print("      “\(text)”: \(percent(outcome.detected, outcome.clips))") }
                for (rate, outcome) in report.perRate.sorted(by: { $0.key < $1.key }) { print("      \(rate) words a minute: \(percent(outcome.detected, outcome.clips))") }
                for (voice, outcome) in report.perVoice.sorted(by: { $0.value.detected * 100 / max(1, $0.value.clips) < $1.value.detected * 100 / max(1, $1.value.clips) }) {
                    print("      voice \(voice): \(percent(outcome.detected, outcome.clips))")
                }
                for alert in report.speechAlerts.prefix(10) { print("      false alert in speech: \(alert.voice) “\(alert.text)…”") }
            }
        } catch {
            print("  boost \(configuration.boost) threshold \(configuration.threshold): FAILED — \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
        engine.shutdown()
    }
}


// MARK: - One file

/// `jarvis-bench kws-wav FILE.wav [--keywords "T T T/T T"] [--boost B] [--threshold T] [--profile P]` — when does the spotter fire
/// inside one recording? (16 kHz, 16-bit mono WAV.) Handy for checking a model, a keyword spelling or a real recording.
func kwsWAV(_ arguments: [String]) async {
    guard arguments.count > 2 else { print("usage: jarvis-bench kws-wav FILE.wav [--keywords …] [--boost B] [--threshold T] [--profile P]"); exit(2) }
    let file = URL(fileURLWithPath: arguments[2])
    let options = EvalOptions(Array(arguments.dropFirst()))   // flags start after the file name
    guard var chosen = profile(named: options.profile), let samples = readWAV(file) else { print("cannot read \(file.path) or unknown profile"); exit(2) }
    if let keywords = options.keywords {
        chosen = SherpaModelProfile(directory: chosen.directory, encoder: chosen.encoder, decoder: chosen.decoder, joiner: chosen.joiner, tokens: chosen.tokens, pronunciations: keywords)
    }
    let library = options.sherpa.appendingPathComponent("lib/libsherpa-onnx-c-api.dylib")
    let directory = options.sherpa.appendingPathComponent("models/\(chosen.directory)")
    let model = SherpaOnnxWakeWordEngine.ModelFiles(
        encoder: directory.appendingPathComponent(chosen.encoder), decoder: directory.appendingPathComponent(chosen.decoder),
        joiner: directory.appendingPathComponent(chosen.joiner), tokens: directory.appendingPathComponent(chosen.tokens)
    )
    // What the app does at the middle of the Sensitivity slider, unless told otherwise.
    let middle = KeywordTuning.default.values(forSensitivity: 0.5)
    let boost = options.boost ?? middle.boost, threshold = options.threshold ?? middle.threshold
    let engine = SherpaOnnxWakeWordEngine(configuration: .init(
        libraryURL: library, model: model, pronunciations: chosen.pronunciations, sensitivity: 0.5,
        tuning: KeywordTuning(boostAtZero: boost, boostAtOne: boost, thresholdAtZero: threshold, thresholdAtOne: threshold),
        numTrailingBlanks: options.trailing, maxActivePaths: options.paths, activityGate: options.gate ? ActivityGate.Configuration() : nil,
        levelNormaliser: options.agc, frameLength: options.frame,
        integrity: chosen.digests.map { .verified($0) } ?? .unverified
    ))
    do {
        try await engine.initialize()
        let frameLength = engine.audioRequirements.frameLength
        // Half a second of room before and a second after, as in the evaluation: a clip that starts mid-word gives the model nothing to wake up on.
        let padded = withRoomNoise([Float](repeating: 0, count: 8_000) + samples + [Float](repeating: 0, count: 16_000), level: options.noise, seed: 7)
        var index = 0
        var hits: [Double] = []
        while index + frameLength <= padded.count {
            let frame = AudioFrame(samples: Array(padded[index..<index + frameLength]), sampleRate: 16_000, sequence: UInt64(index / frameLength), captureTime: .zero)
            if try engine.processAudio(frame) != nil { hits.append(Double(index + frameLength) / 16_000) }
            index += frameLength
        }
        print("\(file.lastPathComponent): \(String(format: "%.2f", Double(samples.count) / 16_000)) s — keywords \(chosen.pronunciations.joined(separator: " / ")) — "
            + (hits.isEmpty ? "no detection" : "detected at " + hits.map { String(format: "%.2f s", $0) }.joined(separator: ", ")))
    } catch {
        print("failed: \(error.errorDescription ?? "\(error)")")
    }
    engine.shutdown()
}


// MARK: - Recordings: finding the utterances, and hearing what the model hears

/// `jarvis-bench kws-hear RECORDING… [--sherpa DIR]` — which sounds does the model hear in each stretch of speech?
/// Shows why a "Jarvis" is missed: it is usually not what the pronunciation list expects.
func kwsHear(_ arguments: [String]) async {
    var files: [URL] = []
    var sherpa = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Vendor/SherpaOnnx")
    var iterator = arguments.dropFirst(2).makeIterator()
    while let argument = iterator.next() {
        if argument == "--sherpa" { sherpa = URL(fileURLWithPath: iterator.next() ?? sherpa.path) } else { files.append(URL(fileURLWithPath: argument)) }
    }
    guard !files.isEmpty else { print("usage: jarvis-bench kws-hear RECORDING…"); exit(2) }
    guard let recognizer = makeRecognizer(sherpa: sherpa) else { exit(2) }
    defer { recognizer.shutdown() }
    for file in files {
        guard let all = samples(fromRecording: file) else { print("\(file.lastPathComponent): cannot read"); continue }
        let pieces = UtteranceSplitter.split(all)
        print("\(file.lastPathComponent): \(String(format: "%.1f", Double(all.count) / 16_000)) s, \(pieces.count) stretch(es) of speech")
        for (number, piece) in pieces.enumerated() {
            print("  \(String(format: "%2d", number + 1)). \(String(format: "%.1f", Double(piece.count) / 16_000)) s  hears: \(recognizer.sounds(in: piece).joined(separator: " "))")
        }
    }
}

private func makeRecognizer(sherpa: URL) -> SherpaSoundRecognizer? {
    let shipped = SherpaOnnxBackend.phoneModel
    let directory = sherpa.appendingPathComponent("models/\(shipped.directory)")
    let model = SherpaOnnxWakeWordEngine.ModelFiles(
        encoder: directory.appendingPathComponent(shipped.encoder), decoder: directory.appendingPathComponent(shipped.decoder),
        joiner: directory.appendingPathComponent(shipped.joiner), tokens: directory.appendingPathComponent(shipped.tokens)
    )
    let recognizer = SherpaSoundRecognizer(configuration: .init(libraryURL: sherpa.appendingPathComponent("lib/libsherpa-onnx-c-api.dylib"), model: model))
    do { try recognizer.initialize(); return recognizer } catch {
        print("the model could not be loaded: \(error.errorDescription ?? "\(error)") — run Scripts/fetch-sherpa.sh")
        return nil
    }
}

// MARK: - Teaching the engine your voice

// jarvis-bench kws-tune RECORDING-OR-FOLDER… [--negatives RECORDING-OR-FOLDER…] [--sensitivity S] [--install [--models DIR] | --out FILE] [--max N]
// jarvis-bench kws-tune --demo es            (try the idea on Spanish voices reading the English word)
//
// "Jarvis" is data for this engine: a list of phoneme sequences. Which sequences match *you* depends on how you say it — and on
// what the network makes of it: a Spanish accent, a fast "hey Jarvis" or a quiet room can come out as `JH AA1 B V IY0 AH0 S`, or
// as Mandarin syllables, because the network is bilingual. So this tool does not guess. It
//
//   1. cuts your recordings into utterances (one long take of "Jarvis … Jarvis … Jarvis" is fine),
//   2. asks the network what it hears in each of them,
//   3. turns what is said often into candidate pronunciations — together with a family of plausible textbook variations —
//      and keeps those that hear your utterances and stay silent on look-alike words, on ordinary English and Spanish speech and
//      on your own `--negatives` recordings,
//   4. checks the result on utterances it did not learn from, and only then writes `jarvis_pronunciations.txt`.
//
// Recordings are only read — never copied or kept.

private struct TuneOptions {
    var positives: [URL] = []
    var negatives: [URL] = []
    var out: URL?
    var install = false
    /// `--models DIR`: where `--install` puts the file instead of the app's own Models folder (for trying the tool out safely).
    var models: URL?
    var demo: String?
    var sensitivity: Float = 0.5
    var sherpa = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Vendor/SherpaOnnx")
    var maxSet = 8
    var workers = max(1, min(6, ProcessInfo.processInfo.activeProcessorCount - 2))
    var useBuiltInNegatives = true

    init(_ arguments: [String]) {
        var iterator = arguments.dropFirst(2).makeIterator()
        var target = 0   // 0 = positives, 1 = negatives
        while let argument = iterator.next() {
            switch argument {
            case "--negatives": target = 1
            case "--out": out = iterator.next().map { URL(fileURLWithPath: $0) }
            case "--install": install = true
            case "--models": models = iterator.next().map { URL(fileURLWithPath: $0, isDirectory: true) }
            case "--demo": demo = iterator.next()
            case "--sensitivity": sensitivity = min(1, max(0, iterator.next().flatMap(Float.init) ?? sensitivity))
            case "--sherpa": sherpa = URL(fileURLWithPath: iterator.next() ?? sherpa.path)
            case "--max": maxSet = max(1, min(PronunciationLimits.pronunciations, iterator.next().flatMap(Int.init) ?? maxSet))
            case "--workers": workers = max(1, iterator.next().flatMap(Int.init) ?? workers)
            case "--only-mine": useBuiltInNegatives = false
            default:
                if target == 0 { positives.append(URL(fileURLWithPath: argument)) } else { negatives.append(URL(fileURLWithPath: argument)) }
            }
        }
    }
}

/// The audio files in `urls`, looking inside folders (one level) and in name order.
private func audioFiles(in urls: [URL]) -> [URL] {
    let extensions: Set<String> = ["m4a", "wav", "aiff", "aif", "caf", "mp3", "aac", "flac", "mp4", "mov"]
    var files: [URL] = []
    for url in urls {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { files.append(url); continue }   // reported as unreadable later
        if isDirectory.boolValue {
            let inside = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            files.append(contentsOf: inside.filter { extensions.contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix(".") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent })
        } else {
            files.append(url)
        }
    }
    return files
}

func kwsTune(_ arguments: [String]) async {
    setvbuf(stdout, nil, _IOLBF, 0)   // progress lines appear as they happen, even through a pipe
    let options = TuneOptions(arguments)
    if options.demo != nil, options.install { print("--demo uses synthetic voices and never installs; use --out FILE to see what it finds"); exit(2) }
    // Said before the minutes of work, not after them.
    var outIsFolder: ObjCBool = false
    if let out = options.out, FileManager.default.fileExists(atPath: out.path, isDirectory: &outIsFolder), outIsFolder.boolValue {
        print("--out takes the name of a file, and \(out.path) is a folder"); exit(2)
    }
    let library = options.sherpa.appendingPathComponent("lib/libsherpa-onnx-c-api.dylib")
    let shipped = SherpaOnnxBackend.phoneModel
    let directory = options.sherpa.appendingPathComponent("models/\(shipped.directory)")
    guard FileManager.default.fileExists(atPath: library.path) else { print("library not found at \(library.path) — run Scripts/fetch-sherpa.sh"); exit(2) }

    // ---- Recordings: yours, or a demonstration with synthetic voices.
    var utterances: [VoiceTuner.Utterance] = []
    var userNegatives: [[Float]] = []
    var demoHeldOut: [(name: String, clips: [[Float]])] = []
    if let demo = options.demo {
        guard demo == "es" else { print("--demo knows only “es” (Spanish voices reading the English word)"); exit(2) }
        let phrases = ["Jarvis", "Hey Jarvis", "Jarvis, what time is it?", "Okay Jarvis, turn on the lights."]
        for text in phrases { for rate in [150, 190] { if let x = speech(voice: "Paulina", rate: rate, text: text) { utterances.append(.init(samples: x, source: "Paulina")) } } }
        var sameVoice: [[Float]] = []
        for text in ["Jarvis, are you there?", "Jarvis, play some music.", "Thanks, Jarvis.", "Good morning, Jarvis."] {
            for rate in [135, 170, 210] { if let x = speech(voice: "Paulina", rate: rate, text: text) { sameVoice.append(x) } }
        }
        demoHeldOut.append(("the same voice, new sentences", sameVoice))
        var otherVoice: [[Float]] = []
        for text in phrases { for rate in [150, 190] { if let x = speech(voice: "Mónica", rate: rate, text: text) { otherVoice.append(x) } } }
        demoHeldOut.append(("another voice", otherVoice))
    } else {
        guard !options.positives.isEmpty else {
            print("""
            usage: jarvis-bench kws-tune RECORDING-OR-FOLDER… [--negatives RECORDING-OR-FOLDER…] [--sensitivity 0…1] [--install | --out FILE]

              (The app does this for you: menu bar ▸ Teach Jarvis your voice… This is the same thing from files.)
              Record yourself (QuickTime Player ▸ File ▸ New Audio Recording): "Jarvis" about 15 times with a pause of a second or two
              between, "hey Jarvis" 10 times, "okay Jarvis, …" 5 times — the way you really say it, at the distance you really use.
              Record a minute of ordinary talk without the word for --negatives. Put the files in one folder and name it.
            """)
            exit(2)
        }
        // Ordinary talk without the word is recognised by its name ("normal", "negativo", "sin-jarvis"…) when it sits among the
        // recordings of the word, so one folder is all that has to be named. A file named under --negatives is never also a recording
        // of the word.
        func looksLikeOrdinaryTalk(_ url: URL) -> Bool {
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            if ["negativ", "no-jarvis", "no_jarvis", "nojarvis", "sin-jarvis", "sin_jarvis", "sinjarvis", "without"].contains(where: { name.contains($0) }) { return true }
            if name.contains("jarvis") { return false }   // "jarvis-normal" is the word, said the way you normally say it
            return ["normal", "ordinary", "habla", "charla", "conversa"].contains { name.contains($0) }
        }
        let wordFiles = audioFiles(in: options.positives)
        let negativeFiles = audioFiles(in: options.negatives) + wordFiles.filter(looksLikeOrdinaryTalk)
        let negativePaths = Set(negativeFiles.map { $0.standardizedFileURL.path })
        for url in wordFiles where !negativePaths.contains(url.standardizedFileURL.path) {
            guard let all = samples(fromRecording: url) else { print("cannot read \(url.path)"); exit(2) }
            let pieces = UtteranceSplitter.split(all)
            utterances.append(contentsOf: pieces.map { .init(samples: $0, source: url.deletingPathExtension().lastPathComponent) })
            print("  \(url.lastPathComponent): \(String(format: "%.0f", Double(all.count) / 16_000)) s → \(pieces.count) utterance\(pieces.count == 1 ? "" : "s")")
            if pieces.count > 30 || all.count > 120 * 16_000 {
                print("    ↳ that is a lot for a recording of the word. If it is ordinary talk, give it a name with “normal” in it (or list it after --negatives): speech without the word would be learned as the word.")
            }
        }
        for url in negativeFiles {
            guard let all = samples(fromRecording: url) else { print("cannot read \(url.path)"); exit(2) }
            userNegatives.append(all)
            print("  \(url.lastPathComponent): \(String(format: "%.0f", Double(all.count) / 16_000)) s of speech that must not fire")
        }
    }

    // ---- The analysis (the same one the app runs from its "Teach Jarvis your voice" window)
    let model = SherpaOnnxWakeWordEngine.ModelFiles(
        encoder: directory.appendingPathComponent(shipped.encoder), decoder: directory.appendingPathComponent(shipped.decoder),
        joiner: directory.appendingPathComponent(shipped.joiner), tokens: directory.appendingPathComponent(shipped.tokens)
    )
    var tuning = VoiceTuner.Options()
    tuning.sensitivity = options.sensitivity
    tuning.workers = options.workers
    tuning.maximumPronunciations = options.maxSet
    tuning.referenceCache = options.useBuiltInNegatives ? corpusDirectory : nil
    tuning.keepsUnheardUtterances = options.demo != nil
    // What the new list has to beat is what the engine runs on: the list already in the models folder, if there is one.
    if options.demo == nil { tuning.baseline = SherpaOnnxBackend.customPronunciations(in: options.models ?? AppDirectories().userModels) }
    let outcome: VoiceTuner.Outcome
    do {
        outcome = try await VoiceTuner(library: library, model: model, options: tuning).tune(
            utterances: utterances, ordinaryTalk: userNegatives, heldOutGroups: demoHeldOut, log: { print($0) }
        )
    } catch {
        print("\n\((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        exit(2)
    }
    guard !outcome.pronunciations.isEmpty else { return }   // (it has already said why)

    // ---- What to do with it
    let refusal = outcome.refusal
    let text = outcome.profileText
    let destination = options.out ?? (options.install ? (options.models ?? AppDirectories().userModels).appendingPathComponent("jarvis_pronunciations.txt") : nil)
    if let destination {
        if options.install, let refusal {
            print("\nNot installed: \(refusal) (\(destination.path) was not touched.)")
        } else {
            do {
                if let kept = try VoiceProfileFile.write(text, replacing: destination) { print("\nThe file that was there is kept as \(kept).") }
                print("\nWritten to \(destination.path)."
                    + (refusal == nil ? " Switch “Listen for Jarvis” off and on in the menu bar to use it."
                                      : " (It was only written because --out asked for it — \(refusal!)"))
            } catch { print("\ncould not write \(destination.path): \((error as? LocalizedError)?.errorDescription ?? "\(error)")") }
        }
    } else if let refusal {
        print("\nNothing to install: \(refusal) Keep the built-in list; recording again — closer, and saying the word the way you do day to day —"
            + " gives the fit more to work with.")
    } else {
        print("\nTo use it, run again with --install, or save this as ~/Library/Application Support/Jarvis Wake Word/Models/jarvis_pronunciations.txt:\n\n\(text)")
    }
    print(refusal == nil ? "This fits the recordings you gave it; it does not promise more. Check it in Diagnostics ▸ Accuracy (“Say Jarvis 20 times”,"
        + " then “Similar-sounding words”), and delete the file to go back to the defaults."
        : "`kws-hear` shows the sounds the model makes of each utterance, if you want to see why.")
}
