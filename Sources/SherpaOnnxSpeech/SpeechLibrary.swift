// The speech side of the sherpa-onnx C API: this file and the two engines are the only ones that import it.
import CSherpaOnnx
import Foundation
import FridayCore
import FridaySpeech
import os

/// The speech function table of `libsherpa-onnx-c-api.dylib`, resolved once per path and kept for the process
/// lifetime (dlopen handles are never closed). The wake-word backend loads its own table from the same file.
final class SpeechLibrary: @unchecked Sendable {
    let api: csherpa_speech_api_t
    let path: String

    private static let cache = OSAllocatedUnfairLock<[String: SpeechLibrary]>(initialState: [:])

    static func load(from url: URL) throws(SpeechError) -> SpeechLibrary {
        let path = url.path
        if let cached = cache.withLock({ $0[path] }) { return cached }
        guard FileManager.default.fileExists(atPath: path) else {
            throw .engineUnavailable("\(url.lastPathComponent) is not installed (run Scripts/fetch-sherpa.sh)")
        }
        var api = csherpa_speech_api_t()
        var error = [CChar](repeating: 0, count: 1_024)
        let status = csherpa_load_speech(path, &api, &error, error.count)
        guard status == CSHERPA_LOAD_OK else {
            let reason = String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            throw .engineUnavailable("could not load \(url.lastPathComponent): \(reason)")
        }
        let library = SpeechLibrary(api: api, path: path)
        return cache.withLock { cache in
            if let raced = cache[path] { return raced }
            cache[path] = library
            return library
        }
    }

    private init(api: csherpa_speech_api_t, path: String) {
        self.api = api
        self.path = path
    }

    var version: String {
        guard let function = api.get_version_str, let text = function() else { return "unknown" }
        return String(cString: text)
    }
}

/// Owns the C strings a native configuration struct points at. The C structs hold `const char *` and the library may
/// read them until the call returns, so keep the box alive (`withExtendedLifetime`) for the whole call.
final class CStringBox {
    private var owned: [UnsafeMutablePointer<CChar>] = []

    func pointer(_ text: String) -> UnsafePointer<CChar> {
        let copy = strdup(text)!
        owned.append(copy)
        return UnsafePointer(copy)
    }

    deinit {
        owned.forEach { free($0) }
    }
}

extension SpeechError {
    /// The reason alone, without the "Speech engine unavailable:" framing of `errorDescription`.
    var reason: String {
        switch self {
        case .engineUnavailable(let message), .synthesisFailed(let message),
             .recognitionFailed(let message), .permissionDenied(let message):
            return message
        }
    }

    /// The reason for Settings: a load failure is a technical message (file names, library errors) and reads the same
    /// in both languages, framed in each.
    var localizedReason: LocalizedText {
        LocalizedText(en: "Could not load the speech engine: \(reason)", es: "No se pudo cargar el motor de voz: \(reason)")
    }
}
