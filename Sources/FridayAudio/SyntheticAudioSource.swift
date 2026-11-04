import Foundation
import WakeWordKit

/// A capture source that needs no microphone.
///
/// * **Manual mode** (tests): audio is pushed explicitly and delivered synchronously on the
///   caller's thread with a deterministic timeline, so the whole stack can be stepped through
///   deterministically. Failures, route changes and interruptions can be injected.
/// * **Real-time mode** (benchmarks, `--synthetic-audio` development runs): a timer thread
///   generates a configurable signal at the pace of a real microphone.
public final class SyntheticAudioSource: AudioCaptureSource, @unchecked Sendable {
    public enum Signal: Sendable, Equatable {
        case silence
        case whiteNoise(amplitude: Float)
        case tone(frequency: Double, amplitude: Float)
    }

    private struct State {
        var handler: AudioChunkHandler?
        var isRunning = false
        var timeline = HostTime.now
        var signal = Signal.silence
        var phase = 0.0
        var noise = SplitMix(seed: 7)
        var timer: DispatchSourceTimer?
        var startCount = 0
        var stopCount = 0
        var selections: [AudioInputSelection] = []
        var startErrors: [AudioCaptureError] = []
        var startFailures: [AudioInputSelection: AudioCaptureError] = [:]
    }

    public let sampleRate: Double
    private let state = Protected(State())
    /// Held while a handler call is in progress, so `stop()` can wait for it — the same guarantee a real
    /// capture gives: once `stop()` returns, the handler is never called again. Recursive so a handler that
    /// stops the capture from inside its own callback cannot deadlock itself.
    private let delivery = NSRecursiveLock()
    private let broadcaster = Broadcaster<AudioCaptureEvent>()
    private let queue = DispatchQueue(label: "jarvis.audio.synthetic", qos: .userInitiated)

    public init(sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
    }

    deinit { stop() }

    // MARK: AudioCaptureSource

    public var isRunning: Bool { state.withLock { $0.isRunning } }

    public func events() -> AsyncStream<AudioCaptureEvent> { broadcaster.stream() }

    @discardableResult
    public func start(input: AudioInputSelection, handler: @escaping AudioChunkHandler) throws(AudioCaptureError) -> AudioCaptureInfo {
        stop()
        let failure: AudioCaptureError? = state.withLock { state in
            state.startCount += 1
            state.selections.append(input)
            if !state.startErrors.isEmpty { return state.startErrors.removeFirst() }
            return state.startFailures[input]
        }
        if let failure { throw failure }
        state.withLock {
            $0.handler = handler
            $0.isRunning = true
            $0.timeline = .now   // anchored to the real clock so measured latencies are meaningful
        }
        return AudioCaptureInfo(deviceName: "Synthetic microphone", deviceUID: nil, sampleRate: sampleRate, channelCount: 1)
    }

    public func stop() {
        let timer = state.withLock { state -> DispatchSourceTimer? in
            if state.isRunning { state.stopCount += 1 }
            state.isRunning = false
            state.handler = nil
            let timer = state.timer
            state.timer = nil
            return timer
        }
        timer?.cancel()
        // Wait out a delivery that was already under way (a later one finds the capture stopped).
        delivery.lock()
        delivery.unlock()
    }

    // MARK: Manual mode

    public var startCount: Int { state.withLock { $0.startCount } }
    public var stopCount: Int { state.withLock { $0.stopCount } }
    public var selections: [AudioInputSelection] { state.withLock { $0.selections } }

    /// The next `start` calls fail with these errors, in order.
    public func failNextStarts(with errors: [AudioCaptureError]) {
        state.withLock { $0.startErrors = errors }
    }

    /// Every `start` that selects `input` fails with `error` until this is called again with `nil` — a microphone
    /// that never works, however often it is tried. (Scripted `failNextStarts` errors are used up first.)
    public func failStarts(selecting input: AudioInputSelection, with error: AudioCaptureError?) {
        state.withLock { $0.startFailures[input] = error }
    }

    /// Delivers `samples` to the running handler (if any) and advances the timeline.
    public func push(_ samples: [Float]) {
        delivery.lock()
        defer { delivery.unlock() }
        let next = state.withLock { state -> (AudioChunkHandler, HostTime)? in
            guard state.isRunning, let handler = state.handler else { return nil }
            let time = state.timeline
            state.timeline = time.advanced(bySeconds: Double(samples.count) / sampleRate)
            return (handler, time)
        }
        guard let (handler, time) = next else { return }
        samples.withUnsafeBufferPointer { handler($0, sampleRate, time) }
    }

    /// Pushes `seconds` of the current signal in 100 ms chunks.
    public func push(seconds: Double, chunkDuration: Double = 0.1) {
        var remaining = seconds
        while remaining > 1e-9 {
            let duration = min(chunkDuration, remaining)
            push(makeChunk(count: Int((duration * sampleRate).rounded())))
            remaining -= duration
        }
    }

    public func setSignal(_ signal: Signal) {
        state.withLock { $0.signal = signal }
    }

    public func simulateConfigurationChange() {
        stop()
        broadcaster.send(.configurationChanged)
    }

    public func simulateInterruption(_ reason: String = "simulated") {
        stop()
        broadcaster.send(.interrupted(reason: reason))
    }

    // MARK: Real-time mode

    /// Generates the current signal at real-time pace until stopped. Call after `start`.
    public func beginRealTimeGeneration(chunkDuration: Double = 0.1) {
        // Chunk k covers [start + k·d, start + (k+1)·d) and is delivered when it ends, like a microphone buffer.
        state.withLock { $0.timeline = .now }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + chunkDuration, repeating: chunkDuration, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.push(self.makeChunk(count: Int((chunkDuration * self.sampleRate).rounded())))
        }
        let previous = state.withLock { state -> DispatchSourceTimer? in
            let previous = state.timer
            state.timer = timer
            return previous
        }
        previous?.cancel()
        timer.resume()
    }

    // MARK: Signal generation

    private func makeChunk(count: Int) -> [Float] {
        state.withLock { state in
            var chunk = [Float](repeating: 0, count: count)
            switch state.signal {
            case .silence:
                break
            case .whiteNoise(let amplitude):
                for index in 0..<count {
                    chunk[index] = amplitude * (Float(state.noise.next() % 20_001) / 10_000 - 1)
                }
            case .tone(let frequency, let amplitude):
                let step = 2 * Double.pi * frequency / sampleRate
                for index in 0..<count {
                    chunk[index] = amplitude * Float(sin(state.phase))
                    state.phase += step
                    if state.phase > 2 * Double.pi { state.phase -= 2 * Double.pi }
                }
            }
            return chunk
        }
    }
}

/// Small deterministic generator so noise-based tests are repeatable.
struct SplitMix: Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
