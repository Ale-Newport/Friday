import Foundation
import FridaySpeech
import SherpaOnnxSpeech

/// The real library and models, when `Scripts/fetch-sherpa.sh` and `Scripts/fetch-speech-models.sh` have been run.
/// Tests that need them are skipped otherwise, never failed.
enum SpeechFixtures {
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static let resources = SherpaOnnxSpeechResources.developmentDefault(repositoryRoot: repositoryRoot)

    static var kokoroIsInstalled: Bool {
        KokoroTextToSpeech(resources: resources).missingFiles.isEmpty
    }

    static var sileroIsInstalled: Bool {
        SileroVoiceActivityDetector(resources: resources).missingFiles.isEmpty
    }

    /// Where synthesised samples are written for a human to listen to. `FRIDAY_TTS_SAMPLES_DIR` overrides the default.
    static let samplesDirectory: URL = {
        let path = ProcessInfo.processInfo.environment["FRIDAY_TTS_SAMPLES_DIR"]
            ?? "/private/tmp/claude-501/-Users-alejandro--claude-spares-spare-TpaWGm/0d6bb7b9-1eb3-4305-b03f-88644013018e/scratchpad/tts-samples"
        let url = URL(fileURLWithPath: path, isDirectory: true)
        if (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil { return url }
        return FileManager.default.temporaryDirectory.appendingPathComponent("friday-tts-samples", isDirectory: true)
    }()

    // MARK: Audio helpers

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    /// A mono 16-bit PCM WAVE file.
    static func writeWAV(_ samples: [Float], sampleRate: Int, to url: URL) throws {
        var data = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let payload = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + payload)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(payload))
        for sample in samples {
            append(UInt16(bitPattern: Int16(max(-1, min(1, sample)) * 32767)))
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// The samples of a mono 16-bit PCM WAVE file.
    static func readWAV(_ url: URL) throws -> (samples: [Float], sampleRate: Int) {
        let data = try Data(contentsOf: url)
        func uint32(_ offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24 }
        var sampleRate = 0
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = uint32(offset + 4)
            if id == "fmt " { sampleRate = uint32(offset + 12) }
            if id == "data" {
                let body = data[(offset + 8)..<min(data.count, offset + 8 + size)]
                let samples = stride(from: body.startIndex, to: body.endIndex - 1, by: 2).map {
                    Float(Int16(bitPattern: UInt16(body[$0]) | UInt16(body[$0 + 1]) << 8)) / 32768
                }
                return (samples, sampleRate)
            }
            offset += 8 + size + (size & 1)
        }
        throw Failure("no data chunk in \(url.lastPathComponent)")
    }

    /// `text` spoken by the Mac's own synthesiser, as 16 kHz mono samples.
    static func spoken(_ text: String) throws -> [Float] {
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("friday-vad-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", wav.path, "--data-format=LEI16@16000", text]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else { throw Failure("say exited with \(say.terminationStatus)") }
        let (samples, rate) = try readWAV(wav)
        guard rate == 16_000 else { throw Failure("say produced \(rate) Hz") }
        return samples
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
