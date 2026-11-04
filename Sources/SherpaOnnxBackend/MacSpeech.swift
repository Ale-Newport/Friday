import CryptoKit
import WakeWordKit
import Foundation

/// Speech made with the Mac's own voices (`say`), cached as 16 kHz mono WAV files — the reference audio that the learning tools check an
/// engine against, and a reader for the recordings people make. Nothing here touches the microphone or the network.
public enum MacSpeech {
    public struct Request: Hashable, Sendable {
        public var voice: String
        public var rate: Int
        public var text: String

        public init(voice: String, rate: Int, text: String) {
            self.voice = voice
            self.rate = rate
            self.text = text
        }
    }

    /// Runs a command-line tool and says whether it succeeded. Nothing it prints is kept. A tool that has not finished after `timeout`
    /// seconds, or when `isCancelled` says so (checked a few times a second), is stopped and counts as failed: a wedged `say` must not hold
    /// up everything that waits for it.
    ///
    /// The arguments reach the tool as the UTF-8 bytes they are written in. Foundation's `Process` does not do that: it hands a program every
    /// accented character *decomposed* ("ó" as "o" and a combining accent), and `say -v "Mónica"` or `say -v "Eddy (Español (México))"` then
    /// finds no such voice and quietly speaks with the system's own — which is how the reference corpus came to hold copies of one voice
    /// under a dozen names. Hence `posix_spawn`.
    @discardableResult
    public static func run(
        _ tool: String, _ arguments: [String], timeout: TimeInterval = 120, isCancelled: @Sendable () -> Bool = { false }
    ) -> Bool {
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return false }
        defer { posix_spawn_file_actions_destroy(&actions) }
        // The tool reads nothing and what it prints is not kept; nothing else of ours is passed on to it.
        for descriptor in Int32(0)...2 {
            let mode = descriptor == 0 ? O_RDONLY : O_WRONLY
            guard posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", mode, 0) == 0 else { return false }
        }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return false }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else { return false }

        var argv: [UnsafeMutablePointer<CChar>?] = ([tool] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, tool, &actions, &attributes, &argv, environ) == 0 else { return false }   // (the environment as it is)

        let deadline = DispatchTime.now() + timeout
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { break }
            if result < 0, errno != EINTR { return false }
            if isCancelled() || DispatchTime.now() >= deadline {
                kill(pid, SIGTERM)
                var attempts = 0
                while attempts < 40, waitpid(pid, &status, WNOHANG) == 0 {   // up to two seconds to go quietly…
                    usleep(50_000)
                    attempts += 1
                }
                if attempts == 40 {                                           // …then not quietly
                    kill(pid, SIGKILL)
                    waitpid(pid, &status, 0)
                }
                return false
            }
            usleep(20_000)
        }
        let exitedNormally = (status & 0x7f) == 0
        return exitedNormally && ((status >> 8) & 0xff) == 0
    }

    /// The cached 16 kHz mono WAV of what `request` says, made on first use.
    static func cachedSpeech(_ request: Request, in cache: URL, isCancelled: @Sendable () -> Bool = { false }) -> URL? {
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        // (Clips of voices with accents in their names that were made before `run` passed arguments byte for byte may be the system's voice
        // under that name; they are never looked up again.)
        let salt = request.voice.utf8.allSatisfy { $0 < 0x80 } ? "" : "exact-name|"
        let key = SHA256.hash(data: Data("\(salt)\(request.voice)|\(request.rate)|\(request.text)".utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        let wav = cache.appendingPathComponent("\(key).wav")
        if !FileManager.default.fileExists(atPath: wav.path) {
            // Written under another name and moved into place, so that another process never reads half a file.
            let aiff = cache.appendingPathComponent("\(key)-\(UUID().uuidString).aiff")
            let partial = cache.appendingPathComponent("\(key)-\(UUID().uuidString).partial")
            defer {
                try? FileManager.default.removeItem(at: aiff)
                try? FileManager.default.removeItem(at: partial)
            }
            // (An empty voice name is the system's own voice.)
            let voice = request.voice.isEmpty ? [] : ["-v", request.voice]
            guard
                run("/usr/bin/say", voice + ["-r", String(request.rate), "-o", aiff.path, request.text], isCancelled: isCancelled),
                run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, partial.path], isCancelled: isCancelled),
                // (`say` succeeds without a sound when the speech service cannot be reached; that is no speech, and is not kept as if it were.)
                ((try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int) ?? 0) > 2_000,
                (try? FileManager.default.moveItem(at: partial, to: wav)) != nil || FileManager.default.fileExists(atPath: wav.path)
            else { return nil }
        }
        return wav
    }

    /// 16 kHz mono samples of what `voice` says, made once and cached in `cache`.
    public static func samples(voice: String, rate: Int, text: String, cache: URL) -> [Float]? {
        cachedSpeech(Request(voice: voice, rate: rate, text: text), in: cache).flatMap(readWAV)
    }

    /// Makes the clips that are not cached yet, several `say` processes at a time (one after another a cold cache takes a quarter of an
    /// hour). Duplicates are dropped first. `progress` is told how many of the distinct requests are done; stops early when `isCancelled`.
    public static func prepare(
        _ requests: [Request], cache: URL, concurrency: Int = 6,
        progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void = { _, _ in }, isCancelled: @escaping @Sendable () -> Bool = { false }
    ) {
        var seen = Set<Request>()
        let unique = requests.filter { seen.insert($0).inserted }
        let queue = DispatchQueue(label: "jarvis.speech.prepare", attributes: .concurrent)
        let group = DispatchGroup()
        let slots = DispatchSemaphore(value: max(1, concurrency))
        let done = Protected(0)
        for request in unique {
            slots.wait()
            if isCancelled() { slots.signal(); break }
            queue.async(group: group) {
                _ = cachedSpeech(request, in: cache, isCancelled: isCancelled)
                let count = done.withLock { value -> Int in value += 1; return value }
                progress(count, unique.count)
                slots.signal()
            }
        }
        group.wait()
    }

    /// Any audio file macOS can read, as 16 kHz mono samples.
    public static func samples(fromRecording url: URL) -> [Float]? {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-speech-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", url.path, temporary.path]) else { return nil }
        return readWAV(temporary)
    }

    /// Minimal reader for the 16-bit mono PCM files `afconvert` writes.
    public static func readWAV(_ url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url), data.count > 44 else { return nil }
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = Int(data[offset + 4]) | Int(data[offset + 5]) << 8 | Int(data[offset + 6]) << 16 | Int(data[offset + 7]) << 24
            if id == "data" {
                let end = min(data.count, offset + 8 + size)
                let body = data[(offset + 8)..<end]
                return stride(from: body.startIndex, to: body.endIndex - 1, by: 2).map { index in
                    Float(Int16(bitPattern: UInt16(body[index]) | UInt16(body[index + 1]) << 8)) / 32768
                }
            }
            offset += 8 + size + (size & 1)
        }
        return nil
    }
}
