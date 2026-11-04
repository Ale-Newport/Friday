// This is the ONLY file in the project that imports Picovoice's C API.
import CPorcupine
import Foundation
import WakeWordKit

/// Picovoice's status codes as a Swift enum, so the rest of the backend (and its tests) never
/// touches the C types.
enum PorcupineStatus: Equatable, Sendable {
    case success
    case outOfMemory
    case ioError
    case invalidArgument
    case stopIteration
    case keyError
    case invalidState
    case runtimeError
    case activationError
    case activationLimitReached
    case activationThrottled
    case activationRefused
    case unknown(Int32)

    init(rawValue: Int32) {
        switch UInt32(bitPattern: rawValue) {
        case PV_STATUS_SUCCESS.rawValue: self = .success
        case PV_STATUS_OUT_OF_MEMORY.rawValue: self = .outOfMemory
        case PV_STATUS_IO_ERROR.rawValue: self = .ioError
        case PV_STATUS_INVALID_ARGUMENT.rawValue: self = .invalidArgument
        case PV_STATUS_STOP_ITERATION.rawValue: self = .stopIteration
        case PV_STATUS_KEY_ERROR.rawValue: self = .keyError
        case PV_STATUS_INVALID_STATE.rawValue: self = .invalidState
        case PV_STATUS_RUNTIME_ERROR.rawValue: self = .runtimeError
        case PV_STATUS_ACTIVATION_ERROR.rawValue: self = .activationError
        case PV_STATUS_ACTIVATION_LIMIT_REACHED.rawValue: self = .activationLimitReached
        case PV_STATUS_ACTIVATION_THROTTLED.rawValue: self = .activationThrottled
        case PV_STATUS_ACTIVATION_REFUSED.rawValue: self = .activationRefused
        default: self = .unknown(rawValue)
        }
    }
}

/// A failed native call: the status plus the library's own explanatory messages (which may echo
/// the AccessKey — they are redacted before they leave the engine).
struct NativeFailure: Error, Equatable, Sendable {
    let status: PorcupineStatus
    let statusName: String
    let messages: [String]
}

/// The operations the engine needs from the native library. Production uses ``LibraryBindings``;
/// tests substitute a fake, which is how the engine's logic is verified without an AccessKey.
protocol PorcupineBindings: Sendable {
    var version: String { get }
    var sampleRate: Int { get }
    var frameLength: Int { get }

    func makeHandle(
        accessKey: String,
        modelPath: String,
        device: String,
        keywordPaths: [String],
        sensitivities: [Float]
    ) throws(NativeFailure) -> OpaquePointer

    /// Returns the detected keyword index, or -1.
    func process(handle: OpaquePointer, pcm: UnsafePointer<Int16>) throws(NativeFailure) -> Int32

    func destroy(handle: OpaquePointer)
}

/// Bindings backed by the real `libpv_porcupine.dylib`, loaded at runtime.
final class LibraryBindings: PorcupineBindings, @unchecked Sendable {
    private let api: cpv_api_t
    let libraryPath: String

    // dlopen handles are process-wide and never closed, so keeping one table per path is enough.
    private static let cache = Protected<[String: LibraryBindings]>([:])

    static func load(from url: URL) throws(WakeWordError) -> LibraryBindings {
        let path = url.path
        if let cached = cache.withLock({ $0[path] }) { return cached }

        var api = cpv_api_t()
        var error = [CChar](repeating: 0, count: 512)
        let status = cpv_load(path, &api, &error, error.count)
        guard status == CPV_LOAD_OK else {
            let reason = String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            throw .engineUnavailable("could not load \(url.lastPathComponent): \(reason)")
        }
        let bindings = LibraryBindings(api: api, path: path)
        cache.withLock { $0[path] = bindings }
        return bindings
    }

    private init(api: cpv_api_t, path: String) {
        self.api = api
        self.libraryPath = path
    }

    var version: String {
        guard let function = api.porcupine_version, let text = function() else { return "unknown" }
        return String(cString: text)
    }

    var sampleRate: Int { api.sample_rate.map { Int($0()) } ?? 16_000 }
    var frameLength: Int { api.porcupine_frame_length.map { Int($0()) } ?? 512 }

    func makeHandle(
        accessKey: String,
        modelPath: String,
        device: String,
        keywordPaths: [String],
        sensitivities: [Float]
    ) throws(NativeFailure) -> OpaquePointer {
        guard let initialise = api.porcupine_init else {
            throw failure(PorcupineStatus.invalidState, name: "library not loaded")
        }
        // The C API wants `const char *const *`; keep the strings alive for the whole call.
        let owned = keywordPaths.map { strdup($0) }
        defer { owned.forEach { free($0) } }
        let pointers: [UnsafePointer<CChar>?] = owned.map { $0.map { UnsafePointer($0) } }

        var handle: OpaquePointer?
        let status = pointers.withUnsafeBufferPointer { keywords in
            sensitivities.withUnsafeBufferPointer { levels in
                initialise(
                    accessKey, modelPath, device, Int32(keywordPaths.count),
                    keywords.baseAddress, levels.baseAddress, &handle
                )
            }
        }
        guard status == PV_STATUS_SUCCESS, let handle else {
            throw failure(PorcupineStatus(rawValue: Int32(bitPattern: status.rawValue)), raw: status)
        }
        return handle
    }

    func process(handle: OpaquePointer, pcm: UnsafePointer<Int16>) throws(NativeFailure) -> Int32 {
        guard let process = api.porcupine_process else {
            throw failure(PorcupineStatus.invalidState, name: "library not loaded")
        }
        var index: Int32 = -1
        let status = process(handle, pcm, &index)
        guard status == PV_STATUS_SUCCESS else {
            throw failure(PorcupineStatus(rawValue: Int32(bitPattern: status.rawValue)), raw: status)
        }
        return index
    }

    func destroy(handle: OpaquePointer) {
        api.porcupine_delete?(handle)
    }

    // MARK: - Error plumbing

    private func failure(_ status: PorcupineStatus, name: String) -> NativeFailure {
        NativeFailure(status: status, statusName: name, messages: [])
    }

    private func failure(_ status: PorcupineStatus, raw: pv_status_t) -> NativeFailure {
        let name = api.status_to_string.flatMap { $0(raw) }.map { String(cString: $0) } ?? "status \(raw.rawValue)"
        return NativeFailure(status: status, statusName: name, messages: errorStack())
    }

    /// Reads (and frees) the library's explanatory message stack for the last failure.
    private func errorStack() -> [String] {
        guard let fetch = api.get_error_stack, let release = api.free_error_stack else { return [] }
        var stack: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        var depth: Int32 = 0
        guard fetch(&stack, &depth) == PV_STATUS_SUCCESS, let stack else { return [] }
        defer { release(stack) }
        return (0..<Int(depth)).compactMap { stack[$0].map { String(cString: $0) } }
    }
}
