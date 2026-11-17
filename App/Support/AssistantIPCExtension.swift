import Foundation
import FridayAssistant
import FridayAudio
import FridayCore
import FridayIPC
import WakeWordCore

/// Serves the assistant-level control-channel requests (`fridayctl --say`, `--voice`, `--synthesize`): the same
/// pipeline the voice and chat paths use, reachable from scripts and automated tests.
struct AssistantIPCExtension: Sendable {
    let assistant: Assistant
    let output: SpeechOutput
    let injectable: InjectableCaptureSource?
    let wakeRuntime: WakeWordRuntime

    func handle(_ request: IPCRequest, connectionID: String) async -> IPCResponse? {
        switch request.type {
        case .assistant:
            guard let text = request.command?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return .failure("invalid_request", "An assistant request needs a non-empty “command”.", id: request.id)
            }
            let response = await assistant.submit(text, source: .ipc, session: request.session ?? connectionID, speak: request.speak ?? false)
            var reply = IPCResponse(engine: response, id: request.id)
            reply.data = await Self.latencyJSON(assistant.current.lastLatency).map { .object(["latency": $0]) }
            return reply

        case .synthesize:
            guard let text = request.command?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return .failure("invalid_request", "A synthesize request needs the text in “command”.", id: request.id)
            }
            guard let path = request.output, !path.isEmpty else { return .failure("invalid_request", "A synthesize request needs an “output” path.", id: request.id) }
            let language = Language(hint: request.language) ?? LanguageDetector.detect(text, fallback: .en)
            do {
                let engine = request.tool?.trimmingCharacters(in: .whitespaces)
                let seconds = try await output.synthesizeToFile(text, language: language, url: URL(fileURLWithPath: path), engineID: engine?.isEmpty == false ? engine : nil)
                return IPCResponse(
                    id: request.id, success: true, status: "completed",
                    message: String(format: "Wrote %.1f s of %@ speech to %@", seconds, language.rawValue, path),
                    data: ["seconds": .double(seconds), "path": .string(path), "language": .string(language.rawValue)])
            } catch {
                return .failure("synthesis_failed", error.localizedDescription, id: request.id)
            }

        case .voice:
            return await injectVoice(request)

        case .transcript:
            let items = await assistant.current.transcript.suffix(max(1, min(request.index ?? 20, 200)))
            let rendered: [JSONValue] = items.map { item in
                var object: JSONObject = [
                    "role": .string(Self.describe(item.role)), "text": .string(item.text), "source": .string(item.source),
                    "date": .string(ISO8601DateFormatter().string(from: item.date)), "streaming": .bool(item.isStreaming),
                ]
                if let response = item.response { object["status"] = .string(response.status.rawValue); object["tools"] = .array(response.results.map { .string($0.tool.rawValue) }) }
                return .object(object)
            }
            return IPCResponse(id: request.id, success: true, status: "ok", message: "\(rendered.count) transcript items", data: .array(rendered))

        default:
            return nil
        }
    }

    // MARK: Voice injection

    private func injectVoice(_ request: IPCRequest) async -> IPCResponse {
        guard let injectable else {
            return .failure("unsupported", "Audio injection is unavailable: Friday was started with synthetic audio.", id: request.id)
        }
        guard let path = request.file, !path.isEmpty else { return .failure("invalid_request", "A voice request needs the audio “file” to play.", id: request.id) }
        let audio: (samples: [Float], sampleRate: Double)
        do { audio = try InjectableCaptureSource.load(contentsOf: URL(fileURLWithPath: path)) } catch {
            return .failure("invalid_request", "Could not read \(path): \(error.localizedDescription)", id: request.id)
        }
        guard !audio.samples.isEmpty else { return .failure("invalid_request", "\(path) holds no audio.", id: request.id) }
        // A previous turn may still be in its conversation window: wait (briefly) for the detector to be listening again.
        var wake = await wakeRuntime.snapshot()
        var waited = 0
        while wake.state != .listening, waited < 40 {
            try? await Task.sleep(for: .milliseconds(500))
            waited += 1
            wake = await wakeRuntime.snapshot()
        }
        guard case .listening = wake.state else {
            return .failure("not_listening", "The wake-word runtime is not listening (\(Self.describe(wake.state))); microphone: \(Self.describe(wake.microphone)).", id: request.id)
        }
        let duration = Double(audio.samples.count) / audio.sampleRate

        // Observe the assistant from before the injection: the first new voice turn after it is the answer.
        let baseline = await assistant.current
        let (stream, continuation) = AsyncStream<AssistantSnapshot?>.makeStream()
        let observer = await assistant.observe { snapshot in continuation.yield(snapshot) }
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                continuation.yield(nil)
            }
        }
        defer {
            ticker.cancel()
            continuation.finish()
            Task { await assistant.stopObserving(observer) }
        }

        let clock = ContinuousClock()
        let started = clock.now
        // A second of silence first: right after a session ends the detector holds off briefly, and a keyword in that
        // window would be dropped.
        guard injectable.inject(audio.samples, sampleRate: audio.sampleRate, leadingSilence: 1.0) else {
            return .failure("not_listening", "The microphone capture is not running; nothing to inject into.", id: request.id)
        }
        var activated = false
        var heard: String?
        var phases: [String] = []
        var reply: EngineResponse?
        var latest = baseline
        let wakeDeadline = duration + 4
        let totalDeadline = max(90, duration + 60)
        for await snapshot in stream {
            if let snapshot { latest = snapshot }
            let elapsed = Self.seconds(started.duration(to: clock.now))
            let phase = Self.describe(latest.phase as FridayAssistant.AssistantPhase)
            if phases.last != phase { phases.append(phase) }
            if latest.inVoiceSession { activated = true }
            let newItems = latest.transcript.dropFirst(baseline.transcript.count)
            if let user = newItems.last(where: { $0.role == .user && $0.source == "voice" }) { heard = user.text }
            if let answer = newItems.last(where: { $0.role == .assistant && !$0.isStreaming && $0.response != nil }) {
                reply = answer.response
                break
            }
            if !activated, elapsed > wakeDeadline { break }
            if activated, !latest.inVoiceSession, heard == nil { break }
            if elapsed > totalDeadline { break }
        }
        let latency = await Self.latencyJSON(latest.lastLatency)
        var data: JSONObject = [
            "wake_word_detected": .bool(activated), "heard": heard.map(JSONValue.string) ?? .null,
            "phases": .array(phases.map(JSONValue.string)), "audio_seconds": .double((duration * 100).rounded() / 100),
        ]
        if let latency { data["latency"] = latency }
        guard activated else {
            return IPCResponse(id: request.id, success: false, status: "no_wake_word", message: "The wake word was not detected in \(path).", data: .object(data))
        }
        guard let reply else {
            let message = heard.map { "Friday heard “\($0)” but produced no reply." } ?? "Friday activated but heard no command."
            return IPCResponse(id: request.id, success: false, status: "no_reply", message: message, data: .object(data))
        }
        var response = IPCResponse(engine: reply, id: request.id)
        response.data = .object(data)
        return response
    }

    // MARK: Status

    /// The voice stack's state for `status` requests.
    func voiceStatus() async -> JSONValue {
        let wake = await wakeRuntime.snapshot()
        let snapshot = await assistant.current
        var object: JSONObject = [
            "wake_state": .string(Self.describe(wake.state)), "microphone": .string(Self.describe(wake.microphone)),
            "assistant_phase": .string(Self.describe(snapshot.phase as FridayAssistant.AssistantPhase)), "audio_injection": .bool(injectable != nil),
            "voice_session": .bool(snapshot.inVoiceSession), "conversation": .bool(snapshot.inConversation),
        ]
        if let pending = snapshot.pending { object["pending"] = .object(["question": .string(pending.question), "token": pending.token.map(JSONValue.string) ?? .null, "options": .array(pending.options.map(JSONValue.string))]) }
        if let engine = wake.engine { object["engine"] = .string(engine.id) }
        if let capture = wake.capture { object["input_device"] = .string(capture.deviceName); object["sample_rate"] = .double(capture.sampleRate) }
        if let notice = wake.notice { object["notice"] = .string(notice) }
        return .object(object)
    }

    // MARK: Helpers

    static func describe(_ state: ActivationState) -> String {
        switch state {
        case .initializing: return "initializing"
        case .listening: return "listening"
        case .verifying: return "verifying"
        case .wakeWordVerified: return "wake_word_verified"
        case .activated: return "activated"
        case .commandSession: return "command_session"
        case .paused(let reason): return "paused(\(reason))"
        case .error(let failure): return "error(\(failure.message))"
        }
    }

    static func describe(_ role: TranscriptItem.Role) -> String {
        switch role {
        case .user: return "user"
        case .assistant: return "assistant"
        case .system: return "system"
        case .step: return "step"
        }
    }

    static func describe(_ authorization: MicrophoneAuthorization) -> String {
        switch authorization {
        case .notDetermined: return "not_determined"
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        }
    }

    static func describe(_ phase: FridayAssistant.AssistantPhase) -> String {
        switch phase {
        case .idle: return "idle"
        case .listening(let partial): return partial.isEmpty ? "listening" : "listening(\(partial))"
        case .thinking: return "thinking"
        case .acting(let step): return "acting(\(step))"
        case .speaking: return "speaking"
        case .waiting(let what): return "waiting(\(what))"
        case .error(let message): return "error(\(message))"
        }
    }

    static func latencyJSON(_ report: LatencyReport?) async -> JSONValue? {
        guard let report, let data = try? JSONEncoder().encode(report) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func seconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
