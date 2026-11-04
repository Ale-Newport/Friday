// This is the ONLY file in the project that imports sherpa-onnx's C API.
import CSherpaOnnx
import Foundation
import WakeWordKit

/// Everything needed to build a keyword spotter, as plain Swift values (so tests never touch the C structs).
struct SpotterSettings: Equatable, Sendable {
    var encoder: String
    var decoder: String
    var joiner: String
    var tokens: String
    /// Threads ONNX Runtime may use. One is right for a model this small: fanning out costs more than it saves.
    var numThreads: Int32 = 1
    var maxActivePaths = Int32(SherpaOnnxBackend.defaultMaxActivePaths)
    /// Blank frames that must follow a keyword before it is reported; more means fewer premature triggers.
    var numTrailingBlanks: Int32 = 1
    /// Defaults for keywords that do not carry their own boost / threshold.
    var keywordsScore: Float = 1.0
    var keywordsThreshold: Float = 0.25
    /// Keywords the spotter is created with (the engine replaces them per stream, see `makeStream`).
    var initialKeywords: String
}

/// A failed native call. The library only reports "NULL" and prints its reasons to stderr, so the message is ours.
struct NativeFailure: Error, Equatable, Sendable {
    let message: String
}

/// The operations the engine needs from the native library. Production uses ``LibraryBindings``; tests substitute
/// a fake, which is how the engine's own logic is verified without the model files.
protocol SherpaBindings: Sendable {
    var version: String { get }

    func makeSpotter(_ settings: SpotterSettings) throws(NativeFailure) -> OpaquePointer
    func destroySpotter(_ spotter: OpaquePointer)

    /// A fresh decoding stream that listens for `keywords` (the library's own text format: one or more
    /// `token token … :boost #threshold @label` entries separated by `/`).
    func makeStream(spotter: OpaquePointer, keywords: String) throws(NativeFailure) -> OpaquePointer
    func destroyStream(_ stream: OpaquePointer)

    /// Forgets everything heard so far (audio, features, decoding state) but keeps the keyword definition.
    func reset(spotter: OpaquePointer, stream: OpaquePointer)

    /// Feeds `count` mono samples in [-1, 1] at `sampleRate`, decodes everything that became decodable, and returns
    /// the label of the first keyword heard (resetting the stream so it starts listening afresh), if any.
    func feed(
        spotter: OpaquePointer, stream: OpaquePointer, samples: UnsafePointer<Float>, count: Int, sampleRate: Int
    ) -> String?
}

/// The streaming recogniser: the same network, asked which sounds it hears instead of whether one keyword was said. Only the
/// voice-tuning tool uses it; detection never does.
protocol SherpaRecognizerBindings: Sendable {
    func makeRecognizer(_ settings: SpotterSettings) throws(NativeFailure) -> OpaquePointer
    func destroyRecognizer(_ recognizer: OpaquePointer)
    /// The tokens the model hears in `count` mono samples in [-1, 1] at `sampleRate`, in order. (Half a second of quiet is put
    /// before them and a second after, so the network has settled and finishes what it was about to say.)
    func transcribe(recognizer: OpaquePointer, samples: UnsafePointer<Float>, count: Int, sampleRate: Int) -> [String]
}

/// Bindings backed by the real `libsherpa-onnx-c-api.dylib`, loaded at runtime.
final class LibraryBindings: SherpaBindings, @unchecked Sendable {
    private let api: csherpa_api_t
    let libraryPath: String

    // dlopen handles are process-wide and never closed, so keeping one table per path is enough.
    private static let cache = Protected<[String: LibraryBindings]>([:])

    static func load(from url: URL) throws(WakeWordError) -> LibraryBindings {
        let path = url.path
        if let cached = cache.withLock({ $0[path] }) { return cached }

        var api = csherpa_api_t()
        var error = [CChar](repeating: 0, count: 1_024)
        let status = csherpa_load(path, &api, &error, error.count)
        guard status == CSHERPA_LOAD_OK else {
            let reason = String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            throw .engineUnavailable("could not load \(url.lastPathComponent): \(reason)")
        }
        let bindings = LibraryBindings(api: api, path: path)
        cache.withLock { $0[path] = bindings }
        return bindings
    }

    private init(api: csherpa_api_t, path: String) {
        self.api = api
        self.libraryPath = path
    }

    var version: String {
        guard let function = api.get_version_str, let text = function() else { return "unknown" }
        return String(cString: text)
    }

    func makeSpotter(_ settings: SpotterSettings) throws(NativeFailure) -> OpaquePointer {
        guard let create = api.create_keyword_spotter else { throw NativeFailure(message: "library not loaded") }

        // The C structs hold `const char *`; keep every string alive for the whole call.
        var owned: [UnsafeMutablePointer<CChar>] = []
        func cString(_ text: String) -> UnsafePointer<CChar> {
            let copy = strdup(text)!
            owned.append(copy)
            return UnsafePointer(copy)
        }
        defer { owned.forEach { free($0) } }

        var config = SherpaOnnxKeywordSpotterConfig()
        config.feat_config.sample_rate = 16_000
        config.feat_config.feature_dim = 80
        config.model_config.transducer.encoder = cString(settings.encoder)
        config.model_config.transducer.decoder = cString(settings.decoder)
        config.model_config.transducer.joiner = cString(settings.joiner)
        config.model_config.tokens = cString(settings.tokens)
        config.model_config.provider = cString("cpu")
        config.model_config.num_threads = settings.numThreads
        config.max_active_paths = settings.maxActivePaths
        config.num_trailing_blanks = settings.numTrailingBlanks
        config.keywords_score = settings.keywordsScore
        config.keywords_threshold = settings.keywordsThreshold
        let keywords = cString(settings.initialKeywords)
        config.keywords_buf = keywords
        config.keywords_buf_size = Int32(strlen(keywords))

        guard let spotter = withUnsafePointer(to: &config, { create($0) }) else {
            throw NativeFailure(message: "the keyword spotter could not be created (the model files are unreadable or do not match each other)")
        }
        return spotter
    }

    func destroySpotter(_ spotter: OpaquePointer) {
        api.destroy_keyword_spotter?(spotter)
    }

    func makeStream(spotter: OpaquePointer, keywords: String) throws(NativeFailure) -> OpaquePointer {
        guard let create = api.create_keyword_stream_with_keywords else { throw NativeFailure(message: "library not loaded") }
        // Careful: for a keyword it cannot encode (a sound the model lacks) the library does not return NULL. It logs the
        // failure and hands back a stream with nothing inside, which crashes at its first use. So this guard cannot be what
        // protects the process; `TokenTable.validate` is, and nothing reaches this call without passing it.
        guard let stream = create(spotter, keywords) else {
            throw NativeFailure(message: "the keyword stream could not be created (the keyword definition was not understood)")
        }
        return stream
    }

    func destroyStream(_ stream: OpaquePointer) {
        api.destroy_online_stream?(stream)
    }

    func reset(spotter: OpaquePointer, stream: OpaquePointer) {
        api.reset?(spotter, stream)
    }

    func feed(
        spotter: OpaquePointer, stream: OpaquePointer, samples: UnsafePointer<Float>, count: Int, sampleRate: Int
    ) -> String? {
        guard let accept = api.accept_waveform, let ready = api.is_ready, let decode = api.decode,
              let result = api.get_result, let release = api.destroy_result, let reset = api.reset else { return nil }
        accept(stream, Int32(sampleRate), samples, Int32(count))
        var heard: String?
        while ready(spotter, stream) != 0 {
            decode(spotter, stream)
            guard let found = result(spotter, stream) else { continue }
            defer { release(found) }
            if heard == nil, let text = found.pointee.keyword, text.pointee != 0 {
                heard = String(cString: text)
                // What the library's own examples do after a trigger, "so the next keyword can be detected independently". In
                // every scenario tried (utterances 0.2 s to 1.5 s apart) the result is the same without it, so no test pins it.
                reset(spotter, stream)
            }
        }
        return heard
    }
}

extension LibraryBindings: SherpaRecognizerBindings {
    func makeRecognizer(_ settings: SpotterSettings) throws(NativeFailure) -> OpaquePointer {
        guard let create = api.create_recognizer else { throw NativeFailure(message: "library not loaded") }
        var owned: [UnsafeMutablePointer<CChar>] = []
        func cString(_ text: String) -> UnsafePointer<CChar> {
            let copy = strdup(text)!
            owned.append(copy)
            return UnsafePointer(copy)
        }
        defer { owned.forEach { free($0) } }

        var config = SherpaOnnxOnlineRecognizerConfig()
        config.feat_config.sample_rate = 16_000
        config.feat_config.feature_dim = 80
        config.model_config.transducer.encoder = cString(settings.encoder)
        config.model_config.transducer.decoder = cString(settings.decoder)
        config.model_config.transducer.joiner = cString(settings.joiner)
        config.model_config.tokens = cString(settings.tokens)
        config.model_config.provider = cString("cpu")
        config.model_config.num_threads = settings.numThreads
        config.decoding_method = cString("greedy_search")
        guard let recognizer = withUnsafePointer(to: &config, { create($0) }) else {
            throw NativeFailure(message: "the recogniser could not be created (the model files are unreadable or do not match each other)")
        }
        return recognizer
    }

    func destroyRecognizer(_ recognizer: OpaquePointer) {
        api.destroy_recognizer?(recognizer)
    }

    func transcribe(recognizer: OpaquePointer, samples: UnsafePointer<Float>, count: Int, sampleRate: Int) -> [String] {
        guard let createStream = api.create_recognizer_stream, let accept = api.accept_waveform, let ready = api.recognizer_is_ready,
              let decode = api.recognizer_decode, let finish = api.input_finished, let result = api.recognizer_get_result,
              let release = api.recognizer_destroy_result, let destroy = api.destroy_online_stream,
              let stream = createStream(recognizer) else { return [] }
        defer { destroy(stream) }

        let quiet = [Float](repeating: 0, count: sampleRate)
        quiet.withUnsafeBufferPointer { accept(stream, Int32(sampleRate), $0.baseAddress, Int32(sampleRate / 2)) }
        var offset = 0
        while offset < count {
            let chunk = min(1_600, count - offset)
            accept(stream, Int32(sampleRate), samples + offset, Int32(chunk))
            offset += chunk
            while ready(recognizer, stream) != 0 { decode(recognizer, stream) }
        }
        quiet.withUnsafeBufferPointer { accept(stream, Int32(sampleRate), $0.baseAddress, Int32(sampleRate)) }
        finish(stream)
        while ready(recognizer, stream) != 0 { decode(recognizer, stream) }

        guard let found = result(recognizer, stream) else { return [] }
        defer { release(found) }
        let heard = found.pointee
        guard heard.count > 0, let tokens = heard.tokens_arr else { return [] }
        return (0..<Int(heard.count)).compactMap { index in tokens[index].map { String(cString: $0) } }
    }
}
